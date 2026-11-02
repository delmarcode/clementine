defmodule Clementine.LLM.OpenAI do
  @moduledoc """
  OpenAI Responses API client.

  Supports synchronous and streaming requests, including tool calls. A
  refusal is the turn's text, with stop reason `"refusal"`; a response
  cut off at `max_output_tokens` stops with `"max_tokens"`; one that ends
  `response.failed` is an error.

  A JSON schema in the `:output_schema` request option goes as the
  Responses API's Structured Outputs, `text.format` with
  `"type": "json_schema"` and `"strict": true`, which constrains the
  model's text answer to it; function calls are unaffected. Strict mode
  takes OpenAI's supported subset: every object needs
  `"additionalProperties": false` and lists all of its properties in
  `required` (an optional one is typed `["string", "null"]`), and the
  API refuses a schema outside it.

  A request names a model by its id (`"gpt-6.1-sol"`), and the client
  reads its sheet (`Clementine.Model`): `max_output_tokens`, the
  reasoning effort and summary (`Clementine.LLM.Reasoning`), and the
  cache TTLs, all checked against the agent's choices first
  (`Clementine.LLM.Policy`).

  Prompt caching is automatic. A request carries the run's
  `prompt_cache_key` (`Clementine.LLM.Cache.key/1`), and on a model whose
  sheet offers `:thirty_minutes` (GPT-5.6 and later)
  `prompt_cache_options` with the agent's TTL, or, with `cache: false`,
  explicit mode with no breakpoints, which turns caching off.
  Usage reads `input_tokens_details.cached_tokens` and
  `cache_write_tokens`.
  """

  @behaviour Clementine.LLM.ClientBehaviour

  alias Clementine.Model
  alias Clementine.LLM.{Cache, Policy, ProviderUsage}
  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Reasoning
  alias Clementine.LLM.ProviderStream
  alias Clementine.LLM.OpenAI.{Messages, Tools}
  alias Clementine.LLM.OpenAIStreamParser
  alias Clementine.LLM.Response

  @retriable_statuses [429, 500, 502, 503, 504]

  @doc """
  Makes a synchronous call to the OpenAI Responses API.
  """
  @impl true
  def call(model, system, messages, tools, opts \\ []) do
    {body, policy} = build_body(model, system, messages, tools, opts, stream: false)
    headers = build_headers()

    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)

    do_call_with_retry(body, headers, usage_meta(policy), max_attempts, 1)
  end

  defp do_call_with_retry(body, headers, usage_meta, max_attempts, attempt) do
    case Req.post(base_url(), json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, parse_response(resp_body, usage_meta)}

      {:ok, %{status: status}} when status in @retriable_statuses and attempt < max_attempts ->
        Process.sleep(calculate_backoff(attempt))
        do_call_with_retry(body, headers, usage_meta, max_attempts, attempt + 1)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, _reason} when attempt < max_attempts ->
        Process.sleep(calculate_backoff(attempt))
        do_call_with_retry(body, headers, usage_meta, max_attempts, attempt + 1)

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Makes a streaming call to the OpenAI Responses API.
  """
  @impl true
  def stream(model, system, messages, tools, opts \\ []) do
    {body, policy} = build_body(model, system, messages, tools, opts, stream: true)
    body = Map.put(body, "stream", true)

    headers = build_headers()
    # A runner caps this to the execution deadline's remaining budget. It
    # bounds the whole streaming call, not one attempt: per-attempt receive
    # timeout and retry backoff draw down the same window, and retries stop
    # once it is spent.
    receive_timeout = Keyword.get(opts, :receive_timeout, 300_000)
    budget_ends = System.monotonic_time(:millisecond) + receive_timeout

    parser = OpenAIStreamParser.new(usage_meta(policy))

    ProviderStream.new({OpenAIStreamParser, parser}, fn parent, ref ->
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

    callback = fn {:data, data}, {req, resp} ->
      :atomics.put(data_sent, 1, 1)
      send(parent, {ref, {:data, data}})
      {:cont, {req, accumulate_error_body(resp, data)}}
    end

    result =
      Req.post(base_url(),
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

  defp build_body(model, system, messages, tools, opts, checks) do
    schema? = Keyword.get(opts, :output_schema) != nil
    policy = Policy.resolve!(model, opts, [output_schema: schema?] ++ checks)

    if policy.platform != :openai do
      raise ArgumentError, "#{inspect(model)} goes to #{inspect(policy.platform)}, not :openai"
    end

    body =
      %{
        "model" => Model.platform_id(policy.model),
        "input" => format_messages(messages),
        "max_output_tokens" => policy.max_tokens
      }
      |> Map.merge(Reasoning.openai(policy))
      |> maybe_put_output_schema(Keyword.get(opts, :output_schema))
      |> put_cache(policy, Keyword.get(opts, :cache_key))

    body =
      if is_binary(system) and system != "" do
        Map.put(body, "instructions", system)
      else
        body
      end

    body =
      if is_list(tools) and tools != [] do
        body
        |> Map.put("tools", format_tools(tools))
        |> Map.put("tool_choice", "auto")
      else
        body
      end

    {body, policy}
  end

  # Caching is automatic. The key keeps a user's requests on one cache
  # (routing on models before GPT-5.6, cache accounting after), and
  # GPT-5.6 and later (a sheet offering :thirty_minutes) take the write's
  # lifetime in prompt_cache_options; with caching off there, explicit
  # mode and no breakpoints turn it off.
  defp put_cache(body, %Policy{cache: %{enabled: true} = cache}, key) do
    body
    |> put_if("prompt_cache_key", key)
    |> put_if("prompt_cache_options", cache.ttl && %{"ttl" => Cache.wire_ttl(cache.ttl)})
  end

  defp put_cache(body, %Policy{cache: %{enabled: false}, model: model}, _key) do
    if Model.cache_mechanism(model.cache.ttls) == :options,
      do: Map.put(body, "prompt_cache_options", %{"mode" => "explicit"}),
      else: body
  end

  defp put_if(body, _key, nil), do: body
  defp put_if(body, key, value), do: Map.put(body, key, value)

  defp maybe_put_output_schema(body, nil), do: body

  defp maybe_put_output_schema(body, schema) do
    Map.put(body, "text", %{
      "format" => %{
        "type" => "json_schema",
        "name" => "output",
        "schema" => schema,
        "strict" => true
      }
    })
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

  defp format_messages(messages) do
    Messages.encode_all(messages)
  end

  defp format_tools(tools) do
    Tools.encode_all(tools)
  end

  defp parse_response(%{"output" => output} = body, usage_meta) when is_list(output) do
    content =
      output
      |> Enum.reject(
        &(match?(%{"type" => "function_call"}, &1) and not OpenAIStreamParser.whole_call?(&1))
      )
      |> Messages.decode_output_items()

    # A refusal or a content filter beats the calls, as in a stream.
    stop_reason =
      cond do
        refused?(output) -> "refusal"
        OpenAIStreamParser.incomplete_reason(body) == "content_filter" -> "content_filter"
        Enum.any?(content, &match?(%Content.ToolUse{}, &1)) -> "tool_use"
        true -> OpenAIStreamParser.incomplete_reason(body)
      end

    %Response{
      content: content,
      stop_reason: stop_reason,
      usage: ProviderUsage.openai(Map.get(body, "usage"), usage_meta)
    }
  end

  defp parse_response(body, usage_meta) when is_map(body) do
    %Response{
      content: [],
      stop_reason: nil,
      usage: ProviderUsage.openai(Map.get(body, "usage"), usage_meta)
    }
  end

  # The vendor is the model's, as `Clementine.LLM.ChatCompletions` says
  # it: a model an app declares on :openai need not be OpenAI's.
  defp usage_meta(%Policy{} = policy),
    do: %{provider: policy.model.vendor, platform: policy.platform, model: policy.model.id}

  defp refused?(output) do
    Enum.any?(output, fn
      %{"type" => "message", "content" => parts} when is_list(parts) ->
        Enum.any?(parts, &match?(%{"type" => "refusal"}, &1))

      _item ->
        false
    end)
  end
end
