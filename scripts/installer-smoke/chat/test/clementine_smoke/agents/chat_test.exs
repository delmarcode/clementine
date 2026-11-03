defmodule ClementineSmoke.Agents.ChatTest do
  use ClementineSmoke.AgentsCase

  alias Clementine.LLM.Message.{AssistantMessage, UserMessage}
  alias Clementine.Runs
  alias Clementine.Runs.{StepWorker, TimerWorker, Worker}
  alias ClementineSmoke.Agents.Chat
  alias ClementineSmoke.Agents.LLMMock
  alias ClementineSmoke.Conversations
  alias ClementineSmoke.Repo

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

    assert :ok = perform_job(Worker, %{"run_id" => first.id})

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

    assert :ok = perform_job(Worker, %{"run_id" => second.id})

    id = second.id
    assert {:chat_text, id, "Your name is Ada."} in broadcasts()
    assert length(Conversations.messages(conversation)) == 4
  end

  test "a thread retries a turn that failed with nothing done: the model reads the message " <>
         "once, and the conversation holds it once",
       %{conversation: conversation} do
    {:ok, loop} =
      Runs.start_loop(
        Clementine.Thread,
        %{"agent" => "chat", "on_failure" => "retry", "retry_after_ms" => 1_000},
        subject: {"conversation", conversation}
      )

    # The user's message is stored as it arrives, and sent to the thread.
    id = Conversations.add_message!(conversation, "Hello?")
    message = %{"prompt" => "Hello?", "id" => id, "metadata" => %{"message_id" => id}}
    {:ok, :appended} = Runs.send(loop.id, message)
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    {:ok, first} = Runs.child(loop.id, {:turn, id})

    # The provider is overloaded: a failure the same request may get past.
    expect_turn([{:error, %{"type" => "overloaded_error", "message" => "Overloaded"}}])
    assert :ok = perform_job(Worker, %{"run_id" => first.id})

    # The thread hears it, and runs the turn again after the delay: its
    # timer job, as Oban would run it.
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    [timer] = all_enqueued(worker: TimerWorker)
    assert :ok = perform_job(%{timer | attempt: 1, attempted_at: DateTime.utc_now()})
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    {:ok, retry} = Runs.child(loop.id, {:turn, id})
    assert retry.id != first.id

    expect(LLMMock, :stream, fn _model, _system, messages, _tools, _opts ->
      assert messages == [UserMessage.new("Hello?")]
      text_events("Hi.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => retry.id})

    assert [%UserMessage{content: "Hello?"}, %AssistantMessage{} = reply] =
             Conversations.messages(conversation)

    assert AssistantMessage.get_text(reply) == "Hi."
  end

  test "a second turn waits for the first to finish", %{conversation: conversation} do
    {:ok, _first} = start_turn(conversation, "Hello")
    assert {:error, :active_run_exists} = start_turn(conversation, "Are you there?")
  end

  # The user's message is stored as it arrives, and the turn that
  # answers it starts in the same transaction, or neither happens.
  defp start_turn(conversation, text) do
    Repo.transaction(fn ->
      message_id = Conversations.add_message!(conversation, text)

      case Runs.start(Chat, text,
             subject: {"conversation", conversation},
             metadata: %{"message_id" => message_id}
           ) do
        {:ok, run} -> run
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
