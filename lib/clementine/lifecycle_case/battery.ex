defmodule Clementine.LifecycleCase.Battery do
  @moduledoc false
  # The conformance battery bodies. `Clementine.LifecycleCase.__using__/1`
  # generates one thin test per function here; keeping the bodies as
  # ordinary code keeps assertion failures pointing at real lines instead
  # of quoted AST. Every function takes the harness map the generated
  # `__conformance__/0` builds: `%{lifecycle:, create_run:, ctx:,
  # storage_now:}`.

  import ExUnit.Assertions

  alias Clementine.Lifecycle.{Facts, Protocol, Transition}
  alias Clementine.LLM.Message.Content.ToolUse
  alias Clementine.LLM.Message.{AssistantMessage, UserMessage}

  alias Clementine.{
    ApprovalRequest,
    Checkpoint,
    InterruptReason,
    Lease,
    Pending,
    Result,
    ResumeToken,
    Suspension,
    ToolResult,
    Usage
  }

  @concurrent_claimers 8

  ## fetch/2

  def fetch_round_trip(h) do
    ref = create!(h)
    facts = fetch!(h, ref)

    assert %Facts{status: :queued, epoch: 0, effects?: false} = facts
    assert facts.ref == ref
    assert %DateTime{} = facts.queued_at

    for field <- [
          :executor_id,
          :heartbeat_at,
          :deadline,
          :cancel,
          :suspension,
          :resume,
          :error,
          :interrupt,
          :finished_at
        ] do
      assert Map.fetch!(facts, field) == nil,
             "expected a fresh queued run to carry #{field}: nil, got: " <>
               inspect(Map.fetch!(facts, field))
    end
  end

  def fetch_not_found(h, missing_ref) do
    assert {:error, :not_found} = h.lifecycle.fetch(missing_ref, h.ctx)

    assert {:error, :not_found} =
             Protocol.claim(h.lifecycle, missing_ref, executor: "x", ctx: h.ctx)
  end

  ## claim

  def claim_mints_execution(h) do
    ref = create!(h)
    lease = claim!(h, ref, executor: "conformance:winner", max_duration: 60_000)

    assert %Lease{epoch: 1, executor_id: "conformance:winner"} = lease

    facts = fetch!(h, ref)
    assert facts.status == :running
    assert facts.epoch == 1
    assert facts.executor_id == "conformance:winner"
    assert %DateTime{} = facts.heartbeat_at
    assert %DateTime{} = facts.deadline

    # Without max_duration there is no execution deadline.
    bare = create!(h)
    claim!(h, bare)
    assert fetch!(h, bare).deadline == nil
  end

  def claim_refuses_unclaimable(h) do
    running = create!(h)
    claim!(h, running)

    assert {:error, {:not_claimable, :running}} =
             Protocol.claim(h.lifecycle, running, executor: "late", ctx: h.ctx)

    waiting = create!(h)
    lease = claim!(h, waiting)
    {:ok, _token} = Protocol.suspend(lease, suspension_request(), cursor: {1, 0})

    assert {:error, {:not_claimable, :waiting}} =
             Protocol.claim(h.lifecycle, waiting, executor: "late", ctx: h.ctx)

    done = create!(h)
    {:ok, _} = Protocol.finish(claim!(h, done), Result.completed())

    assert {:error, {:not_claimable, :completed}} =
             Protocol.claim(h.lifecycle, done, executor: "late", ctx: h.ctx)
  end

  def concurrent_claimers(h) do
    ref = create!(h)

    tasks =
      for i <- 1..@concurrent_claimers do
        Task.async(fn ->
          receive do
            :go -> Protocol.claim(h.lifecycle, ref, executor: "racer:#{i}", ctx: h.ctx)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 30_000)

    {winners, losers} = Enum.split_with(results, &match?({:ok, _}, &1))

    assert length(winners) == 1,
           "expected exactly one claim winner, got #{length(winners)}: #{inspect(results)}"

    # A lost claim race is not an error to retry — every loser learns who
    # holds the run.
    assert Enum.all?(losers, &match?({:error, {:not_claimable, :running}}, &1)),
           "expected every loser to see {:not_claimable, :running}, got: #{inspect(losers)}"

    [{:ok, lease}] = winners
    facts = fetch!(h, ref)
    assert facts.status == :running
    assert facts.epoch == 1
    assert facts.executor_id == lease.executor_id
  end

  ## heartbeat

  def heartbeat_renews_and_piggybacks(h) do
    ref = create!(h)
    lease = claim!(h, ref, max_duration: 60_000)
    before = fetch!(h, ref)

    assert :ok = Protocol.heartbeat(lease, usage: %Usage{input_tokens: 5, output_tokens: 2})

    facts = fetch!(h, ref)
    assert facts.usage == %Usage{input_tokens: 5, output_tokens: 2}
    # A heartbeat writes exactly the keys it mentions: identity and deadline
    # survive untouched.
    assert facts.executor_id == before.executor_id
    assert facts.deadline == before.deadline
    assert facts.status == :running and facts.epoch == 1

    # A beat without a sample leaves the accumulated usage in place —
    # absent keys are never written.
    assert :ok = Protocol.heartbeat(lease)
    assert fetch!(h, ref).usage == %Usage{input_tokens: 5, output_tokens: 2}
  end

  def heartbeat_after_epoch_bump(h) do
    ref = create!(h)
    zombie = claim!(h, ref)

    {:ok, _facts} = Protocol.requeue(zombie, :drain)
    successor = claim!(h, ref)
    assert successor.epoch == 2

    # Status is :running again; only the epoch half of the guard fences.
    assert {:error, :lost_lease} = Protocol.heartbeat(zombie)
    assert :ok = Protocol.heartbeat(successor)
  end

  ## zombie fencing

  def zombie_fencing(h) do
    ref = create!(h)
    zombie = claim!(h, ref)
    {:ok, token} = Protocol.suspend(zombie, suspension_request(), cursor: {1, 4})

    # Status half of the guard: the run is :waiting, so a :running write
    # from the suspending epoch is stale.
    assert {:error, :stale} = h.lifecycle.apply(zombie_beat(ref, zombie.epoch), h.ctx)

    {:ok, _} = Protocol.resume(h.lifecycle, token, {:approved, %{by: 1}}, h.ctx)
    successor = claim!(h, ref)
    assert successor.epoch == 2

    # Epoch half of the guard: status is :running again — status alone
    # would match — but the zombie's epoch no longer does.
    assert {:error, :stale} = h.lifecycle.apply(zombie_beat(ref, zombie.epoch), h.ctx)

    # Every protocol operation the zombie can attempt discovers the loss.
    assert {:error, :lost_lease} = Protocol.heartbeat(zombie)
    assert {:error, :lost_lease} = Protocol.mark_effects(zombie)
    assert {:error, :lost_lease} = Protocol.cancellation(zombie)
    assert {:error, :lost_lease} = Protocol.suspend(zombie, suspension_request(), cursor: {1, 9})
    assert {:error, :lost_lease} = Protocol.requeue(zombie, :drain)
    assert {:error, :lost_lease} = Protocol.finish(zombie, Result.completed())

    # The successor is untouched by any of it.
    assert :ok = Protocol.heartbeat(successor)
    {:ok, done} = Protocol.finish(successor, Result.completed())
    assert done.status == :completed
    assert done.epoch == 2
  end

  defp zombie_beat(ref, epoch) do
    %Transition{
      op: :heartbeat,
      run_ref: ref,
      expect: %{status: :running, epoch: epoch},
      set: %{heartbeat_at: :now}
    }
  end

  ## finish

  def finish_terminal_variants(h) do
    completed = create!(h)

    result =
      Result.completed(
        input_message: UserMessage.new("hi"),
        messages: [%AssistantMessage{content: []}],
        output: "done",
        usage: %Usage{input_tokens: 3, output_tokens: 1}
      )

    {:ok, facts} = Protocol.finish(claim!(h, completed), result)
    assert facts.status == :completed
    assert facts.usage == %Usage{input_tokens: 3, output_tokens: 1}
    assert %DateTime{} = facts.finished_at
    assert fetch!(h, completed).status == :completed

    failed = create!(h)

    error =
      Clementine.Error.normalize(
        {:api_error, 429, %{"error" => %{"message" => "slow"}}},
        :anthropic
      )

    {:ok, facts} =
      Protocol.finish(claim!(h, failed), Result.failed(error, %Usage{input_tokens: 1}))

    assert facts.status == :failed
    assert facts.error == error
    assert facts.usage == %Usage{input_tokens: 1}

    cancelled = create!(h)
    {:ok, facts} = Protocol.finish(claim!(h, cancelled), Result.cancelled({:user, 7}))
    assert facts.status == :cancelled

    interrupted = create!(h)
    reason = InterruptReason.new(:drain, "shutdown with effects present")
    {:ok, facts} = Protocol.finish(claim!(h, interrupted), Result.interrupted(reason))
    assert facts.status == :interrupted
    assert facts.interrupt == reason
  end

  def double_finish(h) do
    ref = create!(h)
    lease = claim!(h, ref)

    {:ok, facts} = Protocol.finish(lease, Result.completed(output: "first"))
    assert facts.status == :completed

    # Terminal states are dead ends: finish fires at most once per run.
    assert {:error, :already_terminal} =
             Protocol.finish(lease, Result.completed(output: "second"))

    assert fetch!(h, ref).status == :completed
  end

  def finish_after_reap(h) do
    ref = create!(h)
    lease = claim!(h, ref)
    observed = fetch!(h, ref)

    reason = InterruptReason.new(:lease_expired, "conformance sweep")
    {:ok, reaped} = Protocol.interrupt(h.lifecycle, observed, reason, h.ctx)
    assert reaped.status == :interrupted
    assert reaped.interrupt == reason
    assert %DateTime{} = reaped.finished_at

    # The runner wakes late: its terminal write disambiguates precisely,
    # and its heartbeat discovers the loss.
    assert {:error, :already_terminal} = Protocol.finish(lease, Result.completed())
    assert {:error, :lost_lease} = Protocol.heartbeat(lease)
    assert fetch!(h, ref).status == :interrupted
  end

  ## projection

  def projection_atomicity(h) do
    ref = create!(h, projection: :raise)

    # No transition without a result touches the projection: the whole
    # non-terminal lifecycle proceeds despite an always-raising projection.
    lease = claim!(h, ref)
    assert :ok = Protocol.heartbeat(lease)
    {:ok, token} = Protocol.suspend(lease, suspension_request(), cursor: {1, 1})
    {:ok, _} = Protocol.resume(h.lifecycle, token, {:approved, %{by: 1}}, h.ctx)
    lease2 = claim!(h, ref)
    before = fetch!(h, ref)

    # The terminal write runs the projection in the same atomic unit: when
    # it raises, nothing commits — status, epoch, and finished_at are
    # exactly what they were.
    assert_aborts(fn -> Protocol.finish(lease2, Result.completed()) end)

    facts = fetch!(h, ref)
    assert facts.status == :running
    assert facts.epoch == before.epoch
    assert facts.finished_at == nil

    # The lease survived the aborted commit; the run is still live.
    assert :ok = Protocol.heartbeat(lease2)
  end

  def projection_fires_for_finish(h) do
    # The probe raises only on the exact variant, so an abort proves the
    # projection ran and received precisely that result.
    ref = create!(h, projection: {:raise_on, :completed})
    lease = claim!(h, ref)

    assert_aborts(fn -> Protocol.finish(lease, Result.completed()) end)
    assert fetch!(h, ref).status == :running

    # The same run finishes cleanly under a different variant: the probe is
    # selective, so the variant delivered to the projection was real.
    {:ok, facts} = Protocol.finish(lease, Result.failed(:conformance_probe))
    assert facts.status == :failed

    ref2 = create!(h, projection: {:raise_on, :failed})
    lease2 = claim!(h, ref2)

    assert_aborts(fn -> Protocol.finish(lease2, Result.failed(:conformance_probe)) end)
    assert fetch!(h, ref2).status == :running

    {:ok, facts2} = Protocol.finish(lease2, Result.completed())
    assert facts2.status == :completed
  end

  def projection_fires_for_interrupt(h) do
    ref = create!(h, projection: {:raise_on, :interrupted})
    claim!(h, ref)
    observed = fetch!(h, ref)

    assert_aborts(fn ->
      Protocol.interrupt(h.lifecycle, observed, InterruptReason.new(:lease_expired), h.ctx)
    end)

    assert fetch!(h, ref).status == :running

    # Negative control: a probe selective on Completed does not block the
    # reaper — the projection received Interrupted, not Completed.
    ref2 = create!(h, projection: {:raise_on, :completed})
    claim!(h, ref2)
    observed2 = fetch!(h, ref2)

    {:ok, reaped} =
      Protocol.interrupt(h.lifecycle, observed2, InterruptReason.new(:lease_expired), h.ctx)

    assert reaped.status == :interrupted
  end

  def projection_fires_for_direct_cancel(h) do
    queued = create!(h, projection: {:raise_on, :cancelled})

    assert_aborts(fn -> Protocol.request_cancel(h.lifecycle, queued, :probe, h.ctx) end)
    assert fetch!(h, queued).status == :queued

    waiting = create!(h, projection: {:raise_on, :cancelled})
    lease = claim!(h, waiting)
    {:ok, _token} = Protocol.suspend(lease, suspension_request(), cursor: {1, 0})

    assert_aborts(fn -> Protocol.request_cancel(h.lifecycle, waiting, :probe, h.ctx) end)
    assert fetch!(h, waiting).status == :waiting
  end

  ## suspend and resume

  def suspension_round_trip(h) do
    ref = create!(h)
    lease = claim!(h, ref, max_duration: 60_000)
    request = suspension_request()

    {:ok, token} =
      Protocol.suspend(lease, request, cursor: {1, 7}, rollout_id: "conformance-rollout")

    assert token == %ResumeToken{run_ref: ref, epoch: 1, reason_type: :approval}

    facts = fetch!(h, ref)
    assert facts.status == :waiting
    assert facts.epoch == 1
    assert facts.usage == request.usage

    # The stored suspension is exactly what the protocol assembled — the
    # host's storage round-trips the checkpoint bit-for-bit.
    assert %Suspension{} = facts.suspension
    assert facts.suspension.token == token
    assert facts.suspension.reason == request.reason

    checkpoint = facts.suspension.checkpoint
    assert %Checkpoint{} = checkpoint
    assert checkpoint.rollout_id == "conformance-rollout"
    assert checkpoint.iteration == request.iteration
    assert checkpoint.cursor == {1, 7}
    assert checkpoint.messages == request.messages
    assert checkpoint.pending == request.pending
    assert checkpoint.usage == request.usage
  end

  def suspend_field_hygiene(h) do
    ref = create!(h)
    lease = claim!(h, ref, max_duration: 60_000)
    assert :ok = Protocol.heartbeat(lease)

    before = fetch!(h, ref)
    assert before.executor_id != nil
    assert before.deadline != nil
    assert before.heartbeat_at != nil

    {:ok, _token} = Protocol.suspend(lease, suspension_request(), cursor: {1, 2})

    # A waiting run has no executor, no deadline, no heartbeat — a field
    # whose meaning does not survive the target status must not survive
    # the transition.
    facts = fetch!(h, ref)
    assert facts.executor_id == nil
    assert facts.deadline == nil
    assert facts.heartbeat_at == nil
  end

  def resume_round_trip(h) do
    ref = create!(h)
    lease = claim!(h, ref)
    request = suspension_request()
    {:ok, token} = Protocol.suspend(lease, request, cursor: {1, 7})
    before = fetch!(h, ref)

    {:ok, facts} = Protocol.resume(h.lifecycle, token, {:approved, %{by: 42}}, h.ctx)

    assert facts.status == :queued
    assert facts.epoch == 1
    assert facts.resume.payload == {:approved, %{by: 42}}
    assert %DateTime{} = facts.resume.resumed_at
    assert %DateTime{} = facts.queued_at
    assert DateTime.compare(facts.queued_at, before.queued_at) != :lt

    # The next claim mints the next epoch and hands back exactly what was
    # parked: the checkpoint and the decision payload ride the lease.
    lease2 = claim!(h, ref)
    assert lease2.epoch == 2
    assert {%Checkpoint{} = checkpoint, {:approved, %{by: 42}}} = lease2.resume
    assert checkpoint.cursor == {1, 7}
    assert checkpoint.messages == request.messages
    assert checkpoint.pending == request.pending
  end

  def resume_already_resumed(h) do
    ref = create!(h)
    {:ok, token} = Protocol.suspend(claim!(h, ref), suspension_request(), cursor: {1, 0})

    {:ok, _} = Protocol.resume(h.lifecycle, token, {:approved, %{by: 1}}, h.ctx)

    # Replay against the queued run dies precisely.
    assert {:error, :already_resumed} =
             Protocol.resume(h.lifecycle, token, {:approved, %{by: 1}}, h.ctx)

    # And against the re-claimed (running) run too.
    claim!(h, ref)

    assert {:error, :already_resumed} =
             Protocol.resume(h.lifecycle, token, {:approved, %{by: 1}}, h.ctx)
  end

  def resume_stale_reference(h) do
    ref = create!(h)
    {:ok, stale_token} = Protocol.suspend(claim!(h, ref), suspension_request(), cursor: {1, 0})

    {:ok, _} = Protocol.resume(h.lifecycle, stale_token, {:approved, %{by: 1}}, h.ctx)
    lease2 = claim!(h, ref)
    {:ok, fresh_token} = Protocol.suspend(lease2, suspension_request(), cursor: {2, 0})

    # The old token names a suspension from a superseded epoch.
    assert {:error, :stale_reference} =
             Protocol.resume(h.lifecycle, stale_token, {:approved, %{by: 1}}, h.ctx)

    # The current token is untouched by the stale one's failure.
    assert {:ok, %Facts{status: :queued}} =
             Protocol.resume(h.lifecycle, fresh_token, {:approved, %{by: 2}}, h.ctx)
  end

  def resume_wrong_reference_type(h) do
    ref = create!(h)

    {:ok, %ResumeToken{} = token} =
      Protocol.suspend(claim!(h, ref), suspension_request(), cursor: {1, 0})

    forged = %ResumeToken{token | reason_type: :until}

    assert {:error, :wrong_reference_type} =
             Protocol.resume(h.lifecycle, forged, :elapsed, h.ctx)

    # The run is still parked; the real token still works.
    assert fetch!(h, ref).status == :waiting
    assert {:ok, _} = Protocol.resume(h.lifecycle, token, {:approved, %{by: 1}}, h.ctx)
  end

  def resume_run_not_waiting(h) do
    ref = create!(h)
    {:ok, token} = Protocol.suspend(claim!(h, ref), suspension_request(), cursor: {1, 0})

    {:ok, :finished} = Protocol.request_cancel(h.lifecycle, ref, :approver_denied, h.ctx)

    assert {:error, :run_not_waiting} =
             Protocol.resume(h.lifecycle, token, {:approved, %{by: 1}}, h.ctx)

    assert fetch!(h, ref).status == :cancelled
  end

  def resume_not_found(h, missing_ref) do
    token = %ResumeToken{run_ref: missing_ref, epoch: 1, reason_type: :approval}

    assert {:error, :not_found} = Protocol.resume(h.lifecycle, token, {:approved, %{}}, h.ctx)
  end

  ## cancellation

  def cancel_flags_running(h) do
    ref = create!(h)
    lease = claim!(h, ref)

    assert Protocol.cancellation(lease) == :none

    assert {:ok, :flagged} = Protocol.request_cancel(h.lifecycle, ref, {:user, 42}, h.ctx)

    # The flag is intent, not an outcome: the run still runs, and the
    # reason term round-trips exactly.
    facts = fetch!(h, ref)
    assert facts.status == :running
    assert facts.cancel.reason == {:user, 42}
    assert %DateTime{} = facts.cancel.requested_at

    assert {:requested, {:user, 42}} = Protocol.cancellation(lease)
  end

  def cancel_direct_queued(h) do
    ref = create!(h)

    assert {:ok, :finished} = Protocol.request_cancel(h.lifecycle, ref, :abandoned, h.ctx)

    facts = fetch!(h, ref)
    assert facts.status == :cancelled
    assert %DateTime{} = facts.finished_at
  end

  def cancel_already_terminal(h) do
    ref = create!(h)
    {:ok, _} = Protocol.finish(claim!(h, ref), Result.completed())

    assert {:error, :already_terminal} =
             Protocol.request_cancel(h.lifecycle, ref, :too_late, h.ctx)

    assert fetch!(h, ref).status == :completed
  end

  def cancel_racing_suspend_flag_first(h) do
    ref = create!(h)
    lease = claim!(h, ref)

    {:ok, :flagged} = Protocol.request_cancel(h.lifecycle, ref, :user_stop, h.ctx)

    # The flag write commutes with the suspend's CAS, so the suspend
    # commits — and its post-CAS re-check resolves the freshly parked run
    # as a direct cancel instead of stranding it in :waiting.
    assert {:cancelled, facts} = Protocol.suspend(lease, suspension_request(), cursor: {1, 0})
    assert facts.status == :cancelled

    stored = fetch!(h, ref)
    assert stored.status == :cancelled
    assert %DateTime{} = stored.finished_at
  end

  def cancel_racing_suspend_suspend_first(h) do
    ref = create!(h)
    lease = claim!(h, ref)

    {:ok, token} = Protocol.suspend(lease, suspension_request(), cursor: {1, 0})

    # The cancel arrives after the park: nobody owns the run, so the
    # request takes its direct terminal flavor.
    assert {:ok, :finished} = Protocol.request_cancel(h.lifecycle, ref, :user_stop, h.ctx)
    assert fetch!(h, ref).status == :cancelled

    # The suspension's token now points at a terminal run.
    assert {:error, :run_not_waiting} =
             Protocol.resume(h.lifecycle, token, {:approved, %{by: 1}}, h.ctx)
  end

  ## requeue

  def requeue_requeues(h) do
    ref = create!(h)
    lease = claim!(h, ref, max_duration: 60_000)
    before = fetch!(h, ref)

    {:ok, facts} = Protocol.requeue(lease, :drain)

    assert facts.status == :queued
    # The epoch is untouched: the next claim mints it, which is what makes
    # the epoch double as the attempt counter.
    assert facts.epoch == 1
    assert %DateTime{} = facts.queued_at
    assert DateTime.compare(facts.queued_at, before.queued_at) != :lt

    # apply returned the committed facts, not a stale snapshot.
    stored = fetch!(h, ref)

    for field <- [:status, :epoch, :queued_at, :executor_id, :heartbeat_at, :deadline] do
      assert Map.fetch!(facts, field) == Map.fetch!(stored, field)
    end

    assert claim!(h, ref).epoch == 2

    # The reaper flavor drives the same transition from observed facts.
    ref2 = create!(h)
    claim!(h, ref2)
    observed = fetch!(h, ref2)

    {:ok, requeued} = Protocol.requeue(h.lifecycle, observed, :lease_expired, h.ctx)
    assert requeued.status == :queued
    assert requeued.epoch == 1
  end

  def requeue_field_hygiene(h) do
    ref = create!(h)
    lease = claim!(h, ref, max_duration: 60_000)
    assert :ok = Protocol.heartbeat(lease)

    {:ok, facts} = Protocol.requeue(lease, :drain)

    # A queued run has no executor: requeue leaves none of the execution
    # fields behind.
    assert facts.executor_id == nil
    assert facts.deadline == nil
    assert facts.heartbeat_at == nil

    stored = fetch!(h, ref)
    assert stored.executor_id == nil
    assert stored.deadline == nil
    assert stored.heartbeat_at == nil
  end

  def requeue_refused_effects_present(h) do
    ref = create!(h)
    lease = claim!(h, ref)
    assert :ok = Protocol.mark_effects(lease)
    assert fetch!(h, ref).effects?

    # Re-executing a rollout whose tools already touched the world is
    # exactly what the fence exists to prevent — both flavors refuse.
    assert {:error, :effects_present} = Protocol.requeue(lease, :drain)

    observed = fetch!(h, ref)

    assert {:error, :effects_present} =
             Protocol.requeue(h.lifecycle, observed, :lease_expired, h.ctx)

    facts = fetch!(h, ref)
    assert facts.status == :running
    assert facts.effects?
  end

  ## reaper interrupt racing a live finish

  def interrupt_loses_to_finish(h) do
    # The probe raises on Interrupted, so a projection fired by the losing
    # reaper would surface loudly — losing must be a true no-op.
    ref = create!(h, projection: {:raise_on, :interrupted})
    lease = claim!(h, ref)
    observed = fetch!(h, ref)

    {:ok, _} = Protocol.finish(lease, Result.completed())

    assert {:error, :stale} =
             Protocol.interrupt(h.lifecycle, observed, InterruptReason.new(:lease_expired), h.ctx)

    # Exactly one terminal writer, decided by the CAS.
    facts = fetch!(h, ref)
    assert facts.status == :completed
    assert facts.interrupt == nil
  end

  ## storage clock

  def storage_clock_stamps(h) do
    ref = create!(h)

    {t0, lease, t1} = bracket(h, fn -> claim!(h, ref, max_duration: 60_000) end)
    facts = fetch!(h, ref)

    assert_stamped_between(t0, facts.heartbeat_at, t1, "claim heartbeat_at")

    assert_stamped_between(
      DateTime.add(t0, 60_000, :millisecond),
      facts.deadline,
      DateTime.add(t1, 60_000, :millisecond),
      "claim deadline ({:now_plus, ms})"
    )

    # A symbolic stamp nested inside a flag value resolves against the same
    # clock as the top-level ones.
    {t0, _, t1} = bracket(h, fn -> Protocol.request_cancel(h.lifecycle, ref, :stop, h.ctx) end)
    facts = fetch!(h, ref)
    assert_stamped_between(t0, facts.cancel.requested_at, t1, "cancel requested_at (nested)")

    {t0, _, t1} = bracket(h, fn -> Protocol.finish(lease, Result.cancelled(:stop)) end)
    facts = fetch!(h, ref)
    assert_stamped_between(t0, facts.finished_at, t1, "finish finished_at")
  end

  def storage_clock_requeue_and_resume(h) do
    requeued = create!(h)
    lease = claim!(h, requeued)

    {t0, {:ok, facts}, t1} = bracket(h, fn -> Protocol.requeue(lease, :drain) end)
    assert_stamped_between(t0, facts.queued_at, t1, "requeue queued_at")

    resumed = create!(h)
    {:ok, token} = Protocol.suspend(claim!(h, resumed), suspension_request(), cursor: {1, 0})

    {t0, {:ok, facts}, t1} =
      bracket(h, fn -> Protocol.resume(h.lifecycle, token, {:approved, %{by: 1}}, h.ctx) end)

    assert_stamped_between(t0, facts.queued_at, t1, "resume queued_at")
    assert_stamped_between(t0, facts.resume.resumed_at, t1, "resume resumed_at (nested)")
  end

  ## Harness helpers

  def create!(h, attrs \\ []), do: h.create_run.(attrs)

  def fetch!(h, ref) do
    assert {:ok, %Facts{} = facts} = h.lifecycle.fetch(ref, h.ctx)
    facts
  end

  def claim!(h, ref, opts \\ []) do
    opts = Keyword.merge([executor: "conformance:#{inspect(ref)}", ctx: h.ctx], opts)
    assert {:ok, %Lease{} = lease} = Protocol.claim(h.lifecycle, ref, opts)
    lease
  end

  @doc false
  # A terminal transition whose projection raises must not commit. A
  # conforming `apply` either re-raises out of its transaction or returns
  # `{:error, term}` — the one thing it may not do is return `{:ok, _}`.
  def assert_aborts(fun) do
    try do
      case fun.() do
        {:ok, committed} ->
          flunk(
            "expected the terminal transition to abort on the raising " <>
              "projection, but it committed: #{inspect(committed)}"
          )

        other ->
          other
      end
    rescue
      e in ExUnit.AssertionError -> reraise(e, __STACKTRACE__)
      _e -> :aborted
    catch
      _kind, _reason -> :aborted
    end
  end

  def suspension_request do
    %Suspension.Request{
      reason:
        {:approval,
         %ApprovalRequest{
           tool_use_id: "tu_gate",
           tool_name: "delete_records",
           args: %{"table" => "users"}
         }},
      pending: %Pending.ToolApproval{
        tool_use_id: "tu_gate",
        tool_name: "delete_records",
        args: %{"table" => "users"},
        completed_results: %{
          "tu_sibling" => %ToolResult{content: "42 rows", is_error: false}
        }
      },
      messages: [
        UserMessage.new("clean up the users table"),
        %AssistantMessage{
          content: [%ToolUse{id: "tu_gate", name: "delete_records", input: %{"table" => "users"}}]
        }
      ],
      iteration: 2,
      usage: %Usage{input_tokens: 40, output_tokens: 9}
    }
  end

  defp bracket(h, fun) do
    t0 = h.storage_now.()
    value = fun.()
    t1 = h.storage_now.()
    {t0, value, t1}
  end

  defp assert_stamped_between(t0, stamp, t1, label) do
    assert %DateTime{} = stamp, "expected #{label} to be stamped, got: #{inspect(stamp)}"

    assert DateTime.compare(t0, stamp) != :gt and DateTime.compare(stamp, t1) != :gt,
           "expected #{label} to resolve against the storage clock " <>
             "(between #{inspect(t0)} and #{inspect(t1)}), got: #{inspect(stamp)} — " <>
             "a stamp outside the bracket was resolved by some other clock"
  end
end
