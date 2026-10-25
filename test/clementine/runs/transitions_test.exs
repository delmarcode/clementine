defmodule Clementine.Runs.TransitionsTest do
  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Clementine.Reconciler.Policy
  alias Clementine.Result
  alias Clementine.Runs.Reaper

  setup do
    Process.register(self(), :clementine_runs_test)
    :ok
  end

  test "the host hears the claim after its commit, and the end only through run_committed/2" do
    {:ok, run} = Runs.start(Echo, "Say hello")
    id = run.id

    expect_turn(text_events("Hello."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert_received {:run_transition, %AgentRun{id: ^id, status: "running", subject: nil},
                     :claimed, false = _in_transaction?}

    assert_received {:run_committed, %AgentRun{status: "completed"}, %Result.Completed{}, false}
    refute_received {:run_transition, _run, _transition, _in_transaction?}
  end

  test "a suspension and its resume are heard after their commits" do
    {:ok, run} = Runs.start(Approval, "Tell the team")

    expect_turn(tool_events("toolu_1", "send_note", %{text: "hello"}))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert_received {:run_transition, %AgentRun{status: "running"}, :claimed, false}
    assert_received {:run_transition, %AgentRun{status: "waiting"}, :suspended, false}

    # Resume writes inside its own transaction, with the run's new job; the
    # host hears of it once that commits.
    assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
    assert_received {:run_transition, %AgentRun{status: "queued"}, :resumed, false}

    expect_turn(text_events("Sent."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert_received {:run_transition, %AgentRun{status: "running"}, :claimed, false}
    refute_received {:run_transition, _run, _transition, _in_transaction?}
  end

  test "a refused resume is never heard" do
    {:ok, run} = Runs.start(Approval, "Tell the team")
    expect_turn(tool_events("toolu_1", "send_note", %{text: "hello"}))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert_received {:run_transition, _run, :suspended, _in_transaction?}

    assert {:error, :forbidden} = Runs.resume(run.id, {:approved, %{by: "mallory"}})
    refute_received {:run_transition, _run, :resumed, _in_transaction?}
  end

  test "resume/2 refuses to run inside the caller's transaction" do
    {:ok, run} = Runs.start(Approval, "Tell the team")
    expect_turn(tool_events("toolu_1", "send_note", %{text: "hello"}))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert_raise RuntimeError, ~r/resume\/2 was called inside a transaction/, fn ->
      TestRepo.transaction(fn -> Runs.resume(run.id, {:approved, %{by: "alice"}}) end)
    end

    assert %AgentRun{status: "waiting"} = Runs.get(run.id)
    refute_received {:run_transition, _run, :resumed, _in_transaction?}
  end

  test "a drain's requeue is heard" do
    {:ok, run} = Runs.start(Lookup, "Look it up")
    worker = self()

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      send(worker, {:clementine, :drain})
      tool_events("toolu_1", "lookup", %{query: "the weather"})
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert_received {:run_transition, %AgentRun{status: "queued"}, :requeued, false}
  end

  test "the reaper's requeue is heard after its commit" do
    {:ok, run} = Runs.start(Echo, "Dead node")
    id = run.id
    dead_executor!(run)

    assert %{requeued: 1} = Reaper.sweep(Policy.new(retry: {:requeue, max_claims: 3}))
    assert_received {:run_transition, %AgentRun{id: ^id, status: "queued"}, :requeued, false}
  end

  test "a cancel flag on a running run is heard" do
    {:ok, run} = Runs.start(Echo, "Long answer")
    id = run.id

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      assert {:ok, :flagged} = Runs.cancel(id)
      text_events("Done anyway.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert_received {:run_transition, %AgentRun{id: ^id, status: "running"}, :cancel_requested,
                     false}
  end

  test "cancelling a queued run ends it, which only run_committed/2 hears" do
    {:ok, run} = Runs.start(Echo, "Never mind")

    assert {:ok, :finished} = Runs.cancel(run.id)
    assert_received {:run_committed, %AgentRun{status: "cancelled"}, %Result.Cancelled{}, false}
    refute_received {:run_transition, _run, _transition, _in_transaction?}
  end

  test "a raising run_transition/2 is logged, and the change stands" do
    {:ok, run} = Runs.start(Echo, "Say hello", metadata: %{"transition_probe" => "raise"})

    expect_turn(text_events("Hello."))

    log = capture_log(fn -> assert :ok = perform_job(Worker, %{"run_id" => run.id}) end)

    assert log =~ "Clementine.RunsCase.Host.run_transition/2 raised: transition probe"
    assert log =~ "transition: claimed"
    assert %AgentRun{status: "completed"} = Runs.get(run.id)
  end

  defp dead_executor!(run) do
    long_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

    {1, _} =
      TestRepo.update_all(from(r in AgentRun, where: r.id == ^run.id),
        set: [
          status: "running",
          lease_epoch: 1,
          executor_id: "oban:1:dead@node",
          heartbeat_at: long_ago,
          deadline: DateTime.add(DateTime.utc_now(), 1, :hour)
        ]
      )

    {1, _} =
      TestRepo.update_all(from(j in Oban.Job, where: j.id == ^run.oban_job_id),
        set: [state: "executing", attempted_at: long_ago]
      )

    :ok
  end
end
