defmodule Clementine.History do
  @moduledoc """
  The window of a long thread a turn replays, cut so the model's earlier
  reasoning survives from one turn to the next.

  A turn agent's `c:Clementine.Agent.history/1` returns the thread's
  messages before the turn's prompt. A thread can outgrow what a turn
  should replay, and the usual cut, the last N messages, moves by a
  message or two every turn. On a model that binds its thinking to the
  conversation before it (Claude Fable 5.1, Mythos 5.1, Opus 5.5, Sonnet
  5.5, Haiku 5.5, and later), every move voids every replayed turn's thinking, so a
  sliding window replays none, ever. `window/2` cuts in steps instead:
  the window keeps its start while the thread grows by half its size,
  then moves forward by that half at once. The turns after a move keep
  their thinking until the next one, and only the move itself costs the
  model what it had reasoned before (Clementine sends a turn without its
  thinking once what came before it changed; see the guide's "Models
  that bind their thinking").

      @impl true
      def history(run) do
        run.subject_id
        |> MyApp.Chat.messages()
        |> Clementine.History.window(max: 100)
      end

  Give it every message of the thread, oldest first, in the order the
  model saw them: each turn's prompt, then what the turn returned
  (`Clementine.Result.Completed`'s `input_message` and `messages`,
  system messages included), never sorted some other way. A message the
  app adds between turns goes where it was added.
  """

  alias Clementine.LLM.Message.{AssistantMessage, SystemMessage, ToolResultMessage, UserMessage}

  @doc """
  The messages a turn replays: all of them while there are at most
  `max:`, otherwise the thread from a cut that moves in steps of half of
  `max:`, at the first prompt from there on (or, when no prompt follows
  the cut, the last one before it). A tool exchange the thread ends
  inside is left out, as are messages before the first prompt.

  The system messages before the window's start come along, in their
  order, after the window's first prompt: a skill an earlier turn loaded
  stays loaded, and its tools stay in front of the model, however far
  back the load was. They sit in the same place until the next step, so
  the window's turns keep their thinking.
  """
  @spec window([Clementine.LLM.Message.message()], keyword()) :: [
          Clementine.LLM.Message.message()
        ]
  def window(messages, opts) when is_list(messages) do
    max = Keyword.fetch!(opts, :max)

    unless is_integer(max) and max > 0 do
      raise ArgumentError, "Clementine.History.window/2 takes max: a positive integer"
    end

    {before, kept} = Enum.split(messages, start(messages, cut(length(messages), max)))

    kept
    |> drop_open_exchange()
    |> carry(for(%SystemMessage{} = message <- before, do: message))
  end

  defp cut(count, max) when count <= max, do: 0

  defp cut(count, max) do
    step = max(div(max, 2), 1)
    div(count - max + step - 1, step) * step
  end

  # The first prompt from the cut on, else the last before it: a turn
  # longer than half the window still replays from its prompt.
  defp start(messages, cut) do
    prompts = for {%UserMessage{}, index} <- Enum.with_index(messages), do: index

    case Enum.split_with(prompts, &(&1 < cut)) do
      {_before, [first | _]} -> first
      {[_ | _] = before, []} -> List.last(before)
      {[], []} -> length(messages)
    end
  end

  defp prompt?(%UserMessage{}), do: true
  defp prompt?(_message), do: false

  defp drop_open_exchange(messages) do
    messages
    |> Enum.reverse()
    |> Enum.drop_while(&open?/1)
    |> Enum.reverse()
  end

  # A system message the thread ends on followed its exchange's results,
  # so it is part of that exchange; the API also refuses one that the
  # next prompt follows.
  defp open?(%ToolResultMessage{}), do: true
  defp open?(%SystemMessage{}), do: true
  defp open?(%AssistantMessage{} = message), do: AssistantMessage.has_tool_use?(message)
  defp open?(_message), do: false

  # After the window's leading prompts, before its first reply: the API
  # takes a system message after a user message and before an assistant
  # one. A skill the window loads again is announced there already.
  defp carry(messages, []), do: messages

  defp carry(messages, carried) do
    loaded = for %SystemMessage{skill: skill} <- messages, is_binary(skill), do: skill
    carried = Enum.reject(carried, &(&1.skill in loaded and is_binary(&1.skill)))

    case Enum.split_while(messages, &prompt?/1) do
      {[_ | _] = prompts, [_ | _] = rest} -> prompts ++ carried ++ rest
      _nowhere -> messages
    end
  end
end
