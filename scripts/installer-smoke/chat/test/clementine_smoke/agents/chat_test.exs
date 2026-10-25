defmodule ClementineSmoke.Agents.ChatTest do
  use ClementineSmoke.AgentsCase

  alias Clementine.LLM.Message.{AssistantMessage, UserMessage}
  alias ClementineSmoke.Agents.Chat
  alias ClementineSmoke.Agents.LLMMock
  alias ClementineSmoke.Conversations

  setup do
    conversation = Ecto.UUID.generate()
    :ok = Phoenix.PubSub.subscribe(ClementineSmoke.PubSub, Conversations.topic(conversation))
    %{conversation: conversation}
  end

  test "a conversation streams each turn and remembers the turns before it", %{
    conversation: conversation
  } do
    # Turn one: nothing came before.
    {:ok, first} = start_turn(conversation, "My name is Ada.")

    expect(LLMMock, :stream, fn _model, _system, messages, _tools, _opts ->
      assert messages == [UserMessage.new("My name is Ada.")]
      text_events("Hello, Ada.")
    end)

    assert :ok = perform_job(Clementine.Runs.Worker, %{"run_id" => first.id})

    id = first.id

    assert [
             {:chat_status, ^id, :claimed},
             {:chat_text, ^id, "Hello, Ada."},
             {:chat_ended, ^id, :completed}
           ] = broadcasts()

    # Turn two: the model sees turn one, then the new prompt.
    {:ok, second} = start_turn(conversation, "What is my name?")

    expect(LLMMock, :stream, fn _model, _system, messages, _tools, _opts ->
      assert [
               %UserMessage{content: "My name is Ada."},
               %AssistantMessage{} = reply,
               %UserMessage{content: "What is my name?"}
             ] = messages

      assert AssistantMessage.get_text(reply) == "Hello, Ada."
      text_events("Your name is Ada.")
    end)

    assert :ok = perform_job(Clementine.Runs.Worker, %{"run_id" => second.id})

    id = second.id
    assert {:chat_text, id, "Your name is Ada."} in broadcasts()
    assert length(Conversations.messages(conversation)) == 4
  end

  test "a second turn waits for the first to finish", %{conversation: conversation} do
    {:ok, _first} = start_turn(conversation, "Hello")
    assert {:error, :active_run_exists} = start_turn(conversation, "Are you there?")
  end

  defp start_turn(conversation, text) do
    Clementine.Runs.start(Chat, text, subject: {"conversation", conversation})
  end

  # What the conversation's topic carried, in order.
  defp broadcasts do
    receive do
      {:chat_status, _id, _transition} = message -> [message | broadcasts()]
      {:chat_text, _id, _text} = message -> [message | broadcasts()]
      {:chat_ended, _id, _status} = message -> [message | broadcasts()]
    after
      0 -> []
    end
  end
end
