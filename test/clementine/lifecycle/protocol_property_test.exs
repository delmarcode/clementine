defmodule Clementine.Lifecycle.ProtocolPropertyTest do
  @moduledoc """
  Generative check of the protocol's governing invariants: arbitrary op
  sequences against a real-CAS lifecycle can never violate them, no matter
  how nonsensical the ordering.

  Invariants under test (RFC §Governing Invariants):

  - `status` is always a member of the closed status set.
  - `epoch` is monotonically nondecreasing, and increments exactly across
    successful claims — claim is the only mint.
  - Terminal statuses are dead ends: after the first terminal fact, facts
    never change again, in any field.
  - `effects?` is monotone (the fence never lowers).
  - Exactly one terminal projection fires per run, ever.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.Pending.ToolApproval
  alias Clementine.Result
  alias Clementine.Test.MemoryLifecycle
  alias Clementine.{ApprovalRequest, InterruptReason, Suspension, Usage}

  @ops [
    :claim,
    :heartbeat,
    :mark_effects,
    :suspend,
    :resume_approved,
    :resume_denied,
    :request_cancel,
    :finish_completed,
    :finish_failed,
    :finish_drain,
    :interrupt,
    :requeue_reaper,
    :requeue_drain
  ]

  property "no op sequence violates the governing invariants" do
    check all(ops <- StreamData.list_of(StreamData.member_of(@ops), max_length: 40)) do
      store = MemoryLifecycle.start_store()
      MemoryLifecycle.seed_queued(store, "run")

      initial = MemoryLifecycle.facts!(store, "run")

      Enum.reduce(ops, %{lease: nil, prev: initial, claims: 0}, fn op, state ->
        execute(op, store, state.lease)

        facts = MemoryLifecycle.facts!(store, "run")
        assert_invariants(state.prev, facts, store)

        %{
          state
          | lease: current_lease(store, state.lease),
            prev: facts,
            claims: state.claims
        }
      end)
    end
  end

  defp assert_invariants(prev, facts, store) do
    assert facts.status in Facts.statuses()
    assert facts.epoch >= prev.epoch
    assert (facts.epoch - prev.epoch) in [0, 1]

    if prev.effects?, do: assert(facts.effects?)

    if Facts.terminal?(prev) do
      assert facts == prev, "terminal facts changed: #{inspect(prev)} -> #{inspect(facts)}"
    end

    # Epoch moves only via claim: a bump implies the new status is :running.
    if facts.epoch == prev.epoch + 1 do
      assert facts.status == :running
    end

    projections = MemoryLifecycle.projections(store)
    assert length(projections) <= 1

    if Facts.terminal?(facts) do
      assert length(projections) == 1
    end
  end

  # Ops fire blindly — wrong-state calls must error, never corrupt.
  defp execute(:claim, store, _lease) do
    Protocol.claim(MemoryLifecycle, "run", executor: "prop", ctx: store)
  end

  defp execute(_op, _store, nil), do: :no_lease

  defp execute(:heartbeat, _store, lease), do: Protocol.heartbeat(lease)

  defp execute(:mark_effects, _store, lease), do: Protocol.mark_effects(lease)

  defp execute(:suspend, _store, lease) do
    Protocol.suspend(lease, request(), cursor: {lease.epoch, 1})
  end

  defp execute(:resume_approved, store, _lease), do: try_resume(store, {:approved, %{}})
  defp execute(:resume_denied, store, _lease), do: try_resume(store, {:denied, %{}})

  defp execute(:request_cancel, store, _lease) do
    Protocol.request_cancel(MemoryLifecycle, "run", :prop_cancel, store)
  end

  defp execute(:finish_completed, _store, lease) do
    Protocol.finish(lease, Result.completed(output: "x"))
  end

  defp execute(:finish_failed, _store, lease) do
    Protocol.finish(lease, Result.failed(:max_iterations_reached))
  end

  defp execute(:finish_drain, _store, lease) do
    Protocol.finish(lease, Result.interrupted(:drain))
  end

  defp execute(:interrupt, store, _lease) do
    case MemoryLifecycle.fetch("run", store) do
      {:ok, %Facts{} = facts} ->
        if Facts.active?(facts) do
          Protocol.interrupt(MemoryLifecycle, facts, InterruptReason.new(:lease_expired), store)
        end

      _ ->
        :ok
    end
  end

  defp execute(:requeue_reaper, store, _lease) do
    case MemoryLifecycle.fetch("run", store) do
      {:ok, %Facts{status: :running} = facts} ->
        Protocol.requeue(MemoryLifecycle, facts, :lease_expired, store)

      _ ->
        :ok
    end
  end

  defp execute(:requeue_drain, _store, lease), do: Protocol.requeue(lease, :drain)

  defp try_resume(store, payload) do
    case MemoryLifecycle.fetch("run", store) do
      {:ok, %Facts{suspension: %Suspension{token: token}}} ->
        Protocol.resume(MemoryLifecycle, token, payload, store)

      _ ->
        :ok
    end
  end

  # The freshest lease is whichever claim last succeeded; model it by
  # rebuilding from facts when the run is running (epoch identifies it).
  defp current_lease(store, prev_lease) do
    case MemoryLifecycle.fetch("run", store) do
      {:ok, %Facts{status: :running, epoch: epoch} = facts} ->
        %Clementine.Lease{
          run_ref: "run",
          epoch: epoch,
          executor_id: facts.executor_id,
          deadline: facts.deadline,
          lifecycle: MemoryLifecycle,
          ctx: store
        }

      _ ->
        prev_lease
    end
  end

  defp request do
    %Suspension.Request{
      reason: {:approval, %ApprovalRequest{tool_use_id: "t", tool_name: "n", args: %{}}},
      pending: %ToolApproval{tool_use_id: "t", tool_name: "n", args: %{}},
      messages: [],
      iteration: 1,
      usage: %Usage{}
    }
  end
end
