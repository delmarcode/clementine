defmodule Clementine.Lifecycle.ProtocolTest do
  use ExUnit.Case, async: true

  alias Clementine.Lifecycle.Protocol
  alias Clementine.Pending.ToolApproval
  alias Clementine.Result
  alias Clementine.Test.{FlakyLifecycle, MemoryLifecycle}
  alias Clementine.{ApprovalRequest, InterruptReason, ResumeToken, Suspension, Usage}

  setup do
    store = MemoryLifecycle.start_store()
    {:ok, store: store}
  end

  defp claim!(store, ref, opts \\ []) do
    opts = Keyword.merge([executor: "test:#{ref}", ctx: store], opts)
    {:ok, lease} = Protocol.claim(MemoryLifecycle, ref, opts)
    lease
  end

  defp approval_request(overrides \\ []) do
    base = %Suspension.Request{
      reason:
        {:approval, %ApprovalRequest{tool_use_id: "tu_1", tool_name: "danger", args: %{"x" => 1}}},
      pending: %ToolApproval{tool_use_id: "tu_1", tool_name: "danger", args: %{"x" => 1}},
      messages: [],
      iteration: 2,
      usage: %Usage{input_tokens: 10, output_tokens: 5}
    }

    struct!(base, overrides)
  end

  describe "claim/3" do
    test "claims a queued run: epoch mints execution identity", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")

      assert {:ok, lease} =
               Protocol.claim(MemoryLifecycle, "r1", executor: "oban:1:node", ctx: store)

      assert lease.epoch == 1
      assert lease.lifecycle == MemoryLifecycle
      assert lease.ctx == store
      assert lease.resume == nil

      facts = MemoryLifecycle.facts!(store, "r1")
      assert facts.status == :running
      assert facts.epoch == 1
      assert facts.executor_id == "oban:1:node"
      assert %DateTime{} = facts.heartbeat_at
      assert facts.deadline == nil
    end

    test "mints a fresh deadline window from max_duration", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1", max_duration: 60_000)

      assert %DateTime{} = lease.deadline
      assert DateTime.compare(lease.deadline, DateTime.utc_now()) == :gt
    end

    test "a lost race reports who holds the run", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      claim!(store, "r1")

      assert {:error, {:not_claimable, :running}} =
               Protocol.claim(MemoryLifecycle, "r1", executor: "late", ctx: store)
    end

    test "terminal and missing runs are not claimable", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      {:ok, _} = Protocol.finish(lease, Result.completed())

      assert {:error, {:not_claimable, :completed}} =
               Protocol.claim(MemoryLifecycle, "r1", executor: "x", ctx: store)

      assert {:error, :not_found} =
               Protocol.claim(MemoryLifecycle, "ghost", executor: "x", ctx: store)
    end

    test "N concurrent claimers: exactly one wins", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")

      results =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            Protocol.claim(MemoryLifecycle, "r1", executor: "racer:#{i}", ctx: store)
          end)
        end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:not_claimable, :running}}, &1)) == 9
      assert MemoryLifecycle.facts!(store, "r1").epoch == 1
    end
  end

  describe "heartbeat/2" do
    test "renews liveness; usage piggybacks only when sampled", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")

      assert :ok = Protocol.heartbeat(lease)
      assert MemoryLifecycle.facts!(store, "r1").usage == nil

      usage = %Usage{input_tokens: 100, output_tokens: 40}
      assert :ok = Protocol.heartbeat(lease, usage: usage)
      assert MemoryLifecycle.facts!(store, "r1").usage == usage

      # A later beat without a sample leaves usage untouched (absent key).
      assert :ok = Protocol.heartbeat(lease)
      assert MemoryLifecycle.facts!(store, "r1").usage == usage
    end

    test "transient storage errors pass through — the beat loop owns retry",
         %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      faults = FlakyLifecycle.start_faults([{:fail, :db_down}])
      flaky_lease = %{lease | lifecycle: FlakyLifecycle, ctx: %{store: store, faults: faults}}

      assert {:error, :db_down} = Protocol.heartbeat(flaky_lease)
    end
  end

  describe "cancellation/1" do
    test "reads intent, or discovers loss", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")

      assert Protocol.cancellation(lease) == :none

      {:ok, :flagged} = Protocol.request_cancel(MemoryLifecycle, "r1", :user_clicked_stop, store)
      assert Protocol.cancellation(lease) == {:requested, :user_clicked_stop}
    end
  end

  describe "mark_effects/1" do
    test "raises the fence durably", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")

      refute MemoryLifecycle.facts!(store, "r1").effects?
      assert :ok = Protocol.mark_effects(lease)
      assert MemoryLifecycle.facts!(store, "r1").effects?
    end
  end

  describe "suspend/3" do
    test "parks the run with field hygiene and a derived token", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1", max_duration: 60_000)

      assert {:ok, %ResumeToken{} = token} =
               Protocol.suspend(lease, approval_request(),
                 cursor: {1, 42},
                 rollout_id: "rollout_r1"
               )

      assert token == %ResumeToken{run_ref: "r1", epoch: 1, reason_type: :approval}

      facts = MemoryLifecycle.facts!(store, "r1")
      assert facts.status == :waiting
      assert facts.executor_id == nil
      assert facts.deadline == nil
      assert facts.heartbeat_at == nil
      assert facts.suspension.token == token
      assert facts.suspension.checkpoint.cursor == {1, 42}
      assert facts.suspension.checkpoint.rollout_id == "rollout_r1"
      assert facts.suspension.checkpoint.iteration == 2
    end

    test "matrix row 17, flag-first order: cancel before suspend converges to cancelled",
         %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")

      # The flag write commutes with the status CAS — this is the race the
      # post-CAS re-check exists for.
      {:ok, :flagged} = Protocol.request_cancel(MemoryLifecycle, "r1", :changed_my_mind, store)

      assert {:cancelled, facts} = Protocol.suspend(lease, approval_request(), cursor: {1, 9})
      assert facts.status == :cancelled

      assert [{"r1", %Result.Cancelled{reason: :changed_my_mind, usage: usage}}] =
               MemoryLifecycle.projections(store)

      assert usage == approval_request().usage
    end

    test "matrix row 17, suspend-first order: request_cancel takes the direct flavor",
         %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")

      {:ok, _token} = Protocol.suspend(lease, approval_request(), cursor: {1, 9})

      assert {:ok, :finished} =
               Protocol.request_cancel(MemoryLifecycle, "r1", :too_late, store)

      assert MemoryLifecycle.facts!(store, "r1").status == :cancelled
      assert [{"r1", %Result.Cancelled{reason: :too_late}}] = MemoryLifecycle.projections(store)
    end

    test "retries a transient storage error under the live lease", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      faults = FlakyLifecycle.start_faults([{:fail, :timeout}])
      flaky_lease = %{lease | lifecycle: FlakyLifecycle, ctx: %{store: store, faults: faults}}

      assert {:ok, %ResumeToken{}} =
               Protocol.suspend(flaky_lease, approval_request(), cursor: {1, 1})

      assert MemoryLifecycle.facts!(store, "r1").status == :waiting
    end
  end

  describe "resume/4" do
    setup %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      {:ok, token} = Protocol.suspend(lease, approval_request(), cursor: {1, 7})
      {:ok, lease: lease, token: token}
    end

    test "resolves the wait: queued, payload stamped, epoch untouched",
         %{store: store, token: token} do
      assert {:ok, facts} =
               Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "user_9"}}, store)

      assert facts.status == :queued
      assert facts.epoch == 1
      assert facts.resume.payload == {:approved, %{by: "user_9"}}
      assert %DateTime{} = facts.resume.resumed_at
      assert %DateTime{} = facts.queued_at
    end

    test "the next claim carries the checkpoint and payload in the lease",
         %{store: store, token: token} do
      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:approved, %{}}, store)

      {:ok, lease2} = Protocol.claim(MemoryLifecycle, "r1", executor: "second", ctx: store)

      assert lease2.epoch == 2
      assert {checkpoint, {:approved, %{}}} = lease2.resume
      assert checkpoint.cursor == {1, 7}
    end

    test "matrix row 7: a token fires at most once", %{store: store, token: token} do
      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:approved, %{}}, store)

      assert {:error, :already_resumed} =
               Protocol.resume(MemoryLifecycle, token, {:approved, %{}}, store)
    end

    test "epoch mismatch is a stale reference", %{store: store, token: token} do
      forged = %{token | epoch: token.epoch + 5}
      assert {:error, :stale_reference} = Protocol.resume(MemoryLifecycle, forged, :x, store)
    end

    test "reason-type mismatch is a wrong reference", %{store: store, token: token} do
      wrong = %{token | reason_type: :external}
      assert {:error, :wrong_reference_type} = Protocol.resume(MemoryLifecycle, wrong, :x, store)
    end

    test "terminal runs are not waiting", %{store: store, token: token} do
      {:ok, :finished} = Protocol.request_cancel(MemoryLifecycle, "r1", :nope, store)
      assert {:error, :run_not_waiting} = Protocol.resume(MemoryLifecycle, token, :x, store)
    end

    test "zombie fencing across the full suspend/resume/re-claim cycle: status recurs, epoch discriminates",
         %{store: store, lease: old_lease, token: token} do
      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:approved, %{}}, store)
      {:ok, _lease2} = Protocol.claim(MemoryLifecycle, "r1", executor: "second", ctx: store)

      # The run is `running` again — a status-only guard would admit the
      # zombie. Every write from the superseded execution must fail.
      assert {:error, :lost_lease} = Protocol.heartbeat(old_lease)
      assert {:error, :lost_lease} = Protocol.mark_effects(old_lease)
      assert {:error, :lost_lease} = Protocol.finish(old_lease, Result.completed())
      assert {:error, :lost_lease} = Protocol.suspend(old_lease, approval_request())
      assert {:error, :lost_lease} = Protocol.cancellation(old_lease)
    end
  end

  describe "request_cancel/4" do
    test "flags a running run; direct-cancels an unowned queued run", %{store: store} do
      MemoryLifecycle.seed_queued(store, "flagged")
      claim!(store, "flagged")

      assert {:ok, :flagged} =
               Protocol.request_cancel(MemoryLifecycle, "flagged", :stop, store)

      assert MemoryLifecycle.facts!(store, "flagged").status == :running

      MemoryLifecycle.seed_queued(store, "direct")

      assert {:ok, :finished} =
               Protocol.request_cancel(MemoryLifecycle, "direct", :stop, store)

      assert MemoryLifecycle.facts!(store, "direct").status == :cancelled
      assert [{"direct", %Result.Cancelled{}}] = MemoryLifecycle.projections(store)
    end

    test "terminal runs report already_terminal", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      {:ok, _} = Protocol.finish(lease, Result.completed())

      assert {:error, :already_terminal} =
               Protocol.request_cancel(MemoryLifecycle, "r1", :late, store)
    end
  end

  describe "finish/2" do
    test "terminalizes with the projection in the same commit", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")

      usage = %Usage{input_tokens: 9, output_tokens: 3}
      result = Result.completed(output: "done", usage: usage)

      assert {:ok, facts} = Protocol.finish(lease, result)
      assert facts.status == :completed
      assert facts.usage == usage
      assert %DateTime{} = facts.finished_at
      assert [{"r1", ^result}] = MemoryLifecycle.projections(store)
    end

    test "failed and interrupted results store their terminal detail", %{store: store} do
      MemoryLifecycle.seed_queued(store, "fail")
      fail_lease = claim!(store, "fail")
      {:ok, facts} = Protocol.finish(fail_lease, Result.failed({:api_error, 429, %{}}))
      assert facts.status == :failed
      assert facts.error.code == :rate_limited

      MemoryLifecycle.seed_queued(store, "drain")
      drain_lease = claim!(store, "drain")
      {:ok, facts} = Protocol.finish(drain_lease, Result.interrupted(:drain))
      assert facts.status == :interrupted
      assert facts.interrupt.code == :drain
    end

    test "matrix row 3 shape: finish fires at most once per run", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")

      {:ok, _} = Protocol.finish(lease, Result.completed())
      assert {:error, :already_terminal} = Protocol.finish(lease, Result.completed())
      assert length(MemoryLifecycle.projections(store)) == 1
    end

    test "matrix row 16: a transient blip at the terminal write retries and commits",
         %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      faults = FlakyLifecycle.start_faults([{:fail, :closed}])
      flaky_lease = %{lease | lifecycle: FlakyLifecycle, ctx: %{store: store, faults: faults}}

      assert {:ok, facts} = Protocol.finish(flaky_lease, Result.completed(output: "ok"))
      assert facts.status == :completed
    end

    test "exhausted retries surface the storage error; the run stays running for the reaper",
         %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      faults = FlakyLifecycle.start_faults(List.duplicate({:fail, :down}, 5))
      flaky_lease = %{lease | lifecycle: FlakyLifecycle, ctx: %{store: store, faults: faults}}

      assert {:error, :down} = Protocol.finish(flaky_lease, Result.completed())
      assert MemoryLifecycle.facts!(store, "r1").status == :running
    end
  end

  describe "interrupt/4" do
    test "reaps with the projection firing and piggybacked usage", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      usage = %Usage{input_tokens: 77, output_tokens: 11}
      :ok = Protocol.heartbeat(lease, usage: usage)

      {:ok, observed} = MemoryLifecycle.fetch("r1", store)
      reason = InterruptReason.new(:lease_expired, "heartbeat expired")

      assert {:ok, facts} = Protocol.interrupt(MemoryLifecycle, observed, reason, store)
      assert facts.status == :interrupted
      assert facts.interrupt == reason

      assert [{"r1", %Result.Interrupted{reason: ^reason, usage: ^usage}}] =
               MemoryLifecycle.projections(store)
    end

    test "matrix row 3: the reaper loses cleanly to a concurrent finish", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      {:ok, observed} = MemoryLifecycle.fetch("r1", store)

      {:ok, _} = Protocol.finish(lease, Result.completed())

      assert {:error, :stale} =
               Protocol.interrupt(
                 MemoryLifecycle,
                 observed,
                 InterruptReason.new(:lease_expired),
                 store
               )

      assert [{"r1", %Result.Completed{}}] = MemoryLifecycle.projections(store)
    end

    test "refuses terminal facts outright — dead-end enforcement is the protocol's job",
         %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      {:ok, _} = Protocol.finish(lease, Result.completed())

      # Fetched AFTER the terminal commit: the exact-pair CAS would match
      # this snapshot, so the protocol itself must refuse it.
      {:ok, terminal_facts} = MemoryLifecycle.fetch("r1", store)

      assert {:error, :already_terminal} =
               Protocol.interrupt(
                 MemoryLifecycle,
                 terminal_facts,
                 InterruptReason.new(:lease_expired),
                 store
               )

      assert MemoryLifecycle.facts!(store, "r1").status == :completed
      assert [{"r1", %Result.Completed{}}] = MemoryLifecycle.projections(store)
    end
  end

  describe "requeue" do
    test "matrix row 18: fence-unset requeue re-queues at the same epoch; the next claim counts the attempt",
         %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      claim!(store, "r1")
      {:ok, observed} = MemoryLifecycle.fetch("r1", store)

      assert {:ok, facts} = Protocol.requeue(MemoryLifecycle, observed, :lease_expired, store)
      assert facts.status == :queued
      assert facts.epoch == 1
      assert facts.executor_id == nil
      assert facts.heartbeat_at == nil
      assert %DateTime{} = facts.queued_at

      {:ok, lease2} = Protocol.claim(MemoryLifecycle, "r1", executor: "retry", ctx: store)
      assert lease2.epoch == 2
    end

    test "refuses when the effect fence is set", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      :ok = Protocol.mark_effects(lease)
      {:ok, observed} = MemoryLifecycle.fetch("r1", store)

      assert {:error, :effects_present} =
               Protocol.requeue(MemoryLifecycle, observed, :lease_expired, store)

      assert {:error, :effects_present} = Protocol.requeue(lease, :drain)
    end

    test "refuses non-running facts with a clean error", %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")
      {:ok, _} = Protocol.finish(lease, Result.completed())
      {:ok, terminal_facts} = MemoryLifecycle.fetch("r1", store)

      assert {:error, {:not_requeueable, :completed}} =
               Protocol.requeue(MemoryLifecycle, terminal_facts, :lease_expired, store)

      assert MemoryLifecycle.facts!(store, "r1").status == :completed
    end

    test "drain flavor requeues via the lease; a zombie is fenced the moment it commits",
         %{store: store} do
      MemoryLifecycle.seed_queued(store, "r1")
      lease = claim!(store, "r1")

      assert {:ok, facts} = Protocol.requeue(lease, :drain)
      assert facts.status == :queued

      # The drained executor may not write after handing the run back.
      assert {:error, :lost_lease} = Protocol.finish(lease, Result.completed())
    end
  end
end
