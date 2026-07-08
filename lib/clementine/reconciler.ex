defmodule Clementine.Reconciler do
  @moduledoc """
  Reaper judgment: the pure, status-scoped half of stale-run
  reconciliation. The host owns the sweep query (its table, its rows); the
  library owns the verdict and the transition it becomes:

      lifecycle = MyApp.ClementineLifecycle
      now = MyApp.Runs.db_now!()          # storage clock — same source the stamps use
      policy = Clementine.Reconciler.Policy.new(retry: {:requeue, max_claims: 3})

      # The rollout sweep: active AND kind = 'rollout', both in SQL.
      for facts <- MyApp.Runs.active_rollout_run_facts() do
        case Clementine.Reconciler.judge(facts, now, policy) do
          :healthy ->
            :ok

          {:interrupt, reason} ->
            Clementine.Lifecycle.Protocol.interrupt(lifecycle, facts, reason)

          {:requeue, reason} ->
            Clementine.Lifecycle.Protocol.requeue(lifecycle, facts, reason)
            # then re-enqueue the job, exactly as after a resume
        end
      end

  This judgment is *rollout* judgment, and the sweep query must exclude
  loop-kind rows in SQL (`WHERE kind = 'rollout'`), not by filtering
  fetched facts: a parked loop is a permanently `waiting` row *by design*
  (LOOP_RFC §Operations — "hibernation" is what `waiting` already is), so
  at fleet scale an unscoped sweep pays for every dormant loop on every
  cadence. Loop-kind rows get their own policy fork and verdicts (LOOP_RFC
  amendment A3), on their own slower cadence over loop rows only — this
  module's rules would judge them wrongly (the epoch-as-attempt-cap gate
  alone would terminally interrupt a long-lived loop on its first crashed
  step).

  `now` must come from the storage clock — the same source that stamped
  the facts — or be compared in the database; a node-local
  `DateTime.utc_now/0` reintroduces the two-clock problem the symbolic
  stamps removed.

  A verdict is evidence, not action: every verdict lands as a CAS guarded
  by the exact observed `(status, epoch)`, so concurrent sweeps on many
  nodes need no coordination — a reaper racing a live finish, or another
  reaper, loses cleanly (`{:error, :stale}`) and that is correct.

  Judgment is status-scoped; each check applies only where its evidence
  means something:

    * `running` — a stale heartbeat is `:lease_expired` (or a
      `{:requeue, _}` verdict when policy opts in, the effect fence is
      unset, and `epoch < max_claims` — the epoch counts claims, so it is
      the attempt counter). A fresh heartbeat past `deadline + grace` is
      `:deadline_exceeded`: the belt for a buggy runner's suspenders,
      scoped here because `running` is the only status where a deadline
      exists at all.
    * `queued` — `queued_at` older than the claim timeout is
      `:claim_timeout`; the claimer is gone or wedged. `queued_at` is
      stamped at enqueue, resume, and requeue, so one check covers all
      three entries into `queued`.
    * `waiting` — only the policy ceiling: older than `max_wait` is
      `:suspension_expired`, and the default policy has no ceiling.
      Nothing else about a waiting run is the reaper's business — it has
      no heartbeat, no deadline, and no executor *by design*.
    * terminal — `:healthy`; nothing left to judge.

  For Oban hosts, `Clementine.Lifecycle.Ecto.Oban.judge_job/2` is the
  companion executor cross-check, scoped the same way.
  """

  alias Clementine.InterruptReason
  alias Clementine.Lifecycle.Facts

  defmodule Policy do
    @moduledoc """
    Reaper thresholds and the retry stance, all in milliseconds. Defaults
    are Meli's production values (60-second sweep, 2-minute stale
    threshold) with `retry: :never` — the `max_attempts: 1` posture — and
    no `max_wait` ceiling: a suspension leaves `waiting` only by explicit
    policy, never by accident.

    `sweep_interval` is not read by `judge/3`; it is the documented
    default cadence the host's scheduler applies.
    """

    defstruct sweep_interval: :timer.seconds(60),
              stale_after: :timer.minutes(2),
              deadline_grace: :timer.minutes(2),
              claim_timeout: :timer.minutes(15),
              max_wait: nil,
              retry: :never

    @type t :: %__MODULE__{
            sweep_interval: pos_integer(),
            stale_after: pos_integer(),
            deadline_grace: pos_integer(),
            claim_timeout: pos_integer(),
            max_wait: pos_integer() | nil,
            retry: :never | {:requeue, [{:max_claims, pos_integer()}]}
          }

    @doc """
    Builds a policy from overrides. The retry shape is validated eagerly —
    a sweep that discovers a malformed policy mid-verdict has already
    judged runs under it.
    """
    @spec new(keyword()) :: t()
    def new(overrides \\ []) do
      policy = struct!(__MODULE__, overrides)
      validate_retry!(policy.retry)

      for {field, value} <-
            Map.take(policy, [:sweep_interval, :stale_after, :deadline_grace, :claim_timeout]) do
        unless is_integer(value) and value > 0 do
          raise ArgumentError,
                "#{field} must be a positive integer of milliseconds, got: #{inspect(value)}"
        end
      end

      unless policy.max_wait == nil or (is_integer(policy.max_wait) and policy.max_wait > 0) do
        raise ArgumentError,
              "max_wait must be nil (no ceiling) or a positive integer of milliseconds, " <>
                "got: #{inspect(policy.max_wait)}"
      end

      policy
    end

    defp validate_retry!(:never), do: :ok

    defp validate_retry!({:requeue, opts}) do
      max_claims = Keyword.get(opts, :max_claims)

      unless is_integer(max_claims) and max_claims > 0 do
        raise ArgumentError,
              "retry: {:requeue, max_claims: n} requires a positive integer, got: #{inspect(opts)}"
      end

      :ok
    end

    defp validate_retry!(other) do
      raise ArgumentError,
            "retry must be :never or {:requeue, max_claims: n}, got: #{inspect(other)}"
    end
  end

  @type verdict :: :healthy | {:interrupt, InterruptReason.t()} | {:requeue, term()}

  @doc """
  Judges one run's facts against the storage clock. Pure: no fetch, no
  write — the caller turns the verdict into a guarded transition.
  """
  @spec judge(Facts.t(), DateTime.t(), Policy.t()) :: verdict()
  def judge(facts, now, policy \\ Policy.new())

  def judge(%Facts{status: :running} = facts, %DateTime{} = now, %Policy{} = policy) do
    stale_for = age(now, facts.heartbeat_at)

    cond do
      stale_for == :no_stamp or stale_for > policy.stale_after ->
        stale_verdict(facts, stale_for, policy)

      overdue(now, facts.deadline) > policy.deadline_grace ->
        {:interrupt,
         InterruptReason.new(
           :deadline_exceeded,
           "running #{ms(overdue(now, facts.deadline))} past its deadline with a fresh heartbeat"
         )}

      true ->
        :healthy
    end
  end

  def judge(%Facts{status: :queued} = facts, %DateTime{} = now, %Policy{} = policy) do
    case age(now, facts.queued_at) do
      :no_stamp ->
        {:interrupt, InterruptReason.new(:claim_timeout, "queued with no queued_at stamp")}

      waited when waited > policy.claim_timeout ->
        {:interrupt,
         InterruptReason.new(:claim_timeout, "queued #{ms(waited)}; the claimer never came")}

      _fresh ->
        :healthy
    end
  end

  def judge(%Facts{status: :waiting} = facts, %DateTime{} = now, %Policy{} = policy) do
    # `Protocol.suspend` re-stamps queued_at at the park (a transition into
    # an unowned state, like resume and requeue), so for a waiting run the
    # stamp is the suspension time and the ceiling measures true waiting
    # age — never time spent queued or running before the park.
    case {policy.max_wait, age(now, facts.queued_at)} do
      {nil, _age} ->
        :healthy

      {max_wait, waited} when waited == :no_stamp or waited > max_wait ->
        {:interrupt,
         InterruptReason.new(
           :suspension_expired,
           "waiting past the #{ms(max_wait)} policy ceiling"
         )}

      _within ->
        :healthy
    end
  end

  def judge(%Facts{} = facts, %DateTime{}, %Policy{}) do
    true = Facts.terminal?(facts)
    :healthy
  end

  # Stale evidence reads the same for interrupt and requeue; policy, the
  # fence, and the claim cap pick which. The epoch counts claims, so it is
  # the attempt counter — no extra field.
  defp stale_verdict(%Facts{} = facts, stale_for, %Policy{retry: {:requeue, opts}})
       when facts.effects? == false do
    if facts.epoch < Keyword.fetch!(opts, :max_claims) do
      {:requeue, :lease_expired}
    else
      interrupt_stale(stale_for)
    end
  end

  defp stale_verdict(%Facts{}, stale_for, %Policy{}), do: interrupt_stale(stale_for)

  defp interrupt_stale(:no_stamp) do
    # Unreachable through a conforming lifecycle — claim stamps
    # heartbeat_at — so absent liveness evidence is judged as dead rather
    # than silently healthy.
    {:interrupt, InterruptReason.new(:lease_expired, "running with no heartbeat_at stamp")}
  end

  defp interrupt_stale(stale_for) do
    {:interrupt, InterruptReason.new(:lease_expired, "no heartbeat for #{ms(stale_for)}")}
  end

  defp age(_now, nil), do: :no_stamp
  defp age(now, %DateTime{} = stamp), do: DateTime.diff(now, stamp, :millisecond)

  # A run with no deadline is never overdue; deadlines are optional.
  defp overdue(_now, nil), do: 0
  defp overdue(now, %DateTime{} = deadline), do: DateTime.diff(now, deadline, :millisecond)

  defp ms(value) when is_integer(value), do: "#{div(value, 1000)}s"
end
