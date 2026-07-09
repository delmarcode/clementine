defmodule Clementine.LoopCase.Battery do
  @moduledoc false
  # The loop conformance battery bodies. `Clementine.LoopCase.__using__/1`
  # generates one thin test per function here; keeping the bodies as
  # ordinary code keeps assertion failures pointing at real lines instead
  # of quoted AST. Every function takes the harness map the generated
  # `__loop_conformance__/0` builds: `%{host:, lifecycle:, create_loop:,
  # ctx:}`.
  #
  # Observation is storage-only: lifecycle `fetch`, host `load`/`pending`,
  # append return values, `Runner.step/2` outcomes, and the committed
  # envelope (children refs, the conformance loop's state log). Mid-step
  # interleavings — crash windows, zombie commits, the park race — are
  # manufactured with the pure step core (`Clementine.Loop.Step`), exactly
  # the states a step runner occupies between its claim and its commit.

  import ExUnit.Assertions

  alias Clementine.Lifecycle.{Facts, Protocol, Transition}
  alias Clementine.Loop
  alias Clementine.Loop.Ecto.Codec, as: InboxCodec
  alias Clementine.Loop.Protocol, as: LoopProtocol
  alias Clementine.Loop.{Codec, Envelope, Input, Runner, Step, StoredInput}
  alias Clementine.LoopCase.ConformanceLoop
  alias Clementine.Reconciler
  alias Clementine.Reconciler.{LoopEvidence, Policy}
  alias Clementine.{Error, InterruptReason, Lease, Result, ResumeToken, Suspension}

  @concurrent_appenders 8

  ## The two lead interleavings (the cold read's mandated order)

  def park_vs_append_interleaving(h) do
    ref = parked!(h)
    append!(h, ref, message(1))

    # The step in flight: claim, read the window, drain to a park intent.
    lease = claim!(h, ref)
    commit = commit!(h, ref, lease)
    assert commit.op == :park

    # The race: an input lands after the drain read its window. The loop
    # is running, so the append cannot wake — its wake CAS no-ops.
    append!(h, ref, message(2))
    assert fetch!(h, ref).status == :running

    # Atomicity sentence 1's re-check: the park re-verifies inside its own
    # commit and downgrades to continue — never parked over a pending
    # input. A substrate that cannot honor the re-check fails here and
    # leans on `:wake_pending` (see the wake_pending battery test).
    assert {:ok, %Facts{status: :queued, suspension: nil}} = h.host.apply_step(commit, h.ctx)

    # The downgraded step drains the racer; nothing was lost.
    assert {:parked, _} = step!(h, ref)
    assert log!(h, ref) == ["init", "message:1", "message:2"]
    assert pending!(h, ref) == []
  end

  def crash_replay_early_completion(h) do
    ref = parked!(h)
    tag_key = tag_key({:reply, 1})

    append!(h, ref, Input.message(%{"id" => "spawn", "actions" => [{:run, {:reply, 1}, %{}}]}))

    # The step claims and the VM dies before even the attempts bump (a
    # crash-after-bump replay degrades to batch-1 and is L1's territory):
    # nothing durable exists at all.
    _lost = claim!(h, ref)
    assert [%StoredInput{attempts: 0}] = pending!(h, ref)
    assert envelope!(h, ref).children == %{}

    # The reaper requeues the stale step (A3a: always — no cap, no opt-in).
    {:ok, _} = Protocol.requeue(h.lifecycle, fetch!(h, ref), :lease_expired, h.ctx)

    # The fast child's completion leaked past the never-committed spawn —
    # the substrate the one-commit rule exists to survive — landing in
    # FIFO behind the spawn input the replay will re-drain.
    append!(
      h,
      ref,
      Input.completed({:reply, 1}, Result.completed(output: "fast")),
      InboxCodec.completion_dedup_key(tag_key, "ghost")
    )

    # The replay drains spawn + completion in one fold. Dedup consults the
    # IN-FOLD envelope — the replayed spawn re-records the tag before its
    # completion is judged: delivered once, dropped never (a stored-
    # envelope-only dedup would dead-letter it as :unknown_tag and strand
    # the parent) — and the completion's existence retires the spawn's
    # cargo, so no duplicate child is ever dispatched.
    assert {:parked, _} = step!(h, ref)

    assert Enum.count(log!(h, ref), &(&1 == "completed:{:reply, 1}")) == 1
    assert envelope!(h, ref).children == %{}
    assert pending!(h, ref) == []

    # Delivered once means once: nothing more arrives on a later drain.
    append!(h, ref, message("after"))
    assert {:parked, _} = step!(h, ref)
    assert Enum.count(log!(h, ref), &(&1 == "completed:{:reply, 1}")) == 1
  end

  ## create

  def create_insert_or_get(h) do
    token = "idem-#{System.unique_integer([:positive])}"
    ref = create!(h, scope_token: token)

    facts = fetch!(h, ref)
    assert facts.kind == :loop
    assert facts.status == :queued
    assert facts.epoch == 0
    assert %DateTime{} = facts.queued_at

    loaded = load!(h, ref)
    assert {:ok, ConformanceLoop} = Loop.resolve(loaded.module)
    assert loaded.envelope == nil

    # The same scope is insert-or-get — webhook-safe under provider
    # retries by the scope key alone.
    assert create!(h, scope_token: token) == ref
    assert fetch!(h, ref).epoch == 0

    # init runs in the first step, not at create — and exactly once.
    assert {:parked, _} = step!(h, ref)
    assert create!(h, scope_token: token) == ref
    assert log!(h, ref) == ["init"]
  end

  ## append

  def append_round_trip(h) do
    ref = parked!(h)

    inputs = [
      Input.message(%{"k" => [1, "x", true], "tag" => :reply}),
      Input.completed({:reply, 5}, Result.failed(%Error{message: "boom"})),
      Input.elapsed({:retry, 9}),
      Input.input_failed(41, %Error{code: :input_dead_lettered, message: "m"})
    ]

    for {input, i} <- Enum.with_index(inputs) do
      assert {:ok, :appended} = h.host.append(ref, input, "rt:#{i}", h.ctx)
    end

    # FIFO commit-visibility order, decoded back exactly — tuple tags,
    # vocabulary atoms, and result/error structs all round-trip storage.
    assert Enum.map(pending!(h, ref), & &1.input) == inputs

    # The first append's wake rode its atomic unit: queued, suspension
    # cleared.
    facts = fetch!(h, ref)
    assert facts.status == :queued
    assert facts.suspension == nil

    # An append against an owned (running) loop leaves the status alone —
    # the in-flight step's park re-check owns visibility.
    _lease = claim!(h, ref)
    assert {:ok, :appended} = h.host.append(ref, message("mid"), nil, h.ctx)
    assert fetch!(h, ref).status == :running
  end

  def dedup_key_duplicates(h) do
    ref = parked!(h)

    assert {:ok, :appended} = h.host.append(ref, message(1), "hook:abc", h.ctx)
    assert {:ok, :duplicate} = h.host.append(ref, message(1), "hook:abc", h.ctx)
    assert [%StoredInput{}] = pending!(h, ref)

    # The key is unique PER LOOP: another loop accepts the same key.
    other = parked!(h)
    assert {:ok, :appended} = h.host.append(other, message(1), "hook:abc", h.ctx)

    # A nil key never dedups.
    assert {:ok, :appended} = h.host.append(ref, message(2), nil, h.ctx)
    assert {:ok, :appended} = h.host.append(ref, message(2), nil, h.ctx)
    assert length(pending!(h, ref)) == 3
  end

  def append_to_terminal_observability(h) do
    ref = parked!(h)
    append!(h, ref, Input.message(%{"halt" => "done"}))
    assert {:finished, %Facts{status: :completed}} = step!(h, ref)

    # The caller is TOLD the loop is over — retained evidence, never
    # silence, never an error to retry (a webhook can ack-and-alert).
    assert {:ok, :dead_lettered} = h.host.append(ref, message("late"), "late:1", h.ctx)
    assert fetch!(h, ref).status == :completed
    assert pending!(h, ref) == []

    # Dedup covers dead rows too: the retried dead append is a duplicate
    # of retained evidence.
    assert {:ok, :duplicate} = h.host.append(ref, message("late"), "late:1", h.ctx)

    # The send verb rides the same door: a sender's host — or the far
    # side of a cross-substrate hop — observes the terminal outcome too.
    assert {:ok, :dead_lettered} =
             LoopProtocol.send(h.host, ref, %{"id" => "late-send"},
               dedup_key: "late:2",
               ctx: h.ctx
             )

    assert {:ok, :duplicate} =
             LoopProtocol.send(h.host, ref, %{"id" => "late-send"},
               dedup_key: "late:2",
               ctx: h.ctx
             )
  end

  def concurrent_appends(h) do
    ref = parked!(h)

    tasks =
      for i <- 1..@concurrent_appenders do
        Task.async(fn ->
          receive do
            :go -> h.host.append(ref, message(i), "race:#{i}", h.ctx)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 30_000)

    assert Enum.all?(results, &match?({:ok, :appended}, &1)),
           "every racing append must land: #{inspect(results)}"

    # At least one appender found the row waiting and woke it; the rest
    # saw a queued row and rode the pending wake.
    assert fetch!(h, ref).status == :queued

    # One step drains all of them — none lost, none doubled. (FIFO order
    # against sequential appends is the round-trip test's job; racing
    # appenders have no defined arrival order to assert.)
    assert {:parked, _} = step!(h, ref)
    ids = for "message:" <> id <- log!(h, ref), do: String.to_integer(id)
    assert Enum.sort(ids) == Enum.to_list(1..@concurrent_appenders)
    assert pending!(h, ref) == []
  end

  def appends_racing_steps_never_strand(h) do
    ref = parked!(h)
    writers = 4
    per_writer = 8

    appenders =
      for t <- 1..writers do
        Task.async(fn ->
          for i <- 1..per_writer do
            assert {:ok, :appended} =
                     h.host.append(ref, message("#{t}:#{i}"), "load:#{t}:#{i}", h.ctx)
          end
        end)
      end

    # Step opportunistically while the appenders run: every claim's window
    # races the in-flight inserts. Lost claims and mid-race discards are
    # the guards working, not failures.
    for _ <- 1..12 do
      if fetch!(h, ref).status == :queued, do: step!(h, ref)
    end

    Task.await_many(appenders, 30_000)
    quiesce!(h, ref)

    # The invariant every interleaving must land on: parked means empty —
    # and every append delivered exactly once: the logged ids match the
    # sent set (a bare count would tolerate one lost and one doubled).
    assert fetch!(h, ref).status == :waiting
    assert pending!(h, ref) == []

    delivered = for "message:" <> id <- log!(h, ref), do: id
    sent = for t <- 1..writers, i <- 1..per_writer, do: "#{t}:#{i}"
    assert Enum.sort(delivered) == Enum.sort(sent)
  end

  ## wrong-state calls

  def kind_guards(h) do
    ref = parked!(h)
    {_tag_key, child_ref} = spawn_child!(h, ref, {:reply, 1})

    # A loop's child is a rollout-kind run in the same lifecycle — the
    # miswired ref every loop verb must refuse (amendment A2's mirror),
    # writing nothing.
    assert {:error, :rollout_run} = h.host.append(child_ref, message(1), nil, h.ctx)

    assert {:error, :rollout_run} =
             LoopProtocol.send(h.host, child_ref, %{"id" => "s"}, ctx: h.ctx)

    assert {:error, :rollout_run} = h.host.load(child_ref, h.ctx)
    assert {:error, :rollout_run} = h.host.cancel(child_ref, :nope, h.ctx)
    assert {:discard, :rollout_run} = step!(h, child_ref)
    assert %Facts{status: :queued, cancel: nil} = fetch!(h, child_ref)

    # A parked rollout is the case the guard exists for: no loop verb may
    # clear its suspension with a wake.
    child_lease = claim!(h, child_ref)

    {:ok, _token} =
      Protocol.suspend(child_lease, Clementine.LifecycleCase.Battery.suspension_request(),
        cursor: {1, 0}
      )

    assert {:error, :rollout_run} = h.host.append(child_ref, message(2), nil, h.ctx)

    waiting = fetch!(h, child_ref)
    assert waiting.status == :waiting
    assert %Suspension{} = waiting.suspension
  end

  def cancel_wrong_states(h) do
    ref = create!(h)

    # Idempotent on the flag, first cause wins — the same doctrine as the
    # cascade's pending halt.
    assert {:ok, :flagged} = LoopProtocol.cancel(h.host, ref, :first, ctx: h.ctx)
    assert {:ok, :flagged} = LoopProtocol.cancel(h.host, ref, :second, ctx: h.ctx)
    assert fetch!(h, ref).cancel.reason == :first

    assert {:finished, %Facts{status: :cancelled}} = step!(h, ref)
    assert {:error, :already_terminal} = LoopProtocol.cancel(h.host, ref, :again, ctx: h.ctx)
    assert fetch!(h, ref).status == :cancelled
  end

  def step_discards_wrong_states(h) do
    # A lost claim race is the single-flight guard working — every loser
    # learns who holds the run and writes nothing.
    ref = create!(h)
    _rival = claim!(h, ref)
    assert {:discard, {:not_claimable, :running}} = step!(h, ref)
    assert fetch!(h, ref).epoch == 1

    # A terminal loop cannot be stepped back to life.
    done = parked!(h)
    append!(h, done, Input.message(%{"halt" => "over"}))
    assert {:finished, _} = step!(h, done)
    assert {:discard, {:not_claimable, :completed}} = step!(h, done)
  end

  def not_found(h, missing_ref) do
    assert {:error, :not_found} = h.host.append(missing_ref, message(1), nil, h.ctx)

    assert {:error, :not_found} =
             LoopProtocol.send(h.host, missing_ref, %{"id" => "s"}, ctx: h.ctx)

    assert {:error, :not_found} = h.host.load(missing_ref, h.ctx)
    assert {:error, :not_found} = h.host.cancel(missing_ref, :ghost, h.ctx)
    assert {:discard, :not_found} = step!(h, missing_ref)
  end

  ## the step commit

  def crash_replay_no_duplicates(h) do
    target = parked!(h)
    ref = parked!(h)

    append!(
      h,
      ref,
      Input.message(%{
        "id" => "x",
        "actions" => [
          {:run, {:reply, 1}, %{"input" => "go"}},
          {:send, target, %{"note" => true}}
        ]
      })
    )

    # Crash before the commit: the drain happened, the commit never did.
    # The one durable pre-commit write is the drain-time attempts bump —
    # cargo never precedes the commit that owns it.
    lease = claim!(h, ref)
    _lost_commit = commit!(h, ref, lease)
    assert [%StoredInput{attempts: 1}] = pending!(h, ref)
    assert envelope!(h, ref).children == %{}
    assert pending!(h, target) == []

    {:ok, _} = Protocol.requeue(h.lifecycle, fetch!(h, ref), :lease_expired, h.ctx)

    # The replay drains the identical input through pure decisions to an
    # identical commit: one child, one send, one log entry.
    assert {:parked, _} = step!(h, ref)

    assert [{tag_key, child_ref}] = Map.to_list(envelope!(h, ref).children)
    assert tag_key == tag_key({:reply, 1})
    assert %Facts{kind: :rollout, status: :queued} = fetch!(h, child_ref)

    assert [%StoredInput{input: %Input{kind: :message, payload: %{"note" => true}}}] =
             pending!(h, target)

    assert log!(h, ref) == ["init", "message:x"]
    assert pending!(h, ref) == []
  end

  def zombie_step_fenced(h) do
    ref = parked!(h)
    append!(h, ref, Input.message(%{"id" => "z", "actions" => [{:run, {:reply, 1}, %{}}]}))

    zombie = claim!(h, ref)
    stale_commit = commit!(h, ref, zombie)
    stored_envelope = load!(h, ref).envelope

    # Status half of the guard: a reaper requeue superseded the execution
    # mid-step, so the run is no longer :running.
    {:ok, _} = Protocol.requeue(h.lifecycle, fetch!(h, ref), :lease_expired, h.ctx)
    assert {:error, :stale} = h.host.apply_step(stale_commit, h.ctx)

    # Epoch half: the successor claims — status is :running again, the
    # epoch no longer matches.
    successor = claim!(h, ref)
    assert successor.epoch == zombie.epoch + 1
    assert {:error, :stale} = h.host.apply_step(stale_commit, h.ctx)

    # Nothing the zombie carried landed: input unconsumed, envelope
    # untouched, no child minted.
    assert [%StoredInput{input: %Input{kind: :message}}] = pending!(h, ref)
    assert load!(h, ref).envelope == stored_envelope
    assert envelope!(h, ref).children == %{}

    # The successor's own commit lands cleanly — exactly one child exists.
    commit = commit!(h, ref, successor)
    assert {:ok, %Facts{status: :waiting}} = h.host.apply_step(commit, h.ctx)
    assert [{_tag_key, child_ref}] = Map.to_list(envelope!(h, ref).children)
    assert %Facts{kind: :rollout} = fetch!(h, child_ref)
    assert pending!(h, ref) == []
  end

  # The send halves of rows L1 and L11 (SKUNK-153's F5 interleaving,
  # draft-v1 numbering): the causal key is what survives the substrates
  # the fence cannot reach. In-substrate the CAS fences a zombie's whole
  # commit, sends included; a degraded substrate that leaks dispatch past
  # its fence, or a cross-substrate transport redelivering, re-presents
  # the SAME key — replay-stable by construction — and the target's inbox
  # answers :duplicate (Governing Invariant 12).
  def send_redispatch_dedup(h) do
    target = parked!(h)
    ref = parked!(h)
    payload = %{"id" => "note"}

    append!(h, ref, Input.message(%{"id" => "cause", "actions" => [{:send, target, payload}]}))

    # The doomed execution: claim, drain, compute the commit — and die
    # before applying it. Dispatch is cargo, so nothing reached the
    # target.
    lost = claim!(h, ref)
    lost_commit = commit!(h, ref, lost)
    assert [%{target: ^target, dedup_key: send_key}] = lost_commit.sends
    assert pending!(h, target) == []

    # A3a requeue; the replay recomputes the IDENTICAL send spec — same
    # causal input, same pure decision, same action index, same key. The
    # zombie's cargo and the replay's are equal by construction, which is
    # exactly why one :duplicate answer covers both re-dispatch stories.
    {:ok, _} = Protocol.requeue(h.lifecycle, fetch!(h, ref), :lease_expired, h.ctx)
    successor = claim!(h, ref)
    replay_commit = commit!(h, ref, successor)
    assert replay_commit.sends == lost_commit.sends

    # The replay's commit delivers — exactly once, waking the target.
    assert {:ok, %Facts{status: :waiting}} = h.host.apply_step(replay_commit, h.ctx)
    assert [%StoredInput{input: %Input{kind: :message, payload: ^payload}}] = pending!(h, target)

    # The zombie's own commit is fenced whole, its send included: the
    # target never hears from it (L11's in-substrate half).
    assert {:error, :stale} = h.host.apply_step(lost_commit, h.ctx)
    assert [%StoredInput{}] = pending!(h, target)

    # The re-dispatched send itself — the far door is the send verb, the
    # traveled key in hand: :duplicate, and the target's inbox is
    # unchanged. Delivered once, in effect.
    assert {:ok, :duplicate} =
             LoopProtocol.send(h.host, target, payload, dedup_key: send_key, ctx: h.ctx)

    assert [%StoredInput{}] = pending!(h, target)
    quiesce!(h, target)
    assert Enum.count(log!(h, target), &(&1 == "message:note")) == 1

    # A genuine re-send is a NEW causal input: fresh key, fresh delivery —
    # unique across genuine re-sends is the key's other half.
    append!(h, ref, Input.message(%{"id" => "again", "actions" => [{:send, target, payload}]}))
    resend = claim!(h, ref)
    resend_commit = commit!(h, ref, resend)
    assert [%{dedup_key: fresh_key}] = resend_commit.sends
    refute fresh_key == send_key

    assert {:ok, %Facts{status: :waiting}} = h.host.apply_step(resend_commit, h.ctx)
    quiesce!(h, target)
    assert Enum.count(log!(h, target), &(&1 == "message:note")) == 2
  end

  def cancel_flag_racing_park(h) do
    ref = parked!(h)
    append!(h, ref, message(1))

    lease = claim!(h, ref)
    commit = commit!(h, ref, lease)
    assert commit.op == :park

    # The flag lands after the claim read it as nil: the loop is running,
    # so cancel leaves only the flag — its wake has nothing to wake yet.
    assert {:ok, :flagged} = LoopProtocol.cancel(h.host, ref, :late_stop, ctx: h.ctx)
    assert fetch!(h, ref).status == :running

    # The park's :any re-check covers the flag: parking over it would
    # strand the cancellation with nobody left to honor it.
    assert {:ok, %Facts{status: :queued}} = h.host.apply_step(commit, h.ctx)

    # The next claim reads the flag and the cascade finishes cancelled.
    assert {:finished, %Facts{status: :cancelled, cancel: nil}} = step!(h, ref)
  end

  ## poison isolation

  def poison_isolation(h) do
    ref = parked!(h, policy: %{"dead_letter_after" => 2})

    append!(h, ref, Input.message(%{"id" => "p", "boom" => true}), "poison:head")
    append!(h, ref, message("innocent"))
    [%StoredInput{ref: poison_ref}, _innocent] = pending!(h, ref)

    # Step 1: full batch planned, head bumped and blamed, the raise
    # counted — and the loop requeued, never terminalized (two-tier
    # failure, the loop analog).
    assert {:error, %Error{}} = step!(h, ref)
    refute Facts.terminal?(fetch!(h, ref))
    assert [%StoredInput{attempts: 1}, %StoredInput{attempts: 0}] = pending!(h, ref)

    # Step 2: a bumped, unconsumed head is the evidence of a failed step —
    # the drain degrades to batch-1, so the innocent accumulates nothing.
    assert {:error, %Error{}} = step!(h, ref)
    assert [%StoredInput{attempts: 2}, %StoredInput{attempts: 0}] = pending!(h, ref)

    # Step 3: head at the threshold — dead-lettered, with the synthesized
    # {:input_failed} evidence appended in the same commit and the backlog
    # continuing behind it.
    assert {:continued, _} = step!(h, ref)

    assert [
             %StoredInput{input: %Input{kind: :message}, attempts: 0},
             %StoredInput{input: %Input{kind: :input_failed} = evidence, attempts: 0}
           ] = pending!(h, ref)

    assert evidence.input_ref == poison_ref
    assert %Error{code: :input_dead_lettered} = evidence.error

    # The poison row was retained as dead-letter evidence, not deleted:
    # its dedup key still holds against a re-send.
    assert {:ok, :duplicate} =
             h.host.append(
               ref,
               Input.message(%{"id" => "p", "boom" => true}),
               "poison:head",
               h.ctx
             )

    # Step 4: the decision layer is informed and the innocent drains — the
    # mailbox never jammed and the loop outlives the poison.
    assert {:parked, _} = step!(h, ref)
    log = log!(h, ref)
    assert "message:innocent" in log
    assert "input_failed:input_dead_lettered" in log
    refute Facts.terminal?(fetch!(h, ref))
    assert pending!(h, ref) == []
  end

  def vm_death_attempts_counted(h) do
    ref = parked!(h)
    append!(h, ref, message("survivor"))

    # Step phase 3, by hand: the bump is one small committed write outside
    # BOTH atomic units — then the VM dies before anything else runs. A
    # bump that rode the step's unit would roll back with it and retry
    # VM-killing poison forever.
    _lease = claim!(h, ref)
    [%StoredInput{ref: head_ref, attempts: 0}] = pending!(h, ref)
    assert :ok = h.host.bump_attempts([head_ref], h.ctx)
    assert [%StoredInput{attempts: 1}] = pending!(h, ref)

    # The reaper requeues the stale step; the bump survived the death.
    {:ok, _} = Protocol.requeue(h.lifecycle, fetch!(h, ref), :lease_expired, h.ctx)
    assert [%StoredInput{attempts: 1}] = pending!(h, ref)

    # The replay drains it normally — attempts short of the threshold are
    # evidence, not a sentence.
    assert {:parked, _} = step!(h, ref)
    assert "message:survivor" in log!(h, ref)
    assert pending!(h, ref) == []
  end

  ## cascade and halt

  def cascade_orders_queued_child(h) do
    ref = parked!(h)
    {_tag_key, child_ref} = spawn_child!(h, ref, {:reply, 1})
    assert %Facts{kind: :rollout, status: :queued} = fetch!(h, child_ref)

    # A straggler is already queued behind the stop; it must never reach
    # handle/2.
    append!(h, ref, message("straggler"))
    assert {:ok, :flagged} = LoopProtocol.cancel(h.host, ref, :operator_stop, ctx: h.ctx)
    assert fetch!(h, ref).cancel.reason == :operator_stop

    # Cascade: the machinery — never handle/2 — cancels the child as
    # commit cargo; the child's terminal projection appends its completion
    # inside the same unit, and the cascade park downgrades to continue.
    # Child terminal first, loop still live.
    assert {:continued, _} = step!(h, ref)
    assert %Facts{status: :cancelled} = fetch!(h, child_ref)
    refute Facts.terminal?(fetch!(h, ref))

    # The last completion folds; the loop finishes last, the flag clears
    # at the finish, and the terminal sweep leaves nothing consumable.
    assert {:finished, %Facts{status: :cancelled, cancel: nil}} = step!(h, ref)
    assert pending!(h, ref) == []
    refute "message:straggler" in log!(h, ref)
  end

  def cascade_running_child_cooperative(h) do
    ref = parked!(h)
    {_tag_key, child_ref} = spawn_child!(h, ref, {:reply, 9})

    # The child is mid-execution when the stop arrives.
    child_lease = claim!(h, child_ref)
    assert {:ok, :flagged} = LoopProtocol.cancel(h.host, ref, :stop, ctx: h.ctx)

    # The cascade flags the running child cooperatively and parks awaiting
    # its completion. The set flag must NOT downgrade a cascade park — the
    # cascade is the flag's handler, and a downgrade would spin the loop
    # hot until its children finished.
    assert {:parked, %Facts{status: :waiting, cancel: %{reason: :stop}}} = step!(h, ref)
    child = fetch!(h, child_ref)
    assert child.status == :running
    assert child.cancel != nil

    # The child honors its flag; its terminal projection delivers the
    # completion durably — exactly-once at source. The parent wake rides
    # a post-commit hook and is best-effort by contract, so the battery
    # backstops a wake that has not landed; the cascade then completes:
    # children's terminals first, the loop's last.
    {:ok, _} = Protocol.finish(child_lease, Result.cancelled({:loop_cascade, ref}))
    assert Enum.any?(pending!(h, ref), &(&1.input.kind == :completed))
    wake_if_parked!(h, ref)
    assert {:finished, %Facts{status: :cancelled, cancel: nil}} = step!(h, ref)
    assert pending!(h, ref) == []
  end

  def halt_with_children_in_flight(h) do
    ref = parked!(h)
    {_tag_key, child_ref} = spawn_child!(h, ref, {:reply, 3})

    # The halt arrives with the child live and an input queued behind it.
    append!(h, ref, Input.message(%{"halt" => "all done"}))
    append!(h, ref, message("too-late"), "late:sweep")

    # The halt enters the cascade: the child cancels as cargo, the pending
    # result parks in the envelope, and the undrained input stays
    # unconsumed for the sweep.
    assert {:continued, _} = step!(h, ref)
    assert %Facts{status: :cancelled} = fetch!(h, child_ref)

    assert %Envelope{pending_halt: %{result: %Result.Completed{output: "all done"}}} =
             envelope!(h, ref)

    # The cascade finishes with the HALT's result — first cause wins — and
    # the terminal sweep dead-letters the leftover rather than silently
    # retaining it.
    assert {:finished, %Facts{status: :completed} = facts} = step!(h, ref)
    assert %DateTime{} = facts.finished_at
    refute "message:too-late" in log!(h, ref)
    assert pending!(h, ref) == []

    # Dead-lettered, not deleted: the swept row still holds its dedup key.
    assert {:ok, :duplicate} = h.host.append(ref, message("too-late"), "late:sweep", h.ctx)
  end

  def cascade_completion_behind_long_backlog(h) do
    ref = parked!(h, policy: %{"batch_cap" => 2})
    {_tag_key, child_ref} = spawn_child!(h, ref, {:reply, 4})

    # A non-completion backlog longer than the batch window queues ahead
    # of where the child's completion will land.
    for i <- 1..4, do: append!(h, ref, message("backlog-#{i}"))
    assert {:ok, :flagged} = LoopProtocol.cancel(h.host, ref, :stop, ctx: h.ctx)

    # Cascade entry: the queued child terminalizes as cargo, its
    # completion appending BEHIND the backlog; the :completions re-check
    # sees it in-unit.
    assert {:continued, _} = step!(h, ref)
    assert %Facts{status: :cancelled} = fetch!(h, child_ref)

    # The cascade's window reads completions only: a FIFO :any window of
    # batch_cap + 1 would never surface a completion behind four skipped
    # messages — the loop would park-and-rewake forever instead of
    # finishing. A host that ignores the :completions scope fails here
    # with a {:continued, _} livelock instead of the finish.
    assert {:finished, %Facts{status: :cancelled}} = step!(h, ref)
    assert pending!(h, ref) == []
  end

  def cancel_never_stepped_short_circuits(h) do
    ref = create!(h)
    for i <- 1..3, do: append!(h, ref, message(i), "short:#{i}")

    assert {:ok, :flagged} = LoopProtocol.cancel(h.host, ref, :never_mind, ctx: h.ctx)

    # The first step enters the cascade with no children and finishes
    # immediately: handle/2 never ran, and the terminal sweep marked every
    # queued input in the finish's own unit — nothing handled after the
    # operator said stop, nothing silently retained.
    assert {:finished, %Facts{status: :cancelled}} = step!(h, ref)
    assert log!(h, ref) == []
    assert pending!(h, ref) == []

    # Swept means marked, never deleted: the rows keep their dedup keys,
    # so a sender's retry is a duplicate of retained evidence — the
    # observable half of "no silent loss" (a host that DELETEs at the
    # sweep would answer :dead_lettered here).
    assert {:ok, :duplicate} = h.host.append(ref, message(1), "short:1", h.ctx)
  end

  ## reaper verdicts

  def reenqueue_verdict(h) do
    ref = parked!(h)
    append!(h, ref, message("stuck"))

    # The wake committed the queued row, but its step job was lost — the
    # crash-between-wake-and-enqueue window on substrates without the
    # atomic unit. The facts alone carry the verdict's evidence.
    facts = fetch!(h, ref)
    assert facts.status == :queued
    assert %DateTime{} = facts.queued_at

    policy = Policy.new()
    fresh = DateTime.add(facts.queued_at, 1_000, :millisecond)
    overdue = DateTime.add(facts.queued_at, policy.claim_timeout + 1_000, :millisecond)

    assert :healthy = Reconciler.judge_loop(facts, nil, fresh, policy)
    assert {:reenqueue, :claim_timeout} = Reconciler.judge_loop(facts, nil, overdue, policy)

    # Never terminal on claim evidence: the host re-inserts the job —
    # enqueue_step must be callable standalone, outside any unit.
    assert :ok = h.host.enqueue_step(ref, h.ctx)

    # The re-enqueued step drains normally; the healed loop judges
    # healthy.
    assert {:parked, _} = step!(h, ref)
    assert "message:stuck" in log!(h, ref)
    assert :healthy = Reconciler.judge_loop(fetch!(h, ref), %LoopEvidence{}, overdue, policy)
  end

  def reconcile_children_heals_lost_glue(h) do
    ref = parked!(h, completion_glue: :dropped)
    {tag_key, child_ref} = spawn_child!(h, ref, {:reply, 1})

    # Pod death: the reaper interrupts the child. Its terminal projection
    # runs WITHOUT the completion glue — the lost-delivery substrate the
    # verdict exists for (see the create_loop contract).
    reason = InterruptReason.new(:lease_expired, "pod died")
    {:ok, _} = Protocol.interrupt(h.lifecycle, fetch!(h, child_ref), reason, h.ctx)
    assert Facts.terminal?(fetch!(h, child_ref))

    # A bare wake cannot heal the strand: any woken step drains nothing
    # and re-parks. The envelope still lists the child live; no completion
    # input exists.
    quiesce!(h, ref)
    facts = fetch!(h, ref)
    assert facts.status == :waiting
    assert pending!(h, ref) == []
    assert Map.has_key?(envelope!(h, ref).children, tag_key)

    # The loop sweep's evidence names the strand; the verdict fires.
    evidence = %LoopEvidence{
      children: [
        %{tag_key: tag_key, child_ref: child_ref, terminal?: true, completion_present?: false}
      ]
    }

    assert {:reconcile_children, [%{tag_key: ^tag_key, child_ref: ^child_ref}]} =
             Reconciler.judge_loop(facts, evidence, facts.queued_at, Policy.new())

    # The documented healing: synthesize {:completed, tag, result} from
    # the child's terminal facts and append it under the canonical dedup
    # key — the append's own unit wakes the loop.
    child = fetch!(h, child_ref)
    synthesized = Input.completed(tag_term(tag_key), Result.interrupted(child.interrupt))

    assert {:ok, :appended} =
             h.host.append(
               ref,
               synthesized,
               InboxCodec.completion_dedup_key(tag_key, child_ref),
               h.ctx
             )

    # The fold retires the child and the parent decides on an ordinary
    # completion input: the strand self-healed.
    quiesce!(h, ref)
    assert Enum.count(log!(h, ref), &(&1 == "completed:{:reply, 1}")) == 1
    assert envelope!(h, ref).children == %{}

    healed = fetch!(h, ref)

    assert :healthy =
             Reconciler.judge_loop(healed, %LoopEvidence{}, healed.queued_at, Policy.new())
  end

  def reconcile_collapses_on_real_delivery(h) do
    ref = parked!(h)
    {tag_key, child_ref} = spawn_child!(h, ref, {:reply, 2})

    # The child's terminal projection delivered the completion for real
    # (exactly-once at source).
    reason = InterruptReason.new(:lease_expired, "pod died")
    {:ok, _} = Protocol.interrupt(h.lifecycle, fetch!(h, child_ref), reason, h.ctx)

    # The sweep's evidence gathering raced the delivery and still claims a
    # strand (gathering need not be one snapshot). The healing append
    # no-ops on the canonical key: observable noise, never double
    # delivery.
    child = fetch!(h, child_ref)
    synthesized = Input.completed(tag_term(tag_key), Result.interrupted(child.interrupt))

    assert {:ok, :duplicate} =
             h.host.append(
               ref,
               synthesized,
               InboxCodec.completion_dedup_key(tag_key, child_ref),
               h.ctx
             )

    # The real delivery was durable in the child's terminal transaction;
    # its wake is best-effort, so backstop one that has not landed and let
    # the fold consume the single row.
    wake_if_parked!(h, ref)
    quiesce!(h, ref)
    assert Enum.count(log!(h, ref), &(&1 == "completed:{:reply, 2}")) == 1
    assert envelope!(h, ref).children == %{}
  end

  def step_job_enqueues(h, step_jobs) do
    # Creation enqueues the first step job inside its unit; insert-or-get
    # does not enqueue a second — a host that lands the queued row but
    # forgets the job would strand every new loop until the reaper's
    # :reenqueue verdict noticed.
    token = "jobs-#{System.unique_integer([:positive])}"
    ref = create!(h, scope_token: token)
    assert step_jobs.(ref) == 1
    assert create!(h, scope_token: token) == ref
    assert step_jobs.(ref) == 1

    assert {:parked, _} = step!(h, ref)
    base = step_jobs.(ref)

    # Atomicity sentence 2: the append carries the wake AND the step-job
    # enqueue in one unit...
    append!(h, ref, message(1))
    assert step_jobs.(ref) == base + 1

    # ...and exactly one: an append against the already-queued loop rides
    # the pending wake instead of enqueueing again.
    append!(h, ref, message(2))
    assert step_jobs.(ref) == base + 1

    # A park the in-unit re-check downgrades enqueues the continue's job —
    # the downgrade would otherwise leave a queued row nobody claims.
    lease = claim!(h, ref)
    commit = commit!(h, ref, lease)
    assert commit.op == :park
    append!(h, ref, message(3))
    before_downgrade = step_jobs.(ref)
    assert {:ok, %Facts{status: :queued}} = h.host.apply_step(commit, h.ctx)
    assert step_jobs.(ref) == before_downgrade + 1

    assert {:parked, _} = step!(h, ref)

    # Cancelling a parked loop wakes it with its job in the same unit.
    before_cancel = step_jobs.(ref)
    assert {:ok, :flagged} = LoopProtocol.cancel(h.host, ref, :stop, ctx: h.ctx)
    assert step_jobs.(ref) == before_cancel + 1
  end

  def wake_pending_backstop(h) do
    ref = parked!(h)
    append!(h, ref, message("stranded"))

    # A sentence-1-imperfect substrate parks over the pending input: the
    # battery manufactures that state with a raw guarded park that skips
    # apply_step's re-check.
    lease = claim!(h, ref)

    park = %Transition{
      op: :suspend,
      run_ref: ref,
      expect: %{status: :running, epoch: lease.epoch},
      set: %{
        status: :waiting,
        suspension: %Suspension{
          reason: {:external, :loop},
          checkpoint: nil,
          token: %ResumeToken{run_ref: ref, epoch: lease.epoch, reason_type: :external}
        },
        executor_id: nil,
        deadline: nil,
        heartbeat_at: nil,
        queued_at: :now
      }
    }

    assert {:ok, %Facts{status: :waiting}} = h.lifecycle.apply(park, h.ctx)
    assert [%StoredInput{}] = pending!(h, ref)

    # The stranded park is invisible to liveness checks; the sweep's
    # evidence — the oldest unconsumed input's age — is what fires.
    facts = fetch!(h, ref)
    policy = Policy.new()
    stamp = facts.queued_at
    fresh = DateTime.add(stamp, 1_000, :millisecond)
    overdue = DateTime.add(stamp, policy.wake_pending_after + 1_000, :millisecond)
    evidence = %LoopEvidence{oldest_pending_at: stamp}

    assert :healthy = Reconciler.judge_loop(facts, evidence, fresh, policy)

    assert {:wake_pending, :stale_inputs} =
             Reconciler.judge_loop(facts, evidence, overdue, policy)

    # The healing is append's wake half — the CAS waiting -> queued plus
    # the step enqueue. Correctness degraded to bounded latency, never to
    # loss.
    wake = %Transition{
      op: :requeue,
      run_ref: ref,
      expect: %{status: :waiting, epoch: lease.epoch},
      set: %{status: :queued, suspension: nil, queued_at: :now}
    }

    assert {:ok, %Facts{status: :queued}} = h.lifecycle.apply(wake, h.ctx)
    assert :ok = h.host.enqueue_step(ref, h.ctx)

    assert {:parked, _} = step!(h, ref)
    assert "message:stranded" in log!(h, ref)
    assert pending!(h, ref) == []
  end

  ## timers (the scheduler seam)

  def timer_fire_delivers_and_rearms(h) do
    ref = parked!(h)
    poll_key = tag_key(:poll)

    # The schedule and the envelope entry recording it are one commit.
    append!(h, ref, Input.message(%{"id" => "arm", "actions" => [{:timer, :poll, 60_000}]}))
    assert {:parked, _} = step!(h, ref)
    assert Map.has_key?(envelope!(h, ref).timers, poll_key)

    # The fire is the scheduler's append under the machinery key (LOOP_RFC
    # §Timers); its wake rides the append's atomic unit.
    fire = InboxCodec.elapsed_dedup_key(poll_key, "s1")
    assert {:ok, :appended} = h.host.append(ref, Input.elapsed(:poll), fire, h.ctx)
    assert fetch!(h, ref).status == :queued

    # A worker retry of the same schedule is a duplicate — exactly-once
    # per schedule, whatever the job queue's delivery guarantees.
    assert {:ok, :duplicate} = h.host.append(ref, Input.elapsed(:poll), fire, h.ctx)

    # Delivered once — and the watcher's handle re-arms the same tag in
    # the very fold that consumed the fire: live-key lifetime.
    assert {:parked, _} = step!(h, ref)
    assert Enum.count(log!(h, ref), &(&1 == "elapsed::poll")) == 1
    assert Map.has_key?(envelope!(h, ref).timers, poll_key)
    assert pending!(h, ref) == []

    # The re-arm is a new schedule with its own exactly-once grain: a
    # fresh id lands where the spent one duplicates.
    refire = InboxCodec.elapsed_dedup_key(poll_key, "s2")
    assert {:ok, :appended} = h.host.append(ref, Input.elapsed(:poll), refire, h.ctx)
    assert {:parked, _} = step!(h, ref)
    assert Enum.count(log!(h, ref), &(&1 == "elapsed::poll")) == 2
  end

  def timer_fire_racing_cancel_dead_letters(h) do
    ref = parked!(h)
    tag = {:retry, 7}
    key = tag_key(tag)

    append!(h, ref, Input.message(%{"id" => "arm", "actions" => [{:timer, tag, 60_000}]}))
    assert {:parked, _} = step!(h, ref)
    assert Map.has_key?(envelope!(h, ref).timers, key)

    append!(h, ref, Input.message(%{"id" => "cancel", "actions" => [{:cancel_timer, tag}]}))
    assert {:parked, _} = step!(h, ref)
    assert envelope!(h, ref).timers == %{}
    log_before = log!(h, ref)

    # The racing fire: the cancel was best-effort, so a schedule that
    # already left the queue still appends — the appender cannot know,
    # and lands `:appended`.
    fire = InboxCodec.elapsed_dedup_key(key, "s1")
    assert {:ok, :appended} = h.host.append(ref, Input.elapsed(tag), fire, h.ctx)

    # The machinery consumes it as a dead letter: never `handle/2`'s,
    # never left pending (matrix row L6, Governing Invariant 11).
    assert {:parked, _} = step!(h, ref)
    assert log!(h, ref) == log_before
    assert pending!(h, ref) == []

    # Never silently dropped: the mark retained the row, whose key still
    # answers the worker's retry.
    assert {:ok, :duplicate} = h.host.append(ref, Input.elapsed(tag), fire, h.ctx)

    # A cancelled tag is immediately re-armable — live-key lifetime.
    append!(h, ref, Input.message(%{"id" => "rearm", "actions" => [{:timer, tag, 60_000}]}))
    assert {:parked, _} = step!(h, ref)
    assert Map.has_key?(envelope!(h, ref).timers, key)
  end

  def timer_fire_against_terminal(h) do
    ref = parked!(h)
    poll_key = tag_key(:poll)

    # Armed and never cancelled: the loop halts with the schedule still
    # out there — the RFC's "timers of terminal loops" noise source.
    append!(h, ref, Input.message(%{"id" => "arm", "actions" => [{:timer, :poll, 60_000}]}))
    assert {:parked, _} = step!(h, ref)
    append!(h, ref, Input.message(%{"halt" => "done"}))
    assert {:finished, %Facts{status: :completed}} = step!(h, ref)

    # The late fire is TOLD — retained evidence, distinguishable noise,
    # never a wake and never a crash.
    fire = InboxCodec.elapsed_dedup_key(poll_key, "s1")
    assert {:ok, :dead_lettered} = h.host.append(ref, Input.elapsed(:poll), fire, h.ctx)
    assert fetch!(h, ref).status == :completed
    assert pending!(h, ref) == []

    # Retained means retained: the worker's retry is a duplicate of
    # evidence, not a second row.
    assert {:ok, :duplicate} = h.host.append(ref, Input.elapsed(:poll), fire, h.ctx)
  end

  def timer_schedule_is_cargo(h, timer_schedules) do
    ref = parked!(h)
    poll_key = tag_key(:poll)
    base = timer_schedules.(ref)

    append!(h, ref, Input.message(%{"id" => "arm", "actions" => [{:timer, :poll, 60_000}]}))

    # The crash window: the step claimed, drained the arm, and died before
    # its commit. Nothing durable may exist — a schedule outliving its
    # never-committed envelope entry is draft v1's permanently wedged
    # watcher, the interleaving the cargo model deletes.
    lost = claim!(h, ref)
    lost_commit = commit!(h, ref, lost)
    assert Enum.any?(lost_commit.timers, &(&1.tag_key == poll_key))
    assert timer_schedules.(ref) == base
    refute Map.has_key?(envelope!(h, ref).timers, poll_key)

    # The reaper requeues (A3a); the zombie's late commit is fenced whole,
    # schedule included.
    {:ok, _} = Protocol.requeue(h.lifecycle, fetch!(h, ref), :lease_expired, h.ctx)
    assert {:error, :stale} = h.host.apply_step(lost_commit, h.ctx)
    assert timer_schedules.(ref) == base
    refute Map.has_key?(envelope!(h, ref).timers, poll_key)

    # The replay commits schedule and envelope entry as one unit — exactly
    # one of each (L1's replay discipline, the timer flavor).
    assert {:parked, _} = step!(h, ref)
    assert timer_schedules.(ref) == base + 1
    assert Map.has_key?(envelope!(h, ref).timers, poll_key)
  end

  ## Harness helpers

  def create!(h, attrs \\ []) do
    attrs =
      attrs
      |> Keyword.put_new(:module, ConformanceLoop)
      |> Keyword.put_new(:args, %{})
      |> Keyword.put_new(:policy, %{})

    h.create_loop.(attrs)
  end

  def parked!(h, attrs \\ []) do
    ref = create!(h, attrs)
    assert {:parked, %Facts{status: :waiting}} = step!(h, ref)
    ref
  end

  def fetch!(h, ref) do
    assert {:ok, %Facts{} = facts} = h.lifecycle.fetch(ref, h.ctx)
    facts
  end

  def load!(h, ref) do
    assert {:ok, loaded} = h.host.load(ref, h.ctx)
    loaded
  end

  def pending!(h, ref), do: h.host.pending(ref, 50, :any, h.ctx)

  def append!(h, ref, %Input{} = input, dedup_key \\ nil) do
    assert {:ok, :appended} = h.host.append(ref, input, dedup_key, h.ctx)
  end

  def message(id), do: Input.message(%{"id" => id})

  def step!(h, ref) do
    Runner.step(ref,
      host: h.host,
      lifecycle: h.lifecycle,
      executor_id: "conformance:step:#{System.unique_integer([:positive])}",
      ctx: h.ctx
    )
  end

  def claim!(h, ref) do
    assert {:ok, %Lease{} = lease} =
             Protocol.claim(h.lifecycle, ref, executor: "conformance:manual", ctx: h.ctx)

    lease
  end

  # The child-terminal parent wake is post-commit and best-effort by
  # contract — only the completion row is durable; the reaper's
  # :wake_pending verdict is the wake's backstop. Where a host's wake has
  # not landed, the battery performs the backstop's action itself (the
  # CAS waiting -> queued plus the step enqueue).
  def wake_if_parked!(h, ref) do
    case fetch!(h, ref) do
      %Facts{status: :waiting, epoch: epoch} ->
        wake = %Transition{
          op: :requeue,
          run_ref: ref,
          expect: %{status: :waiting, epoch: epoch},
          set: %{status: :queued, suspension: nil, queued_at: :now}
        }

        assert {:ok, %Facts{status: :queued}} = h.lifecycle.apply(wake, h.ctx)
        :ok = h.host.enqueue_step(ref, h.ctx)

      %Facts{} ->
        :ok
    end
  end

  # Drives queued steps until the loop leaves :queued — the ground state
  # (or a terminal) every clean path lands on.
  def quiesce!(h, ref, budget \\ 25) do
    case fetch!(h, ref).status do
      :queued when budget > 0 ->
        step!(h, ref)
        quiesce!(h, ref, budget - 1)

      :queued ->
        flunk("loop #{inspect(ref)} failed to quiesce")

      _settled ->
        :ok
    end
  end

  @doc false
  # One manufactured step, mirroring the runner's phases 2–5 (load under
  # the fence, window, plan, bump, drain) — returning the StepCommit for
  # the caller to apply, delay, or abandon (the crash window). Kept
  # faithful input-for-input: the one-past-the-cap window is the runner's
  # backlog probe, and the plan reads the same policy knobs and cancel
  # flag the runner would.
  def commit!(h, ref, %Lease{} = lease) do
    loaded = load!(h, ref)
    {:ok, module} = Loop.resolve(loaded.module)
    envelope = decode_envelope!(loaded.envelope)
    cancel = cancel_reason(loaded.facts)
    batch_cap = Map.get(loaded.policy, "batch_cap", Step.default_batch_cap())
    threshold = Map.get(loaded.policy, "dead_letter_after", Step.default_dead_letter_after())

    scope =
      if cancel != nil or (envelope != nil and Envelope.cascading?(envelope)),
        do: :completions,
        else: :any

    window = h.host.pending(ref, batch_cap + 1, scope, h.ctx)

    plan =
      Step.plan(envelope, window,
        cancel: cancel,
        batch_cap: batch_cap,
        dead_letter_after: threshold
      )

    :ok = h.host.bump_attempts(plan.bump, h.ctx)

    {:ok, commit} =
      Step.drain(module, envelope, plan,
        loop_ref: ref,
        epoch: lease.epoch,
        loop_args: loaded.args
      )

    commit
  end

  defp cancel_reason(%Facts{cancel: nil}), do: nil
  defp cancel_reason(%Facts{cancel: %{reason: reason}}), do: reason || :cancelled

  def spawn_child!(h, ref, tag) do
    append!(
      h,
      ref,
      Input.message(%{"id" => "spawn", "actions" => [{:run, tag, %{"input" => "go"}}]})
    )

    assert {:parked, _} = step!(h, ref)
    assert [{tag_key, child_ref}] = Map.to_list(envelope!(h, ref).children)
    assert child_ref != nil, "apply_step must fill the child's real run ref into the envelope"
    {tag_key, child_ref}
  end

  def envelope!(h, ref) do
    decode_envelope!(load!(h, ref).envelope)
  end

  # The committed state log — delivery asserted through storage. Empty
  # while no drain has committed app state (pre-init, or a cascade that
  # never ran handle/2).
  def log!(h, ref) do
    case envelope!(h, ref) do
      nil ->
        []

      %Envelope{state: nil} ->
        []

      %Envelope{state: state} ->
        state |> Codec.decode(vocabulary: vocabulary()) |> Map.fetch!("log")
    end
  end

  def tag_key(tag), do: Codec.key(tag, vocabulary: vocabulary())

  def tag_term(tag_key), do: InboxCodec.decode_tag(tag_key, vocabulary: vocabulary())

  defp decode_envelope!(nil), do: nil

  defp decode_envelope!(data) do
    assert {:ok, %Envelope{} = envelope} = Envelope.decode(data)
    envelope
  end

  defp vocabulary, do: ConformanceLoop.__loop__(:vocabulary)
end
