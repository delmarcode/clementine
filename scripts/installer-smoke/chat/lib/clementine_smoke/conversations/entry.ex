defmodule ClementineSmoke.Conversations.Entry do
  @moduledoc """
  One message of a conversation, as `Clementine.LLM.Message.to_map/1`
  stores it. A turn's prompt carries the turn's key (`turn`), so it is
  stored once.
  """

  use Ecto.Schema

  schema "conversation_messages" do
    field(:conversation_id, :string)
    field(:turn, :string)
    field(:message, :map)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
