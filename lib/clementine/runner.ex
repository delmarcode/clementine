defmodule Clementine.Runner do
  @moduledoc """
  The interpreter that animates a run: claim, heartbeat, execute the
  rollout, and suspend or finish exactly once — stopping cleanly on lease
  loss. Oban is not the runner; Oban is one place the runner runs.

  `execute/2` returns a closed union the host worker maps:

  - `{:finished, facts}` — a terminal wrote, or a drain requeued the run
    (the facts say which: on `status: :queued` the worker re-enqueues).
  - `{:suspended, token}` — the run parked in `waiting`; no finish occurred.
  - `{:discard, reason}` — nothing was written and nothing may be: a lost
    claim race, a lost lease (always this shape, wherever discovered), or a
    terminal that already exists.
  - `{:error, reason}` — the terminal write exhausted its retries; the run
    stays `running` and the reaper finishes the story.

  Failure handling is two-tier: any in-process exception is rescued and
  finished as `failed` with a normalized error — users should not wait two
  minutes to learn about a crash the process survived. Process death writes
  nothing; the linked heartbeat dies with the runner and the reaper
  interrupts after the stale threshold. There is no third tier.

  The heartbeat outlives the rollout: started after claim, linked, and
  stopped only after the terminal or suspend write returns, so those writes
  retry transient storage errors under a live lease instead of racing the
  reaper.

  The run's trace (`Clementine.Trace`) is recorded the same way: the
  rollout records each entry into a buffer the runner owns and writes the
  new ones at every iteration boundary, fenced on the epoch; the terminal
  or suspend write carries whatever is left, so it commits with the end,
  even when the rollout raised. A drain writes it before the requeue. A
  lost lease writes nothing.

  Cooperative cancellation reaches the run two ways: the rollout's boundary
  poll (the guarantee — worst-case latency is one iteration) and, when the
  lifecycle exports `subscribe_cancel/1`, a push notification that aborts
  the in-flight provider stream (≈ instant). The runner subscribes after
  claim, best-effort: a failed subscription costs latency, never
  correctness.
  """

  require Logger

  alias Clementine.{
    ApprovalRequest,
    Error,
    Events,
    Heartbeat,
    Lease,
    Result,
    Rollout,
    Run,
    Suspension
  }

  alias Clementine.Events.Stamper
  alias Clementine.Trace.Recorder
  alias Clementine.Lifecycle.{Facts, Protocol}

  @type outcome ::
          {:finished, Facts.t()}
          | {:suspended, Clementine.ResumeToken.t()}
          | {:discard, reason :: term()}
          | {:error, term()}

  @doc """
  Claims and executes one run.

  ## Options

  - `:lifecycle` (required) - the host's `Clementine.Lifecycle` module
  - `:executor_id` (required) - human/telemetry identity for this execution
  - `:events` - a `Clementine.Events` sink (default `Clementine.Events.Null`)
  - `:ctx` - opaque host context threaded to the lifecycle
  - `:heartbeat` - `false` to run without a heartbeat process (the
    ephemeral, single-process path — lease loss is impossible there), or a
    keyword list (`interval:`) tuning it; defaults to on
  - `:rollout_execute` - the rollout engine, defaulting to
    `&Clementine.Rollout.execute/2`. A seam for deterministic tests of
    runner branches the real engine cannot yet produce on demand; not host
    API.

  The execution deadline is minted at claim from the rollout's
  `max_duration` limit.
  """
  @spec execute(Run.t(), keyword()) :: outcome()
  def execute(%Run{} = run, opts) do
    lifecycle = Keyword.fetch!(opts, :lifecycle)
    executor = Keyword.fetch!(opts, :executor_id)
    ctx = Keyword.get(opts, :ctx)
    max_duration = run.rollout |> Rollout.limits() |> Keyword.get(:max_duration)

    case Protocol.claim(lifecycle, run.ref,
           executor: executor,
           ctx: ctx,
           max_duration: max_duration
         ) do
      {:ok, lease} -> run_leased(run, lease, opts)
      {:error, reason} -> {:discard, reason}
    end
  end

  defp run_leased(run, lease, opts) do
    sink = Keyword.get(opts, :events, Events.Null)
    rollout_execute = Keyword.get(opts, :rollout_execute, &Rollout.execute/2)
    stamper = Events.stamper(sink, lease)
    heartbeat = start_heartbeat(lease, stamper, Keyword.get(opts, :heartbeat, []))
    recorder = start_recorder(lease, stamper)
    subscribe_cancel(lease)

    try do
      rollout_result =
        try do
          rollout_execute.(run.rollout,
            resume: lease.resume,
            emit: stamper,
            trace: recorder,
            cancel?: fn -> Protocol.cancellation(lease) end,
            mark_effects: fn -> Protocol.mark_effects(lease) end,
            deadline: lease.deadline
          )
        rescue
          e -> {:error, Error.from_exception(:error, e, __STACKTRACE__)}
        catch
          kind, reason -> {:error, Error.from_exception(kind, reason, __STACKTRACE__)}
        end

      # Heartbeat still live: the terminal/suspend write retries transient
      # storage errors without racing the reaper.
      settle(rollout_result, lease, stamper, recorder)
    after
      Recorder.close(recorder)
      if heartbeat, do: Heartbeat.stop(heartbeat)
    end
  end

  # The trace buffer for this execution, written through the protocol's
  # fenced trace write, with the usage so far riding along as on a beat.
  defp start_recorder(lease, stamper) do
    Recorder.new(lease.run_ref, lease.epoch, fn entries ->
      Protocol.record_trace(lease, entries, usage: Stamper.usage(stamper))
    end)
  end

  defp start_heartbeat(_lease, _stamper, false), do: nil

  defp start_heartbeat(lease, stamper, opts) when is_list(opts) do
    {:ok, pid} =
      Heartbeat.start_link(lease, Keyword.merge(opts, notify: self(), usage: stamper))

    pid
  end

  # The optional cancel push channel: delivery lands in this process's
  # mailbox as {:clementine, :cancel, reason} and the rollout's blocking
  # points honor it. Best-effort — the boundary poll is the guarantee, so
  # a failed subscription is logged, never fatal.
  defp subscribe_cancel(%Lease{lifecycle: lifecycle} = lease) do
    if function_exported?(lifecycle, :subscribe_cancel, 1) do
      try do
        lease.lifecycle.subscribe_cancel(lease)
      rescue
        e ->
          Logger.warning(
            "#{inspect(lifecycle)}.subscribe_cancel/1 raised: #{Exception.message(e)} " <>
              "(run: #{inspect(lease.run_ref)}); falling back to the boundary poll"
          )
      catch
        kind, reason ->
          Logger.warning(
            "#{inspect(lifecycle)}.subscribe_cancel/1 #{kind}: #{inspect(reason)} " <>
              "(run: #{inspect(lease.run_ref)}); falling back to the boundary poll"
          )
      end
    end

    :ok
  end

  # The rollout's closed return set, every branch — plus the defensive
  # catch-all: a contract violation from a buggy rollout must become
  # finish(failed), never a CaseClauseError that turns into a two-minute
  # reaped mystery. Results the rollout could not carry usage on (cancel,
  # error, drain-interrupt) get the stamper's accumulated approximation.
  # Every write that ends or parks the run carries the trace entries the
  # rollout recorded and has not written.
  defp settle(rollout_result, lease, stamper, recorder) do
    case rollout_result do
      {:ok, %Result.Completed{} = result} ->
        finish(lease, result, recorder)

      {:suspend, %Suspension.Request{} = request} ->
        suspend(lease, request, stamper, recorder)

      {:cancelled, reason} ->
        finish(lease, Result.cancelled(reason, Stamper.usage(stamper)), recorder)

      :drained ->
        requeue(lease, stamper, recorder)

      {:error, %Error{} = error} ->
        finish(lease, Result.failed(error, Stamper.usage(stamper)), recorder)

      :lost_lease ->
        {:discard, :lost_lease}

      other ->
        finish(
          lease,
          Result.failed(Error.invalid_return(other), Stamper.usage(stamper)),
          recorder
        )
    end
  end

  defp suspend(lease, request, stamper, recorder) do
    case Protocol.suspend(lease, request,
           cursor: Stamper.cursor(stamper),
           trace: Recorder.pending(recorder)
         ) do
      {:ok, token} ->
        # An approval UI must never precede a durable suspension: the
        # advisory event goes out only after the suspend committed.
        emit_approval_requested(stamper, request)
        {:suspended, token}

      {:cancelled, facts} ->
        {:finished, facts}

      {:error, :lost_lease} ->
        {:discard, :lost_lease}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_approval_requested(stamper, %Suspension.Request{
         reason: {:approval, %ApprovalRequest{} = approval}
       }) do
    Stamper.emit(stamper, :approval_requested, %{
      tool_use_id: approval.tool_use_id,
      name: approval.tool_name,
      args: approval.args
    })
  end

  defp emit_approval_requested(_stamper, %Suspension.Request{}), do: :ok

  defp finish(lease, result, recorder) do
    case Protocol.finish(lease, result, trace: Recorder.pending(recorder)) do
      {:ok, facts} -> {:finished, facts}
      {:error, :lost_lease} -> {:discard, :lost_lease}
      {:error, :already_terminal} -> {:discard, :already_terminal}
      # Retries exhausted; the run stays running and the reaper acts.
      {:error, reason} -> {:error, reason}
    end
  end

  # Drain resolution: requeue when nothing external happened — the run
  # silently survives the deploy — else the one sanctioned runner-side
  # interrupt, an immediate labeled outcome instead of a reaped mystery.
  # The trace of what this execution did is written first: a requeued run
  # starts again from its prompt under a new epoch, and what it read here
  # stays on the record.
  defp requeue(lease, stamper, recorder) do
    case Recorder.flush(recorder) do
      :ok -> requeue_flushed(lease, stamper, recorder)
      :lost_lease -> {:discard, :lost_lease}
    end
  end

  defp requeue_flushed(lease, stamper, recorder) do
    case Protocol.requeue(lease, :drain) do
      {:ok, facts} ->
        {:finished, facts}

      {:error, :effects_present} ->
        finish(lease, Result.interrupted(:drain, Stamper.usage(stamper)), recorder)

      {:error, :lost_lease} ->
        {:discard, :lost_lease}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
