defmodule ClementineSmoke.Conversations do
  @moduledoc """
  A conversation's messages: the app's own data. A user's message is
  stored when it arrives, and its id names the turn that answers it; the
  agents' host stores what each turn said after the message it answers.
  The chat agent reads what came before its turn's message as its
  history.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  alias Clementine.LLM.Message
  alias Clementine.LLM.Message.UserMessage
  alias ClementineSmoke.Conversations.Entry
  alias ClementineSmoke.Repo

  @doc "The conversation's messages, in the order the model saw them."
  def messages(conversation_id), do: conversation_id |> entries() |> read()

  @doc """
  What came before the turn that answers `message_id`: every earlier
  message, each followed by what its turn said. The turn's run adds the
  message itself, as its prompt.
  """
  def messages(conversation_id, before: message_id) do
    conversation_id
    |> entries()
    |> where([e], coalesce(e.reply_to, e.id) < ^message_id)
    |> read()
  end

  @doc "Stores a user's message as it arrives. Its id names the turn that answers it."
  def add_message!(conversation_id, text) do
    entry =
      Repo.insert!(%Entry{
        conversation_id: conversation_id,
        message: Message.to_map(UserMessage.new(text))
      })

    entry.id
  end

  @doc "Stores what a turn said, after the message it answers."
  def append_reply!(conversation_id, message_id, messages) do
    now = DateTime.utc_now()

    entries =
      Enum.map(messages, fn message ->
        %{
          conversation_id: conversation_id,
          reply_to: message_id,
          message: Message.to_map(message),
          inserted_at: now
        }
      end)

    Repo.insert_all(Entry, entries)
    :ok
  end

  @doc "The PubSub topic a conversation's runs broadcast on."
  def topic(conversation_id), do: "conversation:" <> conversation_id

  # Each message, then what its turn said: a message that arrived while
  # a turn ran goes after that turn's reply, wherever its row sorts.
  defp entries(conversation_id) do
    from(e in Entry,
      where: e.conversation_id == ^conversation_id,
      order_by: [coalesce(e.reply_to, e.id), e.id]
    )
  end

  defp read(query) do
    query
    |> Repo.all()
    |> Enum.map(&Message.from_map(&1.message))
  end
end
