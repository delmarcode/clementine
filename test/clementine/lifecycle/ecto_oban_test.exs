defmodule Clementine.Lifecycle.Ecto.ObanTest do
  use ExUnit.Case, async: true

  alias Clementine.InterruptReason
  alias Clementine.Lifecycle.Ecto.Oban
  alias Clementine.Lifecycle.Facts

  defp facts(status), do: %Facts{ref: 1, status: status, epoch: 1}
  defp loop_facts(status), do: %Facts{ref: 1, kind: :loop, status: status, epoch: 1}
  defp job(state, id \\ 77), do: %{id: id, state: state}

  describe "waiting (matrix row 10, the load-bearing line)" do
    test "a completed job is the NORMAL state of a suspended run, not evidence of failure" do
      assert Oban.judge_job(facts(:waiting), job("completed")) == :healthy
    end

    test "waiting is healthy whatever the job looks like — even gone" do
      for job <- [nil, job("cancelled"), job("discarded"), job("executing")] do
        assert Oban.judge_job(facts(:waiting), job) == :healthy
      end
    end
  end

  describe "running" do
    test "a vanished job interrupts" do
      assert {:interrupt, %InterruptReason{code: :job_missing}} =
               Oban.judge_job(facts(:running), nil)
    end

    test "cancelled, discarded, and completed-without-terminal each map to their code" do
      assert {:interrupt, %InterruptReason{code: :job_cancelled}} =
               Oban.judge_job(facts(:running), job("cancelled"))

      assert {:interrupt, %InterruptReason{code: :job_discarded}} =
               Oban.judge_job(facts(:running), job("discarded"))

      assert {:interrupt, %InterruptReason{code: :job_completed_without_terminal}} =
               Oban.judge_job(facts(:running), job("completed"))
    end

    test "a live executing job is healthy" do
      assert Oban.judge_job(facts(:running), job("executing")) == :healthy
    end
  end

  describe "queued" do
    test "a missing job means the claimer is never coming" do
      assert {:interrupt, %InterruptReason{code: :job_missing}} =
               Oban.judge_job(facts(:queued), nil)
    end

    test "a cancelled or discarded job is as dead as a missing one (Meli adoption finding)" do
      assert {:interrupt, %InterruptReason{code: :job_cancelled}} =
               Oban.judge_job(facts(:queued), job("cancelled"))

      assert {:interrupt, %InterruptReason{code: :job_discarded}} =
               Oban.judge_job(facts(:queued), job("discarded"))
    end

    test "a live job is healthy — claim timing is the reaper's queued_at check" do
      assert Oban.judge_job(facts(:queued), job("available")) == :healthy
      assert Oban.judge_job(facts(:queued), job("scheduled")) == :healthy
    end

    test "a completed job is healthy: a drain requeue briefly correlates to the old job" do
      assert Oban.judge_job(facts(:queued), job("completed")) == :healthy
    end
  end

  describe "terminal" do
    test "nothing left to judge" do
      for status <- Facts.terminal_statuses() do
        assert Oban.judge_job(facts(status), nil) == :healthy
        assert Oban.judge_job(facts(status), job("completed")) == :healthy
      end
    end
  end

  describe "loop-kind runs (amendment A3: the cross-check must not kill a standing entity)" do
    test "matrix row L16: dead-job evidence under a running loop requeues — the step is replayable by construction" do
      assert Oban.judge_job(loop_facts(:running), nil) == {:requeue, :job_missing}
      assert Oban.judge_job(loop_facts(:running), job("cancelled")) == {:requeue, :job_cancelled}
      assert Oban.judge_job(loop_facts(:running), job("discarded")) == {:requeue, :job_discarded}

      assert Oban.judge_job(loop_facts(:running), job("completed")) ==
               {:requeue, :job_completed_without_terminal}

      assert Oban.judge_job(loop_facts(:running), job("executing")) == :healthy
    end

    test "matrix row L15: dead-job evidence under a queued loop reenqueues — the row is fine, only the job is lost" do
      assert Oban.judge_job(loop_facts(:queued), nil) == {:reenqueue, :job_missing}
      assert Oban.judge_job(loop_facts(:queued), job("cancelled")) == {:reenqueue, :job_cancelled}
      assert Oban.judge_job(loop_facts(:queued), job("discarded")) == {:reenqueue, :job_discarded}

      assert Oban.judge_job(loop_facts(:queued), job("available")) == :healthy
    end

    test "a queued loop's completed job is healthy — a step continue briefly correlates to the previous step's job" do
      assert Oban.judge_job(loop_facts(:queued), job("completed")) == :healthy
    end

    test "waiting and terminal loops are healthy whatever the job looks like" do
      for status <- [:waiting | Facts.terminal_statuses()],
          job <- [nil, job("cancelled"), job("discarded"), job("completed")] do
        assert Oban.judge_job(loop_facts(status), job) == :healthy
      end
    end

    test "loop verdicts here record through the firing-rate seam — a dead step job heals visibly" do
      # The cross-check is the judge that sees a dead job BEFORE the claim
      # timeout ages, so without this emission the reenqueue self-healing
      # would never reach [:clementine, :loop, :verdict]. Unique refs pin
      # the assertions against async siblings emitting the same event.
      handler_id = "oban-test-#{inspect(self())}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:clementine, :loop, :verdict],
        fn _event, _measurements, metadata, _config -> send(parent, {:verdict, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      lost = %Facts{ref: make_ref(), kind: :loop, status: :queued, epoch: 40}
      assert Oban.judge_job(lost, job("cancelled")) == {:reenqueue, :job_cancelled}
      ref = lost.ref

      assert_receive {:verdict,
                      %{loop_ref: ^ref, epoch: 40, verdict: :reenqueue, detail: :job_cancelled}}

      crashed = %Facts{ref: make_ref(), kind: :loop, status: :running, epoch: 41}
      assert Oban.judge_job(crashed, nil) == {:requeue, :job_missing}
      ref = crashed.ref

      assert_receive {:verdict, %{loop_ref: ^ref, verdict: :requeue, detail: :job_missing}}

      # Healthy loop judgments and rollout verdicts stay off the seam —
      # rollout rates ride the :reaped/:requeued commit events.
      healthy = %Facts{ref: make_ref(), kind: :loop, status: :queued, epoch: 42}
      assert Oban.judge_job(healthy, job("available")) == :healthy

      rollout = %Facts{ref: make_ref(), status: :queued, epoch: 1}
      assert {:interrupt, _reason} = Oban.judge_job(rollout, nil)

      healthy_ref = healthy.ref
      rollout_ref = rollout.ref
      refute_receive {:verdict, %{loop_ref: ^healthy_ref}}, 50
      refute_receive {:verdict, %{loop_ref: ^rollout_ref}}, 50
    end
  end
end
