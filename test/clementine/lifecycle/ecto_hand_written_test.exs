defmodule Clementine.Lifecycle.EctoHandWrittenTest do
  @moduledoc """
  Acceptance for the documented escape hatch: the RFC's de-sugared
  two-function lifecycle (§A Hand-Written Lifecycle, In Full) works
  verbatim against the column recipe — no adapter macro anywhere.
  """

  use Clementine.EctoCase, async: false

  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.LLM.Message.UserMessage
  alias Clementine.Test.Ecto.HandWrittenLifecycle, as: Lifecycle

  alias Clementine.{
    ApprovalRequest,
    Pending,
    Result,
    Suspension,
    Usage
  }

  defp claim!(run) do
    {:ok, lease} =
      Protocol.claim(Lifecycle, run.id,
        executor: "hand:#{run.id}",
        ctx: self(),
        max_duration: 30_000
      )

    lease
  end

  test "the full lifecycle cycle runs against the recipe: claim, heartbeat, suspend, resume, re-claim, finish" do
    run = insert_run!()

    # Claim: epoch mints, stamps resolve in the database.
    lease = claim!(run)
    {:ok, facts} = Lifecycle.fetch(run.id, self())
    assert %Facts{status: :running, epoch: 1} = facts
    assert facts.heartbeat_at == db_now!()
    assert facts.deadline == DateTime.add(db_now!(), 30_000, :millisecond)

    assert :ok = Protocol.heartbeat(lease, usage: %Usage{input_tokens: 7, output_tokens: 2})

    # Suspend: the assembled suspension round-trips through the jsonb column.
    request = %Suspension.Request{
      reason: {:approval, %ApprovalRequest{tool_use_id: "tu_1", tool_name: "drop_table"}},
      pending: %Pending.ToolApproval{tool_use_id: "tu_1", tool_name: "drop_table"},
      messages: [UserMessage.new("please drop it")],
      iteration: 1,
      usage: %Usage{input_tokens: 7, output_tokens: 2}
    }

    {:ok, token} = Protocol.suspend(lease, request, cursor: {1, 3})

    {:ok, waiting} = Lifecycle.fetch(run.id, self())
    assert waiting.status == :waiting
    assert waiting.executor_id == nil and waiting.deadline == nil and waiting.heartbeat_at == nil
    assert waiting.suspension.reason == request.reason
    assert waiting.suspension.checkpoint.messages == request.messages
    assert waiting.suspension.token == token

    # Resume re-enters queued; the next claim carries checkpoint + payload.
    {:ok, queued} = Protocol.resume(Lifecycle, token, {:approved, %{by: 42}}, self())
    assert queued.status == :queued

    lease2 = claim!(run)
    assert lease2.epoch == 2
    assert {%Clementine.Checkpoint{cursor: {1, 3}}, {:approved, %{by: 42}}} = lease2.resume

    # Finish commits terminal state and projection in one unit.
    result = Result.completed(output: "dropped", usage: %Usage{input_tokens: 9, output_tokens: 4})
    {:ok, done} = Protocol.finish(lease2, result)

    assert done.status == :completed
    assert done.usage == %Usage{input_tokens: 9, output_tokens: 4}
    assert_received {:hand_written_projected, %Result.Completed{output: "dropped"}, row}
    assert row.id == run.id

    # Dead end: the zombie's own writes are fenced.
    assert {:error, :lost_lease} = Protocol.heartbeat(lease)
    assert {:error, :already_terminal} = Protocol.finish(lease2, Result.completed())
  end

  test "the guarded CAS is exact: either half of the guard failing means :stale and no write" do
    run = insert_run!()
    claim!(run)

    wrong_epoch = %Clementine.Lifecycle.Transition{
      op: :heartbeat,
      run_ref: run.id,
      expect: %{status: :running, epoch: 5},
      set: %{heartbeat_at: :now}
    }

    wrong_status = %Clementine.Lifecycle.Transition{
      op: :heartbeat,
      run_ref: run.id,
      expect: %{status: :queued, epoch: 1},
      set: %{heartbeat_at: :now}
    }

    assert {:error, :stale} = Lifecycle.apply(wrong_epoch, self())
    assert {:error, :stale} = Lifecycle.apply(wrong_status, self())

    {:ok, facts} = Lifecycle.fetch(run.id, self())
    assert facts.status == :running and facts.epoch == 1
  end
end
