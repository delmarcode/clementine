defmodule Clementine.Loop.Runner do
  @moduledoc """
  The step runner (LOOP_RFC §The Step): claim → load → bump → drain →
  `apply_step`, one claim-cycle per call. The host's step worker maps the
  closed outcome union exactly as its run worker maps
  `Clementine.Runner.execute/2`:

  - `{:parked, facts}` — the step committed a park; the loop waits for
    the inbox (or, for an `:incompatible_state`/`:incompatible_spec`
    park, for a compatible deploy).
  - `{:continued, facts}` — a step committed and the next step's job is
    already enqueued (a continue, or a park the host downgraded inside
    its own commit). No worker action needed.
  - `{:finished, facts}` — the loop reached its terminal: a halt with no
    children in flight, or a cascade that drained its last completion.
  - `{:discard, reason}` — nothing was written and nothing may be: a
    lost claim race (`{:not_claimable, status}`), a lost lease, a
    vanished row (`:not_found`), a rollout-kind ref (`:rollout_run`), or
    a terminal that already exists (`:already_terminal`).
  - `{:error, term}` — the step failed. When the failure was an in-step
    exception the run was already requeued and re-enqueued (see below);
    when the commit itself exhausted its transient-error retries the run
    stays `running` and the reaper requeues it (amendment A3a). Either
    way the worker acks — the machinery, not the job queue, owns the
    retry.

  ## Two-tier failure, the loop analog

  The rollout runner rescues in-process exceptions into terminal
  `finish(failed)` — right for a rollout, where the attempt is the unit
  and the caller judges the `Result`. A loop deliberately overrides that
  doctrine: a loop is a standing entity, and terminalizing it over one
  poison input would let any malformed webhook kill a mailbox that
  fifty healthy inputs are queued behind. So an in-step raise walks the
  attempts path instead: the drain-time bump already committed (before
  `handle/2` ran, so even VM-death poison is counted), the runner
  requeues the run and re-enqueues its step job, and the next step
  drains batch-1 until the head either succeeds or dead-letters at the
  threshold with a synthesized `{:input_failed}` — the mailbox never
  jams, innocents never dead-letter, and the loop outlives the poison
  (matrix rows L1, L7). Process death writes nothing here either: the
  reaper requeues loop-kind runs unconditionally — no epoch cap, no
  retry opt-in — because a loop's epoch counts its lifetime claims and
  capping it would kill loops for having lived (A3a, row L16).

  ## Cascade mode

  The cancel flag reads at claim time, ahead of every queued input by
  design (`Clementine.Loop.Protocol.cancel/4` sets it and wakes). A set
  flag — or a pending halt already parked in the envelope — sends the
  drain into cascade mode: the machinery `request_cancel`s live children
  as commit cargo, absorbs completions without invoking `handle/2`,
  parks between them, and finishes last with the pending result (the
  halt's, or `Result.cancelled/1`) plus the terminal sweep. Because the
  cascade never touches `load/1`/`dump/1`, an `:incompatible_state` loop
  is still cancellable (rows L2, L8, L9).

  ## Steps are short by construction

  No heartbeat process runs during a step: the claim stamps liveness,
  the work is one drain and one commit, and the real work lives in
  child rollout-runs with their own leases and heartbeats. A step
  runner that dies is requeued off the stale claim stamp (A3a); one
  that live-wedges trips the deadline belt — the execution deadline is
  minted at claim from `loop_policy` (see below).

  ## `loop_policy`

  The persisted policy map is the runner's to interpret (string keys;
  all RFC non-final knobs, LOOP_RFC §Non-Final):

  - `"deadline_ms"` — the step execution deadline minted at claim
    (default #{5 * 60 * 1000}; explicit `nil` disables the belt).
  - `"batch_cap"` — max inputs folded per step (default
    `Clementine.Loop.Step.default_batch_cap/0`).
  - `"dead_letter_after"` — head attempts at which poison dead-letters
    (default `Clementine.Loop.Step.default_dead_letter_after/0`).

  ## Observation

  Notifications and telemetry are post-commit only. The host's
  `apply_step` fires its own transition notifications after its unit
  commits; the runner emits `[:clementine, :loop, :step]` after a
  committed step — plus `[:clementine, :loop, :spawned]` per child the
  commit created, `[:clementine, :loop, :cascade]` when the commit
  entered cascade mode, and `[:clementine, :loop, :upgraded]` when it
  carried a `handle_upgrade/2` state upgrade — and
  `[:clementine, :loop, :step_failed]` after the requeue that resolves
  an in-step failure (shapes in `Clementine.Telemetry`). Nothing
  observable precedes the commit it describes.

  A resumed loop (a host driving the park's `ResumeToken` through
  `Lifecycle.Protocol.resume/4`) is just a wake: the runner takes its
  inputs from the inbox, so the lease's resume payload is deliberately
  ignored.
  """

  require Logger

  alias Clementine.{Error, Lease, ResumeToken, Suspension}
  alias Clementine.Lifecycle.{Facts, Protocol, Transition}
  alias Clementine.Loop
  alias Clementine.Loop.{Envelope, Step, StepCommit, StoredInput}

  @default_deadline_ms :timer.minutes(5)
  @apply_attempts 3
  @apply_backoff_ms 100

  @type outcome ::
          {:parked, Facts.t()}
          | {:continued, Facts.t()}
          | {:finished, Facts.t()}
          | {:discard, reason :: term()}
          | {:error, term()}

  @doc """
  Claims and executes one step of one loop.

  ## Options

  - `:host` (required) — the `Clementine.Loop.Host` module
  - `:lifecycle` (required) — the `Clementine.Lifecycle` module the
    loop's run row lives in (for the Ecto pairing, the same module the
    host was configured with)
  - `:executor_id` (required) — human/telemetry identity for this step
  - `:ctx` — opaque host context, threaded to both seams
  """
  @spec step(term(), keyword()) :: outcome()
  def step(loop_ref, opts) do
    host = Keyword.fetch!(opts, :host)
    lifecycle = Keyword.fetch!(opts, :lifecycle)
    executor = Keyword.fetch!(opts, :executor_id)
    ctx = Keyword.get(opts, :ctx)

    # Spec columns are create-time-stable, so the pre-claim read is only
    # trusted for the policy the claim's deadline is minted from; the
    # envelope and cancel flag are re-read under the claim's fence.
    case host.load(loop_ref, ctx) do
      {:ok, %{policy: policy}} ->
        claim_opts = [
          executor: executor,
          ctx: ctx,
          max_duration: Map.get(policy, "deadline_ms", @default_deadline_ms)
        ]

        case Protocol.claim(lifecycle, loop_ref, claim_opts) do
          {:ok, lease} -> step_leased(host, lease, ctx)
          {:error, reason} -> {:discard, reason}
        end

      {:error, reason} ->
        {:discard, reason}
    end
  end

  defp step_leased(host, %Lease{} = lease, ctx) do
    started = System.monotonic_time()

    try do
      execute_step(host, lease, ctx, started)
    rescue
      e -> fail_step(host, lease, Error.from_exception(:error, e, __STACKTRACE__))
    catch
      kind, reason -> fail_step(host, lease, Error.from_exception(kind, reason, __STACKTRACE__))
    end
  end

  defp execute_step(host, %Lease{} = lease, ctx, started) do
    with {:ok, loaded} <- load_leased(host, lease, ctx),
         {:ok, module} <- resolve_module(lease, loaded),
         {:ok, stored} <- decode_envelope(lease, loaded),
         {:ok, envelope} <- upgrade_state(host, lease, ctx, loaded, module, stored) do
      drain_and_commit(host, lease, ctx, loaded, module, envelope, stored, started)
    end
  end

  defp cascade_mode?(loaded, envelope) do
    cancel_reason(loaded.facts) != nil or (envelope != nil and Envelope.cascading?(envelope))
  end

  # Phase 2's version gate runs before phase 3's bump (LOOP_RFC §The
  # Step): inputs are innocent of deploys — and of broken upgrades — so
  # an incompatible loop must park before the head's attempts advance, or
  # every deploy-mismatch step would walk an innocent input toward the
  # poison threshold. A stored version behind the declared one takes the
  # `handle_upgrade/2` chain (`Step.upgrade/2`, rescued end to end); the
  # step then drains on the upgraded envelope, which commits with
  # whatever the step commits. The drain re-runs the gate (its own
  # contract), redundantly here. Cascade mode is exempt: it never loads
  # state, which is what keeps an `:incompatible_state` loop cancellable
  # (row L2's host-chosen end) — and is also why this park alone wakes on
  # a racing cancel flag (see `incompatible_park`).
  defp upgrade_state(host, lease, ctx, loaded, module, envelope) do
    if cascade_mode?(loaded, envelope) do
      {:ok, envelope}
    else
      case Step.upgrade(module, envelope) do
        {:ok, upgraded} ->
          {:ok, upgraded}

        {:error, {:incompatible_state, detail}} ->
          incompatible_park(lease, :incompatible_state, detail, wake_on_cancel: {host, ctx})
      end
    end
  end

  # The post-claim read is authoritative: the claim fenced every other
  # writer, so the envelope cannot be superseded until our own commit —
  # and a cancel flag that landed before the claim is visible here, ahead
  # of the drain (LOOP_RFC §The Step, phase 2).
  defp load_leased(host, %Lease{} = lease, ctx) do
    case host.load(lease.run_ref, ctx) do
      {:ok, %{facts: %Facts{status: :running, epoch: epoch}} = loaded}
      when epoch == lease.epoch ->
        {:ok, loaded}

      {:ok, %{facts: %Facts{}}} ->
        {:discard, :lost_lease}

      {:error, :not_found} ->
        {:discard, :not_found}

      {:error, reason} ->
        raise "loop host load failed under a live lease: #{inspect(reason)}"
    end
  end

  defp resolve_module(lease, %{module: module}) do
    case Loop.resolve(module) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, {:incompatible_spec, detail}} ->
        incompatible_park(lease, :incompatible_spec, detail)
    end
  end

  defp decode_envelope(_lease, %{envelope: nil}), do: {:ok, nil}

  defp decode_envelope(lease, %{envelope: data}) do
    case Envelope.decode(data) do
      {:ok, envelope} ->
        {:ok, envelope}

      {:error, {:incompatible_state, detail}} ->
        incompatible_park(lease, :incompatible_state, detail)
    end
  end

  # `envelope` is the drain's (possibly upgraded); `stored` is the
  # pre-upgrade decode, kept for the post-commit from/to signal.
  defp drain_and_commit(host, %Lease{} = lease, ctx, loaded, module, envelope, stored, started) do
    batch_cap = Map.get(loaded.policy, "batch_cap", Step.default_batch_cap())
    threshold = Map.get(loaded.policy, "dead_letter_after", Step.default_dead_letter_after())

    # One past the cap: a full window means backlog remains, so the plan
    # continues instead of parking — backlog detection must not lean on
    # the park re-check, whose job is closing races. A cascade reads
    # completions only: they are all it can consume, and a FIFO window
    # would never surface one parked behind a backlog longer than the
    # cap — the cascade would park empty, the `:completions` re-check
    # would downgrade, and the loop would spin without ever absorbing
    # the child terminal.
    scope = if cascade_mode?(loaded, envelope), do: :completions, else: :any
    pending = host.pending(lease.run_ref, batch_cap + 1, scope, ctx)

    plan =
      Step.plan(envelope, pending,
        cancel: cancel_reason(loaded.facts),
        batch_cap: batch_cap,
        dead_letter_after: threshold
      )

    :ok = host.bump_attempts(plan.bump, ctx)
    assert_decodable!(plan.batch)

    case Step.drain(module, envelope, plan,
           loop_ref: lease.run_ref,
           epoch: lease.epoch,
           loop_args: loaded.args
         ) do
      {:ok, commit} ->
        apply_commit(host, lease, ctx, commit, stored, started, @apply_attempts)

      {:error, {:incompatible_state, detail}} ->
        incompatible_park(lease, :incompatible_state, detail)

      {:error, {:incompatible_spec, detail}} ->
        incompatible_park(lease, :incompatible_spec, detail)
    end
  end

  defp cancel_reason(%Facts{cancel: nil}), do: nil
  defp cancel_reason(%Facts{cancel: %{reason: reason}}), do: reason || :cancelled

  # A row whose payload the current code cannot decode fails the step
  # *after* the attempts bump, so the failure is counted, blamed on the
  # head, and dead-lettered at the threshold like any other deterministic
  # poison (matrix row L7) — inputs are innocent of deploys, so a shrunk
  # vocabulary gets its threshold of chances to deploy back first. In
  # cascade mode nothing bumps, so an undecodable completion retries the
  # step until the vocabulary deploy lands — observable pressure, never a
  # dead-lettered piece of machinery evidence with a live child behind it.
  defp assert_decodable!(batch) do
    case Enum.find(batch, & &1.decode_error) do
      nil ->
        :ok

      %StoredInput{ref: ref, decode_error: %Error{} = error} ->
        raise "loop input #{inspect(ref)} is undecodable by the running code: #{error.message}"
    end
  end

  defp apply_commit(host, %Lease{} = lease, ctx, commit, stored_envelope, started, attempts_left) do
    case host.apply_step(commit, ctx) do
      {:ok, %Facts{} = facts} ->
        outcome = outcome_of(facts)
        emit_step(lease, commit, stored_envelope, outcome, started)
        outcome

      {:error, :stale} ->
        # The fence worked: a reaper requeue or interrupt superseded this
        # execution mid-step. Nothing was written; disambiguate like
        # Protocol.finish does.
        case lease.lifecycle.fetch(lease.run_ref, lease.ctx) do
          {:ok, %Facts{} = facts} ->
            if Facts.terminal?(facts),
              do: {:discard, :already_terminal},
              else: {:discard, :lost_lease}

          {:error, _} ->
            {:discard, :lost_lease}
        end

      {:error, _reason} when attempts_left > 1 ->
        Process.sleep(@apply_backoff_ms)
        apply_commit(host, lease, ctx, commit, stored_envelope, started, attempts_left - 1)

      # Retries exhausted; the run stays running and the reaper requeues
      # (A3a) — the commit is replayable by construction, so nothing is
      # lost but time.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp outcome_of(%Facts{status: :waiting} = facts), do: {:parked, facts}
  defp outcome_of(%Facts{status: :queued} = facts), do: {:continued, facts}
  defp outcome_of(%Facts{} = facts), do: {:finished, facts}

  ## Incompatible parks (matrix row L2)

  # Deploy-shaped problems park the loop visibly — never a crash, never a
  # dead-letter (inputs are innocent of deploys) — with the detail in the
  # suspension's reason for the operator. The park bypasses the host's
  # re-check on purpose: pending inputs are exactly what an incompatible
  # loop cannot drain, and a downgrade would spin the claim hot until the
  # deploy. Fresh appends and the reaper's `:wake_pending` verdict re-wake
  # it once compatible code ships; a cancel cascade (which never loads
  # state) can end it.
  #
  # A cancel flag that raced this park (committed before the park's CAS
  # took the row, so its own wake saw `running` and no-oped) is visible in
  # the returned facts. `wake_on_cancel` wakes it — but ONLY the
  # state-version park sets it, because only there does the flag change
  # the next step's path (the cascade skips the state check). A spec or
  # envelope-decode park would re-park under the flag whatever the mode —
  # the cascade needs the module's vocabulary and a decodable envelope —
  # so waking it would spin; it stays parked, the flag durable, until the
  # healing deploy or an admin `Protocol.interrupt/4`.
  defp incompatible_park(%Lease{} = lease, code, detail, opts \\ []) do
    token = %ResumeToken{run_ref: lease.run_ref, epoch: lease.epoch, reason_type: :external}
    suspension = %Suspension{reason: {:external, {code, detail}}, checkpoint: nil, token: token}

    transition = %Transition{
      op: :suspend,
      run_ref: lease.run_ref,
      expect: %{status: :running, epoch: lease.epoch},
      set: %{
        status: :waiting,
        suspension: suspension,
        executor_id: nil,
        deadline: nil,
        heartbeat_at: nil,
        queued_at: :now
      },
      meta: %{code => detail}
    }

    case apply_with_retry(lease, transition, @apply_attempts) do
      {:ok, %Facts{} = facts} ->
        Logger.warning(
          "loop #{inspect(lease.run_ref)} parked #{code}: #{inspect(detail)} — " <>
            "deploy compatible code, or cancel the loop"
        )

        case Keyword.get(opts, :wake_on_cancel) do
          {host, ctx} when facts.cancel != nil -> wake_flagged_park(host, lease, ctx, facts)
          _ -> {:parked, facts}
        end

      {:error, :stale} ->
        {:discard, :lost_lease}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The park committed with the flag already on the row: hand the loop to
  # the cascade the flag asked for (CAS `waiting -> queued` + step job).
  # A stale CAS means a racing wake — cancel/4's own, seeing `waiting` —
  # already moved it and enqueued; either way the cancellation proceeds.
  defp wake_flagged_park(host, %Lease{} = lease, ctx, %Facts{} = parked_facts) do
    transition = %Transition{
      op: :requeue,
      run_ref: lease.run_ref,
      expect: %{status: :waiting, epoch: lease.epoch},
      set: %{status: :queued, suspension: nil, queued_at: :now},
      meta: %{reason: :cancelled_incompatible_park}
    }

    case lease.lifecycle.apply(transition, lease.ctx) do
      {:ok, %Facts{} = facts} ->
        :ok = host.enqueue_step(lease.run_ref, ctx)
        {:continued, facts}

      {:error, _} ->
        {:parked, parked_facts}
    end
  end

  defp apply_with_retry(%Lease{} = lease, transition, attempts_left) do
    case lease.lifecycle.apply(transition, lease.ctx) do
      {:ok, facts} ->
        {:ok, facts}

      {:error, :stale} ->
        {:error, :stale}

      {:error, _reason} when attempts_left > 1 ->
        Process.sleep(@apply_backoff_ms)
        apply_with_retry(lease, transition, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## The in-step failure path (two-tier, loop analog — see moduledoc)

  defp fail_step(host, %Lease{} = lease, %Error{} = error) do
    Logger.error(
      "loop #{inspect(lease.run_ref)} step failed (epoch #{lease.epoch}): #{error.message} — " <>
        "requeueing; the drained head's attempts bump already counted this toward its threshold"
    )

    {outcome, requeued?} =
      try do
        case Protocol.requeue(lease, {:step_failed, error.code}) do
          {:ok, _facts} ->
            :ok = host.enqueue_step(lease.run_ref, lease.ctx)
            {{:error, error}, true}

          {:error, :lost_lease} ->
            {{:discard, :lost_lease}, false}

          # Requeue could not commit (storage trouble, or the fence-free
          # :effects_present that loops never set); the run stays running
          # and the reaper requeues on the stale claim stamp (A3a).
          {:error, _reason} ->
            {{:error, error}, false}
        end
      rescue
        e ->
          Logger.error("loop step-failure requeue raised: #{Exception.message(e)}")
          {{:error, error}, false}
      catch
        kind, reason ->
          Logger.error("loop step-failure requeue #{kind}: #{inspect(reason)}")
          {{:error, error}, false}
      end

    :telemetry.execute(
      [:clementine, :loop, :step_failed],
      %{},
      %{loop_ref: lease.run_ref, epoch: lease.epoch, error: error, requeued: requeued?}
    )

    outcome
  end

  defp emit_step(
         %Lease{} = lease,
         %StepCommit{meta: meta} = commit,
         stored_envelope,
         outcome,
         started
       ) do
    {tag, _facts} = outcome
    mode = Map.get(meta, :mode, :normal)

    :telemetry.execute(
      [:clementine, :loop, :step],
      %{duration: System.monotonic_time() - started},
      %{
        loop_ref: lease.run_ref,
        epoch: lease.epoch,
        outcome: tag,
        mode: mode,
        batch: Map.get(meta, :batch, 0)
      }
    )

    Enum.each(commit.children, fn spec ->
      :telemetry.execute(
        [:clementine, :loop, :spawned],
        %{},
        %{loop_ref: lease.run_ref, epoch: lease.epoch, tag: spec.tag, tag_key: spec.tag_key}
      )
    end)

    if cascade_entry?(commit, stored_envelope) do
      :telemetry.execute(
        [:clementine, :loop, :cascade],
        %{},
        %{
          loop_ref: lease.run_ref,
          epoch: lease.epoch,
          trigger: if(mode == :cascade, do: :cancel, else: :halt),
          children: length(commit.cancel_children)
        }
      )
    end

    emit_upgraded(lease, commit, stored_envelope)
  end

  # The commit that carried a state upgrade: its written envelope's
  # version moved past the stored one. Threshold commits omit the
  # envelope (no carry), cascades carry the stored version verbatim, and
  # a replayed crashed step re-upgrades from the unchanged stored
  # envelope — so this fires once per carrying commit, post-commit,
  # best-effort like every signal here.
  defp emit_upgraded(
         %Lease{} = lease,
         %StepCommit{set: %{envelope: %Envelope{state_version: to}}},
         %Envelope{state_version: from}
       )
       when to != from do
    :telemetry.execute(
      [:clementine, :loop, :upgraded],
      %{},
      %{loop_ref: lease.run_ref, epoch: lease.epoch, from: from, to: to}
    )
  end

  defp emit_upgraded(_lease, _commit, _stored), do: :ok

  # The committed step that began a cascade — it cancels live children as
  # cargo (a halt with children in flight, or the flag's first drain), or
  # it is a cascade-mode commit against an envelope not yet holding the
  # pending halt (the no-children short-circuit, which finishes at once).
  # A replay of a crashed entry re-detects, but only one commit ever
  # lands, so the event fires exactly once per entry.
  defp cascade_entry?(%StepCommit{cancel_children: [_ | _]}, _stored), do: true

  defp cascade_entry?(%StepCommit{meta: %{mode: :cascade}}, stored),
    do: stored == nil or not Envelope.cascading?(stored)

  defp cascade_entry?(%StepCommit{}, _stored), do: false
end
