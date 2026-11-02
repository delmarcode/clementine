defmodule Clementine.LLM.ChatCompletions do
  @moduledoc """
  OpenAI Chat Completions dialect client for OpenAI-compatible providers.

  One wire dialect covers every lane the open-model ecosystem serves
  fine-tunes through. A model the app declares under
  `config :clementine, :models` names its platform, and the platform
  picks the endpoint and credentials:

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

  A declared model's platform entry may carry `base_url:` and `api_key:`
  (`platforms: [openai_compatible: [base_url: ..., api_key: ...]]`),
  which override the platform's app config. API keys accept a literal
  string, `{:system, "ENV_VAR"}`, or `{module, function, args}` resolved
  per request — the MFA form suits short-lived credentials like Vertex
  OAuth tokens:

      config :clementine,
        vertex_access_token: {MyApp.GcpAuth, :access_token, []}

  `base_url` follows the OpenAI SDK convention: the client appends
  `/chat/completions`.

  A JSON schema in the `:output_schema` request option goes as the
  dialect's `response_format` (`{"type": "json_schema", "json_schema":
  {"name": "output", "schema": ..., "strict": true}}`). Support varies
  by server and model: one without structured outputs may refuse the
  request or ignore the field, and an answer that does not match then
  fails the run (`Clementine.OutputSchema`). A server that enforces the
  format over the whole completion with a grammar (vLLM, SGLang, Ollama,
  and llama.cpp may) leaves the model no way to call a tool, so the
  agent answers at once without its tools and nothing fails. So
  `response_format` goes only to a model whose sheet says
  `features: [structured_outputs: true]`; for any other, the agent's
  instructions describe the answer, and the engine still checks it.

  A refusal (`delta.refusal`, or `message.refusal` on `call/5`) arrives
  as the turn's text with stop reason `"refusal"`.

  Prompt caching: a model whose sheet offers `cache_control` TTLs
  (`cache: [ttls: [:five_minutes, :one_hour]]`, a Claude model on
  OpenRouter or behind a proxy) gets a `cache_control` content part on
  the system prompt and the top-level `cache_control` for the
  conversation's tail. OpenRouter also gets the run's `prompt_cache_key`,
  which it uses for sticky routing. Other servers cache prefixes on their
  own; with `cache: false`, a model offering `prompt_cache_options` TTLs
  gets `mode: "explicit"`, which turns that off. A stream
  asks for usage with `stream_options.include_usage`, and usage reads
  `prompt_tokens_details.cached_tokens` and `cache_write_tokens` wherever
  the server reports them.
  """

  @behaviour Clementine.LLM.ClientBehaviour

  alias Clementine.Model
  alias Clementine.LLM.{Cache, Policy, ProviderUsage}
  alias Clementine.LLM.ChatCompletions.{Messages, Tools}
  alias Clementine.LLM.ChatCompletionsStreamParser
  alias Clementine.LLM.ProviderStream
  alias Clementine.LLM.Reasoning
  alias Clementine.LLM.Response

  @platforms [:openrouter, :bedrock, :vertex, :openai_compatible]
  @retriable_statuses [429, 500, 502, 503, 504]

  @doc """
  Makes a synchronous Chat Completions call.
  """
  @impl true
  def call(model, system, messages, tools, opts \\ []) do
    resolved = policy!(model, opts, stream: false)
    body = build_body(resolved, system, messages, tools, opts)
    headers = build_headers(resolved)
    url = request_url(resolved)

    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)

    case do_call_with_retry(url, body, headers, max_attempts, 1) do
      {:ok, resp_body} -> {:ok, parse_response(resp_body, usage_meta(resolved))}
      error -> error
    end
  end

  defp do_call_with_retry(url, body, headers, max_attempts, attempt) do
    case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, resp_body}

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
    resolved = policy!(model, opts, stream: true)

    # Usage arrives in the stream's last chunk only when asked for.
    body =
      resolved
      |> build_body(system, messages, tools, opts)
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})

    headers = build_headers(resolved)
    url = request_url(resolved)
    # A runner caps this to the execution deadline's remaining budget. It
    # bounds the whole streaming call, not one attempt: per-attempt receive
    # timeout and retry backoff draw down the same window, and retries stop
    # once it is spent.
    receive_timeout = Keyword.get(opts, :receive_timeout, 300_000)
    budget_ends = System.monotonic_time(:millisecond) + receive_timeout

    parser = ChatCompletionsStreamParser.new(usage_meta(resolved))

    ProviderStream.new({ChatCompletionsStreamParser, parser}, fn parent, ref ->
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

  defp build_body(%Policy{} = policy, system, messages, tools, opts) do
    body =
      %{
        "model" => Model.platform_id(policy.model),
        "messages" => encode_messages(system, messages, policy.cache),
        "max_tokens" => policy.max_tokens
      }
      |> Map.merge(Reasoning.chat_completions(policy))
      |> maybe_put_output_schema(policy.model, Keyword.get(opts, :output_schema))
      |> put_cache(policy, Keyword.get(opts, :cache_key))

    if is_list(tools) and tools != [] do
      body
      |> Map.put("tools", Tools.encode_all(tools))
      |> Map.put("tool_choice", "auto")
    else
      body
    end
  end

  defp encode_messages(system, messages, cache) do
    encoded = Messages.encode_all(messages)

    if is_binary(system) and system != "" do
      [%{"role" => "system", "content" => system_content(system, cache)} | encoded]
    else
      encoded
    end
  end

  # With markers, the system prompt ends in a cache_control breakpoint,
  # the stable prefix every run of the agent shares, as Anthropic's
  # Messages API takes it (OpenRouter passes it through).
  defp system_content(system, %{enabled: true, markers: true} = cache) do
    [%{"type" => "text", "text" => system, "cache_control" => Cache.cache_control(cache)}]
  end

  defp system_content(system, _cache), do: system

  # Markers end with the top-level automatic breakpoint, which follows
  # the conversation's tail (OpenRouter documents it for Claude on every
  # provider that serves it). OpenRouter routes a user's requests to one
  # provider by prompt_cache_key; no other Chat Completions provider is
  # sent one, since a strict server may refuse a field it does not know.
  # With caching off, a model offering prompt_cache_options TTLs gets
  # explicit mode and no breakpoints, which turns its implicit caching and
  # its write charge off; nothing else can be turned off.
  defp put_cache(body, %Policy{cache: %{enabled: false}, model: model}, _key) do
    if Model.cache_mechanism(model.cache.ttls) == :options,
      do: Map.put(body, "prompt_cache_options", %{"mode" => "explicit"}),
      else: body
  end

  defp put_cache(body, %Policy{cache: cache, platform: platform}, key) do
    body =
      if cache.markers,
        do: Map.put(body, "cache_control", Cache.cache_control(cache)),
        else: body

    if platform == :openrouter and key, do: Map.put(body, "prompt_cache_key", key), else: body
  end

  # A grammar-enforcing server would take the model's tools away, so the
  # format goes only where the sheet says the model has structured
  # outputs; elsewhere the instructions describe the answer.
  defp maybe_put_output_schema(body, _model, nil), do: body

  defp maybe_put_output_schema(body, %Model{features: %{structured_outputs: true}}, schema) do
    Map.put(body, "response_format", %{
      "type" => "json_schema",
      "json_schema" => %{"name" => "output", "schema" => schema, "strict" => true}
    })
  end

  defp maybe_put_output_schema(body, _model, _schema), do: body

  defp build_headers(resolved) do
    case api_key(resolved) do
      nil -> [{"content-type", "application/json"}]
      key -> [{"authorization", "Bearer #{key}"}, {"content-type", "application/json"}]
    end
  end

  defp request_url(%Policy{} = policy) do
    base_url = endpoint(policy, :base_url) || provider_base_url(policy.platform)
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

  defp api_key(%Policy{platform: platform} = policy) do
    configured =
      endpoint(policy, :api_key) || Application.get_env(:clementine, api_key_config(platform))

    case resolve_credential(configured) do
      key when is_binary(key) and key != "" ->
        key

      nil when platform == :openai_compatible ->
        nil

      _ ->
        raise "Missing #{inspect(api_key_config(platform))} configuration for :clementine"
    end
  end

  # A declared model's platform entry may name its own endpoint.
  defp endpoint(%Policy{model: model, platform: platform}, key) do
    model.platforms |> Keyword.get(platform, %{}) |> Map.get(key)
  end

  @doc false
  # The app config key that holds a platform's credential.
  def api_key_config(:openrouter), do: :openrouter_api_key
  def api_key_config(:bedrock), do: :bedrock_api_key
  def api_key_config(:vertex), do: :vertex_access_token
  def api_key_config(:openai_compatible), do: :openai_compatible_api_key

  defp resolve_credential({:system, env_var}) when is_binary(env_var) do
    System.get_env(env_var)
  end

  defp resolve_credential({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
  end

  defp resolve_credential(key) when is_binary(key), do: key
  defp resolve_credential(_), do: nil

  defp policy!(model, opts, checks) do
    policy = Policy.resolve!(model, opts, checks)

    unless policy.platform in @platforms do
      raise ArgumentError,
            "#{inspect(model)} goes to #{inspect(policy.platform)}, not a Chat Completions " <>
              "platform (#{inspect(@platforms)})"
    end

    policy
  end

  defp usage_meta(%Policy{} = policy), do: %{provider: policy.platform, model: policy.model.id}

  defp parse_response(%{"choices" => [choice | _]} = body, usage_meta) do
    message = Map.get(choice, "message", %{})
    content = Messages.decode_message(message)

    stop_reason =
      case message do
        %{"refusal" => refusal} when is_binary(refusal) and refusal != "" -> "refusal"
        _ -> stop_reason(Map.get(choice, "finish_reason"), content)
      end

    %Response{
      content: content,
      stop_reason: stop_reason,
      usage: ProviderUsage.chat_completions(Map.get(body, "usage"), usage_meta)
    }
  end

  defp parse_response(body, usage_meta) when is_map(body) do
    %Response{
      content: [],
      stop_reason: nil,
      usage: ProviderUsage.chat_completions(Map.get(body, "usage"), usage_meta)
    }
  end

  defp stop_reason(reason, _content) when is_binary(reason),
    do: Clementine.LLM.ChatCompletionsStreamParser.stop_reason(reason)

  defp stop_reason(_reason, content) do
    if Enum.any?(content, &match?(%Clementine.LLM.Message.Content.ToolUse{}, &1)) do
      "tool_use"
    else
      "end_turn"
    end
  end
end
