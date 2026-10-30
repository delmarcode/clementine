defmodule Clementine.Runs.ActorTest do
  @moduledoc """
  The actor: whose authority a run acts with, resolved by the host at
  every claim, refused by it, and seen by the agent and its tools.
  """

  use Clementine.RunsCase

  alias Clementine.Result
  alias Clementine.RunsCase.Host

  setup do
    Process.register(self(), :clementine_runs_test)
    :ok
  end

  test "start/3 stores the actor as text, and get/1 reads it back unresolved" do
    {:ok, run} = Runs.start(Echo, "Hi", actor: {:user, 7})

    assert %AgentRun{actor_type: "user", actor_id: "7", actor: nil} = Runs.get(run.id)
    assert %AgentRun{actor_type: nil, actor_id: nil} = insert_queued_run!()
  end

  test "the host resolves the actor for the agent and its tools, with the rest of the context" do
    {:ok, run} = Runs.start(Lookup, "Who am I?", subject: {"ticket", 42}, actor: {"user", "ada"})
    run_id = run.id

    expect(Clementine.LLM.MockClient, :stream, fn _model, system, _messages, _tools, _opts ->
      assert system =~ ~s(Look up %{ticket: "42"} for %{user: "ada"}.)
      tool_events("toolu_1", "context", %{})
    end)

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      context = inspect(messages, limit: :infinity, printable_limit: :infinity)
      assert context =~ ~s(run_id: \\"#{run_id}\\")
      assert context =~ ~s(agent_key: \\"test_lookup\\")
      assert context =~ "turn: false"
      assert context =~ ~s(subject: %{ticket: \\"42\\"})
      assert context =~ ~s(actor: %{user: \\"ada\\"})
      text_events("Done.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "completed"} = Runs.get(run.id)
  end

  test "a turn's tools see turn: true, and a run without an actor sees nil" do
    {:ok, run} = Runs.start(Handoff, "Take over", subject: {"conversation", "c-1"})

    expect_turn(tool_events("toolu_1", "context", %{}))

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      context = inspect(messages, limit: :infinity, printable_limit: :infinity)
      assert context =~ "turn: true"
      assert context =~ "actor: nil"
      assert context =~ "subject: nil"
      text_events("Taken.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "completed", turn: true} = Runs.get(run.id)
  end

  test "a run whose actor the host refuses is cancelled as unstartable, and the host hears why" do
    {:ok, run} = Runs.start(Echo, "Act", actor: {"suspended", "bob"})

    assert {:cancel, reason} = perform_job(Worker, %{"run_id" => run.id})
    assert reason =~ "actor_suspended"
    assert %AgentRun{status: "cancelled"} = Runs.get(run.id)

    assert_received {:run_finished, _run,
                     %Result.Cancelled{
                       reason: %{"code" => "unstartable", "detail" => ":actor_suspended"}
                     }}
  end

  test "the actor is resolved again at the claim after a resume, so a refusal meanwhile ends the run" do
    {:ok, run} =
      Runs.start(Chat, "Tell the team", subject: {"conversation", "c-1"}, actor: {"user", "ada"})

    expect_turn(tool_events("toolu_1", "send_note", %{text: "hello"}))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "waiting"} = Runs.get(run.id)

    # Ada loses her account while the run waits for approval.
    Host.revoke_actor!("ada")

    assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
    assert {:cancel, reason} = perform_job(Worker, %{"run_id" => run.id})
    assert reason =~ "actor_revoked"
    assert %AgentRun{status: "cancelled"} = Runs.get(run.id)

    assert_received {:run_finished, _run,
                     %Result.Cancelled{
                       reason: %{"code" => "unstartable", "detail" => ":actor_revoked"}
                     }}
  end

  test "list(actor:) is the audit of an actor's runs, newest first" do
    {:ok, first} = Runs.start(Echo, "One", actor: {"user", "ada"})
    {:ok, second} = Runs.start(Lookup, "Two", actor: {"user", "ada"})
    {:ok, _other} = Runs.start(Echo, "Three", actor: {"user", "bob"})
    {:ok, _system} = Runs.start(Echo, "Four")

    assert [%AgentRun{id: second_id}, %AgentRun{id: first_id}] = Runs.list(actor: {"user", "ada"})
    assert {first_id, second_id} == {first.id, second.id}
    assert [%AgentRun{id: ^first_id}] = Runs.list(actor: {"user", "ada"}, agent: Echo)
  end
end
