defmodule Clementine.Runs.ReaperTest do
  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Clementine.Reconciler.Policy
  alias Clementine.Runs.Reaper

  describe "sweep/1" do
    test "interrupts a run whose job is gone" do
      run = insert_queued_run!()

      assert %{interrupted: 1} = Reaper.sweep()

      assert %AgentRun{status: "interrupted", interrupt: %{"code" => "job_missing"}} =
               Runs.get(run.id)
    end

    test "leaves a run that waits for a free slot in a busy queue, however long" do
      # A burst bigger than the agents queue's limit: this run's job is still
      # available, so no worker has had a chance to claim it.
      {:ok, run} = Runs.start(Echo, "Busy queue")
      backdate!(run, 16)

      assert %{interrupted: 0} = Reaper.sweep()
      assert %AgentRun{status: "queued"} = Runs.get(run.id)
    end

    test "interrupts a run whose worker started but never claimed it" do
      {:ok, run} = Runs.start(Echo, "Wedged")
      backdate!(run, 16, job_state: "executing")

      assert %{interrupted: 1} = Reaper.sweep()
      assert %AgentRun{status: "interrupted"} = Runs.get(run.id)
    end

    test "leaves a run whose worker started recently, however long it queued" do
      {:ok, run} = Runs.start(Echo, "Slow start")
      backdate!(run, 16, job_state: "executing")

      {1, _} =
        TestRepo.update_all(from(j in Oban.Job, where: j.id == ^run.oban_job_id),
          set: [attempted_at: DateTime.utc_now()]
        )

      assert %{interrupted: 0} = Reaper.sweep()
      assert %AgentRun{status: "queued"} = Runs.get(run.id)
    end

    test "leaves a parked run alone" do
      {:ok, run} = Runs.start(Approval, "Tell the team")
      expect_turn(tool_events("toolu_1", "send_note", %{text: "hello"}))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert %{interrupted: 0, requeued: 0} = Reaper.sweep()
      assert %AgentRun{status: "waiting"} = Runs.get(run.id)
    end

    test "requeues a dead run with no effects, with a new job, when the policy says so" do
      {:ok, run} = Runs.start(Echo, "Dead node")
      dead_executor!(run)

      policy = Policy.new(retry: {:requeue, max_claims: 3})
      assert %{requeued: 1} = Reaper.sweep(policy)

      requeued = Runs.get(run.id)
      assert %AgentRun{status: "queued"} = requeued
      assert requeued.oban_job_id != run.oban_job_id
      assert_enqueued(worker: Worker, args: %{"run_id" => run.id}, state: "available")
    end

    test "interrupts a dead run under the default policy" do
      {:ok, run} = Runs.start(Echo, "Dead node")
      dead_executor!(run)

      assert %{interrupted: 1} = Reaper.sweep()
      assert %AgentRun{status: "interrupted"} = Runs.get(run.id)
    end
  end

  describe "the reaper process" do
    test "sweeps as soon as it starts" do
      run = insert_queued_run!()

      pid = start_supervised!({Reaper, name: :reaper_test})
      # The first sweep is the first message the reaper handles.
      :sys.get_state(pid)

      assert %AgentRun{status: "interrupted"} = Runs.get(run.id)
    end

    test "logs a failed sweep and keeps running" do
      :persistent_term.erase({Clementine.Runs.Config, :config})

      log =
        capture_log(fn ->
          pid = start_supervised!({Reaper, name: :reaper_test})
          :sys.get_state(pid)
          send(pid, :unexpected)
          :sys.get_state(pid)
          assert Process.alive?(pid)
        end)

      assert log =~ "Agent run sweep failed"
    end

    test "does not start while Oban runs in a testing mode" do
      children =
        for {id, _pid, :worker, _modules} <- Supervisor.which_children(Clementine.Runs.Supervisor),
            do: id

      assert Enum.sort(children) == [Clementine.Runs.CancelRelay, Clementine.Runs.DrainNotifier]
    end
  end

  # A claimed run whose node died: running, its heartbeat two hours old,
  # its job gone with the node.
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
