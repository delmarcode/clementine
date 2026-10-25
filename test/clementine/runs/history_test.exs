defmodule Clementine.Runs.HistoryTest do
  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]

  alias Clementine.LLM.Message
  alias Clementine.LLM.Message.{AssistantMessage, ToolResultMessage, UserMessage}
  alias Clementine.Result

  setup do
    Process.register(self(), :clementine_runs_test)
    :ok
  end

  @history [UserMessage.new("My name is Ada."), AssistantMessage.text("Hello, Ada.")]

  defp start_chat!(prompt, history) do
    {:ok, run} =
      Runs.start(Chat, prompt,
        subject: {"ticket", "t-1"},
        metadata: %{"history" => Enum.map(history, &Message.to_map/1)}
      )

    run
  end

  test "the model sees the agent's history, then the prompt" do
    run = start_chat!("What is my name?", @history)

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      assert messages == @history ++ [UserMessage.new("What is my name?")]
      text_events("Ada.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    # history/1 runs after the subject resolves.
    assert_received {:history, %AgentRun{subject: %{ticket: "t-1"}}}

    # The result holds the prompt and what the run said, never the history.
    assert_received {:run_finished, _run,
                     %Result.Completed{
                       input_message: %UserMessage{content: "What is my name?"},
                       messages: [%AssistantMessage{}]
                     }}
  end

  test "an agent without history starts from its prompt" do
    {:ok, run} = Runs.start(Echo, "Hello")

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      assert messages == [UserMessage.new("Hello")]
      text_events("Hi.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert Echo.history(run) == []
  end

  test "a resumed run continues from its checkpoint without reading history again" do
    run = start_chat!("Send Ada a note", @history)

    expect_turn(tool_events("toolu_1", "send_note", %{text: "hi"}))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert_received {:history, _run}
    assert %AgentRun{status: "waiting"} = Runs.get(run.id)

    # The conversation moved on while the run waited; the run's own
    # conversation is in its checkpoint.
    {1, _} =
      TestRepo.update_all(from(r in AgentRun, where: r.id == ^run.id),
        set: [metadata: %{"history" => "unreadable now"}]
      )

    assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      assert Enum.take(messages, 3) == @history ++ [UserMessage.new("Send Ada a note")]
      text_events("Sent.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    refute_received {:history, _run}
    assert %AgentRun{status: "completed"} = Runs.get(run.id)

    # What the run said, across the suspension, and nothing before its prompt.
    assert_received {:run_finished, _run,
                     %Result.Completed{
                       messages: [
                         %AssistantMessage{},
                         %ToolResultMessage{},
                         %AssistantMessage{}
                       ]
                     }}
  end

  test "history that is not a list of messages cancels the run as unstartable" do
    {:ok, run} = Runs.start(Chat, "Hello", metadata: %{"history" => "not messages"})

    assert {:cancel, reason} = perform_job(Worker, %{"run_id" => run.id})
    assert reason =~ "Clementine.RunsCase.Chat.history/1 must return a list"

    assert %AgentRun{status: "cancelled"} = Runs.get(run.id)

    assert_received {:run_finished, _run,
                     %Result.Cancelled{reason: %{"code" => "unstartable", "detail" => detail}}}

    assert detail =~ ~s|got: "not messages"|
  end
end
