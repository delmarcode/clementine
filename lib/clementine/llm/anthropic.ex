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

  A request names a model by its id (`"claude-sonnet-5-5"`), and the
  client reads the model's sheet (`Clementine.Model`) for everything it
  sends or withholds: the id, `max_tokens`, the `thinking` and
  `output_config.effort` fields (`Clementine.LLM.Reasoning`), whether
  deferred tools can go, whether thinking is bound to the conversation,
  where a system message goes, and the cache TTLs. The request's opts
  carry the agent's choices (`Clementine.LLM.Policy`), checked against
  the sheet before anything is sent.

  ## Deferred tools

  Tools named in the `:deferred` request option (a subset of `tools`)
  go with `defer_loading: true`, beside the API's tool search tool
  (`tool_search_tool_regex_20251119`): Claude sees only the tools that
  are not deferred until a search loads the ones it needs. A model whose
  sheet has no `features.tool_search` gets its deferred tools as
  ordinary tools. The search's
  `server_tool_use` and `tool_search_tool_result` blocks come back as
  `Clementine.LLM.Message.Content.ServerToolUse` and `ServerToolResult`
  and are replayed with the turn as far as the request can honour them:
  a reference to a tool the request no longer carries is left out, and a
  request without the search tool leaves past searches out. The search runs
  inside the response, so its stream emits `{:server_tool_use_start, id,
  name}`, `{:server_tool_input_delta, id, json}`, and
  `{:server_tool_result, block}` rather than the client tool events.

  ## Structured output

  A JSON schema in the `:output_schema` request option goes as
  `output_config.format` (`{"type": "json_schema", "schema": ...}`,
  beside any reasoning `effort`), which constrains Claude's text answer
  to it; tool calls are unaffected. The API takes the subset of JSON
  Schema its structured outputs document: every object needs
  `"additionalProperties": false`, and constraints such as `minimum` or
  `maxLength` are refused. A model without structured outputs refuses
  the request.

  ## Models that bind their thinking

  A model whose sheet says `thinking.binding: :prefix` (Claude Fable
  5.1, Mythos 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5) accepts a replayed
  thinking block only after the exact system prompt, tools, and
  messages it was produced after. On those models each response
  carries a `binding`
  (`Clementine.LLM.Message.AssistantMessage`), and a replay sends a
  turn's thinking only while its binding still holds (a turn without
  one goes without its thinking), so an edited history costs that
  reasoning and is never refused; the engine reports it as
  `[:clementine, :llm, :thinking_dropped]`. Where the sheet has
  `features.mid_conversation_system`, a
  `Clementine.LLM.Message.SystemMessage` goes as a mid-conversation
  `role: "system"` message, its tools as inline definitions, and the
  tools it adds stay out of `tools`; elsewhere its text joins the
  system prompt and its tools join `tools`. The runtime guide's "Models
  that bind their thinking" has the whole policy.

  Beta headers follow the body: `thinking-display-updates-2026-08-18`
  for `display: :updates`, `thinking-binding-controls-2026-08-01` for
  `prefix_mismatch:`, and `inline-tools-2026-09-15` when a system message
  adds a tool.

  ## Prompt caching

  Every request carries two cache breakpoints unless the agent sets
  `cache: false` (`Clementine.LLM.Cache`): `cache_control` on the system
  prompt, which ends the prefix every run of the agent shares (the
  tools, then the system prompt), and the top-level `cache_control` the
  API moves to the last cacheable block, so each call of the model–tool
  cycle reads the prefix the call before it wrote. Without a system
  prompt the first one goes on the last tool loaded up front: a deferred
  tool cannot carry one. Both use the agent's TTL, five minutes unless it
  says `ttl: :one_hour`. A prefix shorter than the model's minimum is not
  cached, and costs nothing extra. Usage counts the cache reads and writes
  the API reports as parts of `input_tokens`.
  """

  @behaviour Clementine.LLM.ClientBehaviour

  alias Clementine.Model
  alias Clementine.LLM.Anthropic.{Binding, Messages, Tools}
  alias Clementine.LLM.Message.SystemMessage
  alias Clementine.LLM.{Cache, Policy, ProviderStream, ProviderUsage}
  alias Clementine.LLM.Reasoning
  alias Clementine.LLM.Response
  alias Clementine.LLM.StreamParser

  @anthropic_version "2023-06-01"

  @doc """
  Makes a synchronous call to the Anthropic API.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @impl true
  def call(model, system, messages, tools, opts \\ []) do
    {body, binding, dropped} = request(model, system, messages, tools, opts, stream: false)
    Binding.log_dropped(dropped, inspect(model))
    headers = build_headers(body)

    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)

    with {:ok, response} <- do_call_with_retry(body, headers, max_attempts, 1) do
      {:ok, %{response | binding: binding}}
    end
  end

  defp do_call_with_retry(body, headers, max_attempts, attempt) do
    case Req.post(base_url(), json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, parse_response(resp_body)}

      {:ok, %{status: status}} when status in [429, 529] and attempt < max_attempts ->
        retry_sleep(calculate_backoff(attempt))
        do_call_with_retry(body, headers, max_attempts, attempt + 1)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, _reason} when attempt < max_attempts ->
        retry_sleep(calculate_backoff(attempt))
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

  # Every retry backoff sleeps through this seam so tests can observe the
  # requested durations instead of asserting on the wall clock (the
  # budget-cap test's flake class). Default is the real sleep.
  defp retry_sleep(ms) do
    sleeper = Application.get_env(:clementine, :retry_sleep, &Process.sleep/1)
    sleeper.(ms)
  end

  @doc false
  # The wait before the attempt after `attempt`, as a retry sleeps it:
  # its backoff, capped to the `remaining` milliseconds of the call's
  # budget. `Clementine.LLM.Anthropic.Fake` retries a scripted 429 or 529
  # here.
  def retry_wait(attempt, remaining),
    do: retry_sleep(min(calculate_backoff(attempt), remaining))

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
    {body, binding, dropped} = request(model, system, messages, tools, opts)
    body = Map.put(body, "stream", true)
    headers = build_headers(body)
    # A runner caps this to the execution deadline's remaining budget. It
    # bounds the whole streaming call, not one attempt: per-attempt receive
    # timeout and retry backoff draw down the same window, and retries stop
    # once it is spent.
    receive_timeout = Keyword.get(opts, :receive_timeout, 300_000)
    budget_ends = System.monotonic_time(:millisecond) + receive_timeout

    stream =
      ProviderStream.new(StreamParser, fn parent, ref ->
        do_stream_request(body, headers, parent, ref, budget_ends)
      end)

    # The turn this request produces is bound to it: the binding leads the
    # stream, and the accumulator sets it on the response. What the
    # request sent without its thinking follows, for the engine to report
    # (`[:clementine, :llm, :thinking_dropped]`).
    case Binding.events(binding, dropped) do
      [] -> stream
      events -> Stream.concat(events, stream)
    end
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
      retry_wait(attempt, remaining)
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

  @doc false
  # The Messages API body for a request, the binding of the turn it
  # produces (nil on a model that does not bind its thinking), and what
  # it sent without its thinking (`Binding.encode/3`). The real client
  # and `Clementine.LLM.Anthropic.Fake` both build requests here, so a
  # test sees exactly what the API would.
  def request(model, system, messages, tools, opts, checks \\ [stream: true]) do
    schema? = Keyword.get(opts, :output_schema) != nil
    policy = policy!(model, opts, [output_schema: schema?] ++ checks)
    facts = policy.model
    binds? = facts.thinking.binding == :prefix
    inline? = facts.features.mid_conversation_system

    {system, tools, added} = arrange(inline?, system, messages, tools || [])

    # A model without tool search gets its deferred tools as ordinary
    # tools, as every other provider does, rather than a request the API
    # refuses.
    deferred = if facts.features.tool_search, do: Keyword.get(opts, :deferred, []), else: []

    encoded_tools =
      case Tools.encode_all(tools, deferred) ++ added do
        [] -> nil
        encoded -> encoded
      end

    # A system message folded into `system` and `tools` sends nothing
    # where it stands.
    replay = fn
      %SystemMessage{} when not inline? -> []
      message -> Messages.encode_replay(message, tool_search: loadable(encoded_tools))
    end

    {encoded_messages, binding, dropped} =
      if binds? do
        Binding.encode(messages, Binding.start(system, encoded_tools), replay)
      else
        {Enum.flat_map(messages, replay), nil, nil}
      end

    body =
      %{
        "model" => Model.platform_id(facts),
        "max_tokens" => policy.max_tokens,
        "messages" => encoded_messages
      }
      |> Map.merge(Reasoning.anthropic(policy))
      |> maybe_put_output_schema(Keyword.get(opts, :output_schema))
      |> put_prompt(system, encoded_tools, policy.cache)

    {body, binding, dropped}
  end

  # A model that takes mid-conversation system messages keeps them in
  # place, and a tool one of them adds goes inline there, not in `tools`:
  # the request's tools stay as the first turn sent them. Elsewhere a
  # system message's text joins the system prompt, and the tools it adds
  # join the request's (the engine already offers a loaded skill's).
  defp arrange(true, system, messages, tools) do
    added = MapSet.new(added_definitions(messages), & &1["name"])
    {system, Enum.reject(tools, &(tool_name(&1) in added)), []}
  end

  defp arrange(false, system, messages, tools) do
    system_messages = Enum.filter(messages, &match?(%SystemMessage{}, &1))
    names = MapSet.new(tools, &tool_name/1)

    added =
      system_messages
      |> added_definitions()
      |> Enum.reject(&(&1["name"] in names))
      |> Enum.uniq_by(& &1["name"])

    texts =
      for message <- system_messages, text = SystemMessage.get_text(message), text != "", do: text

    system =
      case Enum.reject([system | texts], &(&1 in [nil, ""])) do
        [] -> system
        parts -> Enum.join(parts, "\n\n")
      end

    {system, tools, added}
  end

  defp added_definitions(messages) do
    for %SystemMessage{} = message <- messages,
        definition <- SystemMessage.tool_definitions(message),
        do: definition
  end

  defp tool_name(tool), do: Clementine.Tool.to_schema(tool).name

  # The system prompt and tools, with the cache breakpoints when caching
  # is on: one at the end of the stable prefix (the system prompt, or the
  # last tool loaded up front when there is none), which every run of the
  # agent shares, and the top-level automatic one, which the API moves to
  # the last cacheable block, so each call reads what the one before it
  # wrote. Two of the four breakpoints a request may carry.
  defp put_prompt(body, system, encoded_tools, %{enabled: true} = cache) do
    cache_control = Cache.cache_control(cache)

    {system, encoded_tools} =
      if present?(system) do
        {[%{"type" => "text", "text" => system, "cache_control" => cache_control}], encoded_tools}
      else
        {system, mark_last_loaded_tool(encoded_tools, cache_control)}
      end

    body
    |> put_present("system", system)
    |> put_present("tools", encoded_tools)
    |> Map.put("cache_control", cache_control)
  end

  defp put_prompt(body, system, encoded_tools, %{enabled: false}) do
    body
    |> put_present("system", system)
    |> put_present("tools", encoded_tools)
  end

  # A deferred tool cannot carry cache_control (the API refuses it), and
  # deferred tools are not part of the cached prefix anyway; the search
  # tool is left as the API defines it.
  defp mark_last_loaded_tool(nil, _cache_control), do: nil

  defp mark_last_loaded_tool(encoded_tools, cache_control) do
    index =
      encoded_tools
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {tool, index} ->
        if not Map.has_key?(tool, "defer_loading") and not Tools.search_tool?(tool), do: index
      end)

    if index,
      do: List.update_at(encoded_tools, index, &Map.put(&1, "cache_control", cache_control)),
      else: encoded_tools
  end

  defp present?(value), do: value not in [nil, "", []]

  defp put_present(body, key, value) do
    if present?(value), do: Map.put(body, key, value), else: body
  end

  # What this request's tool search can load, read off its own tools: their
  # names when it carries the search tool, nil when it does not. History's
  # past searches replay only that far (`Messages.encode_all/2`).
  defp loadable(nil), do: nil

  defp loadable(encoded_tools) do
    if Enum.any?(encoded_tools, &Tools.search_tool?/1) do
      MapSet.new(encoded_tools, & &1["name"])
    end
  end

  # output_config may already carry the reasoning effort; the format
  # joins it.
  defp maybe_put_output_schema(body, nil), do: body

  defp maybe_put_output_schema(body, schema) do
    format = %{"type" => "json_schema", "schema" => schema}
    Map.update(body, "output_config", %{"format" => format}, &Map.put(&1, "format", format))
  end

  defp build_headers(body) do
    headers = [
      {"x-api-key", get_api_key()},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]

    case betas(body) do
      [] -> headers
      betas -> headers ++ [{"anthropic-beta", Enum.join(betas, ",")}]
    end
  end

  @doc false
  # The beta headers a body needs, read off the body itself so a field
  # never goes without the header that admits it.
  def betas(body) do
    thinking = Map.get(body, "thinking", %{})

    [
      {Map.has_key?(thinking, "block_binding"), "thinking-binding-controls-2026-08-01"},
      {thinking["display"] == "updates", "thinking-display-updates-2026-08-18"},
      {inline_tools?(body["messages"]), "inline-tools-2026-09-15"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp inline_tools?(messages) do
    Enum.any?(messages || [], fn
      %{"role" => "system", "content" => content} when is_list(content) ->
        Enum.any?(content, &(&1["type"] == "tool_addition"))

      _message ->
        false
    end)
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

  # The agent's choices, checked against the model's sheet; a model
  # Anthropic's client cannot serve is refused before anything is sent.
  defp policy!(model, opts, checks) do
    policy = Policy.resolve!(model, opts, checks)

    if policy.platform != :anthropic do
      raise ArgumentError,
            "#{inspect(model)} goes to #{inspect(policy.platform)}, not :anthropic"
    end

    policy
  end

  defp parse_response(%{"content" => content, "stop_reason" => stop_reason} = body) do
    Binding.report(body)

    %Response{
      content: Enum.flat_map(content, &parse_content_block/1),
      stop_reason: stop_reason,
      usage: ProviderUsage.anthropic(Map.get(body, "usage"))
    }
  end

  defp parse_content_block(%{"type" => "text", "text" => text}) do
    [Messages.decode_content(%{"type" => "text", "text" => text})]
  end

  defp parse_content_block(%{"type" => "tool_use"} = block) do
    [Messages.decode_content(block)]
  end

  # Reasoning-enabled responses lead with thinking blocks. They are
  # preserved — signature included — because the API verifies them when the
  # assistant turn is replayed in a tool-use loop.
  defp parse_content_block(%{"type" => "thinking"} = block) do
    [Messages.decode_content(block)]
  end

  defp parse_content_block(%{"type" => "redacted_thinking"} = block) do
    [Messages.decode_content(block)]
  end

  # A tool search the API ran for deferred tools: kept, in place, so the
  # turn replays as produced and the tools it loaded stay loaded.
  defp parse_content_block(%{"type" => "server_tool_use"} = block) do
    [Messages.decode_content(block)]
  end

  defp parse_content_block(%{"type" => "tool_search_tool_result"} = block) do
    [Messages.decode_content(block)]
  end

  # A block type this client does not know must not crash the call; the
  # engine acts only on text and tool_use.
  defp parse_content_block(_block), do: []
end
