defmodule Clementine.LLM.Anthropic do
  @moduledoc """
  Anthropic API client for Claude models.

  This module provides direct HTTP communication with Anthropic's Messages API,
  supporting both synchronous and streaming requests.

  ## Configuration

  Configure the API key in your config:

      config :clementine,
        api_key: {:system, "ANTHROPIC_API_KEY"}  # or a literal string

  ## Models

  Configure model mappings:

      config :clementine, :models,
        claude_sonnet: [
          provider: :anthropic,
          model: "claude-sonnet-4-20250514",
          max_tokens: 8192
        ]

  """

  @behaviour Clementine.LLM.ClientBehaviour

  alias Clementine.LLM.StreamParser
  alias Clementine.Tool

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

    delay = base_delay * :math.pow(2, attempt - 1) |> round()
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
  - `{:input_json_delta, json_chunk}`
  - `{:content_block_stop, index}`
  - `{:message_delta, delta, usage}`
  - `{:message_stop}`
  - `{:error, reason}` on errors
  """
  @impl true
  def stream(model, system, messages, tools, opts \\ []) do
    body = build_body(model, system, messages, tools, opts) |> Map.put("stream", true)
    headers = build_headers()
    parent = self()
    ref = make_ref()

    # Spawn a process to make the request and send chunks back
    pid = spawn_link(fn -> do_stream_request(body, headers, parent, ref) end)

    Stream.resource(
      fn -> {ref, pid, StreamParser.new()} end,
      &receive_chunk/1,
      fn
        {_ref, pid, _parser} ->
          Process.unlink(pid)
          Process.exit(pid, :shutdown)

        {:halting, pid} ->
          Process.unlink(pid)
          Process.exit(pid, :shutdown)

        _ ->
          :ok
      end
    )
  end

  defp do_stream_request(body, headers, parent, ref) do
    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)
    do_stream_request(body, headers, parent, ref, max_attempts, 1)
  end

  defp do_stream_request(body, headers, parent, ref, max_attempts, attempt) do
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

    result = Req.post(base_url(),
      json: body,
      headers: headers,
      into: callback,
      receive_timeout: 300_000
    )

    case result do
      {:ok, %{status: 200}} ->
        send(parent, {ref, :done})

      {:ok, %{status: status}} when status in [429, 529] and attempt < max_attempts ->
        # HTTP-level rate limit / overload. Any data that flowed through the
        # callback was the JSON error body, not SSE events — safe to retry.
        send(parent, {ref, :retry_reset})
        Process.sleep(calculate_backoff(attempt))
        do_stream_request(body, headers, parent, ref, max_attempts, attempt + 1)

      {:ok, %{status: status, body: resp_body}} ->
        send(parent, {ref, {:error, {:api_error, status, resp_body}}})

      {:error, reason} when attempt < max_attempts ->
        if :atomics.get(data_sent, 1) == 0 do
          # No data was streamed — connection failed before any response.
          send(parent, {ref, :retry_reset})
          Process.sleep(calculate_backoff(attempt))
          do_stream_request(body, headers, parent, ref, max_attempts, attempt + 1)
        else
          # Data already streamed to consumer — retrying would duplicate events.
          send(parent, {ref, {:error, {:request_failed, reason}}})
        end

      {:error, reason} ->
        send(parent, {ref, {:error, {:request_failed, reason}}})
    end
  end

  defp receive_chunk({ref, pid, parser}) do
    receive do
      {^ref, {:data, data}} ->
        {events, new_parser} = StreamParser.parse(parser, data)
        {events, {ref, pid, new_parser}}

      {^ref, :retry_reset} ->
        {[], {ref, pid, StreamParser.new()}}

      {^ref, :done} ->
        {:halt, :done}

      {^ref, {:error, reason}} ->
        {[{:error, reason}], {:halting, pid}}
    after
      300_000 ->
        {[{:error, :timeout}], {:halting, pid}}
    end
  end

  # After emitting an error event, halt the stream on the next call.
  # Keeps pid accessible so the cleanup function can terminate it.
  defp receive_chunk({:halting, pid}) do
    {:halt, {:halting, pid}}
  end

  defp base_url do
    Application.get_env(:clementine, :anthropic_base_url, "https://api.anthropic.com/v1/messages")
  end

  # Build the request body
  defp build_body(model, system, messages, tools, opts) do
    model_config = get_model_config(model)
    model_id = Keyword.fetch!(model_config, :model)
    max_tokens = Keyword.get(opts, :max_tokens, Keyword.get(model_config, :max_tokens, @default_max_tokens))

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
    case Application.get_env(:clementine, :api_key) do
      {:system, env_var} -> System.get_env(env_var) || raise "Missing #{env_var} environment variable"
      key when is_binary(key) -> key
      nil -> raise "Missing :api_key configuration for :clementine"
    end
  end

  defp get_model_config(model) when is_atom(model) do
    models = Application.get_env(:clementine, :models, %{})

    case Keyword.get(models, model) do
      nil -> raise "Unknown model: #{inspect(model)}. Configure it in :clementine, :models"
      config -> config
    end
  end

  defp format_messages(messages) do
    Enum.map(messages, &format_message/1)
  end

  defp format_message(%{role: role, content: content}) when is_binary(content) do
    %{"role" => to_string(role), "content" => content}
  end

  defp format_message(%{role: role, content: content}) when is_list(content) do
    %{"role" => to_string(role), "content" => Enum.map(content, &format_content_block/1)}
  end

  defp format_message(%{"role" => _, "content" => _} = msg), do: msg

  defp format_content_block(%{type: :text, text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp format_content_block(%{type: :tool_use, id: id, name: name, input: input}) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp format_content_block(%{type: :tool_result, tool_use_id: id, content: content} = block) do
    result = %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
    if Map.get(block, :is_error), do: Map.put(result, "is_error", true), else: result
  end

  defp format_content_block(%{"type" => _} = block), do: block

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      schema = Tool.to_anthropic_format(tool)

      %{
        "name" => schema.name,
        "description" => schema.description,
        "input_schema" => schema.input_schema
      }
    end)
  end

  defp parse_response(%{"content" => content, "stop_reason" => stop_reason} = body) do
    %{
      content: Enum.map(content, &parse_content_block/1),
      stop_reason: stop_reason,
      usage: Map.get(body, "usage", %{})
    }
  end

  defp parse_content_block(%{"type" => "text", "text" => text}) do
    %{type: :text, text: text}
  end

  defp parse_content_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %{type: :tool_use, id: id, name: name, input: input}
  end
end
