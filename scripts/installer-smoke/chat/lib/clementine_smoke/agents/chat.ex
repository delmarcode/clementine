defmodule ClementineSmoke.Agents.Chat do
  @moduledoc """
  A chat agent: a turn agent. Each turn is one run whose subject is the
  conversation, and the conversation so far is its history.

      Clementine.Runs.start(ClementineSmoke.Agents.Chat, text,
        subject: {"conversation", conversation_id}
      )
  """

  use Clementine.Agent,
    key: "chat",
    turn: true,
    model: :claude_sonnet,
    instructions: "You are a friendly assistant. Answer in a sentence."

  alias ClementineSmoke.Conversations

  @impl true
  def history(run), do: Conversations.messages(run.subject_id)
end
