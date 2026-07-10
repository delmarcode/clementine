defmodule Clementine.LLM.ChatCompletions do
  @moduledoc """
  OpenAI Chat Completions dialect client for OpenAI-compatible providers.

  One wire dialect covers every lane the open-model ecosystem serves
  fine-tunes through; the provider atom picks the endpoint and credentials:

  - `:openrouter` — `https://openrouter.ai/api/v1` with
    `config :clementine, openrouter_api_key: ...`. Model ids are
    OpenRouter's `vendor/model` slugs (e.g. `"deepseek/deepseek-v3.2"`,
    `"qwen/qwen3-235b-a22b"`, `"z-ai/glm-4.7"`).
  - `:bedrock` — Amazon Bedrock's Chat Completions endpoint,
    `https://bedrock-mantle.{region}.api.aws/v1`, built from
    `config :clementine, bedrock_region: ...` (or set
    `bedrock_base_url` directly, e.g. to use `bedrock-runtime`).
    Authenticates with `bedrock_api_key` — an Amazon Bedrock API key
    (bearer token), no SigV4 required.
  - `:vertex` — Google Vertex AI's OpenAI-compatible MaaS endpoint,
    built from `vertex_project` and `vertex_region` (or set
    `vertex_base_url` directly). Authenticates with `vertex_access_token`;
    tokens are short-lived, so hosts typically configure an MFA tuple
    (see below). Model ids are `publisher/model` (e.g.
    `"deepseek-ai/deepseek-v3.2-maas"`, `"zai/glm-4.7-maas"`).
  - `:openai_compatible` — any other OpenAI-compatible server: Tinker's
    inference endpoint, Together, Fireworks, or self-hosted vLLM/SGLang.
    Set `base_url:` (and optionally `api_key:`) per model, or
    `config :clementine, openai_compatible_base_url: ...` app-wide.
    `api_key` is optional — keyless local servers send no auth header.

  Per-model `base_url:`/`api_key:` catalog entries override the provider
  app config. API keys accept a literal string, `{:system, "ENV_VAR"}`, or
  `{module, function, args}` resolved per request — the MFA form suits
  short-lived credentials like Vertex OAuth tokens:

      config :clementine,
        vertex_access_token: {MyApp.GcpAuth, :access_token, []}

  `base_url` follows the OpenAI SDK convention: the client appends
  `/chat/completions`.
  """

  @behaviour Clementine.LLM.ClientBehaviour

  alias Clementine.LLM.ModelRegistry
  alias Clementine.LLM.ChatCompletions.{Messages, Tools}
  alias Clementine.LLM.ChatCompletionsStreamParser
  alias Clementine.LLM.ProviderStream
  alias Clementine.LLM.Reasoning
  alias Clementine.LLM.Response

  @providers [:openrouter, :bedrock, :vertex, :openai_compatible]
  @default_max_tokens 8192
  @retriable_statuses [429, 500, 502, 503, 504]

  @doc """
  Makes a synchronous Chat Completions call.
  """
  @impl true
  def call(model, system, messages, tools, opts \\ []) do
    resolved = resolve_model(model)
    body = build_body(resolved, system, messages, tools, opts)
    headers = build_headers(resolved)
    url = request_url(resolved)

    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)

    do_call_with_retry(url, body, headers, max_attempts, 1)
  end

  defp do_call_with_retry(url, body, headers, max_attempts, attempt) do
    case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, parse_response(resp_body)}

      {:ok, %{status: status}} when status in @retriable_statuses and attempt < max_attempts ->
        Process.sleep(calculate_backoff(attempt))
        do_call_with_retry(url, body, headers, max_attempts, attempt + 1)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, _reason} when attempt < max_attempts ->
        Process.sleep(calculate_backoff(attempt))
        do_call_with_retry(url, body, headers, max_attempts, attempt + 1)

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Makes a streaming Chat Completions call.
  """
  @impl true
  def stream(model, system, messages, tools, opts \\ []) do
    resolved = resolve_model(model)

    body =
      resolved
      |> build_body(system, messages, tools, opts)
      |> Map.put("stream", true)

    headers = build_headers(resolved)
    url = request_url(resolved)
    # A runner caps this to the execution deadline's remaining budget. It
    # bounds the whole streaming call, not one attempt: per-attempt receive
    # timeout and retry backoff draw down the same window, and retries stop
    # once it is spent.
    receive_timeout = Keyword.get(opts, :receive_timeout, 300_000)
    budget_ends = System.monotonic_time(:millisecond) + receive_timeout

    ProviderStream.new(ChatCompletionsStreamParser, fn parent, ref ->
      do_stream_request(url, body, headers, parent, ref, budget_ends)
    end)
  end

  defp do_stream_request(url, body, headers, parent, ref, budget_ends) do
    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)
    do_stream_request(url, body, headers, parent, ref, budget_ends, max_attempts, 1)
  end

  defp do_stream_request(url, body, headers, parent, ref, budget_ends, max_attempts, attempt) do
    data_sent = :atomics.new(1, signed: false)

    callback = fn {:data, data}, {req, resp} ->
      :atomics.put(data_sent, 1, 1)
      send(parent, {ref, {:data, data}})
      {:cont, {req, accumulate_error_body(resp, data)}}
    end

    result =
      Req.post(url,
        json: body,
        headers: headers,
        into: callback,
        decode_body: false,
        receive_timeout: remaining_budget(budget_ends)
      )

    case result do
      {:ok, %{status: 200}} ->
        send(parent, {ref, :done})

      {:ok, %{status: status, body: resp_body}}
      when status in @retriable_statuses and attempt < max_attempts ->
        retry_stream(
          url,
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
            url,
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

  # Chunks of a non-200 response are the provider's error body, not SSE:
  # the parser ignores them, and the response Req hands back would
  # otherwise carry an empty body. Keep them so the api_error clauses
  # report the provider's actual message, as a raw string — the request
  # sets decode_body: false because Req decoding the accumulated JSON
  # would turn a malformed error body into a Jason.DecodeError that masks
  # the HTTP status. A 200 body is never buffered — the parser consumes
  # it as it streams.
  defp accumulate_error_body(%{status: 200} = resp, _data), do: resp
  defp accumulate_error_body(resp, data), do: %{resp | body: resp.body <> data}

  # A retry draws down the same budget as the attempt it follows: the
  # backoff sleep is capped to what remains, and a spent budget sends the
  # failure instead of retrying — a runner-capped stream must not outlive
  # its deadline by sleeping.
  defp retry_stream(url, body, headers, parent, ref, budget_ends, max_attempts, attempt, fail) do
    remaining = remaining_budget(budget_ends)

    if remaining > 0 do
      send(parent, {ref, :retry_reset})
      Process.sleep(min(calculate_backoff(attempt), remaining))
      do_stream_request(url, body, headers, parent, ref, budget_ends, max_attempts, attempt + 1)
    else
      send(parent, {ref, fail})
    end
  end

  defp remaining_budget(budget_ends) do
    max(budget_ends - System.monotonic_time(:millisecond), 0)
  end

  defp calculate_backoff(attempt) do
    retry_opts = Application.get_env(:clementine, :retry, [])
    base_delay = Keyword.get(retry_opts, :base_delay, 1000)
    max_delay = Keyword.get(retry_opts, :max_delay, 30_000)

    delay = (base_delay * :math.pow(2, attempt - 1)) |> round()
    min(delay, max_delay)
  end

  defp build_body(resolved, system, messages, tools, opts) do
    max_tokens =
      Keyword.get(
        opts,
        :max_tokens,
        Keyword.get(
          opts,
          :max_output_tokens,
          Keyword.get(
            resolved.defaults,
            :max_tokens,
            Keyword.get(resolved.defaults, :max_output_tokens, @default_max_tokens)
          )
        )
      )

    body = %{
      "model" => resolved.id,
      "messages" => encode_messages(system, messages),
      "max_tokens" => max_tokens
    }

    body =
      maybe_put_reasoning(
        body,
        resolved.provider,
        Keyword.get(opts, :reasoning, resolved.reasoning)
      )

    if is_list(tools) and tools != [] do
      body
      |> Map.put("tools", Tools.encode_all(tools))
      |> Map.put("tool_choice", "auto")
    else
      body
    end
  end

  defp encode_messages(system, messages) do
    encoded = Messages.encode_all(messages)

    if is_binary(system) and system != "" do
      [%{"role" => "system", "content" => system} | encoded]
    else
      encoded
    end
  end

  defp maybe_put_reasoning(body, _provider, nil), do: body

  defp maybe_put_reasoning(body, provider, reasoning) do
    Map.merge(body, Reasoning.to_provider_config!(provider, reasoning))
  end

  defp build_headers(resolved) do
    case api_key(resolved) do
      nil -> [{"content-type", "application/json"}]
      key -> [{"authorization", "Bearer #{key}"}, {"content-type", "application/json"}]
    end
  end

  defp request_url(resolved) do
    base_url = resolved.base_url || provider_base_url(resolved.provider)
    String.trim_trailing(base_url, "/") <> "/chat/completions"
  end

  defp provider_base_url(:openrouter) do
    Application.get_env(:clementine, :openrouter_base_url, "https://openrouter.ai/api/v1")
  end

  defp provider_base_url(:bedrock) do
    case Application.get_env(:clementine, :bedrock_base_url) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        region = Application.get_env(:clementine, :bedrock_region)

        unless is_binary(region) and region != "" do
          raise "Missing :bedrock_base_url or :bedrock_region configuration for :clementine"
        end

        "https://bedrock-mantle.#{region}.api.aws/v1"
    end
  end

  defp provider_base_url(:vertex) do
    case Application.get_env(:clementine, :vertex_base_url) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        project = Application.get_env(:clementine, :vertex_project)
        region = Application.get_env(:clementine, :vertex_region)

        unless is_binary(project) and project != "" and is_binary(region) and region != "" do
          raise "Missing :vertex_base_url or :vertex_project/:vertex_region configuration " <>
                  "for :clementine"
        end

        "https://#{region}-aiplatform.googleapis.com/v1/projects/#{project}/locations/#{region}/endpoints/openapi"
    end
  end

  defp provider_base_url(:openai_compatible) do
    case Application.get_env(:clementine, :openai_compatible_base_url) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        raise "Missing :base_url in model config or :openai_compatible_base_url " <>
                "configuration for :clementine"
    end
  end

  defp api_key(resolved) do
    configured = resolved.api_key || Application.get_env(:clementine, api_key_config(resolved))

    case resolve_credential(configured) do
      key when is_binary(key) and key != "" ->
        key

      nil when resolved.provider == :openai_compatible ->
        nil

      _ ->
        raise "Missing #{inspect(api_key_config(resolved))} configuration for :clementine"
    end
  end

  defp api_key_config(%{provider: :openrouter}), do: :openrouter_api_key
  defp api_key_config(%{provider: :bedrock}), do: :bedrock_api_key
  defp api_key_config(%{provider: :vertex}), do: :vertex_access_token
  defp api_key_config(%{provider: :openai_compatible}), do: :openai_compatible_api_key

  defp resolve_credential({:system, env_var}) when is_binary(env_var) do
    System.get_env(env_var)
  end

  defp resolve_credential({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
  end

  defp resolve_credential(key) when is_binary(key), do: key
  defp resolve_credential(_), do: nil

  defp resolve_model(model_ref) do
    resolved = ModelRegistry.resolve!(model_ref)

    unless resolved.provider in @providers do
      raise "Model #{inspect(model_ref)} is configured for provider " <>
              "#{inspect(resolved.provider)}, not an OpenAI-compatible chat completions provider"
    end

    resolved
  end

  defp parse_response(%{"choices" => [choice | _]} = body) do
    message = Map.get(choice, "message", %{})
    content = Messages.decode_message(message)

    %Response{
      content: content,
      stop_reason: stop_reason(Map.get(choice, "finish_reason"), content),
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

  defp stop_reason("stop", _content), do: "end_turn"
  defp stop_reason("tool_calls", _content), do: "tool_use"
  defp stop_reason("length", _content), do: "max_tokens"
  defp stop_reason(reason, _content) when is_binary(reason), do: reason

  defp stop_reason(_reason, content) do
    if Enum.any?(content, &match?(%Clementine.LLM.Message.Content.ToolUse{}, &1)) do
      "tool_use"
    else
      "end_turn"
    end
  end
end
