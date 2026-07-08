defmodule Clementine.Loop.EctoHostTest do
  @moduledoc """
  The A5/A6 acceptance battery against the Ecto loop host: both normative
  atomicity sentences demonstrable under concurrent load, the recipes
  round-tripping the envelope and codec-encoded payloads, the append
  return contract, creation's insert-or-get, and the child-terminal
  projection glue. Commits are computed by the real pure core
  (`Clementine.Loop.Step`) so the seam is exercised exactly as the step
  runner will drive it.
  """

  use ExUnit.Case, async: false

  @moduletag :postgres

  import Clementine.EctoCase, only: [insert_run!: 1]
  import Ecto.Query

  alias Clementine.Lifecycle.Protocol
  alias Clementine.Loop.Ecto.Codec, as: InboxCodec
  alias Clementine.Loop.Protocol, as: LoopProtocol
  alias Clementine.Loop.{Codec, Envelope, Input, Step, StoredInput}
  alias Clementine.Test.Ecto.{Job, Lifecycle, LoopHost, Run}
  alias Clementine.Test.ScriptedLoop
  alias Clementine.TestRepo
  alias Clementine.{Error, Result, Usage}

  @inbox "clementine_test_loop_inbox"

  # Genuinely racing writers need shared sandbox ownership — the same
  # documented setup as the lifecycle conformance battery.
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(TestRepo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  ## Creation

  describe "Loop.Protocol.create/3" do
    test "insert-or-get on the scope key: queued row, spec persisted, first step job in the unit" do
      scope = unique_scope()

      assert {:ok, facts} = LoopProtocol.create(LoopHost, spec(scope: scope, args: %{"a" => 1}))
      assert facts.kind == :loop
      assert facts.status == :queued
      assert facts.epoch == 0

      row = TestRepo.get!(Run, facts.ref)
      assert row.loop_module == "Clementine.Test.ScriptedLoop"
      assert row.loop_args == %{"a" => 1}
      assert row.loop_scope == scope
      assert row.state_version == 1
      assert row.envelope == nil
      assert step_jobs(facts.ref) |> length() == 1

      assert {:ok, :already_exists, again} = LoopProtocol.create(LoopHost, spec(scope: scope))
      assert again.ref == facts.ref
      assert step_jobs(facts.ref) |> length() == 1
      assert TestRepo.aggregate(where(Run, loop_scope: ^scope), :count) == 1
    end

    test "concurrent creates on one scope collapse to one row and one first-step job" do
      scope = unique_scope()

      results =
        1..6
        |> Enum.map(fn _ ->
          Task.async(fn -> LoopProtocol.create(LoopHost, spec(scope: scope)) end)
        end)
        |> Task.await_many(30_000)

      assert Enum.count(results, &match?({:ok, %{}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, :already_exists, %{}}, &1)) == 5

      [{:ok, facts}] = Enum.filter(results, &match?({:ok, %{}}, &1))
      assert TestRepo.aggregate(where(Run, loop_scope: ^scope), :count) == 1
      assert step_jobs(facts.ref) |> length() == 1
    end

    test "refuses a module without the loop contract and demands a scope" do
      assert {:error, {:incompatible_spec, _}} =
               LoopProtocol.create(LoopHost, %{module: Enum, scope: unique_scope()})

      assert_raise ArgumentError, ~r/requires a :scope/, fn ->
        LoopProtocol.create(LoopHost, %{module: ScriptedLoop})
      end

      assert_raise ArgumentError, ~r/JSON-safe/, fn ->
        LoopProtocol.create(LoopHost, spec(args: %{"pid" => self()}))
      end
    end
  end

  ## Append — atomicity sentence 2

  describe "append/4" do
    test "appends and wakes a parked loop in one unit: input row, queued status, hygiene, step job" do
      loop = parked_loop!()
      jobs = length(step_jobs(loop.ref))

      assert {:ok, :appended} = LoopHost.append(loop.ref, message(1), "m:1", nil)

      row = TestRepo.get!(Run, loop.ref)
      assert row.status == "queued"
      assert row.suspension == nil
      assert length(step_jobs(loop.ref)) == jobs + 1
      assert [%{kind: "message", dedup_key: "m:1"}] = inbox_rows(loop.ref)
    end

    test "appends to a running loop without a wake — the in-flight step's re-check owns it" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, message(1), nil, nil)
      _lease = claim!(loop.ref)
      jobs = length(step_jobs(loop.ref))

      assert {:ok, :appended} = LoopHost.append(loop.ref, message(2), nil, nil)
      assert TestRepo.get!(Run, loop.ref).status == "running"
      assert length(step_jobs(loop.ref)) == jobs
    end

    test "matrix row L3: appends race each other and the wake — FIFO ids, one wake, one drain" do
      loop = parked_loop!()
      jobs = length(step_jobs(loop.ref))

      1..8
      |> Enum.map(fn i ->
        Task.async(fn -> LoopHost.append(loop.ref, message(i), "m:#{i}", nil) end)
      end)
      |> Task.await_many(30_000)
      |> Enum.each(fn result -> assert {:ok, :appended} = result end)

      # Exactly one append found the row waiting; the rest saw queued.
      assert length(step_jobs(loop.ref)) == jobs + 1
      assert TestRepo.get!(Run, loop.ref).status == "queued"

      # One step drains all eight, none lost, none doubled. (FIFO order
      # against sequential appends is asserted in the round-trip test —
      # racing appenders have no defined arrival order to assert.)
      facts = run_step!(loop.ref)
      assert facts.status == :waiting

      log = loop_log(loop.ref)
      ids = for "message:" <> id <- log, do: String.to_integer(id)
      assert Enum.sort(ids) == Enum.to_list(1..8)
    end

    test "dedup_key hit returns :duplicate and changes nothing" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, message(1), "hook:abc", nil)
      jobs = length(step_jobs(loop.ref))

      assert {:ok, :duplicate} = LoopHost.append(loop.ref, message(1), "hook:abc", nil)
      assert length(inbox_rows(loop.ref)) == 1
      assert length(step_jobs(loop.ref)) == jobs
    end

    test "matrix row L10: append to a terminal loop returns :dead_lettered — retained evidence, informed caller" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, Input.message(%{"halt" => "done"}), nil, nil)
      assert run_step!(loop.ref).status == :completed
      jobs = length(step_jobs(loop.ref))

      assert {:ok, :dead_lettered} = LoopHost.append(loop.ref, message(9), "late:9", nil)

      assert [row] = Enum.filter(inbox_rows(loop.ref), &(&1.dedup_key == "late:9"))
      assert row.dead_reason == "terminal"
      assert %DateTime{} = row.dead_at
      assert length(step_jobs(loop.ref)) == jobs

      # A retried dead append is a duplicate of retained evidence.
      assert {:ok, :duplicate} = LoopHost.append(loop.ref, message(9), "late:9", nil)
    end

    test "unknown loop returns :not_found; an unencodable payload raises at the caller" do
      assert {:error, :not_found} = LoopHost.append(-1, message(1), nil, nil)

      loop = parked_loop!()

      assert_raise ArgumentError, ~r/vocabulary/, fn ->
        LoopHost.append(loop.ref, Input.message(%{"oops" => :undeclared_atom}), nil, nil)
      end
    end
  end

  ## The park re-check — atomicity sentence 1's downgrade

  describe "park re-check" do
    test "matrix row L4: an append landing between drain and park downgrades to continue inside the commit" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, message(1), nil, nil)

      # The step: drain the window down to a park intent...
      commit = build_commit!(loop.ref)
      assert commit.op == :park
      jobs = length(step_jobs(loop.ref))

      # ...the race: an input lands after the drain, before the commit.
      # The loop is running, so the append neither wakes nor enqueues.
      assert {:ok, :appended} = LoopHost.append(loop.ref, message(2), nil, nil)
      assert length(step_jobs(loop.ref)) == jobs

      # The park re-verifies in-unit and downgrades: queued, job enqueued,
      # nothing parked over a pending input.
      assert {:ok, facts} = LoopHost.apply_step(commit, nil)
      assert facts.status == :queued
      assert facts.suspension == nil
      assert length(step_jobs(loop.ref)) == jobs + 1

      assert run_step!(loop.ref).status == :waiting
      assert "message:2" in loop_log(loop.ref)
    end

    test "matrix rows L3/L4 (load): appends racing steps never strand a parked loop with pending inputs" do
      loop = parked_loop!()

      appenders =
        for t <- 1..4 do
          Task.async(fn ->
            for i <- 1..8 do
              assert {:ok, :appended} =
                       LoopHost.append(loop.ref, message("#{t}:#{i}"), "m:#{t}:#{i}", nil)
            end
          end)
        end

      # Step opportunistically while the appenders run: every claim's
      # window races the in-flight inserts.
      for _ <- 1..12 do
        if TestRepo.get!(Run, loop.ref).status == "queued", do: run_step!(loop.ref)
      end

      Task.await_many(appenders, 30_000)
      drain_to_park!(loop.ref, 50)

      # The invariant every interleaving must land on: parked means empty.
      assert TestRepo.get!(Run, loop.ref).status == "waiting"
      assert inbox_rows(loop.ref) |> Enum.filter(&is_nil(&1.dead_at)) == []

      log = loop_log(loop.ref)
      assert Enum.count(log, &String.starts_with?(&1, "message:")) == 32
    end
  end

  ## apply_step — the one atomic unit

  describe "apply_step/2" do
    test "park commits the envelope, a checkpoint-less external suspension, and consumption together" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, message(1), nil, nil)

      facts = run_step!(loop.ref)
      assert facts.status == :waiting
      assert facts.suspension.reason == {:external, :loop}
      assert facts.suspension.checkpoint == nil
      assert facts.suspension.token.epoch == facts.epoch
      assert facts.executor_id == nil and facts.deadline == nil and facts.heartbeat_at == nil

      assert inbox_rows(loop.ref) == []
      assert loop_log(loop.ref) == ["init", "message:1"]
    end

    test "continue re-enqueues in the unit when a backlog remains" do
      loop = parked_loop!()
      for i <- 1..3, do: {:ok, :appended} = LoopHost.append(loop.ref, message(i), nil, nil)
      jobs = length(step_jobs(loop.ref))

      facts = run_step!(loop.ref, limit: 2)
      assert facts.status == :queued
      assert length(step_jobs(loop.ref)) == jobs + 1
      assert length(inbox_rows(loop.ref)) == 1
    end

    test "children cargo: rows and jobs in the unit, real refs filled into the envelope, fan-out unconstrained" do
      loop = parked_loop!()

      actions = [
        {:run, {:reply, 1}, %{"input" => "a"}},
        {:run, {:reply, 2}, %{"input" => "b"}}
      ]

      {:ok, :appended} =
        LoopHost.append(loop.ref, Input.message(%{"id" => 1, "actions" => actions}), nil, nil)

      assert run_step!(loop.ref).status == :waiting

      children =
        TestRepo.all(from(r in Run, where: r.loop_ref == ^loop.ref, order_by: r.tag_key))

      assert length(children) == 2
      assert Enum.all?(children, &(&1.kind == "rollout" and &1.status == "queued"))

      envelope = stored_envelope(loop.ref)
      assert map_size(envelope.children) == 2

      for child <- children do
        assert envelope.children[child.tag_key] == child.id
        assert [job] = TestRepo.all(from(j in Job, where: j.run_ref == ^child.id))
        assert job.kind == "child"
        assert job.args["input"] in ["a", "b"]
      end
    end

    test "the child dedup index refuses a duplicate active tag and frees it at the child's terminal" do
      loop = parked_loop!()
      spawn_child!(loop.ref, {:reply, 7})
      [child] = TestRepo.all(from(r in Run, where: r.loop_ref == ^loop.ref))

      assert_raise Ecto.ConstraintError, ~r/loop_child_dedup_index/, fn ->
        insert_run!(loop_ref: loop.ref, tag_key: child.tag_key, kind: "rollout")
      end

      {:ok, _} = Protocol.finish(claim!(child.id), Result.completed(output: "done"))
      insert_run!(loop_ref: loop.ref, tag_key: child.tag_key, kind: "rollout")
    end

    test "matrix row L11 (writes half): a zombie step's commit is :stale and writes nothing" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, message(1), nil, nil)

      stale_commit = build_commit!(loop.ref)
      {:ok, _} = Protocol.requeue(claim_lease(), :drain)
      _fresh = claim!(loop.ref)
      jobs = length(step_jobs(loop.ref))
      envelope = stored_envelope(loop.ref)

      assert {:error, :stale} = LoopHost.apply_step(stale_commit, nil)

      assert [%{kind: "message", dead_at: nil}] = inbox_rows(loop.ref)
      assert TestRepo.get!(Run, loop.ref).status == "running"
      assert length(step_jobs(loop.ref)) == jobs
      assert stored_envelope(loop.ref) == envelope
    end

    test "matrix row L7 (storage half): the threshold commit marks poison and appends its evidence in one unit" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, message(1), nil, nil)
      {:ok, :appended} = LoopHost.append(loop.ref, message(2), nil, nil)
      [head, _] = inbox_rows(loop.ref)
      exhaust_attempts(head.id)

      facts = run_step!(loop.ref)
      assert facts.status == :queued

      rows = inbox_rows(loop.ref)
      assert [%{dead_reason: "poison"} = dead] = Enum.filter(rows, &(&1.id == head.id))
      assert %DateTime{} = dead.dead_at

      # The synthesized {:input_failed} rides the same commit and decodes
      # back to the head's ref and error.
      [stored] =
        for %StoredInput{input: %Input{kind: :input_failed}} = s <- pending!(loop.ref), do: s

      assert stored.input.input_ref == head.id
      assert %Error{code: :input_dead_lettered} = stored.input.error

      # Innocents behind the poison head survive untouched.
      assert Enum.any?(pending!(loop.ref), &(&1.input.kind == :message))
    end

    test "apply_step is one atomic unit: a raising terminal projection rolls back CAS, consumption, and sweep" do
      loop = parked_loop!(attrs: %{label: "raise:completed"})
      {:ok, :appended} = LoopHost.append(loop.ref, Input.message(%{"halt" => "done"}), nil, nil)
      {:ok, :appended} = LoopHost.append(loop.ref, message("leftover"), "left:1", nil)

      commit = build_commit!(loop.ref)
      assert commit.op == :finish and commit.terminal_sweep

      assert_raise RuntimeError, ~r/projection probe/, fn ->
        LoopHost.apply_step(commit, self())
      end

      row = TestRepo.get!(Run, loop.ref)
      assert row.status == "running"
      assert row.finished_at == nil
      assert [%{dead_at: nil}, %{dead_at: nil}] = inbox_rows(loop.ref)
      refute_received {:projected, _, _}
    end

    test "matrix rows L8/L9 (storage half): the finish commits the result, projection, and terminal sweep together" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, Input.message(%{"halt" => "done"}), nil, nil)
      {:ok, :appended} = LoopHost.append(loop.ref, message("leftover"), "left:1", nil)

      facts = run_step!(loop.ref, ctx: self())
      assert facts.status == :completed
      assert %DateTime{} = facts.finished_at

      assert_received {:projected, %Result.Completed{output: "done"}, _row}

      # The halt's input consumed; everything behind it swept, retained,
      # and reasoned — nothing silently kept.
      assert [swept] = inbox_rows(loop.ref)
      assert swept.dedup_key == "left:1"
      assert swept.dead_reason == "terminal_sweep"
    end

    test "cascade cancel cargo: children cancelled in-unit; a queued child's completion lands in this very commit" do
      loop = parked_loop!()
      spawn_child!(loop.ref, {:reply, 1})
      [child] = TestRepo.all(from(r in Run, where: r.loop_ref == ^loop.ref))

      # Loop cancel is flag + wake; the plan's :cancel stands in for the
      # persisted flag until the cancel verb lands with the step runner.
      :ok = Clementine.Loop.Ecto.wake(LoopHost, loop.ref, nil)
      jobs = length(step_jobs(loop.ref))
      commit = build_commit!(loop.ref, plan: [cancel: :user_stop])
      assert commit.cancel_children == [child.tag_key]
      assert {:ok, facts} = LoopHost.apply_step(commit, nil)

      # The queued child direct-terminalized inside the unit, its terminal
      # projection appended the completion, and the in-unit wake (or the
      # park re-check) turned the cascade park into a continue.
      assert TestRepo.get!(Run, child.id).status == "cancelled"
      assert [completion] = Enum.filter(inbox_rows(loop.ref), &(&1.kind == "completed"))
      assert completion.dedup_key == InboxCodec.completion_dedup_key(child.tag_key, child.id)
      assert facts.status == :queued
      assert length(step_jobs(loop.ref)) == jobs + 1

      # The next step folds the completion and finishes last, cancelled.
      final = run_step!(loop.ref, ctx: self())
      assert final.status == :cancelled
      assert_received {:projected, %Result.Cancelled{reason: :user_stop}, _row}
      assert stored_envelope(loop.ref).children == %{}
    end

    test "send cargo delivers to the target's inbox with a replay-stable causal key and wakes it" do
      sender = parked_loop!()
      target = parked_loop!()
      target_jobs = length(step_jobs(target.ref))

      {:ok, :appended} =
        LoopHost.append(
          sender.ref,
          Input.message(%{"id" => 1, "actions" => [{:send, target.ref, %{"hello" => true}}]}),
          nil,
          nil
        )

      [%{id: causal_ref}] = inbox_rows(sender.ref)
      assert run_step!(sender.ref).status == :waiting

      assert [row] = inbox_rows(target.ref)
      assert row.dedup_key == "send:#{sender.ref}:#{causal_ref}:0"
      assert TestRepo.get!(Run, target.ref).status == "queued"
      assert length(step_jobs(target.ref)) == target_jobs + 1

      assert [%StoredInput{input: %Input{kind: :message, payload: %{"hello" => true}}}] =
               pending!(target.ref)
    end

    test "a send to a terminal target dead-letters as evidence; a missing target fails the whole commit" do
      sender = parked_loop!()
      gone = parked_loop!()
      {:ok, :appended} = LoopHost.append(gone.ref, Input.message(%{"halt" => "x"}), nil, nil)
      assert run_step!(gone.ref).status == :completed

      {:ok, :appended} =
        LoopHost.append(
          sender.ref,
          Input.message(%{"id" => 1, "actions" => [{:send, gone.ref, %{"late" => true}}]}),
          nil,
          nil
        )

      assert run_step!(sender.ref).status == :waiting
      assert [dead] = Enum.filter(inbox_rows(gone.ref), &(&1.dead_reason == "terminal"))
      assert dead.kind == "message"

      {:ok, :appended} =
        LoopHost.append(
          sender.ref,
          Input.message(%{"id" => 2, "actions" => [{:send, -1, %{}}]}),
          nil,
          nil
        )

      commit = build_commit!(sender.ref)
      assert {:error, {:send_target_not_found, -1}} = LoopHost.apply_step(commit, nil)

      # Nothing committed: the input is still pending for the replay, whose
      # attempts walk the poison path if the target never appears.
      assert TestRepo.get!(Run, sender.ref).status == "running"
      assert Enum.any?(inbox_rows(sender.ref), &is_nil(&1.dead_at))
    end

    test "timer cargo schedules through the seam, fills envelope meta, and retires best-effort" do
      loop = parked_loop!()

      {:ok, :appended} =
        LoopHost.append(
          loop.ref,
          Input.message(%{"id" => 1, "actions" => [{:timer, :poll, 60_000}]}),
          nil,
          nil
        )

      assert run_step!(loop.ref, ctx: self()).status == :waiting

      poll_key = Codec.key(:poll, vocabulary: ScriptedLoop.__loop__(:vocabulary))
      envelope = stored_envelope(loop.ref)
      assert %{"job_id" => job_id} = envelope.timers[poll_key]
      assert TestRepo.get!(Job, job_id).kind == "timer"

      {:ok, :appended} =
        LoopHost.append(
          loop.ref,
          Input.message(%{"id" => 2, "actions" => [{:cancel_timer, :poll}]}),
          nil,
          nil
        )

      assert run_step!(loop.ref, ctx: self()).status == :waiting
      assert_received {:timer_cancelled, ^poll_key, %{"job_id" => ^job_id}}
      assert stored_envelope(loop.ref).timers == %{}
      assert TestRepo.get(Job, job_id) == nil
    end
  end

  ## Child-terminal projection glue

  describe "completion glue" do
    test "matrix row L12: the child's terminal projection appends the completion in the terminal transaction; after_transition wakes" do
      loop = parked_loop!()
      spawn_child!(loop.ref, {:reply, 1})
      [child] = TestRepo.all(from(r in Run, where: r.loop_ref == ^loop.ref))
      jobs = length(step_jobs(loop.ref))

      usage = %Usage{input_tokens: 7, output_tokens: 3}
      {:ok, _} = Protocol.finish(claim!(child.id), Result.completed(output: "ok", usage: usage))

      # Delivery rode the terminal transaction; the wake rode
      # after_transition: queued plus one step job.
      assert [completion] = inbox_rows(loop.ref)
      assert completion.dedup_key == InboxCodec.completion_dedup_key(child.tag_key, child.id)
      assert TestRepo.get!(Run, loop.ref).status == "queued"
      assert length(step_jobs(loop.ref)) == jobs + 1

      # The payload round-trips tag term and result struct.
      assert [%StoredInput{input: input}] = pending!(loop.ref)
      assert {:completed, {:reply, 1}, %Result.Completed{output: "ok"}} = Input.to_callback(input)

      # Exactly-once at source: the terminal is a dead end, and the
      # reconcile-shaped retry of the same key is a duplicate.
      assert {:error, :already_terminal} = Protocol.finish(claim_lease(), Result.completed())

      assert {:ok, :duplicate} =
               LoopHost.append(
                 loop.ref,
                 Input.completed({:reply, 1}, Result.completed(output: "ok")),
                 completion.dedup_key,
                 nil
               )

      # The fold retires the child and aggregates its usage.
      facts = run_step!(loop.ref)
      assert facts.status == :waiting
      assert stored_envelope(loop.ref).children == %{}
      assert facts.usage.input_tokens == 7
    end

    test "glue atomicity: when the terminal projection raises after the append, neither commits" do
      loop = parked_loop!()

      child =
        insert_run!(
          loop_ref: loop.ref,
          tag_key: Codec.key({:reply, 9}, vocabulary: [:reply]),
          kind: "rollout",
          label: "raise:completed"
        )

      lease = claim!(child.id)

      assert_raise RuntimeError, ~r/projection probe/, fn ->
        Protocol.finish(lease, Result.completed(output: "x"))
      end

      assert TestRepo.get!(Run, child.id).status == "running"
      assert inbox_rows(loop.ref) == []
    end

    test "wake is a no-op on a loop that is not parked" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, message(1), nil, nil)
      jobs = length(step_jobs(loop.ref))

      assert :ok = Clementine.Loop.Ecto.wake(LoopHost, loop.ref, nil)
      assert length(step_jobs(loop.ref)) == jobs
      assert TestRepo.get!(Run, loop.ref).status == "queued"
    end
  end

  ## The seam's reads

  describe "pending/3 and bump_attempts/2" do
    test "recipes round-trip codec-encoded payloads: tuple tags, vocabulary atoms, maps, structs" do
      loop = parked_loop!()

      inputs = [
        {Input.message(%{"k" => [1, "x", true], "t" => :note}), "p:1"},
        {Input.completed({:reply, 5}, Result.failed(%Error{message: "boom"})), "p:2"},
        {Input.elapsed({:retry, 9, :note}), "p:3"},
        {Input.input_failed(41, %Error{code: :input_dead_lettered, message: "m"}), "p:4"}
      ]

      for {input, key} <- inputs do
        assert {:ok, :appended} = LoopHost.append(loop.ref, input, key, nil)
      end

      decoded = pending!(loop.ref)
      assert Enum.map(decoded, & &1.input) == Enum.map(inputs, &elem(&1, 0))
      assert Enum.map(decoded, & &1.ref) == decoded |> Enum.map(& &1.ref) |> Enum.sort()
    end

    test "an undecodable payload surfaces as decode_error without failing the fetch or its neighbors" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, message(1), nil, nil)

      TestRepo.insert_all(@inbox, [
        %{loop_ref: loop.ref, kind: "message", payload: %{"payload" => ["a", "ghost"]}}
      ])

      {:ok, :appended} = LoopHost.append(loop.ref, message(3), nil, nil)

      assert [good, bad, also_good] = pending!(loop.ref)
      assert good.decode_error == nil and also_good.decode_error == nil
      assert %Error{code: :undecodable_input, retryable?: false} = bad.decode_error
      assert bad.input.kind == :message
    end

    test "bump_attempts commits independently and pending reports the counter" do
      loop = parked_loop!()
      {:ok, :appended} = LoopHost.append(loop.ref, message(1), nil, nil)
      [%{ref: ref}] = pending!(loop.ref)

      assert :ok = LoopHost.bump_attempts([ref], nil)
      assert :ok = LoopHost.bump_attempts([ref], nil)
      assert [%StoredInput{attempts: 2}] = pending!(loop.ref)
    end
  end

  describe "envelope round-trip" do
    test "recipes round-trip the envelope: state, filled children, timer meta, pending halt, usage" do
      loop = parked_loop!()

      actions = [
        {:run, {:reply, 1}, %{"input" => "a"}},
        {:timer, :poll, 60_000}
      ]

      {:ok, :appended} =
        LoopHost.append(loop.ref, Input.message(%{"id" => 1, "actions" => actions}), nil, nil)

      assert run_step!(loop.ref).status == :waiting

      envelope = stored_envelope(loop.ref)
      assert %Envelope{version: 1, state_version: 1} = envelope
      assert loop_log(loop.ref) == ["init", "message:1"]
      assert [child_ref] = Map.values(envelope.children)
      assert TestRepo.get!(Run, child_ref).kind == "rollout"
      assert [%{"job_id" => _}] = Map.values(envelope.timers)
      assert envelope.pending_halt == nil

      # A halt with that child in flight parks the pending result in the
      # envelope — the open Result position round-trips too. The queued
      # child direct-cancels inside the unit, so its completion already
      # pends and the cascade park downgrades to continue.
      {:ok, :appended} = LoopHost.append(loop.ref, Input.message(%{"halt" => "later"}), nil, nil)
      assert run_step!(loop.ref).status == :queued

      cascading = stored_envelope(loop.ref)
      assert %{result: %Result.Completed{output: "later"}} = cascading.pending_halt
      assert Envelope.cascading?(cascading)
    end
  end

  ## Harness

  defp spec(opts) do
    %{
      module: ScriptedLoop,
      scope: Keyword.get(opts, :scope, unique_scope()),
      args: Keyword.get(opts, :args, %{}),
      attrs: Keyword.get(opts, :attrs, %{})
    }
  end

  defp unique_scope, do: "test:#{System.unique_integer([:positive])}"

  defp message(id), do: Input.message(%{"id" => id})

  # Creates a loop and runs its first step (init) to the park — the ground
  # state most scenarios start from.
  defp parked_loop!(opts \\ []) do
    {:ok, facts} = LoopProtocol.create(LoopHost, spec(opts))

    case run_step!(facts.ref) do
      %{status: :waiting} = parked -> parked
      other -> other
    end
  end

  defp claim!(ref) do
    {:ok, lease} = Protocol.claim(Lifecycle, ref, executor: "test-step", ctx: self())
    Process.put(:last_lease, lease)
    lease
  end

  defp claim_lease, do: Process.get(:last_lease)

  # One real step, exactly as the step runner will drive the seam:
  # claim -> load -> pending -> plan -> bump -> drain -> apply_step.
  defp run_step!(ref, opts \\ []) do
    {:ok, facts} = LoopHost.apply_step(build_commit!(ref, opts), Keyword.get(opts, :ctx))
    facts
  end

  defp build_commit!(ref, opts \\ []) do
    lease = claim!(ref)
    row = TestRepo.get!(Run, ref)
    envelope = stored_envelope(ref)
    window = LoopHost.pending(ref, Keyword.get(opts, :limit, 20), nil)
    plan = Step.plan(envelope, window, Keyword.get(opts, :plan, []))
    :ok = LoopHost.bump_attempts(plan.bump, nil)

    {:ok, commit} =
      Step.drain(ScriptedLoop, envelope, plan,
        loop_ref: ref,
        epoch: lease.epoch,
        loop_args: row.loop_args || %{}
      )

    commit
  end

  defp spawn_child!(loop_ref, tag) do
    {:ok, :appended} =
      LoopHost.append(
        loop_ref,
        Input.message(%{"id" => "spawn", "actions" => [{:run, tag, %{"input" => "go"}}]}),
        nil,
        nil
      )

    assert run_step!(loop_ref).status == :waiting
  end

  defp drain_to_park!(ref, budget) do
    assert budget > 0, "loop failed to quiesce"

    case TestRepo.get!(Run, ref).status do
      "waiting" -> :ok
      "queued" -> run_step!(ref) && drain_to_park!(ref, budget - 1)
    end
  end

  # The envelope stores state codec-encoded; assertions read it decoded.
  defp loop_log(ref) do
    vocab = ScriptedLoop.__loop__(:vocabulary)
    state = Codec.decode(stored_envelope(ref).state, vocabulary: vocab)
    state["log"]
  end

  defp stored_envelope(ref) do
    case TestRepo.get!(Run, ref).envelope do
      nil ->
        nil

      data ->
        {:ok, envelope} = Envelope.decode(data)
        envelope
    end
  end

  defp pending!(ref), do: LoopHost.pending(ref, 50, nil)

  defp inbox_rows(loop_ref) do
    TestRepo.all(
      from(i in @inbox,
        where: i.loop_ref == ^loop_ref,
        order_by: i.id,
        select: %{
          id: i.id,
          kind: i.kind,
          payload: i.payload,
          dedup_key: i.dedup_key,
          attempts: i.attempts,
          dead_at: i.dead_at,
          dead_reason: i.dead_reason
        }
      )
    )
  end

  defp step_jobs(ref) do
    TestRepo.all(from(j in Job, where: j.run_ref == ^ref and j.kind == "step"))
  end

  defp exhaust_attempts(inbox_id) do
    TestRepo.update_all(from(i in @inbox, where: i.id == ^inbox_id), set: [attempts: 3])
  end
end
