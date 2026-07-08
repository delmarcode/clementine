defmodule Clementine.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.Reconciler
  alias Clementine.Reconciler.{LoopEvidence, Policy}
  alias Clementine.Test.MemoryLifecycle

  alias Clementine.{
    ApprovalRequest,
    InterruptReason,
    Pending,
    Result,
    Suspension,
    Usage
  }

  # Judgment is pure; every test pins the clock and derives stamps from it.
  @now ~U[2026-07-06 12:00:00.000000Z]

  defp ago(ms), do: DateTime.add(@now, -ms, :millisecond)

  defp running(overrides) do
    struct!(
      %Facts{ref: "r", status: :running, epoch: 1, executor_id: "x", heartbeat_at: @now},
      overrides
    )
  end

  defp loop_running(overrides) do
    struct!(
      %Facts{
        ref: "l",
        kind: :loop,
        status: :running,
        epoch: 1,
        executor_id: "x",
        heartbeat_at: @now
      },
      overrides
    )
  end

  defp loop_queued(overrides) do
    struct!(%Facts{ref: "l", kind: :loop, status: :queued, epoch: 3, queued_at: @now}, overrides)
  end

  defp loop_waiting(overrides \\ []) do
    struct!(%Facts{ref: "l", kind: :loop, status: :waiting, epoch: 3, queued_at: @now}, overrides)
  end

  defp child(tag_key, overrides \\ []) do
    Map.merge(
      %{
        tag_key: tag_key,
        child_ref: "run-" <> tag_key,
        terminal?: false,
        completion_present?: false
      },
      Map.new(overrides)
    )
  end

  # Async siblings (the property battery) also emit verdict events, so the
  # telemetry assertions pin a per-test unique ref.
  defp unique_loop(status, overrides) do
    struct!(%Facts{ref: make_ref(), kind: :loop, status: status, epoch: 7}, overrides)
  end

  describe "judge/3 on running runs" do
    test "matrix row 12: heartbeats inside the stale threshold are healthy — a database blip is not a reap" do
      # Default threshold is 2 minutes: eight missed 15-second beats.
      assert Reconciler.judge(running(heartbeat_at: ago(119_000)), @now) == :healthy

      # The boundary itself is not stale; staleness is strictly beyond it.
      assert Reconciler.judge(running(heartbeat_at: ago(120_000)), @now) == :healthy
    end

    test "matrix row 14: killed between claim and first heartbeat — the claim's own stamp ages past the threshold" do
      # heartbeat_at is stamped at claim, so a runner that dies immediately
      # is judged from claim time; no beat ever happening is not special.
      verdict = Reconciler.judge(running(heartbeat_at: ago(121_000)), @now)

      assert {:interrupt, %InterruptReason{code: :lease_expired}} = verdict
    end

    test "matrix row 9: the reaper backstop interrupts a fresh-heartbeat run past deadline + grace" do
      facts = running(heartbeat_at: @now, deadline: ago(121_000))

      assert {:interrupt, %InterruptReason{code: :deadline_exceeded}} =
               Reconciler.judge(facts, @now)

      # Within grace the runner still gets to self-report :deadline_exceeded.
      assert Reconciler.judge(running(heartbeat_at: @now, deadline: ago(119_000)), @now) ==
               :healthy

      # No deadline, no deadline verdict — deadlines are optional.
      assert Reconciler.judge(running(heartbeat_at: @now, deadline: nil), @now) == :healthy
    end

    test "a stale heartbeat outranks the deadline backstop" do
      facts = running(heartbeat_at: ago(200_000), deadline: ago(300_000))

      assert {:interrupt, %InterruptReason{code: :lease_expired}} =
               Reconciler.judge(facts, @now)
    end

    test "matrix row 18: stale with the fence unset and policy opted in requeues; the epoch caps attempts" do
      policy = Policy.new(retry: {:requeue, max_claims: 3})
      stale = [heartbeat_at: ago(121_000)]

      # Epochs 1 and 2 have headroom under max_claims: 3.
      assert Reconciler.judge(running(stale ++ [epoch: 1]), @now, policy) ==
               {:requeue, :lease_expired}

      assert Reconciler.judge(running(stale ++ [epoch: 2]), @now, policy) ==
               {:requeue, :lease_expired}

      # The epoch counts claims, so it is the attempt counter: at the cap,
      # the verdict falls back to interrupt.
      assert {:interrupt, %InterruptReason{code: :lease_expired}} =
               Reconciler.judge(running(stale ++ [epoch: 3]), @now, policy)

      # The effect fence refuses re-execution no matter the policy.
      assert {:interrupt, %InterruptReason{code: :lease_expired}} =
               Reconciler.judge(running(stale ++ [epoch: 1, effects?: true]), @now, policy)

      # And the default posture never requeues at all.
      assert {:interrupt, %InterruptReason{code: :lease_expired}} =
               Reconciler.judge(running(stale ++ [epoch: 1]), @now, Policy.new())
    end
  end

  describe "judge/3 on queued runs" do
    test "queued past the claim timeout is :claim_timeout — the claimer never came" do
      queued = %Facts{ref: "r", status: :queued, epoch: 0, queued_at: ago(901_000)}

      assert {:interrupt, %InterruptReason{code: :claim_timeout}} =
               Reconciler.judge(queued, @now)

      fresh = %Facts{ref: "r", status: :queued, epoch: 0, queued_at: ago(899_000)}
      assert Reconciler.judge(fresh, @now) == :healthy
    end

    test "queued_at is re-stamped at resume and requeue, so re-entries get a fresh window" do
      # A run at epoch 3 (two prior executions) whose queued_at was just
      # re-stamped is as healthy as a first enqueue.
      resumed = %Facts{ref: "r", status: :queued, epoch: 3, queued_at: ago(1_000)}
      assert Reconciler.judge(resumed, @now, Policy.new(claim_timeout: 60_000)) == :healthy
    end
  end

  describe "judge/3 on waiting runs" do
    test "matrix row 15: the default policy has no ceiling — a suspension leaves waiting only by explicit policy" do
      thirty_days = 30 * 24 * 60 * 60 * 1000
      waiting = %Facts{ref: "r", status: :waiting, epoch: 1, queued_at: ago(thirty_days)}

      assert Reconciler.judge(waiting, @now) == :healthy
    end

    test "matrix row 15: an explicit max_wait ceiling expires an overdue suspension" do
      policy = Policy.new(max_wait: :timer.hours(24))
      overdue = %Facts{ref: "r", status: :waiting, epoch: 1, queued_at: ago(:timer.hours(25))}

      assert {:interrupt, %InterruptReason{code: :suspension_expired}} =
               Reconciler.judge(overdue, @now, policy)

      within = %Facts{ref: "r", status: :waiting, epoch: 1, queued_at: ago(:timer.hours(23))}
      assert Reconciler.judge(within, @now, policy) == :healthy
    end

    test "waiting is never judged by heartbeat or deadline evidence" do
      # Nonconforming facts carrying execution stamps a waiting run cannot
      # have: the reaper's scoping must ignore them, not reap on them.
      adversarial = %Facts{
        ref: "r",
        status: :waiting,
        epoch: 1,
        heartbeat_at: ago(:timer.hours(2)),
        deadline: ago(:timer.hours(1)),
        queued_at: ago(:timer.minutes(5))
      }

      assert Reconciler.judge(adversarial, @now) == :healthy
    end
  end

  describe "judge/3 on terminal runs" do
    test "terminal facts are always healthy — nothing left to judge" do
      for status <- Facts.terminal_statuses() do
        facts = %Facts{
          ref: "r",
          status: status,
          epoch: 4,
          heartbeat_at: ago(:timer.hours(9)),
          queued_at: ago(:timer.hours(9)),
          finished_at: ago(:timer.hours(8))
        }

        assert Reconciler.judge(facts, @now) == :healthy
      end
    end
  end

  describe "judge/3 forks by kind (amendment A3)" do
    test "matrix row L16: a stale 1000-epoch loop requeues under the default policy — longevity is not a death sentence" do
      stale = loop_running(heartbeat_at: ago(121_000), epoch: 1000)

      # retry: :never and no max_claims headroom anywhere in sight: the
      # rollout gates are not consulted for loop-kind facts.
      assert Reconciler.judge(stale, @now) == {:requeue, :lease_expired}

      assert Reconciler.judge(stale, @now, Policy.new(retry: {:requeue, max_claims: 3})) ==
               {:requeue, :lease_expired}

      # The same evidence at the same epoch interrupts a rollout: the cap
      # is spent. That is exactly the verdict a loop must never receive.
      rollout = running(heartbeat_at: ago(121_000), epoch: 1000)

      assert {:interrupt, %InterruptReason{code: :lease_expired}} =
               Reconciler.judge(rollout, @now, Policy.new(retry: {:requeue, max_claims: 3}))
    end

    test "the effect fence is rollout vocabulary — a nonconforming fence-set loop still requeues" do
      # No loop step ever calls mark_effects; a set fence is a host bug.
      # The verdict must not convert that bug into a dead loop.
      stale = loop_running(heartbeat_at: ago(121_000), effects?: true)

      assert Reconciler.judge(stale, @now) == {:requeue, :lease_expired}
    end

    test "a running loop with no heartbeat stamp requeues rather than interrupts" do
      assert Reconciler.judge(loop_running(heartbeat_at: nil), @now) ==
               {:requeue, :lease_expired}
    end

    test "a fresh heartbeat inside the threshold is healthy for loops too" do
      assert Reconciler.judge(loop_running(heartbeat_at: ago(119_000)), @now) == :healthy
    end

    test "the fresh-heartbeat deadline belt is unamended: a live-wedged step still interrupts" do
      # Steps are short by construction; a fresh heartbeat past
      # deadline + grace is a live-wedged step runner, the one failure a
      # requeue cannot heal — without this belt it would hold the lease,
      # and the loop, forever.
      wedged = loop_running(heartbeat_at: @now, deadline: ago(121_000))

      assert {:interrupt, %InterruptReason{code: :deadline_exceeded}} =
               Reconciler.judge(wedged, @now)

      assert Reconciler.judge(loop_running(heartbeat_at: @now, deadline: ago(119_000)), @now) ==
               :healthy

      # Stale evidence outranks the deadline, exactly as for rollouts —
      # and for a loop that means requeue, not death.
      dead = loop_running(heartbeat_at: ago(200_000), deadline: ago(300_000))
      assert Reconciler.judge(dead, @now) == {:requeue, :lease_expired}
    end

    test "matrix row L15: a queued loop past the claim timeout reenqueues — it never dies of :claim_timeout" do
      lost = loop_queued(queued_at: ago(901_000))

      assert Reconciler.judge(lost, @now) == {:reenqueue, :claim_timeout}
      assert Reconciler.judge(loop_queued(queued_at: ago(899_000)), @now) == :healthy

      # A missing stamp is nonconforming; the answer is still never
      # terminal on claim evidence.
      assert Reconciler.judge(loop_queued(queued_at: nil), @now) ==
               {:reenqueue, :claim_timeout}
    end

    test "matrix row L15: the reenqueue verdict is not a transition — the row is untouched and the next claim just works" do
      store = MemoryLifecycle.start_store()
      MemoryLifecycle.seed_queued(store, "loop", kind: :loop, queued_at: ago(901_000))
      observed = MemoryLifecycle.facts!(store, "loop")

      assert Reconciler.judge(observed, @now) == {:reenqueue, :claim_timeout}

      # The host's whole action is re-inserting the step job; when that
      # job runs, the ordinary claim is the recovery.
      assert MemoryLifecycle.facts!(store, "loop") == observed
      assert {:ok, lease} = Protocol.claim(MemoryLifecycle, "loop", executor: "e", ctx: store)
      assert lease.epoch == observed.epoch + 1
    end

    test "waiting loops are exempt from max_wait — parked is the ground state, not an overdue suspension" do
      policy = Policy.new(max_wait: :timer.hours(24))
      month = 30 * 24 * 60 * 60 * 1000
      parked = loop_waiting(queued_at: ago(month))

      assert Reconciler.judge(parked, @now, policy) == :healthy

      # The identical facts as a rollout expire: the exemption is the fork.
      overdue = struct!(parked, kind: :rollout)

      assert {:interrupt, %InterruptReason{code: :suspension_expired}} =
               Reconciler.judge(overdue, @now, policy)
    end

    test "terminal loops are healthy — nothing left to judge" do
      for status <- Facts.terminal_statuses() do
        facts = %Facts{ref: "l", kind: :loop, status: status, epoch: 40, queued_at: ago(1)}
        assert Reconciler.judge(facts, @now) == :healthy
      end
    end
  end

  describe "judge_loop/4 on parked loops (amendment A3c)" do
    test "matrix row L13: a terminal child with no completion input is a strand — the sweep synthesizes what delivery lost" do
      evidence = %LoopEvidence{
        children: [
          child("turn-1", terminal?: true),
          child("turn-2"),
          child("turn-3", terminal?: true, completion_present?: true)
        ]
      }

      assert Reconciler.judge_loop(loop_waiting(), evidence, @now, Policy.new()) ==
               {:reconcile_children, [%{tag_key: "turn-1", child_ref: "run-turn-1"}]}
    end

    test "matrix row L13 (the Postgres-normal case): every terminal child's completion is present — healthy, the alarm stays silent" do
      # completion_present? covers pending, consumed-but-marked, and
      # dead-lettered rows alike: a retained poison completion is present,
      # and re-synthesizing it would only re-poison.
      evidence = %LoopEvidence{
        children: [
          child("turn-1", terminal?: true, completion_present?: true),
          child("turn-2")
        ]
      }

      assert Reconciler.judge_loop(loop_waiting(), evidence, @now, Policy.new()) == :healthy
    end

    test "matrix row L4 backstop: unconsumed inputs older than the threshold wake a parked loop" do
      policy = Policy.new(wake_pending_after: :timer.minutes(5))

      stale = %LoopEvidence{oldest_pending_at: ago(:timer.minutes(5) + 1)}

      assert Reconciler.judge_loop(loop_waiting(), stale, @now, policy) ==
               {:wake_pending, :stale_inputs}

      # The boundary itself is healthy — strictly beyond, like every age
      # check in this module.
      boundary = %LoopEvidence{oldest_pending_at: ago(:timer.minutes(5))}
      assert Reconciler.judge_loop(loop_waiting(), boundary, @now, policy) == :healthy

      assert Reconciler.judge_loop(loop_waiting(), %LoopEvidence{}, @now, policy) == :healthy
    end

    test "reconcile outranks wake_pending — reconciliation's append wakes the loop anyway" do
      evidence = %LoopEvidence{
        children: [child("turn-1", terminal?: true)],
        oldest_pending_at: ago(:timer.hours(2))
      }

      assert {:reconcile_children, _strands} =
               Reconciler.judge_loop(loop_waiting(), evidence, @now, Policy.new())
    end

    test "no evidence gathered means no evidence verdicts" do
      assert Reconciler.judge_loop(loop_waiting(), nil, @now, Policy.new()) == :healthy
    end

    test "running and queued loops ignore evidence — their checks read facts alone" do
      evidence = %LoopEvidence{
        children: [child("turn-1", terminal?: true)],
        oldest_pending_at: ago(:timer.hours(2))
      }

      stale = loop_running(heartbeat_at: ago(121_000))

      assert Reconciler.judge_loop(stale, evidence, @now, Policy.new()) ==
               {:requeue, :lease_expired}

      lost = loop_queued(queued_at: ago(901_000))

      assert Reconciler.judge_loop(lost, evidence, @now, Policy.new()) ==
               {:reenqueue, :claim_timeout}
    end

    test "judge_loop refuses rollout facts — the loop sweep is kind-scoped by contract" do
      assert_raise FunctionClauseError, fn ->
        Reconciler.judge_loop(running(heartbeat_at: @now), nil, @now, Policy.new())
      end
    end
  end

  describe "matrix row L16, acted through the protocol" do
    test "matrix row L16: a 1000-epoch loop crash requeues and reclaims — the epoch is a lifetime, not a budget" do
      store = MemoryLifecycle.start_store()
      MemoryLifecycle.seed_queued(store, "loop", kind: :loop)

      # A thousand executions, each crashing without a terminal write:
      # claim, go stale, get judged, requeue. Default policy throughout.
      for expected_epoch <- 1..1000 do
        {:ok, lease} = Protocol.claim(MemoryLifecycle, "loop", executor: "e", ctx: store)
        assert lease.epoch == expected_epoch

        observed = MemoryLifecycle.facts!(store, "loop")
        sweep_now = DateTime.add(observed.heartbeat_at, 180_000, :millisecond)

        assert {:requeue, :lease_expired} = Reconciler.judge(observed, sweep_now)
        {:ok, _requeued} = Protocol.requeue(MemoryLifecycle, observed, :lease_expired, store)
      end

      # The 1001st claim mints as readily as the first, and no terminal
      # projection ever fired: the loop lived through every crash.
      {:ok, lease} = Protocol.claim(MemoryLifecycle, "loop", executor: "e", ctx: store)
      assert lease.epoch == 1001
      assert MemoryLifecycle.projections(store) == []
    end
  end

  describe "loop verdict telemetry (the firing-rate seam)" do
    setup do
      handler_id = "reconciler-test-#{inspect(self())}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:clementine, :loop, :verdict],
        fn event, measurements, metadata, _config ->
          send(parent, {:verdict_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "every non-healthy loop verdict emits [:clementine, :loop, :verdict] with the verdict and its detail" do
      stale = unique_loop(:running, heartbeat_at: ago(121_000))
      assert {:requeue, :lease_expired} = Reconciler.judge(stale, @now)
      ref = stale.ref

      assert_receive {:verdict_event, [:clementine, :loop, :verdict], %{},
                      %{loop_ref: ^ref, epoch: 7, verdict: :requeue, detail: :lease_expired}}

      lost = unique_loop(:queued, queued_at: ago(901_000))
      assert {:reenqueue, :claim_timeout} = Reconciler.judge(lost, @now)
      ref = lost.ref

      assert_receive {:verdict_event, _, %{},
                      %{loop_ref: ^ref, verdict: :reenqueue, detail: :claim_timeout}}

      stranded = unique_loop(:waiting, queued_at: @now)
      evidence = %LoopEvidence{children: [child("turn-1", terminal?: true)]}
      strands = [%{tag_key: "turn-1", child_ref: "run-turn-1"}]

      assert {:reconcile_children, ^strands} =
               Reconciler.judge_loop(stranded, evidence, @now, Policy.new())

      ref = stranded.ref

      assert_receive {:verdict_event, _, %{},
                      %{loop_ref: ^ref, verdict: :reconcile_children, detail: ^strands}}

      parked = unique_loop(:waiting, queued_at: @now)
      pending = %LoopEvidence{oldest_pending_at: ago(:timer.hours(1))}

      assert {:wake_pending, :stale_inputs} =
               Reconciler.judge_loop(parked, pending, @now, Policy.new())

      ref = parked.ref

      assert_receive {:verdict_event, _, %{},
                      %{loop_ref: ^ref, verdict: :wake_pending, detail: :stale_inputs}}

      wedged = unique_loop(:running, heartbeat_at: @now, deadline: ago(121_000))
      assert {:interrupt, reason} = Reconciler.judge(wedged, @now)
      ref = wedged.ref

      assert_receive {:verdict_event, _, %{},
                      %{loop_ref: ^ref, verdict: :interrupt, detail: ^reason}}
    end

    test "healthy loop judgments emit nothing" do
      healthy = unique_loop(:waiting, queued_at: ago(:timer.hours(720)))
      ref = healthy.ref

      assert Reconciler.judge(healthy, @now) == :healthy
      assert Reconciler.judge_loop(healthy, %LoopEvidence{}, @now, Policy.new()) == :healthy

      refute_receive {:verdict_event, _, _, %{loop_ref: ^ref}}, 50
    end

    test "rollout verdicts never ride the loop event — their rates ride the commit events" do
      rollout = %Facts{ref: make_ref(), status: :running, epoch: 1, heartbeat_at: ago(121_000)}
      ref = rollout.ref

      assert {:interrupt, _reason} = Reconciler.judge(rollout, @now)
      refute_receive {:verdict_event, _, _, %{loop_ref: ^ref}}, 50
    end
  end

  describe "Policy.new/1" do
    test "defaults are Meli's production posture" do
      policy = Policy.new()

      assert policy.sweep_interval == :timer.seconds(60)
      assert policy.stale_after == :timer.minutes(2)
      assert policy.deadline_grace == :timer.minutes(2)
      assert policy.claim_timeout == :timer.minutes(15)
      assert policy.max_wait == nil
      assert policy.retry == :never
    end

    test "loop defaults: a slower sweep and a generous wake backstop" do
      policy = Policy.new()

      assert policy.loop_sweep_interval == :timer.minutes(5)
      assert policy.wake_pending_after == :timer.minutes(5)
    end

    test "validates the retry shape eagerly" do
      assert %Policy{retry: {:requeue, max_claims: 3}} =
               Policy.new(retry: {:requeue, max_claims: 3})

      assert_raise ArgumentError, fn -> Policy.new(retry: :always) end
      assert_raise ArgumentError, fn -> Policy.new(retry: {:requeue, []}) end
      assert_raise ArgumentError, fn -> Policy.new(retry: {:requeue, max_claims: 0}) end
    end

    test "validates thresholds" do
      assert_raise ArgumentError, fn -> Policy.new(stale_after: 0) end
      assert_raise ArgumentError, fn -> Policy.new(claim_timeout: -5) end
      assert_raise ArgumentError, fn -> Policy.new(max_wait: 0) end
      assert_raise ArgumentError, fn -> Policy.new(loop_sweep_interval: 0) end
      assert_raise ArgumentError, fn -> Policy.new(wake_pending_after: -1) end
      assert_raise KeyError, fn -> Policy.new(stale_threshold: 1) end
    end
  end

  describe "the verdict becomes a guarded CAS" do
    setup do
      store = MemoryLifecycle.start_store()
      MemoryLifecycle.seed_queued(store, "run")
      {:ok, store: store}
    end

    test "the reaper loses cleanly to a live finish — exactly one terminal writer", %{
      store: store
    } do
      {:ok, lease} = Protocol.claim(MemoryLifecycle, "run", executor: "e", ctx: store)
      observed = MemoryLifecycle.facts!(store, "run")

      # The sweep runs after the stale threshold and judges an interrupt...
      sweep_now = DateTime.add(observed.heartbeat_at, 180_000, :millisecond)
      assert {:interrupt, reason} = Reconciler.judge(observed, sweep_now)

      # ...but the runner finishes between judgment and action.
      {:ok, _} = Protocol.finish(lease, Result.completed(output: "won"))

      assert {:error, :stale} = Protocol.interrupt(MemoryLifecycle, observed, reason, store)

      facts = MemoryLifecycle.facts!(store, "run")
      assert facts.status == :completed
      assert [{"run", %Result.Completed{}}] = MemoryLifecycle.projections(store)
    end

    test "concurrent sweeps need zero coordination — one verdict commits, the rest are no-ops",
         %{store: store} do
      {:ok, _lease} = Protocol.claim(MemoryLifecycle, "run", executor: "e", ctx: store)
      observed = MemoryLifecycle.facts!(store, "run")
      sweep_now = DateTime.add(observed.heartbeat_at, 180_000, :millisecond)

      results =
        1..2
        |> Enum.map(fn _node ->
          Task.async(fn ->
            {:interrupt, reason} = Reconciler.judge(observed, sweep_now)
            Protocol.interrupt(MemoryLifecycle, observed, reason, store)
          end)
        end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, %Facts{status: :interrupted}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :stale}, &1)) == 1

      assert [{"run", %Result.Interrupted{}}] = MemoryLifecycle.projections(store)
    end

    test "matrix row 18: the sweep requeues a fence-unset crash; the epoch caps the retries",
         %{store: store} do
      policy = Policy.new(retry: {:requeue, max_claims: 2})

      # First execution crashes without effects; the sweep requeues it.
      {:ok, _lease1} = Protocol.claim(MemoryLifecycle, "run", executor: "e1", ctx: store)
      observed = MemoryLifecycle.facts!(store, "run")
      sweep_now = DateTime.add(observed.heartbeat_at, 180_000, :millisecond)

      assert {:requeue, reason} = Reconciler.judge(observed, sweep_now, policy)
      {:ok, requeued} = Protocol.requeue(MemoryLifecycle, observed, reason, store)

      # Same run, same epoch — the next claim mints the attempt.
      assert requeued.status == :queued
      assert requeued.epoch == 1

      {:ok, lease2} = Protocol.claim(MemoryLifecycle, "run", executor: "e2", ctx: store)
      assert lease2.epoch == 2

      # Second execution crashes too; the cap is spent, so the verdict is
      # terminal — and its CAS commits with the projection firing.
      observed2 = MemoryLifecycle.facts!(store, "run")
      sweep2 = DateTime.add(observed2.heartbeat_at, 180_000, :millisecond)

      assert {:interrupt, %InterruptReason{code: :lease_expired} = reason2} =
               Reconciler.judge(observed2, sweep2, policy)

      {:ok, reaped} = Protocol.interrupt(MemoryLifecycle, observed2, reason2, store)
      assert reaped.status == :interrupted

      assert [{"run", %Result.Interrupted{reason: ^reason2}}] =
               MemoryLifecycle.projections(store)
    end

    test "matrix row 18 guard: a fence-set crash is interrupted even under a requeue policy",
         %{store: store} do
      policy = Policy.new(retry: {:requeue, max_claims: 3})

      {:ok, lease} = Protocol.claim(MemoryLifecycle, "run", executor: "e", ctx: store)
      :ok = Protocol.mark_effects(lease)

      observed = MemoryLifecycle.facts!(store, "run")
      sweep_now = DateTime.add(observed.heartbeat_at, 180_000, :millisecond)

      assert {:interrupt, %InterruptReason{code: :lease_expired}} =
               Reconciler.judge(observed, sweep_now, policy)
    end

    test "matrix row 15: the max_wait ceiling measures from the park, not the original enqueue",
         %{store: store} do
      # Review scenario: queued far longer than the ceiling before ever
      # being claimed (12m in the queue, 10m ceiling), then suspended.
      long_ago = DateTime.add(DateTime.utc_now(), -:timer.minutes(12), :millisecond)
      MemoryLifecycle.seed_queued(store, "aged", queued_at: long_ago)

      {:ok, lease} = Protocol.claim(MemoryLifecycle, "aged", executor: "e", ctx: store)
      {:ok, _token} = Protocol.suspend(lease, suspension_request(), cursor: {1, 0})

      waiting = MemoryLifecycle.facts!(store, "aged")
      policy = Policy.new(max_wait: :timer.minutes(10))

      # Freshly parked: healthy despite the 12 minutes of pre-claim history.
      assert Reconciler.judge(waiting, DateTime.utc_now(), policy) == :healthy

      # Expired only once the wait itself outlives the ceiling.
      eleven_minutes_on = DateTime.add(DateTime.utc_now(), :timer.minutes(11), :millisecond)

      assert {:interrupt, %InterruptReason{code: :suspension_expired}} =
               Reconciler.judge(waiting, eleven_minutes_on, policy)
    end

    test "matrix rows 10 + 15: a suspended run survives the full sweep and stays resumable",
         %{store: store} do
      {:ok, lease} = Protocol.claim(MemoryLifecycle, "run", executor: "e", ctx: store)
      {:ok, token} = Protocol.suspend(lease, suspension_request(), cursor: {1, 0})

      waiting = MemoryLifecycle.facts!(store, "run")
      month_later = DateTime.add(@now, 30 * 24 * 60 * 60, :second)

      # The pure judge passes it (no ceiling by default), and the Oban
      # cross-check passes it: a completed job is the NORMAL state of a
      # suspended run.
      assert Reconciler.judge(waiting, month_later) == :healthy

      assert Clementine.Lifecycle.Ecto.Oban.judge_job(waiting, %{id: 9, state: "completed"}) ==
               :healthy

      # Nothing the sweep did touched the suspension: it still resumes.
      assert {:ok, %Facts{status: :queued}} =
               Protocol.resume(MemoryLifecycle, token, {:approved, %{by: 1}}, store)
    end
  end

  defp suspension_request do
    %Suspension.Request{
      reason: {:approval, %ApprovalRequest{tool_use_id: "t", tool_name: "n", args: %{}}},
      pending: %Pending.ToolApproval{tool_use_id: "t", tool_name: "n", args: %{}},
      messages: [],
      iteration: 1,
      usage: %Usage{}
    }
  end
end
