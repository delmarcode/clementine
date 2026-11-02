defmodule ClementineSmoke.Agents.Chat do
  @moduledoc """
  A chat agent: a turn agent. Each turn is one run whose subject is the
  conversation, and the conversation before the turn is its history.

      Clementine.Runs.start(ClementineSmoke.Agents.Chat, text,
        subject: {"conversation", conversation_id}
      )

  A `Clementine.Thread` (`%{"agent" => "chat"}`) runs its turns the same
  way, one message at a time.
  """

  use Clementine.Agent,
    key: "chat",
    turn: true,
    model: "claude-sonnet-5",
    instructions: "You are a friendly assistant. Answer in a sentence."

  alias ClementineSmoke.Conversations

  @impl true
  def history(run), do: Conversations.before_turn(run.subject_id, Conversations.turn_key(run))
end
