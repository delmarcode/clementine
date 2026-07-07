defmodule Clementine.Lifecycle.Ecto.Oban do
  @moduledoc """
  The executor cross-check for Oban-backed runners, learned the hard way in
  production: Oban can cancel, discard, or lose a job without the run ever
  reaching a terminal status, and only a status-scoped judgment tells those
  apart from healthy states.

  The host correlates run to job through its own column (e.g. an
  `oban_job_id` on the run row, updated at enqueue and every re-enqueue);
  `executor_id` is a human/telemetry string and is never parsed for
  correlation. The job argument is duck-typed on Oban's `state` field, so
  this module carries no Oban dependency.
  """

  alias Clementine.InterruptReason
  alias Clementine.Lifecycle.Facts

  @doc """
  Judges a run's facts against its Oban job (or `nil` when the job row is
  gone). Status-scoped — each verdict applies only where its evidence means
  something:

    * `waiting` — always `:healthy`. The job *completed* legitimately at
      suspend; a completed job is the normal state of a suspended run, not
      evidence of failure. (A resumed run sitting in `queued` has a *new*
      job — pass that one.)
    * `running` — job missing, cancelled, discarded, or completed without
      the run reaching a terminal is an interrupt verdict.
    * `queued` — a missing, cancelled, or discarded job means the claimer
      is never coming: `:job_missing` / `:job_cancelled` / `:job_discarded`
      (Meli adoption finding: an operator cancelling a queued job must not
      strand the run until the claim timeout). A *completed* job is judged
      `:healthy` here — a drain requeue's fresh `queued` row briefly
      correlates to the old, legitimately completed job until the host
      re-links `oban_job_id`; the claim-timeout check covers the
      pathological completed-without-claiming case. (Requeue-instead-of-
      interrupt is reaper policy, one level up.)
    * terminal — `:healthy`; nothing left to judge.

  The verdict is evidence, not action: the reaper turns `{:interrupt, _}`
  into `Clementine.Lifecycle.Protocol.interrupt/4` guarded by these exact
  facts, so a racing live finish wins cleanly.
  """
  @spec judge_job(Facts.t(), %{optional(atom()) => term()} | nil) ::
          :healthy | {:interrupt, InterruptReason.t()}
  def judge_job(%Facts{status: :waiting}, _job), do: :healthy

  def judge_job(%Facts{status: :running}, nil) do
    {:interrupt, InterruptReason.new(:job_missing, "no job found for running run")}
  end

  def judge_job(%Facts{status: :running}, %{state: "cancelled"} = job) do
    {:interrupt, InterruptReason.new(:job_cancelled, job_detail(job))}
  end

  def judge_job(%Facts{status: :running}, %{state: "discarded"} = job) do
    {:interrupt, InterruptReason.new(:job_discarded, job_detail(job))}
  end

  def judge_job(%Facts{status: :running}, %{state: "completed"} = job) do
    {:interrupt, InterruptReason.new(:job_completed_without_terminal, job_detail(job))}
  end

  def judge_job(%Facts{status: :running}, _job), do: :healthy

  def judge_job(%Facts{status: :queued}, nil) do
    {:interrupt, InterruptReason.new(:job_missing, "no job found for queued run")}
  end

  def judge_job(%Facts{status: :queued}, %{state: "cancelled"} = job) do
    {:interrupt, InterruptReason.new(:job_cancelled, job_detail(job))}
  end

  def judge_job(%Facts{status: :queued}, %{state: "discarded"} = job) do
    {:interrupt, InterruptReason.new(:job_discarded, job_detail(job))}
  end

  def judge_job(%Facts{status: :queued}, _job), do: :healthy

  def judge_job(%Facts{} = facts, _job) do
    true = Facts.terminal?(facts)
    :healthy
  end

  defp job_detail(%{state: state} = job) do
    case job do
      %{id: id} when not is_nil(id) -> "oban job #{id} is #{state}"
      _ -> "oban job is #{state}"
    end
  end
end
