defmodule Clementine.History do
  @moduledoc """
  The window of a long thread a turn replays, cut so the model's earlier
  reasoning survives from one turn to the next.

  A turn agent's `c:Clementine.Agent.history/1` returns the thread's
  messages before the turn's prompt. A thread can outgrow what a turn
  should replay, and the usual cut, the last N messages, moves by a
  message or two every turn. On a model that binds its thinking to the
  conversation before it (Claude Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku
  5.5, and later), every move voids every replayed turn's thinking, so a
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

  alias Clementine.LLM.Message.{AssistantMessage, ToolResultMessage, UserMessage}

  @doc """
  The messages a turn replays: all of them while there are at most
  `max:`, otherwise the thread from a cut that moves in steps of half of
  `max:`, at the first prompt from there on. A tool exchange the thread
  ends inside is left out, as are messages before the first prompt.
  """
  @spec window([Clementine.LLM.Message.message()], keyword()) :: [
          Clementine.LLM.Message.message()
        ]
  def window(messages, opts) when is_list(messages) do
    max = Keyword.fetch!(opts, :max)

    unless is_integer(max) and max > 0 do
      raise ArgumentError, "Clementine.History.window/2 takes max: a positive integer"
    end

    messages
    |> Enum.drop(cut(length(messages), max))
    |> Enum.drop_while(&(not prompt?(&1)))
    |> drop_open_exchange()
  end

  defp cut(count, max) when count <= max, do: 0

  defp cut(count, max) do
    step = max(div(max, 2), 1)
    div(count - max + step - 1, step) * step
  end

  defp prompt?(%UserMessage{}), do: true
  defp prompt?(_message), do: false

  defp drop_open_exchange(messages) do
    messages
    |> Enum.reverse()
    |> Enum.drop_while(&open?/1)
    |> Enum.reverse()
  end

  defp open?(%ToolResultMessage{}), do: true
  defp open?(%AssistantMessage{} = message), do: AssistantMessage.has_tool_use?(message)
  defp open?(_message), do: false
end
