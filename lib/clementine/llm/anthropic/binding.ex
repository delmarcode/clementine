defmodule Clementine.LLM.Anthropic.Binding do
  @moduledoc false

  # Claude Fable 5.1, Mythos 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5, and
  # every later model bind each thinking block to the conversation it
  # was produced in: the system prompt, the set of tools, and every
  # message before it (Anthropic's preserved-thinking doc, read
  # 2026-11-01). Replaying a block after any of those changed is a 400
  # on accounts created on or after 2026-08-31 (on every account for
  # Mythos 5.1), and billed stale reasoning on older ones.
  #
  # Clementine checks the same thing on its side before it sends. Each
  # assistant turn from a binding model carries `binding`: a digest of
  # the request it answered, as sent. A replay keeps a turn's thinking
  # only while the digest of what precedes it still matches; otherwise
  # the turn goes without its thinking, and so does every turn after it,
  # because their digests cover what was sent before them. The digest
  # chains message by message, so one pass over the history decides
  # every turn. Earlier thinking enters the chain by signature only:
  # its text is a summary the API ignores on replay.
  #
  # Dropping a trailing run of thinking, or all of it, is a valid edit,
  # so what this sends is never refused; an append-only history drops
  # nothing. What it does drop is reported (`encode/3`), and the engine
  # emits it as `[:clementine, :llm, :thinking_dropped]`: an app that
  # replays its threads out of order loses its reasoning and its prompt
  # cache on every turn, and nothing else would say so.

  alias Clementine.LLM.Message.{AssistantMessage, Content}

  require Logger

  @doc """
  What Clementine knows of `model_id`: `:binds` for a Claude model from
  version 5.1 on, in any family; `:older` for one before it (a closed
  set); `:unknown` for an id it cannot read, such as a deployment name
  behind `:anthropic_base_url`.
  """
  def model(model_id) when is_binary(model_id) do
    case Regex.run(~r/^claude-[a-z]+-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$/, model_id) do
      [_, major] ->
        if to_int(major) > 5, do: :binds, else: :older

      [_, major, minor] ->
        if {to_int(major), to_int(minor)} >= {5, 1}, do: :binds, else: :older

      nil ->
        if Regex.match?(~r/^claude-(instant|\d|mythos-preview)/, model_id),
          do: :older,
          else: :unknown
    end
  end

  defp to_int(digits), do: String.to_integer(digits)

  @doc """
  Whether Clementine checks a request to `model_id` before sending it:
  every model but the older ones. An unknown id is checked, since the
  check only drops thinking whose conversation changed, which a model
  that binds would refuse and one that does not would never read.
  """
  def binds?(model_id), do: model(model_id) != :older

  @doc """
  Whether a `Clementine.LLM.Message.SystemMessage` goes to `model_id`
  where it stands, as a mid-conversation system message with inline
  tool definitions: only on a model known to bind. Mid-conversation
  system messages exist on some models and platforms only (not Claude
  Sonnet 5, not Microsoft Foundry), so an unknown id gets the message
  folded into `system` and `tools`, which every model takes; the check
  then costs the earlier turns' thinking once, where a misplaced system
  message would fail every request.
  """
  def inline_system?(model_id), do: model(model_id) == :binds

  @doc """
  The digest a request starts from: its system prompt and its tools as a
  name-sorted set, without cache breakpoints (moving those is no edit).
  """
  def start(system, encoded_tools) do
    tools =
      (encoded_tools || [])
      |> Enum.map(&Map.delete(&1, "cache_control"))
      |> Enum.sort_by(&Map.get(&1, "name", ""))

    :crypto.hash(:sha256, canonical(%{"system" => system || "", "tools" => tools}))
  end

  @doc """
  Encodes `messages` with `encode` (a message to a list of wire maps),
  sending each binding turn's thinking only while its digest holds.
  Returns the wire messages, the digest of all of them (the binding of
  the turn the request produces), and what this request is the first to
  drop: nil, or the number of turns sent without their thinking after
  the last turn whose binding holds, of thinking blocks left out, and
  the index in `messages` of the first such turn. A turn dropped before
  that last turn was already gone when it was produced, so a change
  reports once, not on every turn after it.

  A turn with no binding is sent without its thinking: Clementine
  cannot tell what it was produced after (a turn stored before bindings,
  or from a model that does not bind). A turn left empty goes out
  entirely, unless it follows a system message, which the API takes only
  before an assistant turn or at the end: then it goes as the text
  `(no reply)`, which is what the turn showed.
  """
  def encode(messages, digest, encode) do
    {encoded, {digest, _previous, dropped}} =
      messages
      |> Enum.with_index()
      |> Enum.flat_map_reduce({digest, nil, []}, &encode_one(&1, &2, encode))

    {encoded, stamp(digest), dropped_report(Enum.reverse(dropped))}
  end

  defp encode_one({message, index}, {digest, previous, dropped}, encode) do
    {message, dropped} = replayable(message, stamp(digest), index, dropped)
    wire = stand_in(encode.(message), message, previous)
    {wire, {Enum.reduce(wire, digest, &chain/2), last_role(wire, previous), dropped}}
  end

  @stand_in "(no reply)"

  defp stand_in([], %AssistantMessage{}, "system"),
    do: [%{"role" => "assistant", "content" => [%{"type" => "text", "text" => @stand_in}]}]

  defp stand_in(wire, _message, _previous), do: wire

  defp last_role([], previous), do: previous
  defp last_role(wire, _previous), do: List.last(wire)["role"]

  defp dropped_report([]), do: nil

  defp dropped_report([{first, _blocks} | _rest] = dropped) do
    %{
      turns: length(dropped),
      blocks: Enum.sum_by(dropped, &elem(&1, 1)),
      first_index: first
    }
  end

  @doc """
  The client's own stream events that lead a response: the binding of
  the turn it produces, then what the request sent without its thinking.
  """
  def events(binding, dropped) do
    for {event, value} <- [binding: binding, thinking_dropped: dropped],
        value != nil,
        do: {event, value}
  end

  @doc """
  Warns that a request sent earlier turns without their thinking: their
  conversation changed since they were produced. Counts and the first
  turn's index only, never content.
  """
  def log_dropped(nil, _who), do: :ok

  def log_dropped(%{turns: turns, blocks: blocks, first_index: index}, who) do
    Logger.warning(
      "#{who}: sent #{turns} earlier turn(s) without their thinking (#{blocks} block(s), " <>
        "first at messages.#{index}): the history before them is not the one they were " <>
        "produced after. Replay the thread as the model saw it (the runtime guide's " <>
        "\"Models that bind their thinking\")."
    )
  end

  @doc """
  Logs the thinking the API dropped or let through stale, which a
  response lists in `input_transformations` when the request sent the
  binding-controls beta (`prefix_mismatch:`). Counts and reasons only.
  """
  def report(%{"input_transformations" => [_ | _] = transformations}) do
    reasons =
      transformations
      |> Enum.frequencies_by(&"#{&1["type"]}:#{&1["reason"]}")
      |> Enum.map_join(", ", fn {reason, count} -> "#{count} #{reason}" end)

    Logger.warning("Anthropic transformed replayed thinking blocks: #{reasons}")
  end

  def report(_message), do: :ok

  @doc "The stored form of a digest."
  def stamp(digest), do: Base.url_encode64(digest, padding: false)

  # A turn whose binding holds was produced after everything before it
  # as it is sent now, thinking dropped included: what was dropped before
  # it was lost already, and is not this request's to report.
  defp replayable(%AssistantMessage{binding: current} = message, current, _index, _dropped),
    do: {message, []}

  defp replayable(%AssistantMessage{} = message, _current, index, dropped) do
    case Enum.split_with(message.content, &thinking?/1) do
      {[], _content} ->
        {message, dropped}

      {thinking, content} ->
        {%{message | content: content}, [{index, length(thinking)} | dropped]}
    end
  end

  defp replayable(message, _current, _index, dropped), do: {message, dropped}

  defp thinking?(%Content.Thinking{}), do: true
  defp thinking?(%Content.RedactedThinking{}), do: true
  defp thinking?(_block), do: false

  defp chain(wire_message, digest) do
    :crypto.hash(:sha256, [digest | canonical(bound(wire_message))])
  end

  # A thinking block is bound by its signature; the text beside it is
  # what the API returned for display and plays no part in the replay.
  defp bound(%{"content" => content} = message) when is_list(content) do
    %{message | "content" => Enum.map(content, &bound_block/1)}
  end

  defp bound(message), do: message

  defp bound_block(%{"type" => "thinking"} = block), do: Map.delete(block, "thinking")
  defp bound_block(block), do: Map.delete(block, "cache_control")

  # JSON with sorted keys: the check compares values, never key order.
  @doc false
  def canonical(map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} -> [Jason.encode!(to_string(key)), ?:, canonical(value)] end)
      |> Enum.intersperse(?,)

    [?{, entries, ?}]
  end

  def canonical(list) when is_list(list) do
    [?[, list |> Enum.map(&canonical/1) |> Enum.intersperse(?,), ?]]
  end

  def canonical(value), do: Jason.encode!(value)
end
