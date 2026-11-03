defmodule ClementineSmoke.Conversations.Entry do
  @moduledoc """
  One message of a conversation, as `Clementine.LLM.Message.to_map/1`
  stores it. A message a turn said carries the id of the user's message
  it answers (`reply_to`).
  """

  use Ecto.Schema

  schema "conversation_messages" do
    field(:conversation_id, :string)
    field(:reply_to, :id)
    field(:message, :map)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
