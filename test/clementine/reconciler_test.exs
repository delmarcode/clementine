defmodule Clementine.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.Reconciler
  alias Clementine.Reconciler.Policy
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
