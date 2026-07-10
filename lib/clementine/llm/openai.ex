defmodule Clementine.LLM.OpenAI do
  @moduledoc """
  OpenAI Responses API client.

  Supports synchronous and streaming requests, including tool calls.
  """

  @behaviour Clementine.LLM.ClientBehaviour

  alias Clementine.LLM.ModelRegistry
  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Reasoning
  alias Clementine.LLM.ProviderStream
  alias Clementine.LLM.OpenAI.{Messages, Tools}
  alias Clementine.LLM.OpenAIStreamParser
  alias Clementine.LLM.Response

  @default_max_output_tokens 8192
  @retriable_statuses [429, 500, 502, 503, 504]

  @doc """
  Makes a synchronous call to the OpenAI Responses API.
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

      {:ok, %{status: status}} when status in @retriable_statuses and attempt < max_attempts ->
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

  @doc """
  Makes a streaming call to the OpenAI Responses API.
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

    ProviderStream.new(OpenAIStreamParser, fn parent, ref ->
      do_stream_request(body, headers, parent, ref, budget_ends)
    end)
  end

  defp do_stream_request(body, headers, parent, ref, budget_ends) do
    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)
    do_stream_request(body, headers, parent, ref, budget_ends, max_attempts, 1)
  end

  defp do_stream_request(body, headers, parent, ref, budget_ends, max_attempts, attempt) do
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
      when status in @retriable_statuses and attempt < max_attempts ->
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
    Application.get_env(:clementine, :openai_base_url, "https://api.openai.com/v1/responses")
  end

  defp calculate_backoff(attempt) do
    retry_opts = Application.get_env(:clementine, :retry, [])
    base_delay = Keyword.get(retry_opts, :base_delay, 1000)
    max_delay = Keyword.get(retry_opts, :max_delay, 30_000)

    delay = (base_delay * :math.pow(2, attempt - 1)) |> round()
    min(delay, max_delay)
  end

  defp build_body(model, system, messages, tools, opts) do
    resolved = resolve_model(model)
    model_id = resolved.id

    max_output_tokens =
      Keyword.get(
        opts,
        :max_output_tokens,
        Keyword.get(
          opts,
          :max_tokens,
          Keyword.get(
            resolved.defaults,
            :max_output_tokens,
            Keyword.get(resolved.defaults, :max_tokens, @default_max_output_tokens)
          )
        )
      )

    body = %{
      "model" => model_id,
      "input" => format_messages(messages),
      "max_output_tokens" => max_output_tokens
    }

    body = maybe_put_reasoning(body, Keyword.get(opts, :reasoning, resolved.reasoning))

    body =
      if is_binary(system) and system != "" do
        Map.put(body, "instructions", system)
      else
        body
      end

    if is_list(tools) and tools != [] do
      body
      |> Map.put("tools", format_tools(tools))
      |> Map.put("tool_choice", "auto")
    else
      body
    end
  end

  defp maybe_put_reasoning(body, nil), do: body

  defp maybe_put_reasoning(body, reasoning) do
    Map.merge(body, Reasoning.to_provider_config!(:openai, reasoning))
  end

  defp build_headers do
    [
      {"authorization", "Bearer #{get_api_key()}"},
      {"content-type", "application/json"}
    ]
  end

  defp get_api_key do
    key = resolve_api_key(Application.get_env(:clementine, :openai_api_key))

    case key do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        raise "Missing :openai_api_key configuration for :clementine"
    end
  end

  defp resolve_api_key({:system, env_var}) when is_binary(env_var), do: System.get_env(env_var)
  defp resolve_api_key(key) when is_binary(key), do: key
  defp resolve_api_key(_), do: nil

  defp resolve_model(model_ref) do
    resolved = ModelRegistry.resolve!(model_ref)

    if resolved.provider != :openai do
      raise "Model #{inspect(model_ref)} is configured for provider #{inspect(resolved.provider)}, not :openai"
    end

    resolved
  end

  defp format_messages(messages) do
    Messages.encode_all(messages)
  end

  defp format_tools(tools) do
    Tools.encode_all(tools)
  end

  defp parse_response(%{"output" => output} = body) when is_list(output) do
    content = Messages.decode_output_items(output)

    stop_reason =
      if Enum.any?(content, &match?(%Content.ToolUse{}, &1)) do
        "tool_use"
      else
        "end_turn"
      end

    %Response{
      content: content,
      stop_reason: stop_reason,
      usage: Map.get(body, "usage", %{}) || %{}
    }
  end

  defp parse_response(body) when is_map(body) do
    %Response{
      content: [],
      stop_reason: nil,
      usage: Map.get(body, "usage", %{}) || %{}
    }
  end
end
