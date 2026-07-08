defmodule Clementine.Reconciler do
  @moduledoc """
  Reaper judgment: the deterministic, kind- and status-scoped half of
  stale-run reconciliation — no fetch, no write. The host owns the sweep
  query (its table, its rows); the library owns the verdict and the
  transition it becomes:

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

  Judgment forks by `Facts.kind` (LOOP_RFC amendment A3). A loop is a
  standing entity: its epoch counts lifetime claims, so the
  epoch-as-attempt-cap gate would terminally interrupt a long-lived loop
  on its first crashed step, and a `:claim_timeout` interrupt would kill
  it over one lost enqueue. Loop-kind facts therefore get their own
  verdicts through the same entry points — `judge/3` forks internally, so
  a sweep that forgets its kind scope still judges loops correctly. The
  rollout sweep should exclude loop-kind rows in SQL
  (`WHERE kind = 'rollout'`) all the same: a parked loop is a permanently
  `waiting` row *by design* (LOOP_RFC §Operations — "hibernation" is what
  `waiting` already is), so at fleet scale an unscoped sweep pays for
  every dormant loop on every cadence. The scoping is a cost story; the
  kind fork is the correctness story.

  The loop sweep runs on its own slower cadence over loop rows only
  (`policy.loop_sweep_interval`), gathering per-row evidence the facts
  cannot carry and calling `judge_loop/4`:

      # The loop sweep: active AND kind = 'loop', both in SQL.
      for facts <- MyApp.Runs.active_loop_run_facts() do
        # For waiting rows: envelope children joined to child run statuses
        # and inbox rows; oldest unconsumed input stamp. Nil otherwise.
        evidence = MyApp.Runs.loop_evidence(facts)

        case Clementine.Reconciler.judge_loop(facts, evidence, now, policy) do
          :healthy ->
            :ok

          {:requeue, reason} ->
            Clementine.Lifecycle.Protocol.requeue(lifecycle, facts, reason)
            # then insert the step job, exactly as after a wake

          {:reenqueue, _reason} ->
            # the run row is already queued; only the job is missing
            MyApp.Runs.insert_step_job(facts.ref)

          {:reconcile_children, strands} ->
            # for each strand: synthesize {:completed, tag, result} from the
            # child's terminal row and append it with the canonical dedup key
            # ("completed:" <> tag_key <> ":" <> child_ref, LOOP_RFC
            # §Children) so a racing real delivery no-ops; append wakes.
            MyApp.Runs.reconcile_children(facts, strands)

          {:wake_pending, _reason} ->
            # append's wake half alone: CAS waiting -> queued + step job,
            # one atomic unit
            MyApp.Runs.wake(facts.ref)

          {:interrupt, reason} ->
            Clementine.Lifecycle.Protocol.interrupt(lifecycle, facts, reason)
        end
      end

  Every non-`:healthy` loop verdict emits `[:clementine, :loop, :verdict]`
  at judgment time — three of the four loop verdicts commit nothing
  through the lifecycle, so the judgment is the one seam every firing
  crosses. Nonzero `:reconcile_children`/`:wake_pending` rates on a
  transactional substrate (Postgres) are the alarm condition: the sweep is
  healing strands that atomic delivery glue should make impossible.

  `now` must come from the storage clock — the same source that stamped
  the facts — or be compared in the database; a node-local
  `DateTime.utc_now/0` reintroduces the two-clock problem the symbolic
  stamps removed.

  A verdict is evidence, not action: every verdict lands as a CAS guarded
  by the exact observed `(status, epoch)`, so concurrent sweeps on many
  nodes need no coordination — a reaper racing a live finish, or another
  reaper, loses cleanly (`{:error, :stale}`) and that is correct.

  Judgment is status-scoped; each check applies only where its evidence
  means something. For rollout-kind facts:

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

  For loop-kind facts (amendment A3 — every strand class self-healing,
  never invisible, and no verdict terminal except the deadline belt):

    * `running` — the same stale evidence is `{:requeue, :lease_expired}`
      **always**: no `retry` opt-in, no `epoch < max_claims` gate (capping
      lifetime claims kills loops *for having lived*; poison protection is
      the dead-letter machinery's job, LOOP_RFC L7/L16), and no effect
      fence (rollout vocabulary — a step is replayable by construction,
      Governing Invariant 4). The fresh-heartbeat deadline belt is
      unamended: a live-wedged step runner past `deadline + grace` is
      still `:deadline_exceeded` — the one terminal verdict a loop keeps.
    * `queued` — the same claim-timeout evidence is
      `{:reenqueue, :claim_timeout}`: the run row is fine, the step job is
      lost, and the host re-inserts it (LOOP_RFC L15). A standing entity
      must not die from one lost enqueue, so this verdict re-fires every
      sweep until a claim lands — self-healing with an observable rate,
      never terminal.
    * `waiting` — exempt from `max_wait` (parked is the ground state, not
      an overdue suspension) and judged instead on `LoopEvidence` by
      `judge_loop/4`: a live child whose run is terminal with no
      completion input in the inbox is a strand,
      `{:reconcile_children, strands}` (LOOP_RFC L13); otherwise
      unconsumed inputs older than `policy.wake_pending_after` with the
      loop parked are `{:wake_pending, :stale_inputs}` (LOOP_RFC L4).
      These two replace the backstop the `max_wait` exemption removes.
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

    `sweep_interval` and `loop_sweep_interval` are not read by judgment;
    they are the documented default cadences the host's scheduler applies —
    the loop sweep deliberately slower (LOOP_RFC §Operations), because its
    waiting rows need per-row evidence queries and its verdicts backstop
    races measured in minutes, not liveness measured in heartbeats.

    `retry`, `max_claims`, and `max_wait` govern rollout-kind runs only;
    loop-kind judgment ignores all three (amendment A3).
    `wake_pending_after` is the loop-kind backstop threshold: how long
    unconsumed inputs may sit against a parked loop before the sweep wakes
    it. The default is deliberately generous — on a substrate honoring the
    append atomicity sentence the verdict never fires, and a nonzero rate
    is an alarm, so the threshold only bounds healing latency on
    substrates that need it.
    """

    defstruct sweep_interval: :timer.seconds(60),
              loop_sweep_interval: :timer.minutes(5),
              stale_after: :timer.minutes(2),
              deadline_grace: :timer.minutes(2),
              claim_timeout: :timer.minutes(15),
              max_wait: nil,
              wake_pending_after: :timer.minutes(5),
              retry: :never

    @type t :: %__MODULE__{
            sweep_interval: pos_integer(),
            loop_sweep_interval: pos_integer(),
            stale_after: pos_integer(),
            deadline_grace: pos_integer(),
            claim_timeout: pos_integer(),
            max_wait: pos_integer() | nil,
            wake_pending_after: pos_integer(),
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
            Map.take(policy, [
              :sweep_interval,
              :loop_sweep_interval,
              :stale_after,
              :deadline_grace,
              :claim_timeout,
              :wake_pending_after
            ]) do
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

  defmodule LoopEvidence do
    @moduledoc """
    What the loop sweep gathered beyond the facts for one parked loop —
    the evidence behind the two self-healing verdicts (LOOP_RFC amendment
    A3c). Judgment stays pure; the host owns the queries.

    `children` mirrors the envelope's live-children map, one entry per
    `tag_key => child_ref`, joined to two host lookups: `terminal?` (the
    child run reached a dead-end status) and `completion_present?` (an
    inbox row for this child's completion exists **at all** — pending,
    consumed-but-marked, or dead-lettered; dead letters are retained
    evidence, so a poison completion that already dead-lettered is
    *present*, and re-synthesizing it would only re-poison). A terminal
    child with no completion row is a strand: the exactly-once-at-source
    append was lost.

    `oldest_pending_at` is the storage-clock insert stamp of the oldest
    unconsumed input, nil when the inbox holds none. Stamps must come from
    the same clock as `now` — the facts' own discipline.

    Gathering need not be one snapshot: a step committing mid-gather can
    at worst make the sweep synthesize a completion whose child the
    envelope already retired, and that append dead-letters as
    `:unknown_tag` or no-ops on its dedup key — observable noise, never
    double delivery (Governing Invariants 7 and 11).
    """

    defstruct children: [], oldest_pending_at: nil

    @type child :: %{
            tag_key: String.t(),
            child_ref: term(),
            terminal?: boolean(),
            completion_present?: boolean()
          }

    @type t :: %__MODULE__{
            children: [child()],
            oldest_pending_at: DateTime.t() | nil
          }
  end

  @typedoc """
  One lost child-completion delivery: the envelope lists the child as
  live, its run is terminal, and no completion input exists in the inbox.
  The host synthesizes `{:completed, tag, result}` from the child's
  terminal row and appends it under the canonical dedup key.
  """
  @type strand :: %{tag_key: String.t(), child_ref: term()}

  @typedoc """
  `:reenqueue`, `:reconcile_children`, and `:wake_pending` are loop-kind
  verdicts (amendment A3); rollout-kind facts never produce them. All
  three are host actions with no lifecycle transition — the run row is
  already in the right status; what is missing lives beside it (a step
  job, a completion input, a wake).
  """
  @type verdict ::
          :healthy
          | {:interrupt, InterruptReason.t()}
          | {:requeue, term()}
          | {:reenqueue, term()}
          | {:reconcile_children, [strand()]}
          | {:wake_pending, :stale_inputs}

  @doc """
  Judges one run's facts against the storage clock. No fetch, no write —
  the caller turns the verdict into a guarded transition (or, for the
  loop-kind verdicts, the host action beside the row).

  Forks on `Facts.kind`: loop-kind facts are judged by the loop rules —
  with no evidence, so only the checks the facts can answer — even when a
  mis-scoped rollout sweep is the caller. The loop sweep proper calls
  `judge_loop/4` with gathered evidence.
  """
  @spec judge(Facts.t(), DateTime.t(), Policy.t()) :: verdict()
  def judge(facts, now, policy \\ Policy.new())

  def judge(%Facts{kind: :loop} = facts, %DateTime{} = now, %Policy{} = policy) do
    judge_loop(facts, nil, now, policy)
  end

  def judge(%Facts{status: :running} = facts, %DateTime{} = now, %Policy{} = policy) do
    stale_for = age(now, facts.heartbeat_at)

    cond do
      stale_for == :no_stamp or stale_for > policy.stale_after ->
        stale_verdict(facts, stale_for, policy)

      overdue(now, facts.deadline) > policy.deadline_grace ->
        deadline_exceeded(now, facts.deadline)

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

  @doc """
  Judges one loop-kind run's facts plus the sweep's gathered evidence
  (nil when none was gathered — running and queued rows need none).
  Judgment is deterministic over its arguments; every non-`:healthy`
  verdict additionally emits `[:clementine, :loop, :verdict]` so firing
  rates stay observable no matter which host glue acts on them — the
  loop verdicts have no lifecycle commit to ride the way `:requeued` and
  `:reaped` do.

  Verdict order within `waiting`: strands first — reconciliation's append
  wakes the loop anyway, so it subsumes a pending `:wake_pending`.
  """
  @spec judge_loop(Facts.t(), LoopEvidence.t() | nil, DateTime.t(), Policy.t()) :: verdict()
  def judge_loop(facts, evidence, now, policy \\ Policy.new())

  def judge_loop(%Facts{kind: :loop} = facts, evidence, %DateTime{} = now, %Policy{} = policy)
      when is_struct(evidence, LoopEvidence) or is_nil(evidence) do
    verdict = loop_verdict(facts, evidence || %LoopEvidence{}, now, policy)
    record_loop_verdict(facts, verdict)
    verdict
  end

  # A3a: the same stale evidence that interrupts (or policy-requeues) a
  # rollout requeues a loop unconditionally. The retry opt-in, the
  # epoch-as-attempt-cap, and the effect fence are all rollout vocabulary:
  # a loop's epoch counts its lifetime claims, its steps are replayable by
  # construction, and poison protection lives in the dead-letter
  # machinery. The fresh-heartbeat deadline belt is deliberately
  # unamended — a live-wedged step runner is the one failure a requeue
  # cannot heal, and holding the lease forever would be invisible.
  defp loop_verdict(%Facts{status: :running} = facts, _evidence, now, policy) do
    stale_for = age(now, facts.heartbeat_at)

    cond do
      stale_for == :no_stamp or stale_for > policy.stale_after ->
        {:requeue, :lease_expired}

      overdue(now, facts.deadline) > policy.deadline_grace ->
        deadline_exceeded(now, facts.deadline)

      true ->
        :healthy
    end
  end

  # A3b: claim-timeout evidence means the step job is lost, not that the
  # loop should die — the host re-inserts the job (duplicates no-op on the
  # claim CAS). A missing stamp is nonconforming, but the answer is the
  # same: never terminal on claim evidence.
  defp loop_verdict(%Facts{status: :queued} = facts, _evidence, now, policy) do
    case age(now, facts.queued_at) do
      :no_stamp -> {:reenqueue, :claim_timeout}
      waited when waited > policy.claim_timeout -> {:reenqueue, :claim_timeout}
      _fresh -> :healthy
    end
  end

  # A3c: parked is the ground state, so `max_wait` never applies; the two
  # evidence verdicts replace the backstop that exemption removes.
  defp loop_verdict(%Facts{status: :waiting}, %LoopEvidence{} = evidence, now, policy) do
    strands =
      for child <- evidence.children,
          child.terminal? and not child.completion_present? do
        %{tag_key: child.tag_key, child_ref: child.child_ref}
      end

    cond do
      strands != [] ->
        {:reconcile_children, strands}

      stale_pending?(evidence, now, policy) ->
        {:wake_pending, :stale_inputs}

      true ->
        :healthy
    end
  end

  defp loop_verdict(%Facts{} = facts, _evidence, _now, _policy) do
    true = Facts.terminal?(facts)
    :healthy
  end

  # Strictly beyond the threshold, like every age check here: the
  # boundary itself is healthy.
  defp stale_pending?(%LoopEvidence{oldest_pending_at: nil}, _now, _policy), do: false

  defp stale_pending?(%LoopEvidence{oldest_pending_at: oldest}, now, policy) do
    age(now, oldest) > policy.wake_pending_after
  end

  defp record_loop_verdict(_facts, :healthy), do: :ok

  defp record_loop_verdict(%Facts{} = facts, {verdict, detail}) do
    :telemetry.execute(
      [:clementine, :loop, :verdict],
      %{},
      %{loop_ref: facts.ref, epoch: facts.epoch, verdict: verdict, detail: detail}
    )
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

  defp deadline_exceeded(now, deadline) do
    {:interrupt,
     InterruptReason.new(
       :deadline_exceeded,
       "running #{ms(overdue(now, deadline))} past its deadline with a fresh heartbeat"
     )}
  end

  defp age(_now, nil), do: :no_stamp
  defp age(now, %DateTime{} = stamp), do: DateTime.diff(now, stamp, :millisecond)

  # A run with no deadline is never overdue; deadlines are optional.
  defp overdue(_now, nil), do: 0
  defp overdue(now, %DateTime{} = deadline), do: DateTime.diff(now, deadline, :millisecond)

  defp ms(value) when is_integer(value), do: "#{div(value, 1000)}s"
end
