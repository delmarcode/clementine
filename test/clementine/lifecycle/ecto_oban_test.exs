defmodule Clementine.Lifecycle.Ecto.ObanTest do
  use ExUnit.Case, async: true

  alias Clementine.InterruptReason
  alias Clementine.Lifecycle.Ecto.Oban
  alias Clementine.Lifecycle.Facts

  defp facts(status), do: %Facts{ref: 1, status: status, epoch: 1}
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

    test "a present job is healthy — claim timing is the reaper's queued_at check" do
      assert Oban.judge_job(facts(:queued), job("available")) == :healthy
      assert Oban.judge_job(facts(:queued), job("scheduled")) == :healthy
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
end
