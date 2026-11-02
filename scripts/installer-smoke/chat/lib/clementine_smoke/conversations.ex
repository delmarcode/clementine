defmodule ClementineSmoke.Conversations do
  @moduledoc """
  A conversation's messages: the app's own data. The chat agent reads them
  as its history, and the agents' host appends each finished turn.
  """

  import Ecto.Query, only: [from: 2]

  alias Clementine.LLM.Message
  alias ClementineSmoke.Conversations.Entry
  alias ClementineSmoke.Repo

  @doc "The conversation's messages, oldest first."
  def messages(conversation_id) do
    from(e in Entry,
      where: e.conversation_id == ^conversation_id,
      order_by: e.id,
      select: e.message
    )
    |> Repo.all()
    |> Enum.map(&Message.from_map/1)
  end

  @doc """
  Stores a turn's prompt, unless the turn's is stored already: `turn`
  keys it, and a retry of the turn has the same key and the same prompt.
  """
  def put_prompt!(conversation_id, turn, message) do
    entry = %{
      conversation_id: conversation_id,
      turn: turn,
      message: Message.to_map(message),
      inserted_at: DateTime.utc_now()
    }

    Repo.insert_all(Entry, [entry],
      on_conflict: :nothing,
      conflict_target: [:conversation_id, :turn]
    )

    :ok
  end

  @doc "Appends `messages` to the conversation, in order."
  def append!(conversation_id, messages) do
    now = DateTime.utc_now()

    entries =
      Enum.map(messages, fn message ->
        %{conversation_id: conversation_id, message: Message.to_map(message), inserted_at: now}
      end)

    Repo.insert_all(Entry, entries)
    :ok
  end

  @doc "The PubSub topic a conversation's runs broadcast on."
  def topic(conversation_id), do: "conversation:" <> conversation_id
end
