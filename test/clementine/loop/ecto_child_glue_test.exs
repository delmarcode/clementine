defmodule Clementine.Loop.EctoChildGlueTest do
  @moduledoc """
  The child glue, end-to-end (LOOP_RFC §Children): children are real
  rollout runs — constructed through `Clementine.Loop.Ecto.build_child_run/4`
  from the job's durable args, executed by `Clementine.Runner.execute/2`
  against the mock-streamed provider, terminalized through the lifecycle's
  projection — and their completions, interrupts, and usage flow back into
  the parent loop through the shipped glue alone. Matrix rows L5, L11, and
  L12 run here with real children; `Clementine.LoopCase` proves the same
  rows' pure interleavings (the in-fold dedup, the manufactured zombie)
  host-agnostically.
  """

  use Clementine.EctoCase, async: false

  import Ecto.Query
  import Mox

  alias Clementine.{InterruptReason, Lease, Reconciler, Result, Usage}
  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.Loop
  alias Clementine.Loop.Ecto, as: LoopEcto
  alias Clementine.Loop.Ecto.Codec, as: InboxCodec
  alias Clementine.Loop.Protocol, as: LoopProtocol
  alias Clementine.Loop.Runner, as: LoopRunner
  alias Clementine.Loop.{Codec, Envelope, Input, Step}
  alias Clementine.Reconciler.Policy
  alias Clementine.Runner
  alias Clementine.Test.ChildGlueLoop
  alias Clementine.Test.Ecto.{Job, Lifecycle, LoopHost}

  setup :verify_on_exit!

  describe "build_child_run/4 (the child worker seam)" do
    test "constructs the run from the job's durable identifiers" do
      ref = parked!()
      append!(ref, Input.message(%{"reply_to" => 9, "input" => "hello"}))
      assert {:parked, _} = step!(ref)

      {:ok, child_ref} = LoopProtocol.child_ref(LoopHost, ref, {:reply, 9}, ctx: self())
      assert [%Job{run_ref: ^child_ref, args: args}] = child_jobs!(ref)

      # The durable args crossed the job whole: JSON-safe, cursor included
      # — history flows by cursor, never as envelope transcripts.
      assert args == %{"input" => "hello", "history_through" => 0}

      assert {:ok, %Clementine.Run{ref: ^child_ref, metadata: metadata}} =
               LoopEcto.build_child_run(LoopHost, child_ref, args, self())

      assert metadata == %{loop_ref: ref, tag: {:reply, 9}}

      # The host's build_child/4 received the child's own facts and the
      # tag decoded from the stored tag_key under the parent's vocabulary.
      assert_received {:build_child, %Facts{ref: ^child_ref, kind: :rollout, status: :queued},
                       {:reply, 9}, ^args}
    end

    test "refuses rows that are not a loop's children" do
      assert {:error, :not_found} = LoopEcto.build_child_run(LoopHost, -1, %{}, self())

      plain = insert_run!()
      assert {:error, :not_loop_child} = LoopEcto.build_child_run(LoopHost, plain.id, %{}, self())

      loop = parked!()
      assert {:error, :not_loop_child} = LoopEcto.build_child_run(LoopHost, loop, %{}, self())
    end

    test "a cascade-cancelled child's late job discards at the claim" do
      ref = parked!()
      append!(ref, Input.message(%{"reply_to" => 4, "input" => "doomed"}))
      assert {:parked, _} = step!(ref)
      [job] = child_jobs!(ref)

      # Cancel the loop: the cascade direct-terminalizes the queued child
      # inside the step's own unit and finishes cancelled behind it.
      assert {:ok, :flagged} = LoopProtocol.cancel(LoopHost, ref, :stop, ctx: self())
      quiesce!(ref)
      assert fetch!(ref).status == :cancelled
      assert fetch!(job.run_ref).status == :cancelled

      # The job fires late — the documented worker posture: the build
      # still succeeds, the claim discards, the worker acks.
      assert {:discard, {:not_claimable, :cancelled}} = run_child_job!(job)
    end
  end

  describe "Loop.Protocol.child_ref/3" do
    test "correlation lifetime and refusals" do
      ref = create_loop!()

      # No envelope before the first commit, no children after it: both
      # are the truthful :no_child, not failures.
      assert {:error, :no_child} = LoopProtocol.child_ref(LoopHost, ref, {:reply, 1}, ctx: self())
      assert {:parked, _} = step!(ref)
      assert {:error, :no_child} = LoopProtocol.child_ref(LoopHost, ref, {:reply, 1}, ctx: self())

      assert {:error, :not_found} = LoopProtocol.child_ref(LoopHost, -1, {:reply, 1}, ctx: self())

      plain = insert_run!()

      assert {:error, :rollout_run} =
               LoopProtocol.child_ref(LoopHost, plain.id, {:reply, 1}, ctx: self())

      # A tag outside the loop's declared vocabulary is the caller's
      # contract violation — loud at the call, exactly like encoding.
      assert_raise ArgumentError, fn ->
        LoopProtocol.child_ref(LoopHost, ref, {:undeclared, 1}, ctx: self())
      end
    end
  end

  test "matrix row L5 end-to-end: fast child completes during the parent's crash window; replay delivers once" do
    ref = parked!()
    append!(ref, Input.message(%{"reply_to" => 1, "input" => "hi"}))
    assert {:parked, _} = step!(ref)

    # The spawn committed as cargo: child row, its job, and the envelope's
    # (tag_key -> ref) correlation, one atomic unit.
    assert {:ok, child_ref} = LoopProtocol.child_ref(LoopHost, ref, {:reply, 1}, ctx: self())
    assert [%Job{run_ref: ^child_ref}] = child_jobs!(ref)

    # The child is fast — a real run: build_child_run -> Runner.execute,
    # terminal projection appends the completion, the wake queues the
    # parent.
    expect_child_stream("hi there")
    assert [{:finished, %Facts{status: :completed}}] = run_pending_children!(ref)
    assert_received {:projected, %Result.Completed{output: "hi there"} = child_result, _row}
    assert fetch!(ref).status == :queued

    # The crash window: the parent's consuming step claims and the VM
    # dies. Nothing durable moved; the reaper requeues (A3a — always for
    # loop-kind, no epoch cap).
    _lost = claim!(ref, "child-glue:crashed")
    {:ok, _} = Protocol.requeue(Lifecycle, fetch!(ref), :lease_expired, self())

    # The reconcile belt racing the real delivery: the synthesized append
    # no-ops on the canonical key while the real row pends.
    dedup = completion_dedup(ref, {:reply, 1}, child_ref)
    ghost = Input.completed({:reply, 1}, Result.completed(output: "ghost"))
    assert {:ok, :duplicate} = LoopHost.append(ref, ghost, dedup, self())

    # The replay drains the completion exactly once: delivered once,
    # dropped never.
    assert {:parked, _} = step!(ref)
    assert log!(ref) == ["init", "spawn:1", "completed:1:hi there"]
    assert envelope!(ref).children == %{}
    assert envelope!(ref).usage == %Usage{input_tokens: 7, output_tokens: 3}
    assert state!(ref)["cursor"] == length(child_result.messages)
    assert {:error, :no_child} = LoopProtocol.child_ref(LoopHost, ref, {:reply, 1}, ctx: self())

    # Post-consumption the dedup row is gone (consumed rows delete) — the
    # envelope guards instead: a late duplicate dead-letters as
    # :unknown_tag, never reaching handle/2, never silently dropped
    # (Governing Invariant 11).
    assert {:ok, :appended} = LoopHost.append(ref, ghost, dedup, self())
    assert {:parked, _} = step!(ref)
    assert log!(ref) == ["init", "spawn:1", "completed:1:hi there"]
    assert [%{dedup_key: ^dedup, dead_reason: "unknown_tag"}] = dead_letters!(ref)
  end

  test "matrix row L11 end-to-end: zombie step cannot re-dispatch a real child" do
    ref = parked!()
    append!(ref, Input.message(%{"reply_to" => 7, "input" => "case 11"}))

    # The zombie: claims, drains to a commit value carrying spawn cargo,
    # and stalls mid-step.
    zombie = claim!(ref, "child-glue:zombie")
    stale_commit = manual_commit!(ref, zombie)
    assert [_spawn_spec] = stale_commit.children

    # The reaper supersedes the stalled execution (A3a requeue), and the
    # successor commits the identical drain for real: one child, running
    # end-to-end to its completion fold.
    {:ok, _} = Protocol.requeue(Lifecycle, fetch!(ref), :lease_expired, self())
    assert {:parked, _} = step!(ref)
    {:ok, child_ref} = LoopProtocol.child_ref(LoopHost, ref, {:reply, 7}, ctx: self())

    expect_child_stream("zombie-proof")
    assert [{:finished, %Facts{status: :completed}}] = run_pending_children!(ref)
    assert {:parked, _} = step!(ref)
    assert log!(ref) == ["init", "spawn:7", "completed:7:zombie-proof"]

    # The zombie wakes at the worst moment — the child already terminal,
    # its tag freed by the where-active index — and dies at the fence:
    # the lifecycle CAS, ahead of any cargo, is what makes re-dispatch
    # impossible (nothing new was written).
    assert {:error, :stale} = LoopHost.apply_step(stale_commit, self())

    tag_key = tag_key({:reply, 7})

    assert [%Run{id: ^child_ref}] =
             TestRepo.all(from(r in Run, where: r.loop_ref == ^ref and r.tag_key == ^tag_key))

    assert child_jobs!(ref) == []
    assert envelope!(ref).children == %{}
    assert log!(ref) == ["init", "spawn:7", "completed:7:zombie-proof"]
  end

  test "matrix row L12 end-to-end: reaper-interrupted child delivers through the identical projection path" do
    ref = parked!()
    append!(ref, Input.message(%{"reply_to" => 3, "input" => "first try"}))
    assert {:parked, _} = step!(ref)
    {:ok, child_ref} = LoopProtocol.child_ref(LoopHost, ref, {:reply, 3}, ctx: self())

    # A pod claims the child and dies mid-run: stale heartbeat, no write.
    assert {:ok, %Lease{}} = Protocol.claim(Lifecycle, child_ref, executor: "pod-1", ctx: self())
    child = fetch!(child_ref)
    assert child.status == :running

    # The reaper's verdict past the stale threshold is an interrupt — a
    # terminal transition WITH a projection: the identical completion
    # path a finishing child takes, usage attached.
    policy = Policy.new()
    overdue = DateTime.add(child.heartbeat_at, policy.stale_after + 1_000, :millisecond)
    assert {:interrupt, %InterruptReason{} = reason} = Reconciler.judge(child, overdue, policy)

    assert {:ok, %Facts{status: :interrupted}} =
             Protocol.interrupt(Lifecycle, child, reason, self())

    assert_received {:projected, %Result.Interrupted{}, %Run{id: ^child_ref}}

    # Exactly-once at source, :reconcile_children as belt: the
    # synthesized append no-ops on the canonical key.
    dedup = completion_dedup(ref, {:reply, 3}, child_ref)
    synthesized = Input.completed({:reply, 3}, Result.interrupted(fetch!(child_ref).interrupt))
    assert {:ok, :duplicate} = LoopHost.append(ref, synthesized, dedup, self())

    # The parent decides — the thread-agent posture: retry, immediately.
    assert fetch!(ref).status == :queued
    assert {:parked, _} = step!(ref)
    assert log!(ref) == ["init", "spawn:3", "interrupted:3"]
    {:ok, retry_ref} = LoopProtocol.child_ref(LoopHost, ref, {:retry, 3}, ctx: self())
    assert retry_ref != child_ref

    # The interrupted child's stale job fires late and discards; the
    # retry child runs for real and its completion folds.
    expect_child_stream("recovered")

    assert [{:discard, {:not_claimable, :interrupted}}, {:finished, %Facts{status: :completed}}] =
             run_pending_children!(ref)

    assert {:parked, _} = step!(ref)
    assert log!(ref) == ["init", "spawn:3", "interrupted:3", "retried:3:recovered"]
    assert envelope!(ref).children == %{}
    assert envelope!(ref).usage == %Usage{input_tokens: 7, output_tokens: 3}
    assert {:error, :no_child} = LoopProtocol.child_ref(LoopHost, ref, {:reply, 3}, ctx: self())
  end

  test "usage aggregation end-to-end: real child usage folds into the envelope, the terminal result, and the billing grain" do
    ref = parked!()
    append!(ref, Input.message(%{"reply_to" => 1, "input" => "one"}))
    append!(ref, Input.message(%{"reply_to" => 2, "input" => "two"}))

    # One drain, two spawns: fan-out is unconstrained by the machinery —
    # the (loop_ref, tag_key) index is dedup, NOT single-active.
    assert {:parked, _} = step!(ref)
    {:ok, ref_1} = LoopProtocol.child_ref(LoopHost, ref, {:reply, 1}, ctx: self())
    {:ok, ref_2} = LoopProtocol.child_ref(LoopHost, ref, {:reply, 2}, ctx: self())
    assert ref_1 != ref_2

    expect_child_stream("first", %{"input_tokens" => 7, "output_tokens" => 3})
    expect_child_stream("second", %{"input_tokens" => 11, "output_tokens" => 5})
    assert [{:finished, _}, {:finished, _}] = run_pending_children!(ref)

    quiesce!(ref)
    assert envelope!(ref).usage == %Usage{input_tokens: 18, output_tokens: 8}
    assert fetch!(ref).usage == %Usage{input_tokens: 18, output_tokens: 8}

    # The billing grain the migration documents: every token already sits
    # on its child's own row — summing kind = 'rollout' rows counts each
    # exactly once...
    children_usage =
      from(r in Run, where: r.loop_ref == ^ref and r.kind == "rollout")
      |> TestRepo.all()
      |> Enum.map(& &1.usage)
      |> Enum.reduce(%Usage{}, &Usage.add(&2, &1))

    assert children_usage == %Usage{input_tokens: 18, output_tokens: 8}

    # ...while a query that forgets the kind guard bills every token twice.
    assert Usage.add(children_usage, fetch!(ref).usage) ==
             %Usage{input_tokens: 36, output_tokens: 16}

    # The halt's terminal carries the machinery-aggregated usage.
    append!(ref, Input.message(%{"halt" => "done"}))
    assert {:finished, %Facts{status: :completed}} = step!(ref)

    assert_received {:projected,
                     %Result.Completed{
                       output: "done",
                       usage: %Usage{input_tokens: 18, output_tokens: 8}
                     }, %Run{id: ^ref}}
  end

  ## Harness

  defp create_loop!(args \\ %{}) do
    spec = %{
      module: ChildGlueLoop,
      scope: "child-glue:#{System.unique_integer([:positive])}",
      args: args
    }

    {:ok, %Facts{} = facts} = LoopProtocol.create(LoopHost, spec, ctx: self())
    facts.ref
  end

  defp parked!(args \\ %{}) do
    ref = create_loop!(args)
    assert {:parked, %Facts{status: :waiting}} = step!(ref)
    ref
  end

  defp step!(ref) do
    LoopRunner.step(ref,
      host: LoopHost,
      lifecycle: Lifecycle,
      executor_id: "child-glue:step:#{System.unique_integer([:positive])}",
      ctx: self()
    )
  end

  defp quiesce!(ref, budget \\ 10) do
    case fetch!(ref).status do
      :queued when budget > 0 ->
        step!(ref)
        quiesce!(ref, budget - 1)

      :queued ->
        flunk("loop #{inspect(ref)} failed to quiesce")

      _settled ->
        :ok
    end
  end

  defp claim!(ref, executor) do
    {:ok, %Lease{} = lease} = Protocol.claim(Lifecycle, ref, executor: executor, ctx: self())
    lease
  end

  defp fetch!(ref) do
    {:ok, %Facts{} = facts} = Lifecycle.fetch(ref, self())
    facts
  end

  defp append!(ref, %Input{} = input) do
    assert {:ok, :appended} = LoopHost.append(ref, input, nil, self())
  end

  # The child worker, as host code would write it: the job's durable
  # identifiers through build_child_run/4 into Runner.execute/2, then ack.
  defp run_child_job!(%Job{} = job) do
    {:ok, run} = LoopEcto.build_child_run(LoopHost, job.run_ref, job.args, self())

    outcome =
      Runner.execute(run,
        lifecycle: Lifecycle,
        ctx: self(),
        executor_id: "child-glue:child:#{job.run_ref}",
        heartbeat: false
      )

    TestRepo.delete!(job)
    outcome
  end

  defp run_pending_children!(loop_ref) do
    loop_ref |> child_jobs!() |> Enum.map(&run_child_job!/1)
  end

  defp child_jobs!(loop_ref) do
    child_ids = TestRepo.all(from(r in Run, where: r.loop_ref == ^loop_ref, select: r.id))

    TestRepo.all(
      from(j in Job, where: j.kind == "child" and j.run_ref in ^child_ids, order_by: j.id)
    )
  end

  defp expect_child_stream(text, usage \\ %{"input_tokens" => 7, "output_tokens" => 3}) do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      [
        {:text_delta, text},
        {:message_delta, %{"stop_reason" => "end_turn"}, usage}
      ]
    end)
  end

  # One manufactured step mirroring the runner's phases (load under the
  # fence, window, plan, bump, drain), returning the StepCommit unapplied
  # — the zombie's held value.
  defp manual_commit!(ref, %Lease{} = lease) do
    {:ok, loaded} = LoopHost.load(ref, self())
    {:ok, module} = Loop.resolve(loaded.module)
    envelope = decode_envelope!(loaded.envelope)
    batch_cap = Step.default_batch_cap()

    window = LoopHost.pending(ref, batch_cap + 1, :any, self())
    plan = Step.plan(envelope, window, batch_cap: batch_cap)
    :ok = LoopHost.bump_attempts(plan.bump, self())

    {:ok, commit} =
      Step.drain(module, envelope, plan,
        loop_ref: ref,
        epoch: lease.epoch,
        loop_args: loaded.args
      )

    commit
  end

  defp envelope!(ref) do
    {:ok, %{envelope: data}} = LoopHost.load(ref, self())
    decode_envelope!(data)
  end

  defp decode_envelope!(nil), do: nil

  defp decode_envelope!(data) do
    {:ok, %Envelope{} = envelope} = Envelope.decode(data)
    envelope
  end

  defp state!(ref) do
    %Envelope{state: state} = envelope!(ref)
    Codec.decode(state, vocabulary: vocab())
  end

  defp log!(ref), do: state!(ref)["log"]

  defp tag_key(tag), do: Codec.key(tag, vocabulary: vocab())

  defp completion_dedup(_loop_ref, tag, child_ref) do
    InboxCodec.completion_dedup_key(tag_key(tag), child_ref)
  end

  defp dead_letters!(loop_ref) do
    TestRepo.all(
      from(i in "clementine_test_loop_inbox",
        where: i.loop_ref == ^loop_ref and not is_nil(i.dead_at),
        select: %{dedup_key: i.dedup_key, dead_reason: i.dead_reason}
      )
    )
  end

  defp vocab, do: ChildGlueLoop.__loop__(:vocabulary)
end
