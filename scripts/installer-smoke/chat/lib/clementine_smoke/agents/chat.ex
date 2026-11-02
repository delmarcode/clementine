defmodule ClementineSmoke.Agents.Chat do
  @moduledoc """
  A chat agent: a turn agent. Each turn is one run whose subject is the
  conversation. The user's message is stored when it arrives and named
  in the turn's metadata, and what came before it is the turn's history:

      message_id = Conversations.add_message!(conversation_id, text)

      Clementine.Runs.start(ClementineSmoke.Agents.Chat, text,
        subject: {"conversation", conversation_id},
        metadata: %{"message_id" => message_id}
      )

  A `Clementine.Thread` (`%{"agent" => "chat"}`) runs its turns the same
  way, one message at a time, sent as `%{"prompt" => text, "id" =>
  message_id, "metadata" => %{"message_id" => message_id}}`.
  """

  use Clementine.Agent,
    key: "chat",
    turn: true,
    model: "claude-sonnet-5",
    instructions: "You are a friendly assistant. Answer in a sentence."

  alias ClementineSmoke.Conversations

  @impl true
  def history(run), do: Conversations.messages(run.subject_id, before: run.metadata["message_id"])
end
