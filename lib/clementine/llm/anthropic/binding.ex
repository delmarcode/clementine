defmodule Clementine.LLM.Anthropic.Binding do
  @moduledoc false

  # Claude Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5, and every later
  # model bind each thinking block to the conversation it was produced
  # in: the system prompt, the set of tools, and every message before it
  # (Anthropic's preserved-thinking doc, read 2026-11-01). Replaying a
  # block after any of those changed is a 400 on accounts created on or
  # after 2026-08-31, and billed stale reasoning on older ones.
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
  # nothing.

  alias Clementine.LLM.Message.{AssistantMessage, Content}

  require Logger

  @doc """
  Whether `model_id` binds its thinking blocks to the conversation:
  Claude models from version 5.1 on, in every family. The models before
  it are a closed set, so an id this cannot read binds.
  """
  def binds?(model_id) when is_binary(model_id) do
    case Regex.run(~r/^claude-[a-z]+-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$/, model_id) do
      [_, major] -> String.to_integer(major) > 5
      [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)} >= {5, 1}
      nil -> not Regex.match?(~r/^claude-(instant|\d|mythos-preview)/, model_id)
    end
  end

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
  Returns the wire messages and the digest of all of them: the binding
  of the turn the request produces.
  """
  def encode(messages, digest, encode) do
    {encoded, digest} =
      Enum.flat_map_reduce(messages, digest, fn message, digest ->
        wire = encode.(replayable(message, stamp(digest)))
        {wire, Enum.reduce(wire, digest, &chain/2)}
      end)

    {encoded, stamp(digest)}
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

  defp replayable(%AssistantMessage{binding: binding} = message, current)
       when is_binary(binding) and binding != current do
    %{message | content: Enum.reject(message.content, &thinking?/1)}
  end

  defp replayable(message, _current), do: message

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
