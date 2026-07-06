defmodule Clementine.Lifecycle.EctoAdapterTest do
  use Clementine.EctoCase, async: false

  alias Clementine.Lifecycle.{Facts, Protocol, Transition}
  alias Clementine.LLM.Message.Content.ToolUse
  alias Clementine.LLM.Message.{AssistantMessage, UserMessage}
  alias Clementine.Test.Ecto.Lifecycle

  alias Clementine.{
    ApprovalRequest,
    InterruptReason,
    Pending,
    Result,
    Suspension,
    Usage
  }

  defp claim!(run, opts \\ []) do
    {:ok, lease} =
      Protocol.claim(
        Lifecycle,
        run.id,
        Keyword.merge([executor: "test:#{run.id}", ctx: self()], opts)
      )

    lease
  end

  defp fetch!(run_id) do
    {:ok, facts} = Lifecycle.fetch(run_id, self())
    facts
  end

  defp suspension_request do
    %Suspension.Request{
      reason:
        {:approval,
         %ApprovalRequest{tool_use_id: "tu_1", tool_name: "delete_records", args: %{"t" => "x"}}},
      pending: %Pending.ToolApproval{
        tool_use_id: "tu_1",
        tool_name: "delete_records",
        args: %{"t" => "x"}
      },
      messages: [
        UserMessage.new("clean up"),
        %AssistantMessage{
          content: [%ToolUse{id: "tu_1", name: "delete_records", input: %{"t" => "x"}}]
        }
      ],
      iteration: 2,
      usage: %Usage{input_tokens: 40, output_tokens: 9}
    }
  end

  describe "fetch/2" do
    test "returns :not_found for a missing run" do
      assert {:error, :not_found} = Lifecycle.fetch(-1, self())
    end

    test "round-trips a freshly enqueued row, queued_at stamped by the column default" do
      run = insert_run!()
      facts = fetch!(run.id)

      assert %Facts{ref: ref, status: :queued, epoch: 0, effects?: false} = facts
      assert ref == run.id
      assert %DateTime{} = facts.queued_at
    end
  end

  describe "claim" do
    test "queued -> running: epoch mints, stamps resolve against the storage clock" do
      run = insert_run!()
      lease = claim!(run, max_duration: 60_000)

      facts = fetch!(run.id)
      db_now = db_now!()

      assert facts.status == :running
      assert facts.epoch == 1
      assert lease.epoch == 1
      assert facts.executor_id == "test:#{run.id}"

      # Exact equality with the transaction timestamp proves the stamp was
      # resolved by the database, not the app node's clock.
      assert facts.heartbeat_at == db_now
      assert facts.deadline == DateTime.add(db_now, 60_000, :millisecond)
    end

    test "a lost claim race reports who holds the run" do
      run = insert_run!()
      claim!(run)

      assert {:error, {:not_claimable, :running}} =
               Protocol.claim(Lifecycle, run.id, executor: "late", ctx: self())
    end
  end

  describe "heartbeat" do
    test "moves heartbeat_at and can piggyback usage; absent keys stay untouched" do
      run = insert_run!()
      lease = claim!(run, max_duration: 60_000)
      before = fetch!(run.id)

      assert :ok = Protocol.heartbeat(lease, usage: %Usage{input_tokens: 5, output_tokens: 2})

      facts = fetch!(run.id)
      assert facts.usage == %Usage{input_tokens: 5, output_tokens: 2}
      # A heartbeat writes exactly heartbeat_at (+ usage): the deadline and
      # executor identity it did not mention are untouched.
      assert facts.deadline == before.deadline
      assert facts.executor_id == before.executor_id
      assert facts.status == :running and facts.epoch == 1
    end

    test "matrix row 2: a write from a superseded epoch returns lost_lease, even with status running again" do
      run = insert_run!()
      zombie = claim!(run)

      {:ok, _token} = Protocol.suspend(zombie, suspension_request(), cursor: {1, 4})

      {:ok, _facts} =
        Protocol.resume(Lifecycle, token_from_store(run.id), {:approved, %{by: 1}}, self())

      successor = claim!(run)

      # Status alone would match — running again — but the epoch does not.
      assert successor.epoch == 2
      assert {:error, :lost_lease} = Protocol.heartbeat(zombie)
      assert {:error, :lost_lease} = Protocol.mark_effects(zombie)
      assert {:error, :lost_lease} = Protocol.finish(zombie, Result.completed())

      # The successor's writes land.
      assert :ok = Protocol.heartbeat(successor)
    end
  end

  describe "suspend and resume" do
    test "suspend stores an exactly round-trippable suspension and clears executor fields" do
      run = insert_run!()
      lease = claim!(run, max_duration: 60_000)
      request = suspension_request()

      {:ok, token} = Protocol.suspend(lease, request, cursor: {1, 7}, rollout_id: "rollout-1")

      facts = fetch!(run.id)
      assert facts.status == :waiting
      assert facts.epoch == 1

      # Field hygiene: a waiting run has no executor, no deadline, no
      # heartbeat.
      assert facts.executor_id == nil
      assert facts.deadline == nil
      assert facts.heartbeat_at == nil

      assert %Suspension{} = facts.suspension
      assert facts.suspension.token == token
      assert facts.suspension.reason == request.reason
      assert facts.suspension.checkpoint.messages == request.messages
      assert facts.suspension.checkpoint.pending == request.pending
      assert facts.suspension.checkpoint.iteration == 2
      assert facts.suspension.checkpoint.cursor == {1, 7}
      assert facts.usage == request.usage
    end

    test "resume validates the token, stamps the payload, and re-enters queued" do
      run = insert_run!()
      lease = claim!(run)
      {:ok, token} = Protocol.suspend(lease, suspension_request(), cursor: {1, 0})

      {:ok, facts} = Protocol.resume(Lifecycle, token, {:approved, %{by: 42}}, self())

      assert facts.status == :queued
      assert facts.epoch == 1
      assert facts.resume.payload == {:approved, %{by: 42}}
      assert facts.resume.resumed_at == facts.queued_at

      # matrix row 7: a second fire of the same token dies precisely.
      assert {:error, :already_resumed} =
               Protocol.resume(Lifecycle, token, {:approved, %{by: 42}}, self())

      # The next claim hands the checkpoint and payload back through the lease.
      lease2 = claim!(run)
      assert {%Clementine.Checkpoint{cursor: {1, 0}}, {:approved, %{by: 42}}} = lease2.resume
    end
  end

  describe "cancellation" do
    test "flags a running run with a storage-clock stamp and an exact reason term" do
      run = insert_run!()
      lease = claim!(run)

      assert {:ok, :flagged} = Protocol.request_cancel(Lifecycle, run.id, {:user, 42}, self())

      facts = fetch!(run.id)
      assert facts.status == :running
      assert facts.cancel.reason == {:user, 42}
      assert facts.cancel.requested_at == db_now!()

      assert {:requested, {:user, 42}} = Protocol.cancellation(lease)
    end

    test "cancels an unowned queued run directly, projection firing" do
      run = insert_run!()

      assert {:ok, :finished} = Protocol.request_cancel(Lifecycle, run.id, :abandoned, self())

      assert %Facts{status: :cancelled, finished_at: %DateTime{}} = fetch!(run.id)
      assert_received {:projected, %Result.Cancelled{reason: :abandoned}, _row}
    end

    test "matrix row 17: cancel flag landing before a suspend converges to cancelled, never a stranded waiting run" do
      run = insert_run!()
      lease = claim!(run)

      {:ok, :flagged} = Protocol.request_cancel(Lifecycle, run.id, :user_stop, self())

      assert {:cancelled, facts} = Protocol.suspend(lease, suspension_request(), cursor: {1, 0})
      assert facts.status == :cancelled
      assert_received {:projected, %Result.Cancelled{reason: :user_stop}, _row}
    end
  end

  describe "cancel push channel" do
    alias Clementine.Lifecycle.Ecto, as: EctoAdapter
    alias Clementine.Test.Ecto.PubsubLifecycle

    setup do
      start_supervised!({Phoenix.PubSub, name: Clementine.Test.PubSub})
      :ok
    end

    test "subscribe_cancel/1 is exported exactly when pubsub is configured" do
      Code.ensure_loaded!(PubsubLifecycle)
      Code.ensure_loaded!(Lifecycle)

      assert function_exported?(PubsubLifecycle, :subscribe_cancel, 1)
      refute function_exported?(Lifecycle, :subscribe_cancel, 1)
    end

    test "a committed cancel flag broadcasts to the executor subscribed at claim" do
      run = insert_run!()

      {:ok, lease} =
        Protocol.claim(PubsubLifecycle, run.id, executor: "test:push", ctx: self())

      assert :ok = PubsubLifecycle.subscribe_cancel(lease)

      assert {:ok, :flagged} =
               Protocol.request_cancel(PubsubLifecycle, run.id, {:user, 7}, self())

      # Exactly the message shape the rollout's blocking points match.
      assert_receive {:clementine, :cancel, {:user, 7}}
    end

    test "a direct cancel of an unowned run does not broadcast" do
      run = insert_run!()
      :ok = Phoenix.PubSub.subscribe(Clementine.Test.PubSub, EctoAdapter.cancel_topic(run.id))

      assert {:ok, :finished} =
               Protocol.request_cancel(PubsubLifecycle, run.id, :abandoned, self())

      refute_receive {:clementine, :cancel, _}, 100
    end
  end

  describe "finish" do
    test "commits the terminal atomically with the projection" do
      run = insert_run!()
      lease = claim!(run)

      result =
        Result.completed(
          input_message: UserMessage.new("hi"),
          messages: [%AssistantMessage{content: []}],
          output: "done",
          usage: %Usage{input_tokens: 3, output_tokens: 1}
        )

      {:ok, facts} = Protocol.finish(lease, result)

      assert facts.status == :completed
      assert facts.usage == %Usage{input_tokens: 3, output_tokens: 1}
      assert facts.finished_at == db_now!()
      assert_received {:projected, %Result.Completed{output: "done"}, row}
      assert row.id == run.id

      # Terminal states are dead ends: a second finish is refused precisely.
      assert {:error, :already_terminal} = Protocol.finish(lease, Result.completed())
    end

    test "a raising projection aborts the transition: status and epoch unchanged" do
      run = insert_run!(label: "boom")
      lease = claim!(run)

      assert_raise RuntimeError, "projection boom", fn ->
        Protocol.finish(lease, Result.completed())
      end

      facts = fetch!(run.id)
      assert facts.status == :running
      assert facts.epoch == 1
      assert facts.finished_at == nil
    end

    test "failed terminals persist the normalized error" do
      run = insert_run!()
      lease = claim!(run)

      error =
        Clementine.Error.normalize(
          {:api_error, 429, %{"error" => %{"message" => "slow"}}},
          :anthropic
        )

      {:ok, facts} = Protocol.finish(lease, Result.failed(error, %Usage{input_tokens: 1}))

      assert facts.status == :failed
      assert facts.error == error
      assert_received {:projected, %Result.Failed{}, _row}
    end
  end

  describe "interrupt (reaper-facing)" do
    test "fires the projection for reaped runs exactly as for finished ones" do
      run = insert_run!()
      claim!(run)
      facts = fetch!(run.id)

      reason = InterruptReason.new(:lease_expired, "heartbeat stale")
      {:ok, interrupted} = Protocol.interrupt(Lifecycle, facts, reason, self())

      assert interrupted.status == :interrupted
      assert interrupted.interrupt == reason
      assert_received {:projected, %Result.Interrupted{reason: ^reason}, _row}
    end

    test "matrix row 3: a reaper guarded by observed facts loses cleanly to a concurrent finish" do
      run = insert_run!()
      lease = claim!(run)
      observed = fetch!(run.id)

      {:ok, _} = Protocol.finish(lease, Result.completed())

      # The reaper's CAS fails — the database decided the single terminal
      # writer, and losing is a no-op with a precise error.
      assert {:error, :stale} =
               Protocol.interrupt(
                 Lifecycle,
                 observed,
                 InterruptReason.new(:lease_expired),
                 self()
               )

      # Exactly one terminal writer: the run stays completed and only the
      # finish projection fired.
      assert fetch!(run.id).status == :completed
      assert_received {:projected, %Result.Completed{}, _row}
      refute_received {:projected, %Result.Interrupted{}, _row}
    end
  end

  describe "requeue" do
    test "drain flavor: running -> queued with field hygiene, epoch untouched" do
      run = insert_run!()
      lease = claim!(run, max_duration: 60_000)

      {:ok, facts} = Protocol.requeue(lease, :drain)

      assert facts.status == :queued
      assert facts.epoch == 1
      assert facts.executor_id == nil
      assert facts.deadline == nil
      assert facts.heartbeat_at == nil
      assert facts.queued_at == db_now!()

      # The next claim mints the next epoch: epoch doubles as attempt count.
      assert claim!(run).epoch == 2
    end

    test "matrix row 18 guard: refused outright once the effect fence is set" do
      run = insert_run!()
      lease = claim!(run)
      :ok = Protocol.mark_effects(lease)

      assert fetch!(run.id).effects?
      assert {:error, :effects_present} = Protocol.requeue(lease, :drain)
    end
  end

  describe "after_transition/3" do
    test "fires post-commit for every applied transition with the committed facts" do
      run = insert_run!()
      lease = claim!(run)

      assert_received {:transition, %Facts{status: :running, epoch: 1}, %Transition{op: :claim}}

      {:ok, _} = Protocol.finish(lease, Result.completed())

      assert_received {:transition, %Facts{status: :completed}, %Transition{op: :finish}}
    end

    test "a raising hook is swallowed: the committed transition still succeeds" do
      run = insert_run!()

      transition = %Transition{
        op: :heartbeat,
        run_ref: run.id,
        expect: %{status: :queued, epoch: 0},
        set: %{queued_at: :now},
        meta: %{raise_in_hook: true}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %Facts{}} = Lifecycle.apply(transition, self())
        end)

      assert log =~ "after_transition"
      assert_received {:transition, _facts, _transition}
    end

    test "a stale apply fires no hook" do
      run = insert_run!()

      transition = %Transition{
        op: :heartbeat,
        run_ref: run.id,
        expect: %{status: :running, epoch: 9},
        set: %{heartbeat_at: :now}
      }

      assert {:error, :stale} = Lifecycle.apply(transition, self())
      refute_received {:transition, _, _}
    end
  end

  describe "single-active index (matrix row 6)" do
    test "a second active run in the same scope is uninsertable, waiting included" do
      run = insert_run!(scope_id: 999)

      assert_raise Ecto.ConstraintError, fn -> insert_run!(scope_id: 999) end

      # waiting still blocks the scope — the documented default.
      lease = claim!(run)
      {:ok, _token} = Protocol.suspend(lease, suspension_request(), cursor: {1, 0})
      assert_raise Ecto.ConstraintError, fn -> insert_run!(scope_id: 999) end
    end

    test "a terminal run frees the scope" do
      run = insert_run!(scope_id: 1000)
      lease = claim!(run)
      {:ok, _} = Protocol.finish(lease, Result.completed())

      assert %Run{} = insert_run!(scope_id: 1000)
    end
  end

  describe "set semantics" do
    test "explicit nil writes NULL; absent keys leave values untouched" do
      run = insert_run!()
      claim!(run)

      # mark_effects sets only effects?: everything else untouched.
      facts_before = fetch!(run.id)

      transition = %Transition{
        op: :mark_effects,
        run_ref: run.id,
        expect: %{status: :running, epoch: 1},
        set: %{effects?: true}
      }

      {:ok, facts} = Lifecycle.apply(transition, self())
      assert facts.effects?
      assert facts.executor_id == facts_before.executor_id
      assert facts.heartbeat_at == facts_before.heartbeat_at

      # Explicit nil writes NULL.
      clear = %Transition{
        op: :heartbeat,
        run_ref: run.id,
        expect: %{status: :running, epoch: 1},
        set: %{executor_id: nil}
      }

      {:ok, cleared} = Lifecycle.apply(clear, self())
      assert cleared.executor_id == nil
    end
  end

  # The token lives inside the stored suspension — apps read it from their
  # own storage when building the approval surface (RFC step 5).
  defp token_from_store(run_id) do
    %Facts{suspension: %Suspension{token: token}} = fetch!(run_id)
    token
  end
end
