defmodule Clementine.Lifecycle.Protocol do
  @moduledoc """
  The lifecycle protocol: every named operation of durable execution —
  claim, heartbeat, cancellation, effect fence, suspend, resume, cancel
  request, finish, interrupt, requeue — implemented once against the
  two-function `Clementine.Lifecycle` behaviour.

  Every write is a compare-and-swap guarded by an exact `(status, epoch)`
  pair; `claim` is the only operation that increments the epoch, so an
  epoch names one execution and doubles as the attempt counter. Lease loss
  is never detected proactively — it is discovered when a write returns
  stale, and the epoch guard makes late discovery harmless.

  Operations whose semantics depend on a flag re-fetch after their own
  successful CAS (see `suspend/3`): a flag write commutes with a status
  transition under an exact-pair guard, and the re-check is what keeps a
  cancel request from stranding a freshly parked run.

  Terminal writes (`finish`, `suspend`, direct cancels, `interrupt`) retry
  transient storage errors bounded-with-backoff — a completed rollout must
  not convert into a reaped `interrupted` because of a two-second database
  blip. `:stale` is never retried; it is an answer, not an error.

  Committed writes emit `[:clementine, :run, ...]` telemetry events after
  their CAS succeeds (the two flag writes — the effect fence and the
  cooperative cancel flag — are the deliberate exceptions), and every
  lease-holding operation that discovers lease loss emits `:lease_lost` —
  so run-level observability rides the protocol itself, not any
  particular caller. Shapes are documented in `Clementine.Telemetry`.
  """

  alias Clementine.Lifecycle.{Facts, Transition}
  alias Clementine.{Checkpoint, InterruptReason, Lease, Result, ResumeToken, Suspension, Usage}

  @terminal_write_attempts 3
  @terminal_write_backoff_ms 100

  @type claim_error ::
          :not_found | {:not_claimable, Facts.status()} | term()

  ## Claim

  @doc """
  Claims a queued run: `queued -> running`, epoch incremented — the mint of
  execution identity.

  Options: `:executor` (required), `:ctx`, `:max_duration` (ms; mints the
  deadline window fresh for this execution — a run that waited days in
  `waiting` is not born dead on resume; omitted means no deadline).

  A lost claim race is not an error to retry — it is the single-flight
  guard working; the re-fetch reports who holds the run. The returned lease
  is the runtime handle for everything that follows, and carries
  `{checkpoint, payload}` when the claimed facts held a suspension and a
  resume payload.
  """
  @spec claim(module(), term(), keyword()) :: {:ok, Lease.t()} | {:error, claim_error()}
  def claim(lifecycle, run_ref, opts) do
    executor = Keyword.fetch!(opts, :executor)
    ctx = Keyword.get(opts, :ctx)
    max_duration = Keyword.get(opts, :max_duration)

    with {:ok, %Facts{} = facts} <- lifecycle.fetch(run_ref, ctx) do
      case facts.status do
        :queued ->
          set = %{
            status: :running,
            epoch: facts.epoch + 1,
            executor_id: executor,
            heartbeat_at: :now,
            deadline: if(max_duration, do: {:now_plus, max_duration}, else: nil)
          }

          transition = %Transition{
            op: :claim,
            run_ref: run_ref,
            expect: expect(facts),
            set: set
          }

          case lifecycle.apply(transition, ctx) do
            {:ok, %Facts{} = claimed} ->
              emit(:claimed, %{epoch: claimed.epoch}, %{run_ref: run_ref, executor_id: executor})

              {:ok,
               %Lease{
                 run_ref: run_ref,
                 epoch: claimed.epoch,
                 executor_id: executor,
                 deadline: claimed.deadline,
                 resume: lease_resume(facts),
                 lifecycle: lifecycle,
                 ctx: ctx,
                 claimed_at: claimed.heartbeat_at
               }}

            {:error, :stale} ->
              not_claimable(lifecycle, run_ref, ctx)

            {:error, reason} ->
              {:error, reason}
          end

        status ->
          {:error, {:not_claimable, status}}
      end
    end
  end

  ## Heartbeat

  @doc """
  Renews liveness: `heartbeat_at` moves to the storage clock's now, plus an
  optional `usage:` sample so even interrupted runs carry billing-grade
  numbers. `:stale` maps to `:lost_lease` and is definitive; any other
  error is transient — the caller logs, keeps beating, and lets the
  generous stale threshold absorb the gap.
  """
  @spec heartbeat(Lease.t(), keyword()) :: :ok | {:error, :lost_lease} | {:error, term()}
  def heartbeat(%Lease{} = lease, opts \\ []) do
    set =
      case Keyword.fetch(opts, :usage) do
        {:ok, %Usage{} = usage} -> %{heartbeat_at: :now, usage: usage}
        :error -> %{heartbeat_at: :now}
      end

    transition = %Transition{
      op: :heartbeat,
      run_ref: lease.run_ref,
      expect: running_expect(lease),
      set: set
    }

    case lease.lifecycle.apply(transition, lease.ctx) do
      {:ok, _facts} ->
        emit(:heartbeat, %{}, lease_metadata(lease))
        :ok

      {:error, :stale} ->
        emit(:lease_lost, %{}, lease_metadata(lease))
        {:error, :lost_lease}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Cancellation intent

  @doc """
  Reads cooperative cancellation intent. A read, not a write: reports the
  cancel flag while this lease still owns the run, or `:lost_lease` the
  moment it does not.
  """
  @spec cancellation(Lease.t()) :: :none | {:requested, term()} | {:error, term()}
  def cancellation(%Lease{} = lease) do
    case lease.lifecycle.fetch(lease.run_ref, lease.ctx) do
      {:ok, %Facts{status: :running, epoch: epoch} = facts} when epoch == lease.epoch ->
        case facts.cancel do
          nil -> :none
          %{reason: reason} -> {:requested, reason}
        end

      {:ok, %Facts{}} ->
        emit(:lease_lost, %{}, lease_metadata(lease))
        {:error, :lost_lease}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Effect fence

  @doc """
  Durably raises the effect fence — called before the first tool whose
  `retry` metadata is not `:safe` executes. The fence must exist before the
  effect does; it is what makes same-run requeue refusable, and it is
  written at most once per run.
  """
  @spec mark_effects(Lease.t()) :: :ok | {:error, :lost_lease} | {:error, term()}
  def mark_effects(%Lease{} = lease) do
    transition = %Transition{
      op: :mark_effects,
      run_ref: lease.run_ref,
      expect: running_expect(lease),
      set: %{effects?: true}
    }

    case lease.lifecycle.apply(transition, lease.ctx) do
      {:ok, _facts} ->
        :ok

      {:error, :stale} ->
        emit(:lease_lost, %{}, lease_metadata(lease))
        {:error, :lost_lease}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Suspend

  @doc """
  Parks the run: `running -> waiting`, with the assembled suspension stored
  durably and the executor fields cleared (a waiting run has no executor,
  no deadline, no heartbeat). Like resume and requeue, suspend is a
  transition into an unowned state, so it re-stamps `queued_at` — the
  reaper measures the wait's age from that stamp
  (`Clementine.Reconciler`'s `max_wait` ceiling), which must not include
  time spent queued or running before the park.

  The rollout produced the `Suspension.Request` body; the runner supplies
  `cursor:` (its event stamper position) and `rollout_id:`; this function
  derives the token from the lease and persists the assembled suspension.

  After its own CAS succeeds, `suspend` re-fetches and checks the cancel
  flag: a cancel request that won the write order just before the suspend
  changed neither status nor epoch, so it cannot invalidate the guard — but
  it must not strand a "cancelled" run in `waiting` with nobody left to
  honor the flag. If the flag is set, the freshly parked run resolves as a
  direct cancel and `{:cancelled, facts}` tells the runner the run is
  terminal, not parked. (In the residual race where the run has already
  moved on by re-check time, the flag survives in facts and the next
  execution's cancellation poll honors it.)
  """
  @spec suspend(Lease.t(), Suspension.Request.t(), keyword()) ::
          {:ok, ResumeToken.t()}
          | {:cancelled, Facts.t()}
          | {:error, :lost_lease}
          | {:error, term()}
  def suspend(%Lease{} = lease, %Suspension.Request{} = request, opts \\ []) do
    token = %ResumeToken{
      run_ref: lease.run_ref,
      epoch: lease.epoch,
      reason_type: Suspension.reason_type(request)
    }

    checkpoint = %Checkpoint{
      rollout_id: Keyword.get(opts, :rollout_id, inspect(lease.run_ref)),
      iteration: request.iteration,
      messages: request.messages,
      pending: request.pending,
      usage: request.usage,
      cursor: Keyword.get(opts, :cursor)
    }

    suspension = %Suspension{reason: request.reason, checkpoint: checkpoint, token: token}

    transition = %Transition{
      op: :suspend,
      run_ref: lease.run_ref,
      expect: running_expect(lease),
      set: %{
        status: :waiting,
        suspension: suspension,
        executor_id: nil,
        deadline: nil,
        heartbeat_at: nil,
        queued_at: :now,
        usage: request.usage
      }
    }

    case apply_with_retry(lease.lifecycle, transition, lease.ctx) do
      {:ok, _facts} ->
        emit(:suspended, %{}, Map.put(lease_metadata(lease), :reason_type, token.reason_type))
        post_suspend_cancel_check(lease, token, request.usage)

      {:error, :stale} ->
        emit(:lease_lost, %{}, lease_metadata(lease))
        {:error, :lost_lease}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post_suspend_cancel_check(%Lease{} = lease, token, usage) do
    case lease.lifecycle.fetch(lease.run_ref, lease.ctx) do
      {:ok, %Facts{status: :waiting, epoch: epoch, cancel: %{reason: reason}} = facts}
      when epoch == lease.epoch ->
        result = Result.cancelled(reason, usage)

        transition = %Transition{
          op: :cancel_request,
          run_ref: lease.run_ref,
          expect: expect(facts),
          set: %{status: :cancelled, finished_at: :now},
          result: result
        }

        case apply_with_retry(lease.lifecycle, transition, lease.ctx) do
          {:ok, cancelled_facts} ->
            emit_finished(lease.run_ref, lease.epoch, result,
              claimed_at: lease.claimed_at,
              finished_at: cancelled_facts.finished_at
            )

            {:cancelled, cancelled_facts}

          # Someone else terminalized it first; report what stands.
          {:error, :stale} ->
            refetch_terminal_or_token(lease, token)

          {:error, _reason} ->
            {:ok, token}
        end

      {:ok, %Facts{status: :waiting}} ->
        {:ok, token}

      {:ok, %Facts{} = facts} ->
        if Facts.terminal?(facts), do: {:cancelled, facts}, else: {:ok, token}

      {:error, _reason} ->
        # The suspend itself committed; a failed advisory re-read must not
        # unpark the run. The flag, if any, survives for the next execution.
        {:ok, token}
    end
  end

  defp refetch_terminal_or_token(%Lease{} = lease, token) do
    case lease.lifecycle.fetch(lease.run_ref, lease.ctx) do
      {:ok, %Facts{} = facts} ->
        if Facts.terminal?(facts), do: {:cancelled, facts}, else: {:ok, token}

      {:error, _} ->
        {:ok, token}
    end
  end

  ## Resume

  @doc """
  Resolves a waiting run by reference: `waiting -> queued`, payload
  stamped, `queued_at` reset. The token names the run; validation is the
  staleness defense (status, suspension presence, epoch, reason type) —
  authorization happened before this call, in the host. The epoch is
  untouched; the next claim increments it. Resume never hides an enqueue:
  after `{:ok, facts}` the host re-enqueues its job explicitly.

  Approval payloads are normative: `{:approved, meta}` | `{:denied, meta}`.
  `{:until, _}` resumes carry `:elapsed`; `{:external, _}` payloads are
  host-defined.
  """
  @spec resume(module(), ResumeToken.t(), term(), term()) ::
          {:ok, Facts.t()}
          | {:error,
             :stale_reference
             | :run_not_waiting
             | :already_resumed
             | :wrong_reference_type
             | :not_found
             | term()}
  def resume(lifecycle, %ResumeToken{} = token, payload, ctx \\ nil) do
    do_resume(lifecycle, token, payload, ctx, 3)
  end

  defp do_resume(_lifecycle, _token, _payload, _ctx, 0), do: {:error, :conflict}

  defp do_resume(lifecycle, %ResumeToken{} = token, payload, ctx, attempts) do
    with {:ok, %Facts{} = facts} <- lifecycle.fetch(token.run_ref, ctx) do
      cond do
        facts.status in [:queued, :running] ->
          {:error, :already_resumed}

        Facts.terminal?(facts) ->
          {:error, :run_not_waiting}

        facts.suspension == nil ->
          {:error, :run_not_waiting}

        facts.epoch != token.epoch ->
          {:error, :stale_reference}

        Suspension.reason_type(facts.suspension) != token.reason_type ->
          {:error, :wrong_reference_type}

        true ->
          transition = %Transition{
            op: :resume,
            run_ref: token.run_ref,
            expect: expect(facts),
            set: %{
              status: :queued,
              queued_at: :now,
              resume: %{payload: payload, resumed_at: :now}
            }
          }

          case lifecycle.apply(transition, ctx) do
            {:ok, resumed} ->
              emit(:resumed, %{}, %{run_ref: token.run_ref, epoch: resumed.epoch})
              {:ok, resumed}

            {:error, :stale} ->
              do_resume(lifecycle, token, payload, ctx, attempts - 1)

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  ## Cancel request

  @doc """
  Requests cancellation of a rollout run. Two flavors by ownership: a
  `running` run gets the cooperative flag (`{:ok, :flagged}` — a *delivery*
  promise, not an outcome promise: the run terminates as cancelled, or
  reaches the terminal it was already committing); an unowned
  `queued`/`waiting` run resolves directly as terminal `cancelled` with the
  projection firing (`{:ok, :finished}`). Racing movement re-routes between
  the flavors.

  Live loop-kind runs are refused with `{:error, :loop_run}` (LOOP_RFC
  amendment A2), before either flavor: the direct-terminal flavor would
  orphan a loop's children, and the flag this operation sets is honored by
  rollout boundary polls, not step machinery. Loop cancellation is
  loop-owned — a kind-aware flag plus wake whose cascade cancels children
  first and finishes last. A terminal run answers `:already_terminal`
  whatever its kind: dead ends have nothing left to protect.
  """
  @spec request_cancel(module(), term(), term(), term()) ::
          {:ok, :flagged}
          | {:ok, :finished}
          | {:error, :already_terminal | :loop_run | :not_found | term()}
  def request_cancel(lifecycle, run_ref, reason, ctx \\ nil) do
    do_request_cancel(lifecycle, run_ref, reason, ctx, 3)
  end

  defp do_request_cancel(_lifecycle, _run_ref, _reason, _ctx, 0), do: {:error, :conflict}

  defp do_request_cancel(lifecycle, run_ref, reason, ctx, attempts) do
    with {:ok, %Facts{} = facts} <- lifecycle.fetch(run_ref, ctx) do
      cond do
        Facts.terminal?(facts) ->
          {:error, :already_terminal}

        facts.kind == :loop ->
          {:error, :loop_run}

        facts.status == :running ->
          transition = %Transition{
            op: :cancel_request,
            run_ref: run_ref,
            expect: expect(facts),
            set: %{cancel: %{reason: reason, requested_at: :now}}
          }

          case lifecycle.apply(transition, ctx) do
            {:ok, _} -> {:ok, :flagged}
            {:error, :stale} -> do_request_cancel(lifecycle, run_ref, reason, ctx, attempts - 1)
            {:error, other} -> {:error, other}
          end

        facts.status in [:queued, :waiting] ->
          result = Result.cancelled(reason, facts.usage || %Usage{})

          transition = %Transition{
            op: :cancel_request,
            run_ref: run_ref,
            expect: expect(facts),
            set: %{status: :cancelled, finished_at: :now},
            result: result
          }

          case apply_with_retry(lifecycle, transition, ctx) do
            {:ok, cancelled_facts} ->
              # No execution owned the run, so there is no claim to measure
              # a duration from.
              emit_finished(run_ref, facts.epoch, result,
                claimed_at: nil,
                finished_at: cancelled_facts.finished_at
              )

              {:ok, :finished}

            {:error, :stale} ->
              do_request_cancel(lifecycle, run_ref, reason, ctx, attempts - 1)

            {:error, other} ->
              {:error, other}
          end
      end
    end
  end

  ## Finish

  @doc """
  The single runner-side terminal transition: `running -> ` the status the
  result names, with the result attached so the host projection commits in
  the same atomic unit. Fires at most once per run lifetime — terminal
  statuses are dead ends, and a `:stale` here disambiguates to
  `:already_terminal` (the reaper won) or `:lost_lease` (someone else owns
  the run now). Transient storage errors retry under the still-live
  heartbeat; `:stale` never retries.
  """
  @spec finish(Lease.t(), Result.t()) ::
          {:ok, Facts.t()}
          | {:error, :lost_lease | :already_terminal}
          | {:error, term()}
  def finish(%Lease{} = lease, result) do
    set =
      %{status: Result.status(result), usage: Result.usage(result), finished_at: :now}
      |> put_terminal_detail(result)

    transition = %Transition{
      op: :finish,
      run_ref: lease.run_ref,
      expect: running_expect(lease),
      set: set,
      result: result
    }

    case apply_with_retry(lease.lifecycle, transition, lease.ctx) do
      {:ok, facts} ->
        emit_finished(lease.run_ref, lease.epoch, result,
          claimed_at: lease.claimed_at,
          finished_at: facts.finished_at
        )

        {:ok, facts}

      {:error, :stale} ->
        case lease.lifecycle.fetch(lease.run_ref, lease.ctx) do
          {:ok, %Facts{} = facts} ->
            if Facts.terminal?(facts) do
              {:error, :already_terminal}
            else
              emit(:lease_lost, %{}, lease_metadata(lease))
              {:error, :lost_lease}
            end

          {:error, _} ->
            emit(:lease_lost, %{}, lease_metadata(lease))
            {:error, :lost_lease}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Interrupt

  @doc """
  Reaper- and admin-facing terminal transition to `interrupted`, guarded by
  the exact facts the caller observed and carrying `Result.Interrupted` so
  the projection fires for reaped runs exactly as for finished ones (usage
  is the heartbeat-piggybacked approximation). A concurrent live finish
  wins the CAS and that is correct — exactly one terminal writer per run.

  Terminal facts are refused outright: the exact-pair CAS would happily
  match a stale-fetched terminal snapshot and rewrite a dead-end status,
  firing a second projection. Dead-end enforcement is this module's job,
  not the caller's pre-filtering.
  """
  @spec interrupt(module(), Facts.t(), InterruptReason.t(), term()) ::
          {:ok, Facts.t()} | {:error, :already_terminal | :stale} | {:error, term()}
  def interrupt(lifecycle, %Facts{} = facts, %InterruptReason{} = reason, ctx \\ nil) do
    if Facts.terminal?(facts) do
      {:error, :already_terminal}
    else
      result = Result.interrupted(reason, facts.usage || %Usage{})

      transition = %Transition{
        op: :interrupt,
        run_ref: facts.ref,
        expect: expect(facts),
        set: %{status: :interrupted, interrupt: reason, finished_at: :now},
        result: result
      }

      case apply_with_retry(lifecycle, transition, ctx) do
        {:ok, reaped} ->
          emit(:reaped, %{}, %{run_ref: facts.ref, epoch: facts.epoch, code: reason.code})
          {:ok, reaped}

        {:error, _} = error ->
          error
      end
    end
  end

  ## Requeue

  @doc """
  The same-run retry path: `running -> queued`, refused outright when the
  effect fence is set — re-executing a rollout whose tools already touched
  the world is exactly what this design exists to prevent. The epoch is
  untouched (the next claim increments it, and because epochs count claims
  they double as the attempt counter). Field hygiene clears the executor
  fields. This arity is the drain flavor, fired by the runner holding the
  lease; see `requeue/4` for the reaper flavor.
  """
  @spec requeue(Lease.t(), term()) ::
          {:ok, Facts.t()} | {:error, :effects_present | :lost_lease | term()}
  def requeue(%Lease{} = lease, reason) do
    case lease.lifecycle.fetch(lease.run_ref, lease.ctx) do
      {:ok, %Facts{status: :running, epoch: epoch} = facts} when epoch == lease.epoch ->
        do_requeue(lease.lifecycle, facts, reason, lease.ctx)

      {:ok, %Facts{}} ->
        emit(:lease_lost, %{}, lease_metadata(lease))
        {:error, :lost_lease}

      {:error, fetch_error} ->
        {:error, fetch_error}
    end
  end

  @doc """
  Reaper flavor of `requeue/2`: fired on the same stale-heartbeat evidence
  as an interrupt, when policy opts in, guarded by the exact observed
  facts. Only `running` runs are requeueable — anything else (including a
  stale-fetched terminal snapshot) is refused with a clean error, for the
  same reason `interrupt/4` refuses terminal facts.
  """
  @spec requeue(module(), Facts.t(), term(), term()) ::
          {:ok, Facts.t()}
          | {:error, :effects_present | {:not_requeueable, Facts.status()} | :stale | term()}
  def requeue(lifecycle, facts, reason, ctx \\ nil)

  def requeue(lifecycle, %Facts{status: :running} = facts, reason, ctx) do
    do_requeue(lifecycle, facts, reason, ctx)
  end

  def requeue(_lifecycle, %Facts{} = facts, _reason, _ctx) do
    {:error, {:not_requeueable, facts.status}}
  end

  defp do_requeue(_lifecycle, %Facts{effects?: true}, _reason, _ctx) do
    {:error, :effects_present}
  end

  defp do_requeue(lifecycle, %Facts{} = facts, reason, ctx) do
    transition = %Transition{
      op: :requeue,
      run_ref: facts.ref,
      expect: expect(facts),
      set: %{
        status: :queued,
        queued_at: :now,
        executor_id: nil,
        deadline: nil,
        heartbeat_at: nil
      },
      meta: %{reason: reason}
    }

    case lifecycle.apply(transition, ctx) do
      {:ok, requeued} ->
        emit(:requeued, %{}, %{run_ref: facts.ref, epoch: facts.epoch, reason: reason})
        {:ok, requeued}

      {:error, _} = error ->
        error
    end
  end

  ## Internals

  # Telemetry describes committed state, so it rides the emission seam: a
  # protocol operation executed inside an enclosing atomic unit (the loop
  # adapter cancelling children as cargo) defers its events to that unit's
  # commit and loses them to its rollback. Immediate everywhere else.
  defp emit(event, measurements, metadata) do
    Clementine.Emissions.emit(fn ->
      :telemetry.execute([:clementine, :run, event], measurements, metadata)
    end)
  end

  # A terminal write by a live lease measures its execution, claim to
  # finish, on the storage clock that stamped both ends. A terminal with no
  # owning execution (direct cancel of a queued/waiting run) has no claim
  # to measure from and reports zero.
  defp emit_finished(run_ref, epoch, result, stamps) do
    duration =
      case {Keyword.get(stamps, :claimed_at), Keyword.get(stamps, :finished_at)} do
        {%DateTime{} = claimed_at, %DateTime{} = finished_at} ->
          finished_at
          |> DateTime.diff(claimed_at, :microsecond)
          |> System.convert_time_unit(:microsecond, :native)
          |> max(0)

        _missing ->
          0
      end

    emit(:finished, %{duration: duration}, %{
      run_ref: run_ref,
      epoch: epoch,
      terminal: Result.status(result),
      usage: Result.usage(result)
    })
  end

  defp lease_metadata(%Lease{run_ref: run_ref, epoch: epoch}) do
    %{run_ref: run_ref, epoch: epoch}
  end

  defp expect(%Facts{status: status, epoch: epoch}), do: %{status: status, epoch: epoch}

  defp running_expect(%Lease{epoch: epoch}), do: %{status: :running, epoch: epoch}

  defp lease_resume(%Facts{
         suspension: %Suspension{checkpoint: checkpoint},
         resume: %{payload: payload}
       }) do
    {checkpoint, payload}
  end

  defp lease_resume(%Facts{}), do: nil

  defp not_claimable(lifecycle, run_ref, ctx) do
    case lifecycle.fetch(run_ref, ctx) do
      {:ok, %Facts{status: status}} -> {:error, {:not_claimable, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_terminal_detail(set, %Result.Failed{error: error}), do: Map.put(set, :error, error)

  defp put_terminal_detail(set, %Result.Interrupted{reason: reason}),
    do: Map.put(set, :interrupt, reason)

  defp put_terminal_detail(set, _result), do: set

  # :stale is an answer, never retried; only transient storage errors are.
  defp apply_with_retry(lifecycle, transition, ctx) do
    apply_with_retry(lifecycle, transition, ctx, @terminal_write_attempts)
  end

  defp apply_with_retry(lifecycle, transition, ctx, attempts_left) do
    case lifecycle.apply(transition, ctx) do
      {:ok, facts} ->
        {:ok, facts}

      {:error, :stale} ->
        {:error, :stale}

      {:error, reason} ->
        if attempts_left > 1 do
          Process.sleep(@terminal_write_backoff_ms)
          apply_with_retry(lifecycle, transition, ctx, attempts_left - 1)
        else
          {:error, reason}
        end
    end
  end
end
