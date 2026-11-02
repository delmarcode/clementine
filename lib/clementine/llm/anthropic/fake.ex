defmodule Clementine.LLM.Anthropic.Fake do
  @moduledoc """
  A scripted Anthropic model for tests, which fails a turn whose request
  lost an earlier turn's thinking, and checks a replayed history the way
  the Messages API does on models that bind their thinking.

  Claude Fable 5.1, Mythos 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5, and
  later models accept a thinking block only after the exact system
  prompt, tools, and messages it was produced after. Clementine checks
  that before it sends (`Clementine.LLM.Message.AssistantMessage`'s
  `binding`) and sends a turn without its thinking once the history
  before it changed, so the API never refuses what an app replays: the
  app loses the model's reasoning and its prompt cache instead, without
  an error. This fake is how a test sees that loss.

      Mox.expect(MyApp.LLMMock, :stream, fn model, system, messages, tools, opts ->
        Clementine.LLM.Anthropic.Fake.stream(model, system, messages, tools, opts, [
          {:thinking, "Checking the record."},
          {:update, "Looking up the appointment."},
          {:tool_use, "toolu_1", "lookup", %{"id" => 7}}
        ])
      end)

  It builds the request with `Clementine.LLM.Anthropic`'s own encoder.
  By default (`strict: true`, the last argument's option) a request that
  sends any earlier turn without its thinking fails with a 400, as
  `{:error, {:api_error, 400, body}}`, naming the first such message:
  a rebuilt system prompt, a changed tool list, a history replayed in
  another order than the model saw it, a moved window, a turn stored
  without its `binding`. Store a thread's turns as each test turn
  returns them and replay them unchanged, and the fake passes.

  `strict: false` lets Clementine's drops through, for a test of a
  deliberate change (a window's step, new instructions). The fake then
  checks what the API does: each thinking block it returned carries a
  signature recording the conversation before it, and a request that
  replays a block after that conversation (a block moved into another
  thread, say) gets the API's 400, or, when the request sets
  `prefix_mismatch: :drop_block`, the block and every later one
  dropped. Either way the fake refuses what the API refuses in any
  history: a mid-conversation system message that does not follow a
  user message, or that a user message follows; a text block that is
  empty or only whitespace; and an empty message anywhere but last. On
  a model that does not bind its thinking, only those are checked.

  A script is a list of steps, answered in order:

  - `{:thinking, text}`: a reasoning block. Its text shows only under
    `display: :summarized`, as the API's summary does.
  - `{:update, text}`: a progress update before the next tool call. Its
    text shows under `display: :updates` or `:summarized`, and under
    `thinking: :between_tools`; under the default display it is empty.
  - `{:text, text}`: answer text.
  - `{:tool_use, id, name, input}`: a tool call.
  - `{:unfinished_tool_use, id, name, json}`: a tool call cut off
    inside its input, which streams only `json` (a prefix of its
    arguments, or `""`) before its block closes, as the API closes one
    at `max_tokens`. The turn ends there, on `"max_tokens"` unless
    `stop_reason:` says otherwise, and the run fails on that stop
    (`:truncated`, or `:refused`), with the call in the error's
    `raw["unfinished_call"]`. No step may follow it.
  - `{:error, type}`: an `error` event mid-stream, after the steps
    before it, as the API sends one after its 200 (`"overloaded_error"`,
    `"api_error"`, ...; or the event's whole map). The turn ends there,
    with no stop reason, and the run fails with the error
    `Clementine.Error.normalize/2` makes of it (`:overloaded`, ...),
    charged for the input the stream's start reported. No step may
    follow it.

  The turn ends on `"tool_use"` when it calls a tool and `"end_turn"`
  otherwise. The fake's options (the last argument) script the rest of
  the turn:

  - `stop_reason:` the turn's stop reason, any the API sends:
    `"refusal"` (the run fails `:refused`, and runs none of the turn's
    tools), `"max_tokens"` (a final turn fails `:truncated`),
    `"pause_turn"` (the engine sends the turn back, and the next
    scripted turn continues it), `"model_context_window_exceeded"`.
  - `stop_details:` the stop's details, as the API sends them on a
    refusal: `%{"type" => "refusal", "category" => "cyber",
    "explanation" => "..."}`. The `:refused` error keeps them in
    `raw["stop_details"]`.
  - `usage:` the usage the turn reports, in the API's keys:
    `input_tokens` (the uncached input), `output_tokens`,
    `cache_read_input_tokens`, `cache_creation_input_tokens`, and
    `cache_creation` (`%{ephemeral_5m_input_tokens: n,
    ephemeral_1h_input_tokens: m}`, whose sum is the cache write when
    `cache_creation_input_tokens` is left out). The keys given replace
    the default's, 10 input and 5 output tokens. It reaches the engine
    as the client normalizes it, the input counting the cache's reads
    and writes, so `[:clementine, :llm, :usage]`, the token and cost
    series, and the trace see what a real response's would. The stream
    starts with the input, as the API's does, so a turn a stream error
    ends is charged for it.
  - `api_errors:` the HTTP statuses the request meets before the turn
    answers it, in order, as the client meets them: it retries a `429`
    or a `529` after `:retry`'s backoff, through the `:retry_sleep`
    seam, until `:retry`'s `max_attempts` attempts are spent or the
    call's budget is (the request's `:receive_timeout`, which the
    engine caps to the run's deadline; a backoff sleeps no longer than
    what is left of it); any other status, or the attempt that spends
    them, ends the turn with the error the client gives up with,
    `{:error, {:api_error, status, body}}` (`:rate_limited`,
    `:overloaded`, ...). `api_errors: [529]` answers after one retry;
    `[529, 529, 529]` fails under the default three attempts.
  - `strict:` as above.

      expect_claude_turn([{:text, "Sunny."}],
        usage: [input_tokens: 40, cache_read_input_tokens: 900],
        stop_reason: "max_tokens"
      )
  """

  alias Clementine.LLM.{Anthropic, ProviderUsage}
  alias Clementine.LLM.Anthropic.Binding

  @prefix "clementine-fake."

  @default_usage %{"input_tokens" => 10, "output_tokens" => 5}
  @usage_keys ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens
                 cache_creation)
  @cache_creation_keys ~w(ephemeral_5m_input_tokens ephemeral_1h_input_tokens)

  # What the API answers each status with, as the error's type and message.
  @api_errors %{
    400 => {"invalid_request_error", "Invalid request"},
    401 => {"authentication_error", "invalid x-api-key"},
    403 => {"permission_error", "Permission denied"},
    404 => {"not_found_error", "Not found"},
    413 => {"request_too_large", "Request exceeds the maximum allowed size"},
    429 => {"rate_limit_error", "Rate limited"},
    500 => {"api_error", "Internal server error"},
    529 => {"overloaded_error", "Overloaded"}
  }

  @type step ::
          {:thinking, String.t()}
          | {:update, String.t()}
          | {:text, String.t()}
          | {:tool_use, String.t(), String.t(), map()}
          | {:unfinished_tool_use, String.t(), String.t(), String.t()}
          | {:error, String.t() | map()}

  @doc """
  The stream events of one scripted turn, or a stream that ends in an
  error: an HTTP error `api_errors:` scripts, or a 400 when the request
  lost an earlier turn's thinking (`strict: true`, the default) or
  sends what the API would refuse. Takes the arguments the mock's
  `stream/5` receives, then the script, then the fake's options:
  `strict:`, `stop_reason:`, `stop_details:`, `usage:`, `api_errors:`.
  """
  @spec stream(term(), String.t() | nil, list(), list(), keyword(), [step()], keyword()) ::
          list()
  def stream(model, system, messages, tools, opts, script, fake_opts \\ [])
      when is_list(script) do
    fake_opts =
      Keyword.validate!(fake_opts,
        strict: true,
        stop_reason: nil,
        stop_details: nil,
        usage: [],
        api_errors: []
      )

    {body, binding, dropped} = Anthropic.request(model, system, messages, tools || [], opts)

    # The client reports what it dropped before the API answers, so the
    # engine's telemetry sees a drop the strict check then refuses.
    with :ok <- answered(fake_opts[:api_errors], Keyword.get(opts, :receive_timeout, 300_000)),
         {:ok, body} <- checked(body, dropped, fake_opts[:strict]) do
      Binding.events(binding, dropped) ++ turn(body, script, fake_opts)
    else
      {:error, {:api_error, _status, _body} = error} ->
        Binding.events(nil, dropped) ++ [{:error, error}]
    end
  end

  @doc """
  Checks the request a turn would send, as `stream/7` does: `:ok`, or
  the 400 as `{:error, {:api_error, 400, body}}`.
  """
  @spec check(term(), String.t() | nil, list(), list(), keyword(), keyword()) ::
          :ok | {:error, {:api_error, 400, map()}}
  def check(model, system, messages, tools, opts \\ [], fake_opts \\ []) do
    fake_opts = Keyword.validate!(fake_opts, strict: true)
    {body, _binding, dropped} = Anthropic.request(model, system, messages, tools || [], opts)

    with {:ok, _body} <- checked(body, dropped, fake_opts[:strict]), do: :ok
  end

  ## HTTP errors before the answer

  # The attempts the client makes, each meeting the next scripted status:
  # a 429 or a 529 it retries after its backoff while attempts and the
  # call's budget remain, the backoff capped to what is left of it;
  # anything else ends the turn with the error it gives up with.
  defp answered(statuses, budget) do
    max_attempts = Keyword.get(Application.get_env(:clementine, :retry, []), :max_attempts, 3)
    budget_ends = System.monotonic_time(:millisecond) + budget

    statuses
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {status, attempt}, :ok ->
      remaining = max(budget_ends - System.monotonic_time(:millisecond), 0)

      if status in [429, 529] and attempt < max_attempts and remaining > 0 do
        Anthropic.retry_wait(attempt, remaining)
        {:cont, :ok}
      else
        {:halt, {:error, {:api_error, status, api_error_body(status)}}}
      end
    end)
  end

  # The body as the client keeps it: the response's raw JSON.
  defp api_error_body(status) when is_integer(status) and status in 400..599 do
    {type, message} = Map.get(@api_errors, status, {"api_error", "HTTP #{status}"})
    Jason.encode!(%{"type" => "error", "error" => %{"type" => type, "message" => message}})
  end

  defp api_error_body(status) do
    raise ArgumentError,
          "api_errors: takes HTTP error statuses (400..599), got: #{inspect(status)}"
  end

  ## The check

  defp checked(body, dropped, strict?) do
    with :ok <- check_dropped(dropped, strict?),
         :ok <- check_system_messages(body["messages"]),
         :ok <- check_content(body["messages"]) do
      if Binding.binds?(body["model"]), do: check_thinking(body), else: {:ok, body}
    end
  end

  # The API refuses a text block that is empty or only whitespace
  # anywhere in the history, and an empty message anywhere but last,
  # where only an assistant's may be empty.
  defp check_content(messages) do
    last = length(messages) - 1

    messages
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {message, index} ->
      empty_text = &match?(%{"type" => "text", "text" => ""}, &1)

      blank_text =
        &(match?(%{"type" => "text", "text" => _}, &1) and String.trim(&1["text"]) == "")

      case message["content"] do
        empty when empty in ["", []] ->
          unless index == last and message["role"] == "assistant" do
            refuse(
              "messages.#{index}: all messages must have non-empty content except for " <>
                "the optional final assistant message"
            )
          end

        blocks when is_list(blocks) ->
          cond do
            position = Enum.find_index(blocks, empty_text) ->
              refuse(
                "messages.#{index}.content.#{position}.text: text content blocks must be " <>
                  "non-empty"
              )

            position = Enum.find_index(blocks, blank_text) ->
              refuse(
                "messages.#{index}.content.#{position}.text: text content blocks must " <>
                  "contain non-whitespace text"
              )

            true ->
              nil
          end

        _text ->
          nil
      end
    end)
  end

  defp check_dropped(%{turns: turns, blocks: blocks, first_index: index}, true) do
    refuse(
      "messages.#{index}: Clementine sent this turn without its thinking, and " <>
        "#{turns} earlier turn(s) in all (#{blocks} thinking block(s)): the history " <>
        "before it is not the one it was produced after (a changed system prompt or " <>
        "tool list, a reordered or trimmed history, or a turn stored without its " <>
        "binding). Replay the thread as the model saw it, or pass strict: false to " <>
        "Clementine.LLM.Anthropic.Fake where a test changes it on purpose."
    )
  end

  defp check_dropped(_dropped, _strict), do: :ok

  # Consecutive system messages are judged together (the API's
  # mid-conversation system messages doc): a run of them must follow a
  # user message, and be last or be followed by an assistant message.
  defp check_system_messages(messages) do
    roles = Enum.map(messages, & &1["role"])

    roles
    |> Enum.with_index()
    |> Enum.chunk_by(fn {role, _index} -> role == "system" end)
    |> Enum.find_value(:ok, fn
      [{"system", first} | _] = run ->
        {_role, last} = List.last(run)
        before = first > 0 and Enum.at(roles, first - 1) == "user"
        later = last == length(roles) - 1 or Enum.at(roles, last + 1) == "assistant"

        unless before and later do
          refuse(
            "messages.#{first}: a system message must follow a user message and be " <>
              "the last message or be followed by an assistant message"
          )
        end

      _run ->
        nil
    end)
  end

  # Walks the messages as the API does: each block of ours must follow
  # the conversation its signature recorded, and the thinking block the
  # conversation produced before it (or none, when a leading run of
  # thinking was left out). The first that does not fails the request,
  # or, under drop_block, goes with every thinking block after it.
  defp check_thinking(body) do
    drop? =
      get_in(body, ["thinking", "block_binding", "prefix_mismatch_behavior"]) == "drop_block"

    state = %{digest: start(body), previous: nil, failed?: false}

    body["messages"]
    |> Enum.with_index()
    |> Enum.reduce_while({[], state}, fn {message, index}, {messages, state} ->
      case check_blocks(message, index, state, drop?) do
        {:ok, message, state} ->
          {:cont, {[message | messages], %{state | digest: chain(state.digest, message)}}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      {messages, _state} -> {:ok, %{body | "messages" => Enum.reverse(messages)}}
    end
  end

  defp check_blocks(%{"content" => content} = message, index, state, drop?)
       when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], state}, fn {block, position}, {:ok, kept, state} ->
      case check_block(block, "messages.#{index}.content.#{position}", state, drop?) do
        {:keep, state} -> {:cont, {:ok, [block | kept], state}}
        {:drop, state} -> {:cont, {:ok, kept, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, kept, state} -> {:ok, Map.put(message, "content", Enum.reverse(kept)), state}
      {:error, error} -> {:error, error}
    end
  end

  defp check_blocks(message, _index, state, _drop?), do: {:ok, message, state}

  defp check_block(%{"type" => type} = block, path, state, drop?)
       when type in ["thinking", "redacted_thinking"] do
    signature = block["signature"] || block["data"]

    cond do
      state.failed? -> {:drop, state}
      valid?(signature, state) -> {:keep, %{state | previous: signature}}
      drop? -> {:drop, %{state | failed?: true}}
      true -> {:error, refusal(path)}
    end
  end

  defp check_block(_block, _path, state, _drop?), do: {:keep, state}

  defp valid?(signature, state) do
    case recorded(signature) do
      nil ->
        true

      %{"prefix" => prefix, "after" => after_id} ->
        prefix == Binding.stamp(state.digest) and
          (after_id == id(state.previous) or state.previous == nil)
    end
  end

  defp refusal(path) do
    {:api_error, 400,
     %{
       "type" => "error",
       "error" => %{
         "type" => "invalid_request_error",
         "message" =>
           "#{path}: Invalid `signature` in `thinking` block. The block is bound to a " <>
             "different conversation. Remove the block, or set " <>
             ~s(`thinking.block_binding.prefix_mismatch_behavior` to "drop_block".)
       }
     }}
  end

  defp refuse(message) do
    {:error,
     {:api_error, 400,
      %{"type" => "error", "error" => %{"type" => "invalid_request_error", "message" => message}}}}
  end

  ## The turn

  # The stream as the client hands it to the engine: its start with the
  # input the request burned, the steps' blocks, then the stop and the
  # whole usage, or a mid-stream error in its place. Usage leaves
  # normalized, as the client's parser leaves it.
  defp turn(body, script, fake_opts) do
    display = display(body)
    request = without_continuation(body["messages"])
    digest = Enum.reduce(request, start(body), &chain(&2, &1))
    previous = last_signature(body["messages"])
    {steps, error} = until_error(script)
    usage = usage(fake_opts[:usage])

    {events, _state} =
      steps
      |> Enum.with_index()
      |> Enum.flat_map_reduce(previous, fn {step, index}, previous ->
        step_events(step, index, digest, previous, display)
      end)

    started =
      {:message_start,
       %{
         "type" => "message",
         "role" => "assistant",
         "model" => body["model"],
         "usage" => ProviderUsage.anthropic(Map.delete(usage, "output_tokens"))
       }}

    ending =
      case error do
        nil ->
          delta = %{"stop_reason" => fake_opts[:stop_reason] || stop_reason(steps)}

          delta =
            if details = fake_opts[:stop_details],
              do: Map.put(delta, "stop_details", details),
              else: delta

          {:message_delta, delta, ProviderUsage.anthropic(usage)}

        error ->
          {:error, error}
      end

    [started | events] ++ [ending]
  end

  defp until_error(script) do
    case Enum.split_while(script, &(not match?({:unfinished_tool_use, _, _, _}, &1))) do
      {_steps, [_unfinished, _next | _rest]} ->
        raise ArgumentError,
              "a script's {:unfinished_tool_use, ...} step ends the turn: no step may follow it"

      _last ->
        :ok
    end

    case Enum.split_while(script, &(not match?({:error, _}, &1))) do
      {steps, []} ->
        {steps, nil}

      {steps, [{:error, error}]} ->
        {steps, stream_error(error)}

      {_steps, [{:error, _} | _rest]} ->
        raise ArgumentError, "a script's {:error, _} step ends the turn: no step may follow it"
    end
  end

  # The error event's error, as the client's parser emits it.
  defp stream_error(%{"type" => _} = error), do: error

  defp stream_error(type) when is_binary(type) do
    message =
      case Enum.find(@api_errors, fn {_status, {error_type, _}} -> error_type == type end) do
        {_status, {_type, message}} -> message
        nil -> type
      end

    %{"type" => type, "message" => message}
  end

  defp stop_reason(steps) do
    cond do
      match?({:unfinished_tool_use, _, _, _}, List.last(steps)) -> "max_tokens"
      Enum.any?(steps, &match?({:tool_use, _, _, _}, &1)) -> "tool_use"
      true -> "end_turn"
    end
  end

  # The usage the API reports, in its keys: the scripted keys over the
  # default's, the cache write the TTLs' sum when only they are given.
  defp usage(scripted) when is_list(scripted) or is_map(scripted) do
    scripted = Map.new(scripted, fn {key, value} -> {to_string(key), value} end)

    case Map.keys(scripted) -- @usage_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "usage: takes #{inspect(@usage_keys)}, got: #{inspect(unknown)}"
    end

    usage = Map.merge(@default_usage, Map.delete(scripted, "cache_creation"))

    case scripted["cache_creation"] do
      nil ->
        usage

      ttls ->
        ttls = Map.new(ttls, fn {key, value} -> {to_string(key), value} end)

        case Map.keys(ttls) -- @cache_creation_keys do
          [] ->
            :ok

          unknown ->
            raise ArgumentError,
                  "cache_creation: takes #{inspect(@cache_creation_keys)}, got: #{inspect(unknown)}"
        end

        usage
        |> Map.put("cache_creation", ttls)
        |> Map.put_new("cache_creation_input_tokens", ttls |> Map.values() |> Enum.sum())
    end
  end

  defp step_events({kind, text}, index, digest, previous, display)
       when kind in [:thinking, :update] do
    signature = mint(digest, previous)

    shown =
      case {kind, display} do
        {_kind, "summarized"} -> text
        {:update, shows} when shows in ["updates", "between_tools"] -> text
        _hidden -> ""
      end

    {[
       {:content_block_start, index, :thinking},
       {:thinking_delta, index, shown},
       {:signature_delta, signature},
       {:content_block_stop, index}
     ], signature}
  end

  defp step_events({:text, text}, _index, _digest, previous, _display) do
    {[{:text_delta, text}], previous}
  end

  defp step_events({:unfinished_tool_use, id, name, json}, index, _digest, previous, _display)
       when is_binary(json) do
    {[{:tool_use_start, id, name}] ++
       if(json == "", do: [], else: [{:input_json_delta, id, json}]) ++
       [{:content_block_stop, index}], previous}
  end

  defp step_events({:tool_use, id, name, input}, index, _digest, previous, _display) do
    {[
       {:tool_use_start, id, name},
       {:input_json_delta, id, Jason.encode!(input)},
       {:content_block_stop, index}
     ], previous}
  end

  defp display(%{"thinking" => %{"type" => "between_tools"}}), do: "between_tools"
  defp display(%{"thinking" => %{"display" => display}}), do: display

  defp display(%{"model" => model}),
    do: if(Binding.binds?(model), do: "omitted", else: "summarized")

  # A request that ends with an assistant turn continues that turn (a
  # paused one): what the response adds follows the conversation before
  # it.
  defp without_continuation(messages) do
    case List.last(messages) do
      %{"role" => "assistant"} -> Enum.drop(messages, -1)
      _other -> messages
    end
  end

  defp last_signature(messages) do
    messages
    |> Enum.flat_map(fn message -> List.wrap(message["content"]) end)
    |> Enum.filter(&(is_map(&1) and &1["type"] in ["thinking", "redacted_thinking"]))
    |> Enum.map(&(&1["signature"] || &1["data"]))
    |> List.last()
  end

  ## Signatures and the API's prefix

  defp mint(digest, previous) do
    record = %{
      "prefix" => Binding.stamp(digest),
      "after" => id(previous),
      "n" => System.unique_integer([:positive])
    }

    @prefix <> Base.url_encode64(Jason.encode!(record), padding: false)
  end

  defp recorded(@prefix <> encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, record} <- Jason.decode(json),
         do: record,
         else: (_ -> nil)
  end

  defp recorded(_signature), do: nil

  defp id(nil), do: nil
  defp id(signature), do: Binding.stamp(:crypto.hash(:sha256, signature))

  # The API's prefix: the system prompt's text, the tools as a set, and
  # each earlier message without its thinking (earlier thinking is bound
  # through the chain of blocks, not the prefix) or cache breakpoints.
  defp start(body) do
    system =
      case body["system"] do
        blocks when is_list(blocks) -> Enum.map_join(blocks, "", & &1["text"])
        text -> text || ""
      end

    Binding.start(system, body["tools"])
  end

  defp chain(digest, message) do
    message =
      case message["content"] do
        content when is_list(content) ->
          content =
            content
            |> Enum.reject(&(&1["type"] in ["thinking", "redacted_thinking"]))
            |> Enum.map(&Map.delete(&1, "cache_control"))

          Map.put(message, "content", content)

        _text ->
          message
      end

    :crypto.hash(:sha256, [digest | Binding.canonical(message)])
  end
end
