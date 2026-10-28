if Code.ensure_loaded?(Oban.Testing) and Code.ensure_loaded?(Mox) do
  defmodule Clementine.LoopCase.Battery do
    @moduledoc false
    # The loop battery's bodies. `Clementine.LoopCase.__using__/1`
    # generates one thin test per function here; keeping the bodies as
    # ordinary code keeps assertion failures pointing at real lines
    # instead of quoted AST.
    #
    # Observation is storage-only: the loop's facts, `Clementine.Runs.Loops`'
    # seam (load, pending), the return values of `Clementine.Runs`, the
    # step runner's outcomes, and the committed envelope (children refs,
    # the conformance loop's state log). Mid-step interleavings (crash
    # windows, zombie commits, the park race) are manufactured with the
    # pure step core (`Clementine.Loop.Step`), exactly the states a step
    # occupies between its claim and its commit.

    import ExUnit.Assertions
    import Ecto.Query, only: [from: 2]

    alias Clementine.Lifecycle.{Facts, Protocol, Transition}
    alias Clementine.LLM.ProviderStream
    alias Clementine.Loop.{Codec, Envelope, InboxCodec, Input, Step, StoredInput}
    alias Clementine.LoopCase.{ConformanceLoop, Task, Turn}
    alias Clementine.Reconciler.Policy
    alias Clementine.Runs

    alias Clementine.Runs.{
      AgentRun,
      Config,
      Lifecycle,
      Loops,
      Reaper,
      StepWorker,
      TimerWorker,
      Worker
    }

    alias Clementine.{Error, InterruptReason, Result, ResumeToken, RunView, Suspension}

    @concurrent_appenders 8

    ## The two lead interleavings (the cold read's mandated order)

    def park_vs_append_interleaving do
      loop = parked!()
      send!(loop, message(1))

      # The step in flight: claim, read the window, drain to a park intent.
      lease = claim!(loop)
      commit = commit!(loop, lease)
      assert commit.op == :park

      # The race: an input lands after the drain read its window. The loop
      # is running, so the send cannot wake it; its wake CAS no-ops.
      send!(loop, message(2))
      assert fetch!(loop).status == :running

      # Atomicity sentence 1's re-check: the park re-verifies inside its
      # own commit and downgrades to continue, never parked over a pending
      # input.
      assert {:ok, %Facts{status: :queued, suspension: nil}} = Loops.apply_step(commit, nil)

      # The downgraded step drains the racer; nothing was lost.
      assert {:parked, _} = step!(loop)
      assert log!(loop) == ["init", "message:1", "message:2"]
      assert pending!(loop) == []
    end

    def crash_replay_early_completion do
      loop = parked!()
      tag_key = tag_key({:reply, 1})

      send!(loop, spawn_payload({:reply, 1}))

      # The step claims and the VM dies before even the attempts bump:
      # nothing durable exists at all.
      _lost = claim!(loop)
      assert [%StoredInput{attempts: 0}] = pending!(loop)
      assert envelope!(loop).children == %{}

      # The reaper requeues the stale step (A3a: always, no cap).
      {:ok, _} = Protocol.requeue(Lifecycle, fetch!(loop), :lease_expired)

      # The fast child's completion leaked past the never-committed spawn,
      # landing in FIFO behind the spawn input the replay will re-drain.
      append!(
        loop,
        Input.completed({:reply, 1}, Result.completed(output: "fast")),
        InboxCodec.completion_dedup_key(tag_key, "ghost")
      )

      # The replay drains spawn + completion in one fold. Dedup consults
      # the in-fold envelope: the replayed spawn re-records the tag before
      # its completion is judged, so it is delivered once and never
      # dropped, and the completion's existence retires the spawn's
      # cargo, so no duplicate child is ever inserted.
      assert {:parked, _} = step!(loop)

      assert Enum.count(log!(loop), &(&1 == "completed:{:reply, 1}:completed")) == 1
      assert envelope!(loop).children == %{}
      assert pending!(loop) == []
      assert Runs.list(parent: loop.id) == []

      # Delivered once means once: nothing more arrives on a later drain.
      send!(loop, message("after"))
      assert {:parked, _} = step!(loop)
      assert Enum.count(log!(loop), &(&1 == "completed:{:reply, 1}:completed")) == 1
    end

    ## start_loop

    def start_loop_is_a_run do
      {:ok, loop} =
        Runs.start_loop(ConformanceLoop, %{"greeting" => "hi"},
          subject: {"thread", "t-1"},
          actor: {"user", "u-1"},
          policy: %{"batch_cap" => 5},
          metadata: %{"source" => "battery"}
        )

      assert %AgentRun{
               kind: "loop",
               agent_key: "conformance_loop",
               input: %{"greeting" => "hi"},
               loop_policy: %{"batch_cap" => 5},
               state_version: 1,
               envelope: nil,
               turn: false,
               subject_type: "thread",
               subject_id: "t-1",
               actor_type: "user",
               actor_id: "u-1",
               metadata: %{"source" => "battery"},
               status: "queued",
               lease_epoch: 0
             } = loop

      assert %DateTime{} = loop.queued_at
      assert step_jobs(loop) == 1
      assert Runs.active({"thread", "t-1"}, kind: :loop).id == loop.id
      assert Runs.active({"thread", "t-1"}) == nil

      # init runs in the first step, not at start, and exactly once.
      assert {:parked, %Facts{status: :waiting, kind: :loop}} = step!(loop)
      assert log!(loop) == ["init"]

      assert {:ok, :already_exists, _} =
               Runs.start_loop(ConformanceLoop, %{}, subject: {"thread", "t-1"})

      assert log!(loop) == ["init"]

      # The host heard the loop's life like any run's.
      assert_received {:run_transition, %AgentRun{id: id, kind: "loop"}, :claimed}
                      when id == loop.id

      assert_received {:run_transition, %AgentRun{id: id, status: "waiting"}, :suspended}
                      when id == loop.id
    end

    def start_loop_insert_or_get do
      subject = {"thread", unique("thread")}

      {:ok, loop} = Runs.start_loop(ConformanceLoop, %{"n" => 1}, subject: subject)

      assert {:ok, :already_exists, %AgentRun{id: id}} =
               Runs.start_loop(ConformanceLoop, %{"n" => 2}, subject: subject)

      assert id == loop.id
      assert Runs.get(loop.id).input == %{"n" => 1}
      assert step_jobs(loop) == 1

      # Another subject is another loop; another controller key would be
      # another lane too.
      {:ok, other} = Runs.start_loop(ConformanceLoop, %{}, subject: {"thread", unique("thread")})
      refute other.id == loop.id

      # Once the loop ends, the lane frees: a new loop stands.
      send!(loop, Input.message(%{"halt" => "done"}) |> Map.get(:payload))
      assert {:finished, %Facts{status: :completed}} = step!(loop)
      {:ok, successor} = Runs.start_loop(ConformanceLoop, %{}, subject: subject)
      refute successor.id == loop.id
    end

    def start_loop_refusals do
      assert {:error, :unknown_controller} = Runs.start_loop(Task, %{}, subject: {"thread", "x"})
      assert {:error, :unknown_controller} = Runs.start_loop(Enum, %{}, subject: {"thread", "x"})
      assert {:error, :subject_required} = Runs.start_loop(ConformanceLoop, %{})

      assert {:error, :subject_required} =
               Runs.start_loop(ConformanceLoop, %{}, subject: {"thread", nil})

      assert_raise ArgumentError, ~r/loop args/, fn ->
        Runs.start_loop(ConformanceLoop, %{"bad" => :atom}, subject: {"thread", "x"})
      end

      assert_raise ArgumentError, ~r/loop policy/, fn ->
        Runs.start_loop(ConformanceLoop, %{}, subject: {"thread", "x"}, policy: %{k: 1})
      end
    end

    ## send and append

    def append_round_trip do
      loop = parked!()

      inputs = [
        Input.message(%{"k" => [1, "x", true], "tag" => :reply}),
        Input.completed({:reply, 5}, Result.failed(%Error{message: "boom"})),
        Input.elapsed({:retry, 9}),
        Input.input_failed(41, %Error{code: :input_dead_lettered, message: "m"})
      ]

      for {input, i} <- Enum.with_index(inputs) do
        assert {:ok, :appended} = Loops.append(loop.id, input, "rt:#{i}")
      end

      # FIFO commit-visibility order, decoded back exactly: tuple tags,
      # vocabulary atoms, and result/error structs all round-trip.
      assert Enum.map(pending!(loop), & &1.input) == inputs
      assert Enum.map(Runs.pending(loop.id), & &1.input) == inputs

      # The first append's wake rode its atomic unit: queued, suspension
      # cleared, the host told.
      facts = fetch!(loop)
      assert facts.status == :queued
      assert facts.suspension == nil

      assert_received {:run_transition, %AgentRun{id: id, status: "queued"}, :resumed}
                      when id == loop.id

      # An append against an owned (running) loop leaves the status alone;
      # the in-flight step's park re-check owns visibility.
      _lease = claim!(loop)
      assert {:ok, :appended} = Runs.send(loop.id, %{"id" => "mid"})
      assert fetch!(loop).status == :running

      # A payload outside the controller's vocabulary raises at the caller.
      assert_raise ArgumentError, ~r/vocabulary/, fn ->
        Runs.send(loop.id, %{"id" => :undeclared})
      end
    end

    def dedup_key_duplicates do
      loop = parked!()

      assert {:ok, :appended} = Runs.send(loop.id, %{"id" => 1}, dedup_key: "hook:abc")
      assert {:ok, :duplicate} = Runs.send(loop.id, %{"id" => 1}, dedup_key: "hook:abc")
      assert [%StoredInput{}] = pending!(loop)

      # The key is unique per loop: another loop accepts the same key.
      other = parked!()
      assert {:ok, :appended} = Runs.send(other.id, %{"id" => 1}, dedup_key: "hook:abc")

      # A nil key never dedups.
      assert {:ok, :appended} = Runs.send(loop.id, %{"id" => 2})
      assert {:ok, :appended} = Runs.send(loop.id, %{"id" => 2})
      assert length(pending!(loop)) == 3
    end

    def append_to_terminal_observability do
      loop = parked!()
      send!(loop, %{"halt" => "done"})
      assert {:finished, %Facts{status: :completed}} = step!(loop)

      assert_received {:run_committed, %AgentRun{id: id, status: "completed"},
                       %Result.Completed{output: "done"}}
                      when id == loop.id

      # The caller is told the loop is over: retained evidence, never
      # silence, never an error to retry.
      assert {:ok, :dead_lettered} = Runs.send(loop.id, %{"id" => "late"}, dedup_key: "late:1")
      assert fetch!(loop).status == :completed
      assert pending!(loop) == []

      # Dedup covers dead rows too: the retried dead send is a duplicate of
      # retained evidence.
      assert {:ok, :duplicate} = Runs.send(loop.id, %{"id" => "late"}, dedup_key: "late:1")
      assert [%StoredInput{dead_reason: :terminal}] = Loops.dead_letters(loop.id, 50, nil)
    end

    def send_inside_a_transaction do
      loop = parked!()
      repo = repo()

      # A rolled-back transaction takes the input and the job with it.
      {:error, :changed_my_mind} =
        repo.transaction(fn ->
          {:ok, :appended} = Runs.send(loop.id, %{"id" => "never"})
          repo.rollback(:changed_my_mind)
        end)

      assert pending!(loop) == []
      assert fetch!(loop).status == :waiting
      refute_received {:run_transition, %AgentRun{id: _}, :resumed}

      # A committed one lands both, and the host hears the claim that
      # follows rather than the wake.
      {:ok, _} = repo.transaction(fn -> Runs.send(loop.id, %{"id" => "kept"}) end)
      assert [%StoredInput{}] = pending!(loop)
      assert fetch!(loop).status == :queued
      refute_received {:run_transition, %AgentRun{id: _}, :resumed}
      assert {:parked, _} = step!(loop)
      assert "message:kept" in log!(loop)
    end

    def concurrent_appends do
      loop = parked!()

      tasks =
        for i <- 1..@concurrent_appenders do
          Elixir.Task.async(fn ->
            receive do
              :go -> Runs.send(loop.id, %{"id" => i}, dedup_key: "race:#{i}")
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Elixir.Task.await_many(tasks, 30_000)

      assert Enum.all?(results, &match?({:ok, :appended}, &1)),
             "every racing send must land: #{inspect(results)}"

      # At least one sender found the row waiting and woke it; the rest
      # saw a queued row and rode the pending wake.
      assert fetch!(loop).status == :queued

      # One step drains all of them: none lost, none doubled.
      assert {:parked, _} = step!(loop)
      ids = for "message:" <> id <- log!(loop), do: String.to_integer(id)
      assert Enum.sort(ids) == Enum.to_list(1..@concurrent_appenders)
      assert pending!(loop) == []
    end

    def appends_racing_steps_never_strand do
      loop = parked!()
      writers = 4
      per_writer = 8

      appenders =
        for t <- 1..writers do
          Elixir.Task.async(fn ->
            for i <- 1..per_writer do
              assert {:ok, :appended} =
                       Runs.send(loop.id, %{"id" => "#{t}:#{i}"}, dedup_key: "load:#{t}:#{i}")
            end
          end)
        end

      # Step opportunistically while the senders run: every claim's window
      # races the in-flight inserts. Lost claims are the guards working.
      for _ <- 1..12 do
        if fetch!(loop).status == :queued, do: step!(loop)
      end

      Elixir.Task.await_many(appenders, 30_000)
      quiesce!(loop)

      # Parked means empty, and every send delivered exactly once.
      assert fetch!(loop).status == :waiting
      assert pending!(loop) == []

      delivered = for "message:" <> id <- log!(loop), do: id
      sent = for t <- 1..writers, i <- 1..per_writer, do: "#{t}:#{i}"
      assert Enum.sort(delivered) == Enum.sort(sent)
    end

    ## wrong-state calls

    def kind_guards do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 1})

      # A loop's child is a run like any other: the loop verbs refuse it,
      # writing nothing.
      assert {:error, :not_a_loop} = Runs.send(child.id, %{"id" => 1})
      assert {:error, :not_a_loop} = Loops.load(child.id, nil)
      assert {:error, :not_a_loop} = Runs.inspect(child.id)
      assert {:discard, :not_a_loop} = step!(child)
      assert Runs.pending(child.id) == []
      assert %Facts{status: :queued, cancel: nil} = fetch!(child)

      # A parked rollout is the case the guard exists for: no loop verb may
      # clear its suspension with a wake.
      child_lease = claim!(child)

      {:ok, _token} =
        Protocol.suspend(child_lease, Clementine.LifecycleCase.Battery.suspension_request(),
          cursor: {1, 0}
        )

      assert {:error, :not_a_loop} = Runs.send(child.id, %{"id" => 2})

      waiting = fetch!(child)
      assert waiting.status == :waiting
      assert %Suspension{} = waiting.suspension

      # And a loop's job on the run worker is miswired: discarded, never
      # executed as a rollout.
      assert {:cancel, reason} = perform_job(Worker, %{"run_id" => loop.id})
      assert reason =~ "loop_run"
      assert fetch!(loop).status == :waiting
    end

    def cancel_wrong_states do
      loop = start!()

      # Idempotent on the flag, first cause wins, the host told once.
      assert {:ok, :flagged} = Runs.cancel(loop.id)
      assert {:ok, :flagged} = Runs.cancel(loop.id)
      assert %{"code" => "cancelled"} = fetch!(loop).cancel.reason

      assert_received {:run_transition, %AgentRun{id: id, cancel: %{}}, :cancel_requested}
                      when id == loop.id

      refute_received {:run_transition, %AgentRun{id: _}, :cancel_requested}

      assert {:finished, %Facts{status: :cancelled}} = step!(loop)
      assert {:error, :already_terminal} = Runs.cancel(loop.id)
      assert fetch!(loop).status == :cancelled

      assert_received {:run_finished, %AgentRun{id: id},
                       %Result.Cancelled{reason: %{"code" => "cancelled"}}}
                      when id == loop.id
    end

    def step_discards_wrong_states do
      # A lost claim race is the single-flight guard working.
      loop = start!()
      _rival = claim!(loop)
      assert {:discard, {:not_claimable, :running}} = step!(loop)
      assert fetch!(loop).epoch == 1

      # A terminal loop cannot be stepped back to life.
      done = parked!()
      send!(done, %{"halt" => "over"})
      assert {:finished, _} = step!(done)
      assert {:discard, {:not_claimable, :completed}} = step!(done)
    end

    def not_found do
      missing = Ecto.UUID.generate()

      assert {:error, :not_found} = Runs.send(missing, %{"id" => 1})
      assert {:error, :not_found} = Runs.send("not-a-uuid", %{"id" => 1})
      assert {:error, :not_found} = Runs.inspect(missing)
      assert {:error, :not_found} = Runs.cancel(missing)
      assert {:error, :no_child} = Runs.child(missing, {:reply, 1})
      assert Runs.pending(missing) == []
      assert {:discard, :not_found} = Loops.step(missing, "conformance:missing")
    end

    def resume_refuses_a_loop do
      loop = parked!()
      assert {:error, :loop_run} = Runs.resume(loop.id, {:approved, %{}})
      assert fetch!(loop).status == :waiting
      assert step_jobs(loop) == 1
    end

    ## the step commit

    def crash_replay_no_duplicates do
      target = parked!()
      loop = parked!()

      send!(loop, %{
        "id" => "x",
        "actions" => [
          {:run, {:reply, 1}, child(Task)},
          {:send, target.id, %{"note" => true}}
        ]
      })

      # Crash before the commit: the drain happened, the commit never did.
      # The one durable pre-commit write is the drain-time attempts bump.
      lease = claim!(loop)
      _lost_commit = commit!(loop, lease)
      assert [%StoredInput{attempts: 1}] = pending!(loop)
      assert envelope!(loop).children == %{}
      assert pending!(target) == []
      assert Runs.list(parent: loop.id) == []

      {:ok, _} = Protocol.requeue(Lifecycle, fetch!(loop), :lease_expired)

      # The replay drains the identical input through pure decisions to an
      # identical commit: one child, one send, one log entry.
      assert {:parked, _} = step!(loop)

      assert [{tag_key, child_id}] = Map.to_list(envelope!(loop).children)
      assert tag_key == tag_key({:reply, 1})

      assert [%AgentRun{id: ^child_id, kind: "rollout", status: "queued"}] =
               Runs.list(parent: loop.id)

      assert [%StoredInput{input: %Input{kind: :message, payload: %{"note" => true}}}] =
               pending!(target)

      assert log!(loop) == ["init", "message:x"]
      assert pending!(loop) == []
    end

    def zombie_step_fenced do
      loop = parked!()
      send!(loop, spawn_payload({:reply, 1}))

      zombie = claim!(loop)
      stale_commit = commit!(loop, zombie)
      stored_envelope = load!(loop).envelope

      # Status half of the guard: a reaper requeue superseded the execution
      # mid-step, so the run is no longer :running.
      {:ok, _} = Protocol.requeue(Lifecycle, fetch!(loop), :lease_expired)
      assert {:error, :stale} = Loops.apply_step(stale_commit, nil)

      # Epoch half: the successor claims; status is :running again, the
      # epoch no longer matches.
      successor = claim!(loop)
      assert successor.epoch == zombie.epoch + 1
      assert {:error, :stale} = Loops.apply_step(stale_commit, nil)

      # Nothing the zombie carried landed: input unconsumed, envelope
      # untouched, no child inserted.
      assert [%StoredInput{input: %Input{kind: :message}}] = pending!(loop)
      assert load!(loop).envelope == stored_envelope
      assert envelope!(loop).children == %{}
      assert Runs.list(parent: loop.id) == []

      # The successor's own commit lands cleanly: exactly one child exists.
      commit = commit!(loop, successor)
      assert {:ok, %Facts{status: :waiting}} = Loops.apply_step(commit, nil)
      assert [{_tag_key, child_id}] = Map.to_list(envelope!(loop).children)
      assert [%AgentRun{id: ^child_id}] = Runs.list(parent: loop.id)
      assert pending!(loop) == []
    end

    def send_redispatch_dedup do
      target = parked!()
      loop = parked!()
      payload = %{"id" => "note"}

      send!(loop, %{"id" => "cause", "actions" => [{:send, target.id, payload}]})

      # The doomed execution: claim, drain, compute the commit, and die
      # before applying it. Dispatch is cargo, so nothing reached the
      # target.
      lost = claim!(loop)
      lost_commit = commit!(loop, lost)
      assert [%{target: target_id, dedup_key: send_key}] = lost_commit.sends
      assert target_id == target.id
      assert pending!(target) == []

      # A3a requeue; the replay recomputes the identical send spec.
      {:ok, _} = Protocol.requeue(Lifecycle, fetch!(loop), :lease_expired)
      successor = claim!(loop)
      replay_commit = commit!(loop, successor)
      assert replay_commit.sends == lost_commit.sends

      # The replay's commit delivers exactly once, waking the target.
      assert {:ok, %Facts{status: :waiting}} = Loops.apply_step(replay_commit, nil)
      assert [%StoredInput{input: %Input{kind: :message, payload: ^payload}}] = pending!(target)
      assert fetch!(target).status == :queued

      # The zombie's own commit is fenced whole, its send included.
      assert {:error, :stale} = Loops.apply_step(lost_commit, nil)
      assert [%StoredInput{}] = pending!(target)

      # The re-dispatched send itself, the traveled key in hand: duplicate.
      assert {:ok, :duplicate} = Runs.send(target.id, payload, dedup_key: send_key)
      assert [%StoredInput{}] = pending!(target)
      quiesce!(target)
      assert Enum.count(log!(target), &(&1 == "message:note")) == 1

      # A genuine re-send is a new causal input: fresh key, fresh delivery.
      send!(loop, %{"id" => "again", "actions" => [{:send, target.id, payload}]})
      resend = claim!(loop)
      resend_commit = commit!(loop, resend)
      assert [%{dedup_key: fresh_key}] = resend_commit.sends
      refute fresh_key == send_key

      assert {:ok, %Facts{status: :waiting}} = Loops.apply_step(resend_commit, nil)
      quiesce!(target)
      assert Enum.count(log!(target), &(&1 == "message:note")) == 2
    end

    def cancel_flag_racing_park do
      loop = parked!()
      send!(loop, message(1))

      lease = claim!(loop)
      commit = commit!(loop, lease)
      assert commit.op == :park

      # The flag lands after the claim read it as nil: the loop is running,
      # so cancel leaves only the flag; its wake has nothing to wake yet.
      assert {:ok, :flagged} = Runs.cancel(loop.id)
      assert fetch!(loop).status == :running

      # The park's :any re-check covers the flag: parking over it would
      # strand the cancellation with nobody left to honor it.
      assert {:ok, %Facts{status: :queued}} = Loops.apply_step(commit, nil)

      # The next claim reads the flag and the cascade finishes cancelled.
      assert {:finished, %Facts{status: :cancelled, cancel: nil}} = step!(loop)
    end

    def step_worker_outcomes do
      loop = start!()

      # The first step parks: ack.
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert fetch!(loop).status == :waiting

      # A backlog continues: ack, the next job already in the unit.
      {:ok, loop} = {:ok, %{loop | loop_policy: %{"batch_cap" => 1}}}

      repo().update_all(from(r in AgentRun, where: r.id == ^loop.id),
        set: [loop_policy: %{"batch_cap" => 1}]
      )

      send!(loop, message(1))
      send!(loop, message(2))
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert fetch!(loop).status == :queued
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert fetch!(loop).status == :waiting

      # A finish acks; a run that is not a loop, or a lost claim, cancels
      # the job.
      send!(loop, %{"halt" => "done"})
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert fetch!(loop).status == :completed
      assert {:cancel, reason} = perform_job(StepWorker, %{"run_id" => loop.id})
      assert reason =~ "not_claimable"

      {:ok, task} = Runs.start(Task, "A task")
      assert {:cancel, reason} = perform_job(StepWorker, %{"run_id" => task.id})
      assert reason =~ "not_a_loop"
    end

    ## poison isolation

    def poison_isolation do
      loop = parked!(policy: %{"dead_letter_after" => 2})

      send!(loop, %{"id" => "p", "boom" => true}, "poison:head")
      send!(loop, message("innocent"))
      [%StoredInput{ref: poison_ref}, _innocent] = pending!(loop)

      # Step 1: full batch planned, head bumped and blamed, the raise
      # counted, and the loop requeued, never terminalized.
      assert {:error, %Error{}} = step!(loop)
      refute Facts.terminal?(fetch!(loop))
      assert fetch!(loop).status == :queued
      assert [%StoredInput{attempts: 1}, %StoredInput{attempts: 0}] = pending!(loop)

      # Step 2: a bumped, unconsumed head is the evidence of a failed step;
      # the drain degrades to batch-1, so the innocent accumulates nothing.
      assert {:error, %Error{}} = step!(loop)
      assert [%StoredInput{attempts: 2}, %StoredInput{attempts: 0}] = pending!(loop)

      # Step 3: head at the threshold, dead-lettered with the synthesized
      # {:input_failed} evidence appended in the same commit.
      assert {:continued, _} = step!(loop)

      assert [
               %StoredInput{input: %Input{kind: :message}, attempts: 0},
               %StoredInput{input: %Input{kind: :input_failed} = evidence, attempts: 0}
             ] = pending!(loop)

      assert evidence.input_ref == poison_ref
      assert %Error{code: :input_dead_lettered} = evidence.error

      # The poison row was retained as dead-letter evidence: its dedup key
      # still holds against a re-send.
      assert {:ok, :duplicate} =
               Runs.send(loop.id, %{"id" => "p", "boom" => true}, dedup_key: "poison:head")

      assert [%StoredInput{dead_reason: :poison}] = Loops.dead_letters(loop.id, 50, nil)

      # Step 4: the controller is informed and the innocent drains.
      assert {:parked, _} = step!(loop)
      log = log!(loop)
      assert "message:innocent" in log
      assert "input_failed:input_dead_lettered" in log
      refute Facts.terminal?(fetch!(loop))
      assert pending!(loop) == []
    end

    def vm_death_attempts_counted do
      loop = parked!()
      send!(loop, message("survivor"))

      # Step phase 3, by hand: the bump is one small committed write
      # outside both atomic units; then the VM dies.
      _lease = claim!(loop)
      [%StoredInput{ref: head_ref, attempts: 0}] = pending!(loop)
      assert :ok = Loops.bump_attempts([head_ref], nil)
      assert [%StoredInput{attempts: 1}] = pending!(loop)

      # The reaper requeues the stale step; the bump survived the death.
      {:ok, _} = Protocol.requeue(Lifecycle, fetch!(loop), :lease_expired)
      assert [%StoredInput{attempts: 1}] = pending!(loop)

      # The replay drains it normally: attempts short of the threshold are
      # evidence, not a sentence.
      assert {:parked, _} = step!(loop)
      assert "message:survivor" in log!(loop)
      assert pending!(loop) == []
    end

    ## children through the start path

    def child_inserted_through_the_start_path do
      loop = parked!(subject: {"thread", "t-child"}, actor: {"user", "u-loop"})

      send!(loop, %{
        "id" => "spawn",
        "actions" => [
          {:run, {:reply, 7}, child(Turn, %{"metadata" => %{"message_id" => 7}})},
          {:run, {:retry, "r-1"},
           child(Task, %{"subject" => ["case", "c-1"], "actor" => ["user", "u-child"]})}
        ]
      })

      assert {:parked, _} = step!(loop)

      {:ok, turn} = Runs.child(loop.id, {:reply, 7})

      assert %AgentRun{
               kind: "rollout",
               agent_key: "conformance_turn",
               turn: true,
               input: %{"prompt" => "go"},
               subject_type: "thread",
               subject_id: "t-child",
               actor_type: "user",
               actor_id: "u-loop",
               metadata: %{"message_id" => 7},
               parent_id: parent_id,
               tag_kind: "reply",
               tag_id: "7",
               status: "queued"
             } = turn

      assert parent_id == loop.id
      assert is_integer(turn.oban_job_id)
      assert_enqueued(worker: Worker, args: %{"run_id" => turn.id})

      {:ok, task} = Runs.child(loop.id, {:retry, "r-1"})

      assert %AgentRun{
               agent_key: "conformance_task",
               turn: false,
               subject_type: "case",
               subject_id: "c-1",
               actor_type: "user",
               actor_id: "u-child",
               metadata: %{},
               tag_kind: "retry",
               tag_id: "r-1"
             } = task

      # The envelope records both under their canonical keys, filled with
      # the rows' ids in the same commit.
      assert envelope!(loop).children == %{
               tag_key({:reply, 7}) => turn.id,
               tag_key({:retry, "r-1"}) => task.id
             }

      # The loop's queries see them.
      assert Runs.turns(loop.id) |> Enum.map(& &1.id) == [turn.id]

      assert Runs.list(parent: loop.id) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([turn.id, task.id])

      assert Runs.active({"thread", "t-child"}).id == turn.id
    end

    def child_builds_at_claim do
      loop = parked!(subject: {"thread", "t-build"}, actor: {"user", "u-1"})
      send!(loop, spawn_payload({:reply, 1}, Turn))
      assert {:parked, _} = step!(loop)
      {:ok, child} = Runs.child(loop.id, {:reply, 1})

      # The child builds like any run: history/1 with the subject and actor
      # resolved, and its tool sees the run's context, parent and tag
      # included.
      expect_turn(tool_events("toolu_1", "context", %{}))
      expect_turn(text_events("Answered."))
      assert :ok = perform_job(Worker, %{"run_id" => child.id})

      assert_received {:history,
                       %AgentRun{id: id, subject: %{thread: "t-build"}, actor: %{user: "u-1"}}}
                      when id == child.id

      assert_received {:tool_context, context}
      assert context.run_id == child.id
      assert context.turn == true
      assert context.subject == %{thread: "t-build"}
      assert context.actor == %{user: "u-1"}
      assert context.parent_id == loop.id
      assert context.tag == {:reply, "1"}

      assert %AgentRun{status: "completed", result: %{"output" => "Answered."}} =
               Runs.get(child.id)
    end

    def child_completion_wakes_parent do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 1})
      assert fetch!(loop).status == :waiting

      # The child's terminal transaction appends the completion; the
      # host's run_finished/2 commits with it, and the parent wakes after.
      expect_turn(text_events("Done."))
      assert :ok = perform_job(Worker, %{"run_id" => child.id})

      assert_received {:run_finished, %AgentRun{id: id, status: "completed"}, %Result.Completed{}}
                      when id == child.id

      assert [
               %StoredInput{
                 input: %Input{
                   kind: :completed,
                   tag: {:reply, 1},
                   result: %Result.Completed{output: "Done."}
                 },
                 dedup_key: key
               }
             ] = pending!(loop)

      assert key == InboxCodec.completion_dedup_key(tag_key({:reply, 1}), child.id)
      assert fetch!(loop).status == :queued

      assert_received {:run_transition, %AgentRun{id: id, status: "queued"}, :resumed}
                      when id == loop.id

      # The parent decides on it, and the tag re-arms.
      assert {:parked, _} = step!(loop)
      assert "completed:{:reply, 1}:completed" in log!(loop)
      assert envelope!(loop).children == %{}
      assert {:error, :no_child} = Runs.child(loop.id, {:reply, 1})

      # The child's usage folded into the loop's.
      assert %Facts{usage: %Clementine.Usage{input_tokens: 10, output_tokens: 5}} = fetch!(loop)
    end

    def unstartable_child_completes_cancelled do
      loop = parked!()
      send!(loop, spawn_payload({:reply, 1}, Task, %{"subject" => ["gone", "g-1"]}))
      assert {:parked, _} = step!(loop)
      {:ok, child} = Runs.child(loop.id, {:reply, 1})

      # The host refuses the subject at the claim: the child is cancelled
      # as unstartable, and the loop hears why.
      assert {:cancel, reason} = perform_job(Worker, %{"run_id" => child.id})
      assert reason =~ "subject_gone"
      assert %AgentRun{status: "cancelled"} = Runs.get(child.id)

      quiesce!(loop)
      assert "completed:{:reply, 1}:cancelled" in log!(loop)
    end

    def child_events_fold do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 1})

      expect_turn(text_events("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => child.id})

      # The child's events reach the host in (epoch, seq) order and fold
      # into a view that its committed end closes.
      events = collect_events(child.id)
      refute events == []

      view =
        Enum.reduce(events, RunView.new(child.id), fn event, view ->
          RunView.apply(view, event)
        end)

      assert view.epoch == 1

      assert_received {:run_committed, %AgentRun{id: id, status: "completed"} = run,
                       %Result.Completed{}}
                      when id == child.id

      closed = RunView.close(view, run)
      assert closed.closed?
      assert closed.status == :completed
    end

    def children_queries do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 1})

      assert {:ok, %AgentRun{id: id}} = Runs.child(loop.id, {:reply, 1})
      assert id == child.id
      # Ids compare as text: the integer and its string name one lane.
      assert {:ok, %AgentRun{id: ^id}} = Runs.child(loop.id, {:reply, "1"})
      assert {:error, :no_child} = Runs.child(loop.id, {:reply, 2})
      assert Runs.list(parent: loop.id) |> Enum.map(& &1.id) == [child.id]
      assert Runs.turns(loop.id) == []

      # A tag re-arms once its child ends, and ended children stay listed.
      assert {:ok, :finished} = Runs.cancel(child.id)
      assert {:error, :no_child} = Runs.child(loop.id, {:reply, 1})
      quiesce!(loop)
      assert "completed:{:reply, 1}:cancelled" in log!(loop)

      send!(loop, spawn_payload({:reply, 1}, Turn))
      assert {:parked, _} = step!(loop)
      assert {:ok, %AgentRun{turn: true} = again} = Runs.child(loop.id, {:reply, 1})
      refute again.id == child.id
      assert Runs.turns(loop.id) |> Enum.map(& &1.id) == [again.id]
      assert length(Runs.list(parent: loop.id)) == 2
    end

    ## {:cancel, tag}

    def cancel_action_stops_running_child do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 1})

      # The child streams a long answer in a process of its own.
      long_answer(words: 50, every: 100)
      worker = Elixir.Task.async(fn -> perform_job(Worker, %{"run_id" => child.id}) end)
      assert_receive {:model_answering, _request}, 5_000

      assert_receive {:run_event, %AgentRun{id: id}, %Clementine.Event{type: :text_delta}}
                     when id == child.id,
                     1_000

      # The controller cancels it: the step flags the child as cargo, and
      # the relay pushes the flag to its runner once the step commits.
      send!(loop, %{"id" => "stop", "actions" => [{:cancel, {:reply, 1}}]})
      assert {:parked, _} = step!(loop)

      assert_receive {:run_committed, %AgentRun{id: id, status: "cancelled"},
                      %Result.Cancelled{reason: %{"code" => "loop_cancel", "loop_id" => loop_id}}}
                     when id == child.id,
                     2_000

      assert loop_id == loop.id
      assert :ok = Elixir.Task.await(worker)

      # The Cancelled completion arrives and the parent decides; the tag
      # re-arms.
      quiesce!(loop)
      assert "completed:{:reply, 1}:cancelled" in log!(loop)
      assert envelope!(loop).children == %{}
    end

    def cancel_action_queued_child_and_no_op do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 1})

      # A queued child ends inside the step's own commit, and its
      # completion lands in this very unit, where the park re-check sees
      # it: the step continues rather than parks.
      send!(loop, %{"id" => "stop", "actions" => [{:cancel, {:reply, 1}}]})
      assert {:continued, _} = step!(loop)
      assert %AgentRun{status: "cancelled"} = Runs.get(child.id)

      assert_received {:run_finished, %AgentRun{id: id},
                       %Result.Cancelled{reason: %{"code" => "loop_cancel"}}}
                      when id == child.id

      assert {:parked, _} = step!(loop)
      assert "completed:{:reply, 1}:cancelled" in log!(loop)

      # No live child under the tag: a no-op, not an error.
      send!(loop, %{"id" => "again", "actions" => [{:cancel, {:reply, 1}}]})
      assert {:parked, _} = step!(loop)
      assert "message:again" in log!(loop)
    end

    ## cancel/1

    def cascade_orders_queued_child do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 1})
      assert %Facts{kind: :rollout, status: :queued} = fetch!(child)

      # A straggler is already queued behind the stop; it must never reach
      # handle/2.
      send!(loop, message("straggler"), "straggle:1")
      assert {:ok, :flagged} = Runs.cancel(loop.id)
      assert fetch!(loop).status == :queued
      assert %{"code" => "cancelled"} = fetch!(loop).cancel.reason

      # Cascade: the machinery, never handle/2, cancels the child as
      # commit cargo; the child's terminal projection appends its
      # completion inside the same unit, and the cascade park downgrades
      # to continue. Child terminal first, loop still live.
      assert {:continued, _} = step!(loop)
      assert %Facts{status: :cancelled} = fetch!(child)

      assert_received {:run_finished, %AgentRun{id: id},
                       %Result.Cancelled{reason: %{"code" => "loop_cascade"}}}
                      when id == child.id

      refute Facts.terminal?(fetch!(loop))

      # The last completion folds; the loop finishes last, the flag clears
      # at the finish, and the terminal sweep leaves nothing consumable.
      assert {:finished, %Facts{status: :cancelled, cancel: nil}} = step!(loop)
      assert pending!(loop) == []
      refute "message:straggler" in log!(loop)

      assert {:ok, :duplicate} =
               Runs.send(loop.id, %{"id" => "straggler"}, dedup_key: "straggle:1")

      assert_received {:run_committed, %AgentRun{id: id, status: "cancelled"},
                       %Result.Cancelled{}}
                      when id == loop.id
    end

    def cascade_running_child_cooperative do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 9})

      # The child is mid-execution when the stop arrives.
      child_lease = claim!(child)
      assert {:ok, :flagged} = Runs.cancel(loop.id)

      # The cascade flags the running child cooperatively and parks
      # awaiting its completion. The set flag must not downgrade a cascade
      # park: the cascade is the flag's handler.
      assert {:parked, %Facts{status: :waiting, cancel: %{reason: %{"code" => "cancelled"}}}} =
               step!(loop)

      flagged = fetch!(child)
      assert flagged.status == :running
      assert %{reason: %{"code" => "loop_cascade"}} = flagged.cancel

      # The child honors its flag; its terminal projection delivers the
      # completion durably and wakes the parent. The cascade completes:
      # children's terminals first, the loop's last.
      {:ok, _} = Protocol.finish(child_lease, Result.cancelled(flagged.cancel.reason))
      assert Enum.any?(pending!(loop), &(&1.input.kind == :completed))
      assert fetch!(loop).status == :queued
      assert {:finished, %Facts{status: :cancelled, cancel: nil}} = step!(loop)
      assert pending!(loop) == []
    end

    def cancel_child_like_a_rollout do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 1})

      # A queued child finishes cancelled at once, as any rollout does.
      assert {:ok, :finished} = Runs.cancel(child.id)
      assert %AgentRun{status: "cancelled"} = Runs.get(child.id)
      assert {:error, :already_terminal} = Runs.cancel(child.id)

      # Its loop hears the completion and goes on.
      assert fetch!(loop).status == :queued
      assert {:parked, _} = step!(loop)
      assert "completed:{:reply, 1}:cancelled" in log!(loop)
      refute Facts.terminal?(fetch!(loop))
    end

    def halt_with_children_in_flight do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 3})

      # The halt arrives with the child live and an input queued behind it.
      send!(loop, %{"halt" => "all done"})
      send!(loop, message("too-late"), "late:sweep")

      # The halt enters the cascade: the child cancels as cargo, the
      # pending result parks in the envelope, and the undrained input
      # stays unconsumed for the sweep.
      assert {:continued, _} = step!(loop)
      assert %Facts{status: :cancelled} = fetch!(child)

      assert %Envelope{pending_halt: %{result: %Result.Completed{output: "all done"}}} =
               envelope!(loop)

      # The cascade finishes with the halt's result, first cause wins, and
      # the terminal sweep dead-letters the leftover.
      assert {:finished, %Facts{status: :completed} = facts} = step!(loop)
      assert %DateTime{} = facts.finished_at
      refute "message:too-late" in log!(loop)
      assert pending!(loop) == []
      assert %AgentRun{result: %{"output" => "all done"}} = Runs.get(loop.id)

      # Dead-lettered, not deleted: the swept row still holds its key.
      assert {:ok, :duplicate} =
               Runs.send(loop.id, %{"id" => "too-late"}, dedup_key: "late:sweep")
    end

    def cascade_completion_behind_long_backlog do
      loop = parked!(policy: %{"batch_cap" => 2})
      child = spawn_child!(loop, {:reply, 4})

      # A non-completion backlog longer than the batch window queues ahead
      # of where the child's completion will land.
      for i <- 1..4, do: send!(loop, message("backlog-#{i}"))
      assert {:ok, :flagged} = Runs.cancel(loop.id)

      # Cascade entry: the queued child terminalizes as cargo, its
      # completion appending behind the backlog; the :completions re-check
      # sees it in-unit.
      assert {:continued, _} = step!(loop)
      assert %Facts{status: :cancelled} = fetch!(child)

      # The cascade's window reads completions only: a FIFO :any window of
      # batch_cap + 1 would never surface a completion behind four skipped
      # messages.
      assert {:finished, %Facts{status: :cancelled}} = step!(loop)
      assert pending!(loop) == []
    end

    def cancel_never_stepped_short_circuits do
      loop = start!()
      for i <- 1..3, do: send!(loop, message(i), "short:#{i}")

      assert {:ok, :flagged} = Runs.cancel(loop.id)

      # The first step enters the cascade with no children and finishes
      # immediately: handle/2 never ran, and the terminal sweep marked
      # every queued input in the finish's own unit.
      assert {:finished, %Facts{status: :cancelled}} = step!(loop)
      assert log!(loop) == []
      assert pending!(loop) == []

      # Swept means marked, never deleted: the rows keep their keys.
      assert {:ok, :duplicate} = Runs.send(loop.id, %{"id" => 1}, dedup_key: "short:1")
    end

    ## timers

    def timer_fire_delivers_and_rearms do
      loop = parked!()
      poll_key = tag_key(:poll)

      # The schedule and the envelope entry recording it are one commit:
      # a timer job on the child spec's queue, its id in the entry.
      send!(loop, %{"id" => "arm", "actions" => [{:timer, :poll, 60_000}]})
      assert {:parked, _} = step!(loop)
      assert %{^poll_key => %{"schedule_id" => job_id}} = envelope!(loop).timers
      assert [%Oban.Job{id: ^job_id, scheduled_at: at}] = timer_jobs(loop)
      assert DateTime.diff(at, DateTime.utc_now(), :second) in 50..70

      # The fire is the timer worker's append under the schedule's key;
      # its wake rides the append's unit.
      [job] = timer_jobs(loop)
      assert :ok = perform_job(job)
      assert fetch!(loop).status == :queued

      # A worker retry of the same schedule is a duplicate: exactly-once
      # per schedule, whatever the job queue's delivery guarantees.
      assert {:ok, :duplicate} = Loops.fire_timer(loop.id, poll_key, job_id)

      # Delivered once, and the watcher re-arms the same tag in the very
      # fold that consumed the fire: a fresh schedule, a fresh job.
      assert {:parked, _} = step!(loop)
      assert Enum.count(log!(loop), &(&1 == "elapsed::poll")) == 1
      assert %{^poll_key => %{"schedule_id" => next_job_id}} = envelope!(loop).timers
      refute next_job_id == job_id
      assert pending!(loop) == []

      # The re-arm's fire lands where the spent one duplicates.
      assert {:ok, :appended} = Loops.fire_timer(loop.id, poll_key, next_job_id)
      assert {:ok, :dead_lettered} = Loops.fire_timer(loop.id, poll_key, job_id)
      assert {:parked, _} = step!(loop)
      assert Enum.count(log!(loop), &(&1 == "elapsed::poll")) == 2
    end

    def timer_fire_racing_cancel_dead_letters do
      loop = parked!()
      tag = {:retry, 7}
      key = tag_key(tag)

      send!(loop, %{"id" => "arm", "actions" => [{:timer, tag, 60_000}]})
      assert {:parked, _} = step!(loop)
      assert %{^key => %{"schedule_id" => job_id}} = envelope!(loop).timers
      assert [%Oban.Job{id: ^job_id}] = timer_jobs(loop)

      # The cancel retires the entry and cancels the job, best-effort.
      send!(loop, %{"id" => "cancel", "actions" => [{:cancel_timer, tag}]})
      assert {:parked, _} = step!(loop)
      assert envelope!(loop).timers == %{}
      assert timer_jobs(loop) == []
      log_before = log!(loop)

      # The racing fire: a schedule that already left the queue still
      # arrives; the door sees no entry for it and dead-letters it, never
      # waking the loop.
      assert {:ok, :dead_lettered} = Loops.fire_timer(loop.id, key, job_id)
      assert fetch!(loop).status == :waiting
      assert [%StoredInput{dead_reason: :stale_elapsed}] = Loops.dead_letters(loop.id, 50, nil)
      assert {:ok, :duplicate} = Loops.fire_timer(loop.id, key, job_id)
      assert log!(loop) == log_before

      # A cancelled tag is immediately re-armable.
      send!(loop, %{"id" => "rearm", "actions" => [{:timer, tag, 60_000}]})
      assert {:parked, _} = step!(loop)
      assert Map.has_key?(envelope!(loop).timers, key)
    end

    def timer_fire_against_terminal do
      loop = parked!()
      poll_key = tag_key(:poll)

      # Armed and never cancelled: the loop halts with the schedule still
      # out there.
      send!(loop, %{"id" => "arm", "actions" => [{:timer, :poll, 60_000}]})
      assert {:parked, _} = step!(loop)
      %{^poll_key => %{"schedule_id" => job_id}} = envelope!(loop).timers
      send!(loop, %{"halt" => "done"})
      assert {:finished, %Facts{status: :completed}} = step!(loop)

      # The late fire is told: retained evidence, never a wake, never a
      # crash; the worker acks it.
      [job] = timer_jobs(loop)
      assert job.id == job_id
      assert :ok = perform_job(job)
      assert fetch!(loop).status == :completed
      assert pending!(loop) == []
      assert [%StoredInput{dead_reason: :terminal}] = Loops.dead_letters(loop.id, 50, nil)
      assert {:ok, :duplicate} = Loops.fire_timer(loop.id, poll_key, job_id)

      # And a fire for a run that is not a loop, or none, cancels the job.
      {:ok, task} = Runs.start(Task, "A task")

      assert {:cancel, _} =
               perform_job(TimerWorker, %{"run_id" => task.id, "tag_key" => poll_key})

      assert {:cancel, _} =
               perform_job(TimerWorker, %{"run_id" => Ecto.UUID.generate(), "tag_key" => poll_key})
    end

    def timer_schedule_is_cargo do
      loop = parked!()
      poll_key = tag_key(:poll)
      assert timer_jobs(loop) == []

      send!(loop, %{"id" => "arm", "actions" => [{:timer, :poll, 60_000}]})

      # The crash window: the step claimed, drained the arm, and died
      # before its commit. Nothing durable may exist.
      lost = claim!(loop)
      lost_commit = commit!(loop, lost)
      assert Enum.any?(lost_commit.timers, &(&1.tag_key == poll_key))
      assert timer_jobs(loop) == []
      refute Map.has_key?(envelope!(loop).timers, poll_key)

      # The reaper requeues; the zombie's late commit is fenced whole,
      # schedule included.
      {:ok, _} = Protocol.requeue(Lifecycle, fetch!(loop), :lease_expired)
      assert {:error, :stale} = Loops.apply_step(lost_commit, nil)
      assert timer_jobs(loop) == []
      refute Map.has_key?(envelope!(loop).timers, poll_key)

      # The replay commits schedule and envelope entry as one unit.
      assert {:parked, _} = step!(loop)
      assert [%Oban.Job{}] = timer_jobs(loop)
      assert Map.has_key?(envelope!(loop).timers, poll_key)
    end

    ## the loop sweep's verdicts

    def sweep_requeues_crashed_step do
      loop = parked!()
      send!(loop, message("stuck"))

      # A step claimed and died: running, its heartbeat gone stale, at an
      # epoch no rollout policy would requeue.
      _lease = claim!(loop)
      long_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

      repo().update_all(from(r in AgentRun, where: r.id == ^loop.id),
        set: [heartbeat_at: long_ago, lease_epoch: 40]
      )

      jobs = step_jobs(loop)
      assert %{requeue: 1} = Reaper.loop_sweep()

      requeued = fetch!(loop)
      assert requeued.status == :queued
      assert requeued.epoch == 40
      assert step_jobs(loop) == jobs + 1

      assert_received {:run_transition, %AgentRun{id: id, status: "queued"}, :requeued}
                      when id == loop.id

      # Healed: the step drains, and the next sweep judges it healthy.
      assert {:parked, _} = step!(loop)
      assert "message:stuck" in log!(loop)
      assert %{healthy: 1} = Reaper.loop_sweep()
    end

    def sweep_reenqueues_lost_job do
      loop = parked!()
      send!(loop, message("stuck"))
      assert fetch!(loop).status == :queued

      # The wake committed the queued row, but its step job was lost, and
      # the row has sat past the claim timeout.
      repo().delete_all(from(j in Oban.Job, where: j.worker == "Clementine.Runs.StepWorker"))
      assert step_jobs(loop) == 0
      policy = Policy.new()
      stale = DateTime.add(DateTime.utc_now(), -(policy.claim_timeout + 60_000), :millisecond)
      repo().update_all(from(r in AgentRun, where: r.id == ^loop.id), set: [queued_at: stale])

      assert %{reenqueue: 1} = Reaper.loop_sweep()
      assert step_jobs(loop) == 1
      assert fetch!(loop).status == :queued

      # Never terminal on claim evidence: the re-enqueued step drains.
      assert {:parked, _} = step!(loop)
      assert "message:stuck" in log!(loop)
    end

    def sweep_reconciles_children do
      loop = parked!()
      child = spawn_child!(loop, {:reply, 1})
      tag_key = tag_key({:reply, 1})

      # Pod death: the reaper interrupts the child, whose terminal
      # projection delivers the completion. The lost-delivery substrate
      # the verdict exists for is manufactured by deleting that row.
      reason = InterruptReason.new(:lease_expired, "pod died")
      {:ok, _} = Protocol.interrupt(Lifecycle, fetch!(child), reason)
      assert Facts.terminal?(fetch!(child))
      key = InboxCodec.completion_dedup_key(tag_key, child.id)
      {1, _} = repo().delete_all(from(i in "agent_run_inbox", where: i.dedup_key == ^key))

      # The woken step drains nothing and re-parks; the envelope still
      # lists the child live.
      quiesce!(loop)
      assert fetch!(loop).status == :waiting
      assert pending!(loop) == []
      assert Map.has_key?(envelope!(loop).children, tag_key)
      assert [%{class: :stranded_completion}] = inspect!(loop).strands

      # The sweep's evidence names the strand; the healing synthesizes the
      # completion from the child's terminal row under the canonical key,
      # and the append's own unit wakes the loop.
      assert %{reconcile_children: 1} = Reaper.loop_sweep()

      assert [
               %StoredInput{
                 input: %Input{kind: :completed, result: %Result.Interrupted{} = synthesized},
                 dedup_key: ^key
               }
             ] = pending!(loop)

      # It carries what the child's row holds, as the lost delivery did.
      assert %InterruptReason{code: :lease_expired} = synthesized.reason
      assert fetch!(loop).status == :queued

      quiesce!(loop)
      assert Enum.count(log!(loop), &(&1 == "completed:{:reply, 1}:interrupted")) == 1
      assert envelope!(loop).children == %{}
      assert %{healthy: 1} = Reaper.loop_sweep()

      # A completed child: the synthesized completion carries the output
      # the child stored, so a controller deciding on it decides the same.
      done = spawn_child!(loop, {:reply, 3})
      expect_turn(text_events("The answer"))
      assert :ok = perform_job(Worker, %{"run_id" => done.id})

      assert %AgentRun{status: "completed", result: %{"output" => "The answer"}} =
               Runs.get(done.id)

      done_key = InboxCodec.completion_dedup_key(tag_key({:reply, 3}), done.id)
      {1, _} = repo().delete_all(from(i in "agent_run_inbox", where: i.dedup_key == ^done_key))
      quiesce!(loop)
      assert %{reconcile_children: 1} = Reaper.loop_sweep()

      assert [%StoredInput{input: %Input{result: %Result.Completed{output: "The answer"}}}] =
               pending!(loop)

      quiesce!(loop)
      assert Enum.count(log!(loop), &(&1 == "completed:{:reply, 3}:completed")) == 1

      # The race: evidence gathered before a real delivery landed. The
      # healing append no-ops on the canonical key: observable noise, never
      # double delivery.
      other = spawn_child!(loop, {:reply, 2})
      {:ok, _} = Protocol.interrupt(Lifecycle, fetch!(other), reason)

      assert {:ok, :duplicate} =
               Loops.append(
                 loop.id,
                 Input.completed({:reply, 2}, Result.interrupted(reason)),
                 InboxCodec.completion_dedup_key(tag_key({:reply, 2}), other.id)
               )

      :ok =
        Loops.reconcile_child(Runs.get(loop.id), %{
          tag_key: tag_key({:reply, 2}),
          child_ref: other.id
        })

      quiesce!(loop)
      assert Enum.count(log!(loop), &(&1 == "completed:{:reply, 2}:interrupted")) == 1
    end

    def sweep_wakes_pending do
      loop = parked!()

      # A sentence-1-imperfect substrate parks over a pending input: the
      # battery manufactures that state with a raw guarded park that skips
      # the re-check, over an input the step had not drained.
      send!(loop, message("stranded"))
      lease = claim!(loop)

      park = %Transition{
        op: :suspend,
        run_ref: loop.id,
        expect: %{status: :running, epoch: lease.epoch},
        set: %{
          status: :waiting,
          suspension: %Suspension{
            reason: {:external, :loop},
            checkpoint: nil,
            token: %ResumeToken{run_ref: loop.id, epoch: lease.epoch, reason_type: :external}
          },
          executor_id: nil,
          deadline: nil,
          heartbeat_at: nil,
          queued_at: :now
        }
      }

      assert {:ok, %Facts{status: :waiting}} = Lifecycle.apply(park, nil)
      assert [%StoredInput{}] = pending!(loop)
      assert [%{class: :parked_with_pending}] = inspect!(loop).strands

      # Fresh inputs judge healthy; past the threshold, the sweep wakes.
      assert %{healthy: 1} = Reaper.loop_sweep()
      policy = Policy.new()

      stale =
        DateTime.add(DateTime.utc_now(), -(policy.wake_pending_after + 60_000), :millisecond)

      repo().update_all(
        from(i in "agent_run_inbox", where: i.run_id == type(^loop.id, Ecto.UUID)),
        set: [inserted_at: stale]
      )

      jobs = step_jobs(loop)
      assert %{wake_pending: 1} = Reaper.loop_sweep()
      assert fetch!(loop).status == :queued
      assert step_jobs(loop) == jobs + 1

      assert {:parked, _} = step!(loop)
      assert "message:stranded" in log!(loop)
      assert pending!(loop) == []
    end

    def sweep_interrupts_wedged_step do
      loop = parked!()
      send!(loop, message("wedged"))

      # A step holds the lease with a fresh heartbeat, long past its
      # deadline: the one failure a requeue cannot heal.
      _lease = claim!(loop)
      long_ago = DateTime.add(DateTime.utc_now(), -1, :hour)
      repo().update_all(from(r in AgentRun, where: r.id == ^loop.id), set: [deadline: long_ago])

      assert %{interrupt: 1} = Reaper.loop_sweep()

      assert %Facts{status: :interrupted, interrupt: %InterruptReason{code: :deadline_exceeded}} =
               fetch!(loop)

      assert_received {:run_finished, %AgentRun{id: id, kind: "loop"}, %Result.Interrupted{}}
                      when id == loop.id

      assert {:ok, :dead_lettered} = Runs.send(loop.id, %{"id" => "late"})
    end

    ## step-job enqueues

    def step_job_enqueues do
      # start_loop enqueues the first step job inside its unit; insert-or-get
      # does not enqueue a second.
      subject = {"thread", unique("jobs")}
      {:ok, loop} = Runs.start_loop(ConformanceLoop, %{}, subject: subject)
      assert step_jobs(loop) == 1
      assert {:ok, :already_exists, _} = Runs.start_loop(ConformanceLoop, %{}, subject: subject)
      assert step_jobs(loop) == 1

      assert {:parked, _} = step!(loop)
      base = step_jobs(loop)

      # Atomicity sentence 2: the send carries the wake and the step-job
      # enqueue in one unit, and exactly one: a send against the already
      # queued loop rides the pending wake.
      send!(loop, message(1))
      assert step_jobs(loop) == base + 1
      assert Runs.get(loop.id).oban_job_id == newest_step_job(loop).id
      send!(loop, message(2))
      assert step_jobs(loop) == base + 1

      # A park the in-unit re-check downgrades enqueues the continue's job.
      lease = claim!(loop)
      commit = commit!(loop, lease)
      assert commit.op == :park
      send!(loop, message(3))
      before_downgrade = step_jobs(loop)
      assert {:ok, %Facts{status: :queued}} = Loops.apply_step(commit, nil)
      assert step_jobs(loop) == before_downgrade + 1

      assert {:parked, _} = step!(loop)

      # Cancelling a parked loop wakes it with its job in the same unit.
      before_cancel = step_jobs(loop)
      assert {:ok, :flagged} = Runs.cancel(loop.id)
      assert step_jobs(loop) == before_cancel + 1
    end

    ## the lane matrix

    def lane_turn_child_vs_direct_turn do
      thread = {"thread", unique("lane")}
      loop = parked!(subject: thread)
      child = spawn_child!(loop, {:reply, 1}, Turn)

      # The thread's lane holds the turn child: a direct turn is refused.
      assert {:error, :active_run_exists} = Runs.start(Turn, "Me too", subject: thread)
      assert Runs.active(thread).id == child.id

      # And the other way: with a direct turn on the thread, a step that
      # would start a turn child fails, and the poison path records it.
      other = parked!(subject: {"thread", unique("lane")}, policy: %{"dead_letter_after" => 2})
      {:ok, direct} = Runs.start(Turn, "First", subject: {"thread", other.subject_id})
      send!(other, spawn_payload({:reply, 1}, Turn), "spawn:1")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %Error{message: message}} = step!(other)
          assert message =~ "already holds an active run"
          assert {:error, %Error{}} = step!(other)
          assert {:continued, _} = step!(other)
        end)

      assert log =~ "already holds an active run"
      assert Runs.list(parent: other.id) == []
      assert %AgentRun{status: "queued"} = Runs.get(direct.id)
      assert {:parked, _} = step!(other)
      assert "input_failed:input_dead_lettered" in log!(other)
      assert [%StoredInput{dead_reason: :poison}] = Loops.dead_letters(other.id, 50, nil)
    end

    def lane_turn_child_vs_task_child do
      loop = parked!()

      send!(loop, %{
        "id" => "both",
        "actions" => [
          {:run, {:reply, 1}, child(Turn)},
          {:run, {:retry, 1}, child(Task)}
        ]
      })

      assert {:parked, _} = step!(loop)
      {:ok, turn} = Runs.child(loop.id, {:reply, 1})
      {:ok, task} = Runs.child(loop.id, {:retry, 1})
      assert turn.subject_id == loop.subject_id and task.subject_id == loop.subject_id

      expect_turn(text_events("Turn."))
      assert :ok = perform_job(Worker, %{"run_id" => turn.id})
      expect_turn(text_events("Task."))
      assert :ok = perform_job(Worker, %{"run_id" => task.id})

      quiesce!(loop)
      assert "completed:{:reply, 1}:completed" in log!(loop)
      assert "completed:{:retry, 1}:completed" in log!(loop)
    end

    def lane_loop_vs_loop_and_own_turn do
      thread = {"thread", unique("own")}
      loop = parked!(subject: thread)

      assert {:ok, :already_exists, %AgentRun{id: id}} =
               Runs.start_loop(ConformanceLoop, %{}, subject: thread)

      assert id == loop.id

      # The loop's own turn sits in the thread's turn lane, the loop in its
      # controller's: no collision, and the queries tell them apart.
      child = spawn_child!(loop, {:reply, 1}, Turn)
      assert Runs.active(thread).id == child.id
      assert Runs.active(thread, kind: :loop).id == loop.id
      assert Runs.latest(thread, turn: true).id == child.id
      assert Runs.list(subject: thread, kind: :loop) |> Enum.map(& &1.id) == [loop.id]
    end

    def lane_two_task_children do
      loop = parked!()
      _first = spawn_child!(loop, {:reply, 1}, Task)

      # Two children of one task agent on one subject share a lane: the
      # second is refused, and the step walks the poison path. A loop that
      # wants two at once gives them subjects of their own.
      send!(loop, spawn_payload({:reply, 2}, Task))

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Error{message: message}} = step!(loop)
        assert message =~ "conformance_task on thread"
      end)

      assert length(Runs.list(parent: loop.id)) == 1
    end

    def lane_interrupt_two_phase do
      loop = parked!()
      first = spawn_child!(loop, {:reply, 1}, Turn)

      # Cancel-and-spawn in one step: the running child still holds the
      # thread's lane, so the spawn fails the step.
      send!(loop, %{
        "id" => "interrupt-at-once",
        "actions" => [{:cancel, {:reply, 1}}, {:run, {:reply, 2}, child(Turn)}]
      })

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Error{message: message}} = step!(loop)
        assert message =~ "turn lane"
      end)

      # Nothing of that step landed: the first child is still live and
      # unflagged.
      assert %Facts{status: :queued, cancel: nil} = fetch!(first)
      assert Runs.list(parent: loop.id) |> length() == 1

      # Two steps: cancel first, spawn on the completion. The failed
      # input stays at the head; the cancel comes behind it. Dead-letter
      # the poison quickly so the two-phase story drains.
      repo().update_all(from(r in AgentRun, where: r.id == ^loop.id),
        set: [loop_policy: %{"dead_letter_after" => 1}]
      )

      ExUnit.CaptureLog.capture_log(fn -> assert {:continued, _} = step!(loop) end)
      assert {:parked, _} = step!(loop)

      send!(loop, %{"id" => "interrupt", "actions" => [{:cancel, {:reply, 1}}]})
      assert {:continued, _} = step!(loop)
      assert %AgentRun{status: "cancelled"} = Runs.get(first.id)
      assert {:parked, _} = step!(loop)
      assert "completed:{:reply, 1}:cancelled" in log!(loop)

      send!(loop, spawn_payload({:reply, 2}, Turn))
      assert {:parked, _} = step!(loop)
      assert {:ok, %AgentRun{status: "queued", turn: true}} = Runs.child(loop.id, {:reply, 2})
    end

    def child_spec_refused do
      # Each malformed child description fails the step with a message
      # naming the tag, requeues the loop, and inserts nothing: the poison
      # path records it from there, as lane_turn_child_vs_direct_turn shows.
      cases = [
        {{:run, {:reply, "a"}, %{"prompt" => "go"}}, ~s(needs an "agent" key)},
        {{:run, {:reply, "b"}, %{"agent" => "nope", "prompt" => "go"}}, "does not list"},
        {{:run, {:reply, "c"}, child(ConformanceLoop)}, "a loop controller"},
        {{:run, {:reply, "d"}, child(Task, %{"prompt" => " "})}, ~s(blank "prompt")},
        {{:run, {:reply, "e"}, %{"agent" => Task.key()}}, ~s(needs a "prompt" string)},
        {{:run, {:reply, "f"}, child(Task, %{"subject" => "thread:1"})}, ~s(malformed "subject")},
        {{:run, {:reply, "g"}, child(Task, %{"metadata" => [1]})}, ~s(malformed "metadata")},
        {{:run, {:reply, "h"}, child(Turn, %{"subject" => ["thread", nil]})}, "needs a subject"},
        {{:run, {:reply, "i", "extra"}, child(Task)}, "two parts"}
      ]

      ExUnit.CaptureLog.capture_log(fn ->
        for {action, expected} <- cases do
          loop = parked!()
          send!(loop, %{"id" => "bad", "actions" => [action]})

          assert {:error, %Error{message: message}} = step!(loop)
          assert message =~ expected, "#{inspect(action)}: #{message}"
          assert fetch!(loop).status == :queued
          assert Runs.list(parent: loop.id) == []
        end
      end)
    end

    def send_target_refused do
      # A send names a loop. A missing run or a rollout fails the commit,
      # which rolls back whole: the loop keeps its lease as `running`, the
      # reaper's :requeue verdict replays the step (LOOP_RFC A3a), and the
      # head's attempts bump counts each replay toward the poison threshold.
      {:ok, task} = Runs.start(Task, "A task")

      for {target, expected} <- [
            {Ecto.UUID.generate(), :send_target_not_found},
            {task.id, :send_target_not_a_loop}
          ] do
        loop = parked!()
        send!(loop, %{"id" => "send", "actions" => [{:send, target, %{"id" => "hello"}}]})

        assert {:error, {^expected, ^target}} = step!(loop)
        assert fetch!(loop).status == :running
        assert [%StoredInput{attempts: 1}] = pending!(loop)
      end

      assert Loops.pending(task.id, 50, :any, nil) == []
    end

    ## Harness helpers

    @doc false
    def start!(opts \\ []) do
      subject = Keyword.get_lazy(opts, :subject, fn -> {"thread", unique("thread")} end)

      {:ok, loop} =
        Runs.start_loop(ConformanceLoop, Keyword.get(opts, :args, %{}),
          subject: subject,
          actor: Keyword.get(opts, :actor),
          policy: Keyword.get(opts, :policy, %{})
        )

      loop
    end

    @doc false
    def parked!(opts \\ []) do
      loop = start!(opts)
      assert {:parked, %Facts{status: :waiting}} = step!(loop)
      loop
    end

    @doc false
    def step!(%AgentRun{id: id}), do: step!(id)

    def step!(id) when is_binary(id) do
      Loops.step(id, "conformance:step:#{System.unique_integer([:positive])}")
    end

    @doc false
    def fetch!(%AgentRun{id: id}), do: fetch!(id)

    def fetch!(id) when is_binary(id) do
      assert {:ok, %Facts{} = facts} = Lifecycle.fetch(id, nil)
      facts
    end

    @doc false
    def load!(%AgentRun{id: id}) do
      assert {:ok, loaded} = Loops.load(id, nil)
      loaded
    end

    @doc false
    def pending!(%AgentRun{id: id}), do: Loops.pending(id, 50, :any, nil)

    @doc false
    def inspect!(%AgentRun{id: id}) do
      assert {:ok, report} = Runs.inspect(id)
      report
    end

    @doc false
    def send!(%AgentRun{id: id}, payload, dedup_key \\ nil) do
      assert {:ok, :appended} = Runs.send(id, payload, dedup_key: dedup_key)
    end

    @doc false
    def append!(%AgentRun{id: id}, %Input{} = input, dedup_key \\ nil) do
      assert {:ok, :appended} = Loops.append(id, input, dedup_key)
    end

    @doc false
    def message(id), do: %{"id" => id}

    @doc false
    # A child of `agent` under `tag`: the action's JSON map.
    def child(agent, extra \\ %{}) do
      Map.merge(%{"agent" => agent.key(), "prompt" => "go"}, extra)
    end

    @doc false
    def spawn_payload(tag, agent \\ Task, extra \\ %{}) do
      %{"id" => "spawn", "actions" => [{:run, tag, child(agent, extra)}]}
    end

    @doc false
    def claim!(%AgentRun{id: id}) do
      assert {:ok, %Clementine.Lease{} = lease} =
               Protocol.claim(Lifecycle, id, executor: "conformance:manual")

      lease
    end

    # Drives queued steps until the loop leaves :queued, the ground state
    # (or a terminal) every clean path lands on.
    @doc false
    def quiesce!(%AgentRun{} = loop, budget \\ 25) do
      case fetch!(loop).status do
        :queued when budget > 0 ->
          step!(loop)
          quiesce!(loop, budget - 1)

        :queued ->
          flunk("loop #{loop.id} failed to quiesce")

        _settled ->
          :ok
      end
    end

    @doc false
    # One manufactured step, mirroring the runner's phases 2–5 (load under
    # the fence, window, plan, bump, drain), returning the StepCommit for
    # the caller to apply, delay, or abandon (the crash window).
    def commit!(%AgentRun{id: id} = loop, %Clementine.Lease{} = lease) do
      loaded = load!(loop)
      {:ok, module} = Clementine.Loop.resolve(loaded.module)
      envelope = decode_envelope!(loaded.envelope)
      cancel = cancel_reason(loaded.facts)
      batch_cap = Map.get(loaded.policy, "batch_cap", Step.default_batch_cap())
      threshold = Map.get(loaded.policy, "dead_letter_after", Step.default_dead_letter_after())

      scope =
        if cancel != nil or (envelope != nil and Envelope.cascading?(envelope)),
          do: :completions,
          else: :any

      window = Loops.pending(id, batch_cap + 1, scope, nil)

      plan =
        Step.plan(envelope, window,
          cancel: cancel,
          batch_cap: batch_cap,
          dead_letter_after: threshold
        )

      :ok = Loops.bump_attempts(plan.bump, nil)

      {:ok, commit} =
        Step.drain(module, envelope, plan,
          loop_ref: id,
          epoch: lease.epoch,
          loop_args: loaded.args
        )

      commit
    end

    defp cancel_reason(%Facts{cancel: nil}), do: nil
    defp cancel_reason(%Facts{cancel: %{reason: reason}}), do: reason || :cancelled

    @doc false
    def spawn_child!(%AgentRun{} = loop, tag, agent \\ Task) do
      send!(loop, spawn_payload(tag, agent))
      assert {:parked, _} = step!(loop)
      assert {:ok, %AgentRun{} = child} = Runs.child(loop.id, tag)
      assert Map.get(envelope!(loop).children, tag_key(tag)) == child.id
      child
    end

    @doc false
    def envelope!(%AgentRun{} = loop), do: decode_envelope!(load!(loop).envelope)

    @doc false
    # The committed state log: delivery asserted through storage. Empty
    # while no drain has committed app state (pre-init, or a cascade that
    # never ran handle/2).
    def log!(%AgentRun{} = loop) do
      case envelope!(loop) do
        nil ->
          []

        %Envelope{state: nil} ->
          []

        %Envelope{state: state} ->
          state |> Codec.decode(vocabulary: vocabulary()) |> Map.fetch!("log")
      end
    end

    @doc false
    def tag_key(tag), do: Codec.key(tag, vocabulary: vocabulary())

    @doc false
    def step_jobs(%AgentRun{id: id}) do
      repo().aggregate(
        from(j in Oban.Job,
          where: j.worker == "Clementine.Runs.StepWorker",
          where: fragment("?->>'run_id' = ?", j.args, ^id)
        ),
        :count
      )
    end

    defp newest_step_job(%AgentRun{id: id}) do
      repo().one(
        from(j in Oban.Job,
          where: j.worker == "Clementine.Runs.StepWorker",
          where: fragment("?->>'run_id' = ?", j.args, ^id),
          order_by: [desc: j.id],
          limit: 1
        )
      )
    end

    @doc false
    # The loop's live timer schedules: its timer jobs still waiting to fire.
    def timer_jobs(%AgentRun{id: id}) do
      repo().all(
        from(j in Oban.Job,
          where: j.worker == "Clementine.Runs.TimerWorker",
          where: fragment("?->>'run_id' = ?", j.args, ^id),
          where: j.state in ["available", "scheduled"],
          order_by: [asc: j.id]
        )
      )
    end

    defp decode_envelope!(nil), do: nil

    defp decode_envelope!(data) do
      assert {:ok, %Envelope{} = envelope} = Envelope.decode(data)
      envelope
    end

    defp vocabulary, do: ConformanceLoop.__loop__(:vocabulary)

    defp repo, do: Config.fetch!().repo

    defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

    ## The model: scripted on the configured client, a Mox mock.

    defp client, do: Application.fetch_env!(:clementine, :llm_client)

    @doc false
    def expect_turn(events) when is_list(events) do
      Mox.expect(client(), :stream, fn _model, _system, _messages, _tools, _opts -> events end)
    end

    @doc false
    def text_events(text) do
      [
        {:text_delta, text},
        {:message_delta, %{"stop_reason" => "end_turn"},
         %{"input_tokens" => 10, "output_tokens" => 5}}
      ]
    end

    @doc false
    def tool_events(id, name, input) do
      [
        {:tool_use_start, id, name},
        {:input_json_delta, id, Jason.encode!(input)},
        {:content_block_stop, 0},
        {:message_delta, %{"stop_reason" => "tool_use"},
         %{"input_tokens" => 10, "output_tokens" => 5}}
      ]
    end

    # Scripts a model turn that streams `words` words, one every `every`
    # ms, from a request process of its own, as an HTTP provider does. The
    # test hears {:model_answering, request} when the answer starts.
    defp long_answer(words: words, every: every) do
      test = self()

      Mox.expect(client(), :stream, fn _model, _system, _messages, _tools, _opts ->
        ProviderStream.new(Clementine.LoopCase.Battery.Passthrough, fn parent, ref ->
          send(test, {:model_answering, self()})

          for n <- 1..words do
            send(parent, {ref, {:data, {:text_delta, "word#{n} "}}})
            Process.sleep(every)
          end

          usage = %{"input_tokens" => 10, "output_tokens" => words}
          send(parent, {ref, {:data, {:message_delta, %{"stop_reason" => "end_turn"}, usage}}})
          send(parent, {ref, :done})
        end)
      end)
    end

    # Every run_event the host reported for `run_id`, in arrival order.
    defp collect_events(run_id, acc \\ []) do
      receive do
        {:run_event, %AgentRun{id: ^run_id}, %Clementine.Event{} = event} ->
          collect_events(run_id, [event | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    # A job read back from the table, performed as Oban would: attempted
    # now, on its first attempt.
    defp perform_job(%Oban.Job{} = job) do
      Oban.Testing.perform_job(%{job | attempt: 1, attempted_at: DateTime.utc_now()},
        repo: repo()
      )
    end

    defp perform_job(worker, args) when is_atom(worker) do
      Oban.Testing.perform_job(worker, args, repo: repo())
    end

    defp assert_enqueued(opts) do
      Oban.Testing.assert_enqueued(Keyword.merge([repo: repo()], opts))
    end

    defmodule Passthrough do
      @moduledoc false
      # Events pass through as the model streams them.
      def new, do: nil
      def parse(state, event), do: {[event], state}
    end
  end
end
