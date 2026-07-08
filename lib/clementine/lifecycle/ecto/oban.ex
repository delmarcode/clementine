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
  alias Clementine.Reconciler

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

  Reaper policy forks by kind here too (LOOP_RFC amendment A3): the same
  dead-job evidence that terminally interrupts a rollout must not kill a
  standing entity. For loop-kind facts a dead job under a `running` run is
  `{:requeue, code}` — the step is replayable by construction — and under
  a `queued` run it is `{:reenqueue, code}`: the host re-inserts the step
  job (the run row is fine; only the job is lost). The reason atoms are
  the same codes the interrupt taxonomy uses. A queued loop's *completed*
  job stays `:healthy` for the same correlation reason as rollouts — a
  step `continue`'s fresh row briefly points at the legitimately
  completed previous step job.

  Loop-kind verdicts here record through the same
  `[:clementine, :loop, :verdict]` seam as the facts-judge, so the firing
  rate counts the Oban path too — the cross-check is precisely the judge
  that sees a dead step job *before* the claim timeout ages. Consult the
  cross-check only for rows the facts-judge passed (the natural wiring —
  job evidence adds nothing once the facts convicted) and each firing
  counts exactly once.

  The verdict is evidence, not action: the reaper turns `{:interrupt, _}`
  into `Clementine.Lifecycle.Protocol.interrupt/4` guarded by these exact
  facts, so a racing live finish wins cleanly — and `{:requeue, _}` into
  `Protocol.requeue/4` the same way.
  """
  @spec judge_job(Facts.t(), %{optional(atom()) => term()} | nil) ::
          :healthy
          | {:interrupt, InterruptReason.t()}
          | {:requeue, InterruptReason.code()}
          | {:reenqueue, InterruptReason.code()}
  def judge_job(%Facts{status: :waiting}, _job), do: :healthy

  # Loop verdicts record through the same telemetry seam as the
  # facts-judge: a dead step job is judged and re-inserted long before
  # claim_timeout lets `Reconciler.judge/3` see it, so without the
  # emission here those self-healings would never reach the firing rate.
  def judge_job(%Facts{kind: :loop, status: :running} = facts, nil) do
    Reconciler.record_loop_verdict(facts, {:requeue, :job_missing})
  end

  def judge_job(%Facts{kind: :loop, status: :running} = facts, %{state: state})
      when state in ["cancelled", "discarded", "completed"] do
    Reconciler.record_loop_verdict(facts, {:requeue, job_code(state)})
  end

  def judge_job(%Facts{kind: :loop, status: :queued} = facts, nil) do
    Reconciler.record_loop_verdict(facts, {:reenqueue, :job_missing})
  end

  def judge_job(%Facts{kind: :loop, status: :queued} = facts, %{state: state})
      when state in ["cancelled", "discarded"] do
    Reconciler.record_loop_verdict(facts, {:reenqueue, job_code(state)})
  end

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

  defp job_code("cancelled"), do: :job_cancelled
  defp job_code("discarded"), do: :job_discarded
  defp job_code("completed"), do: :job_completed_without_terminal
end
