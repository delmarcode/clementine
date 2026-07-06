defmodule Clementine.LLM.Anthropic do
  @moduledoc """
  Anthropic API client for Claude models.

  This module provides direct HTTP communication with Anthropic's Messages API,
  supporting both synchronous and streaming requests.

  ## Configuration

  Configure the API key in your config:

      config :clementine,
        anthropic_api_key: {:system, "ANTHROPIC_API_KEY"}  # or a literal string

  ## Models

  Configure model mappings:

      config :clementine, :models,
        claude_sonnet: [
          provider: :anthropic,
          id: "claude-sonnet-4-20250514",
          defaults: [max_tokens: 8192]
        ]

  """

  @behaviour Clementine.LLM.ClientBehaviour

  alias Clementine.LLM.ModelRegistry
  alias Clementine.LLM.Anthropic.{Messages, Tools}
  alias Clementine.LLM.ProviderStream
  alias Clementine.LLM.Response
  alias Clementine.LLM.StreamParser

  @anthropic_version "2023-06-01"
  @default_max_tokens 8192

  @doc """
  Makes a synchronous call to the Anthropic API.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @impl true
  def call(model, system, messages, tools, opts \\ []) do
    body = build_body(model, system, messages, tools, opts)
    headers = build_headers()

    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)

    do_call_with_retry(body, headers, max_attempts, 1)
  end

  defp do_call_with_retry(body, headers, max_attempts, attempt) do
    case Req.post(base_url(), json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, parse_response(resp_body)}

      {:ok, %{status: status}} when status in [429, 529] and attempt < max_attempts ->
        Process.sleep(calculate_backoff(attempt))
        do_call_with_retry(body, headers, max_attempts, attempt + 1)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, _reason} when attempt < max_attempts ->
        Process.sleep(calculate_backoff(attempt))
        do_call_with_retry(body, headers, max_attempts, attempt + 1)

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp calculate_backoff(attempt) do
    retry_opts = Application.get_env(:clementine, :retry, [])
    base_delay = Keyword.get(retry_opts, :base_delay, 1000)
    max_delay = Keyword.get(retry_opts, :max_delay, 30_000)

    delay = (base_delay * :math.pow(2, attempt - 1)) |> round()
    min(delay, max_delay)
  end

  @doc """
  Makes a streaming call to the Anthropic API.

  Returns a Stream that emits events as they arrive. The stream is lazy -
  events are only fetched when consumed.

  ## Events

  The stream emits tuples like:
  - `{:message_start, message_data}`
  - `{:text_delta, text}`
  - `{:tool_use_start, id, name}`
  - `{:input_json_delta, id, json_chunk}`
  - `{:content_block_stop, index}`
  - `{:message_delta, delta, usage}`
  - `{:message_stop}`
  - `{:error, reason}` on errors
  """
  @impl true
  def stream(model, system, messages, tools, opts \\ []) do
    body = build_body(model, system, messages, tools, opts) |> Map.put("stream", true)
    headers = build_headers()
    # A runner caps this to the execution deadline's remaining budget. It
    # bounds the whole streaming call, not one attempt: per-attempt receive
    # timeout and retry backoff draw down the same window, and retries stop
    # once it is spent.
    receive_timeout = Keyword.get(opts, :receive_timeout, 300_000)
    budget_ends = System.monotonic_time(:millisecond) + receive_timeout

    ProviderStream.new(StreamParser, fn parent, ref ->
      do_stream_request(body, headers, parent, ref, budget_ends)
    end)
  end

  defp do_stream_request(body, headers, parent, ref, budget_ends) do
    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)
    do_stream_request(body, headers, parent, ref, budget_ends, max_attempts, 1)
  end

  defp do_stream_request(body, headers, parent, ref, budget_ends, max_attempts, attempt) do
    # Track whether the into callback sent any data to the parent.
    # For 429/529 the callback fires with the error body (not real SSE),
    # which the parser ignores, so those retries are always safe.
    # For network errors ({:error, _}), data_sent distinguishes a
    # pre-connection failure (safe to retry) from a mid-stream disconnect
    # (data already emitted to the consumer — must not retry).
    data_sent = :atomics.new(1, signed: false)

    callback = fn {:data, data}, acc ->
      :atomics.put(data_sent, 1, 1)
      send(parent, {ref, {:data, data}})
      {:cont, acc}
    end

    result =
      Req.post(base_url(),
        json: body,
        headers: headers,
        into: callback,
        receive_timeout: remaining_budget(budget_ends)
      )

    case result do
      {:ok, %{status: 200}} ->
        send(parent, {ref, :done})

      {:ok, %{status: status, body: resp_body}}
      when status in [429, 529] and attempt < max_attempts ->
        # HTTP-level rate limit / overload. Any data that flowed through the
        # callback was the JSON error body, not SSE events — safe to retry.
        retry_stream(
          body,
          headers,
          parent,
          ref,
          budget_ends,
          max_attempts,
          attempt,
          {:error, {:api_error, status, resp_body}}
        )

      {:ok, %{status: status, body: resp_body}} ->
        send(parent, {ref, {:error, {:api_error, status, resp_body}}})

      {:error, reason} when attempt < max_attempts ->
        if :atomics.get(data_sent, 1) == 0 do
          # No data was streamed — connection failed before any response.
          retry_stream(
            body,
            headers,
            parent,
            ref,
            budget_ends,
            max_attempts,
            attempt,
            {:error, {:request_failed, reason}}
          )
        else
          # Data already streamed to consumer — retrying would duplicate events.
          send(parent, {ref, {:error, {:request_failed, reason}}})
        end

      {:error, reason} ->
        send(parent, {ref, {:error, {:request_failed, reason}}})
    end
  end

  # A retry draws down the same budget as the attempt it follows: the
  # backoff sleep is capped to what remains, and a spent budget sends the
  # failure instead of retrying — a runner-capped stream must not outlive
  # its deadline by sleeping.
  defp retry_stream(body, headers, parent, ref, budget_ends, max_attempts, attempt, fail_message) do
    remaining = remaining_budget(budget_ends)

    if remaining > 0 do
      send(parent, {ref, :retry_reset})
      Process.sleep(min(calculate_backoff(attempt), remaining))
      do_stream_request(body, headers, parent, ref, budget_ends, max_attempts, attempt + 1)
    else
      send(parent, {ref, fail_message})
    end
  end

  defp remaining_budget(budget_ends) do
    max(budget_ends - System.monotonic_time(:millisecond), 0)
  end

  defp base_url do
    Application.get_env(:clementine, :anthropic_base_url, "https://api.anthropic.com/v1/messages")
  end

  # Build the request body
  defp build_body(model, system, messages, tools, opts) do
    resolved = resolve_model(model)
    model_id = resolved.id

    max_tokens =
      Keyword.get(
        opts,
        :max_tokens,
        Keyword.get(resolved.defaults, :max_tokens, @default_max_tokens)
      )

    body = %{
      "model" => model_id,
      "max_tokens" => max_tokens,
      "messages" => format_messages(messages)
    }

    body =
      if system != nil and system != "" do
        Map.put(body, "system", system)
      else
        body
      end

    body =
      if tools != nil and tools != [] do
        Map.put(body, "tools", format_tools(tools))
      else
        body
      end

    body
  end

  defp build_headers do
    [
      {"x-api-key", get_api_key()},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]
  end

  defp get_api_key do
    key = resolve_api_key(Application.get_env(:clementine, :anthropic_api_key))

    case key do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        raise "Missing :anthropic_api_key configuration for :clementine"
    end
  end

  defp resolve_api_key({:system, env_var}) when is_binary(env_var), do: System.get_env(env_var)
  defp resolve_api_key(key) when is_binary(key), do: key
  defp resolve_api_key(_), do: nil

  defp resolve_model(model_ref) do
    resolved = ModelRegistry.resolve!(model_ref)

    if resolved.provider != :anthropic do
      raise "Model #{inspect(model_ref)} is configured for provider #{inspect(resolved.provider)}, not :anthropic"
    end

    resolved
  end

  defp format_messages(messages) do
    Messages.encode_all(messages)
  end

  defp format_tools(tools) do
    Tools.encode_all(tools)
  end

  defp parse_response(%{"content" => content, "stop_reason" => stop_reason} = body) do
    %Response{
      content: Enum.map(content, &parse_content_block/1),
      stop_reason: stop_reason,
      usage: Map.get(body, "usage", %{})
    }
  end

  defp parse_content_block(%{"type" => "text", "text" => text}) do
    Messages.decode_content(%{"type" => "text", "text" => text})
  end

  defp parse_content_block(%{"type" => "tool_use"} = block) do
    Messages.decode_content(block)
  end
end
