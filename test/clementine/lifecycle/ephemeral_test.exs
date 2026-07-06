defmodule Clementine.Lifecycle.EphemeralTest do
  use ExUnit.Case, async: true

  alias Clementine.Lifecycle.{Ephemeral, Facts, Protocol, Transition}
  alias Clementine.{Result, Usage}

  test "create seeds a queued run in this process" do
    {ref, ctx} = Ephemeral.create()

    assert {:ok, %Facts{ref: ^ref, status: :queued, epoch: 0, queued_at: %DateTime{}}} =
             Ephemeral.fetch(ref, ctx)
  end

  test "the full protocol cycle runs against the ephemeral store" do
    {ref, ctx} = Ephemeral.create()

    {:ok, lease} =
      Protocol.claim(Ephemeral, ref, executor: "ephemeral:test", ctx: ctx, max_duration: 60_000)

    assert lease.epoch == 1
    # The deadline was minted from max_duration against this process's clock.
    assert DateTime.compare(lease.deadline, DateTime.utc_now()) == :gt
    assert DateTime.diff(lease.deadline, DateTime.utc_now(), :second) <= 60

    assert :ok = Protocol.heartbeat(lease, usage: %Usage{input_tokens: 3, output_tokens: 1})

    result = Result.completed(output: "done", usage: %Usage{input_tokens: 3, output_tokens: 1})
    assert {:ok, %Facts{status: :completed}} = Protocol.finish(lease, result)

    # The ephemeral projection is remembering the terminal result.
    assert %Result.Completed{output: "done"} = Ephemeral.result(ctx)
  end

  test "the CAS still checks — a mismatched guard is stale" do
    {ref, ctx} = Ephemeral.create()

    transition = %Transition{
      op: :claim,
      run_ref: ref,
      expect: %{status: :queued, epoch: 7},
      set: %{status: :running, epoch: 8}
    }

    assert {:error, :stale} = Ephemeral.apply(transition, ctx)
    assert {:ok, %Facts{status: :queued, epoch: 0}} = Ephemeral.fetch(ref, ctx)
  end

  test "nested symbolic stamps resolve against this process's clock" do
    {ref, ctx} = Ephemeral.create()
    {:ok, _lease} = Protocol.claim(Ephemeral, ref, executor: "ephemeral:test", ctx: ctx)

    {:ok, :flagged} = Protocol.request_cancel(Ephemeral, ref, :user_stop, ctx)

    assert {:ok, %Facts{cancel: %{reason: :user_stop, requested_at: %DateTime{}}}} =
             Ephemeral.fetch(ref, ctx)
  end

  test "foreign refs and deleted runs are not found" do
    {ref, ctx} = Ephemeral.create()
    {_other_ref, other_ctx} = Ephemeral.create()

    assert {:error, :not_found} = Ephemeral.fetch(ref, other_ctx)

    :ok = Ephemeral.delete(ctx)
    assert {:error, :not_found} = Ephemeral.fetch(ref, ctx)
    assert Ephemeral.result(ctx) == nil
  end
end
