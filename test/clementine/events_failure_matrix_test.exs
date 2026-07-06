defmodule Clementine.EventsFailureMatrixTest do
  @moduledoc """
  Failure-matrix rows 1 and 2 (RFC §Failure Matrix), run end to end
  through the real protocol core, a real-CAS lifecycle, the stamper, and
  the fold — the observation half of the zombie story: writes are fenced
  by the `(status, epoch)` guard, events are silenced by fold closure.
  """

  use ExUnit.Case, async: true

  alias Clementine.Event
  alias Clementine.Events
  alias Clementine.Events.Stamper
  alias Clementine.InterruptReason
  alias Clementine.Lifecycle.Protocol
  alias Clementine.Result
  alias Clementine.RunView
  alias Clementine.Test.{CollectingSink, MemoryLifecycle}
  alias Clementine.Usage

  setup do
    store = MemoryLifecycle.start_store()
    MemoryLifecycle.seed_queued(store, "run_1")
    {:ok, lease} = Protocol.claim(MemoryLifecycle, "run_1", executor: "pod-a", ctx: store)
    {:ok, store: store, lease: lease}
  end

  defp drain_into(view) do
    receive do
      {:clementine_event, %Event{} = event} -> drain_into(RunView.apply(view, event))
    after
      0 -> view
    end
  end

  test "matrix row 1: pod OOM mid-stream — the view goes quiet, then the reaper's transition notification closes it",
       %{store: store, lease: lease} do
    stamper = Events.stamper(CollectingSink, lease)

    # Mid-stream: text flowing, usage piggybacked onto a heartbeat.
    Stamper.emit(stamper, :iteration_start, %{n: 1})
    Stamper.emit(stamper, :text_delta, %{content: "Reticulating spl"})
    Stamper.emit(stamper, :usage_delta, %{input_tokens: 120, output_tokens: 8})
    assert :ok = Protocol.heartbeat(lease, usage: Stamper.usage(stamper))

    view = drain_into(RunView.new("run_1"))
    assert view.text == "Reticulating spl"
    assert RunView.cursor(view) == {1, 3}

    # OOM: the process (and its linked heartbeat) dies. Nothing is written,
    # nothing more is emitted — the view just goes quiet.
    quiet = drain_into(view)
    assert quiet == view
    refute RunView.closed?(quiet)

    # The reaper's threshold passes; its verdict lands as a guarded
    # interrupt carrying the heartbeat-piggybacked usage approximation.
    {:ok, facts} = MemoryLifecycle.fetch("run_1", store)
    assert facts.status == :running

    {:ok, terminal} =
      Protocol.interrupt(MemoryLifecycle, facts, InterruptReason.new(:lease_expired), store)

    assert terminal.status == :interrupted
    assert terminal.interrupt.code == :lease_expired

    # The projection fired for the reaped run exactly as for a finished one.
    assert [{"run_1", %Result.Interrupted{usage: usage} = result}] =
             MemoryLifecycle.projections(store)

    assert result.reason.code == :lease_expired
    assert usage == %Usage{input_tokens: 120, output_tokens: 8}

    # The transition notification is how the observer learns; it closes
    # the fold, pinning the last live state under the terminal facts.
    closed = RunView.close(quiet, terminal)
    assert RunView.closed?(closed)
    assert closed.status == :interrupted
    assert closed.final.interrupt.code == :lease_expired
    assert closed.text == "Reticulating spl"
  end

  test "matrix row 2: zombie wakes after reap — every write stale, ghost events rejected once the fold closes",
       %{store: store, lease: lease} do
    stamper = Events.stamper(CollectingSink, lease)

    Stamper.emit(stamper, :text_delta, %{content: "Before the partition. "})
    view = drain_into(RunView.new("run_1"))

    # The partition outlasts the stale threshold; the reaper interrupts.
    {:ok, facts} = MemoryLifecycle.fetch("run_1", store)

    {:ok, terminal} =
      Protocol.interrupt(MemoryLifecycle, facts, InterruptReason.new(:lease_expired), store)

    # `interrupted` is a dead end: no successor epoch will ever exist, so
    # epoch comparison alone could never drop this zombie's events.
    assert {:error, {:not_claimable, :interrupted}} =
             Protocol.claim(MemoryLifecycle, "run_1", executor: "pod-b", ctx: store)

    # The zombie wakes. Every write is fenced by the (status, epoch) guard
    # and maps to the precise protocol error — state never splits.
    assert {:error, :lost_lease} = Protocol.heartbeat(lease)
    assert {:error, :lost_lease} = Protocol.mark_effects(lease)
    assert {:error, :lost_lease} = Protocol.cancellation(lease)
    assert {:error, :already_terminal} = Protocol.finish(lease, Result.completed(output: "?"))

    # Its events, though, are not database writes: until the terminal
    # notification reaches the observer, ghost deltas land in the open
    # view. Bounded, advisory, touching nothing durable — the stated window.
    Stamper.emit(stamper, :text_delta, %{content: "Ghost of epoch one."})
    haunted = drain_into(view)
    assert haunted.text == "Before the partition. Ghost of epoch one."

    # The notification arrives and closes the fold. Closure, not epoch
    # comparison, is the silencer.
    closed = RunView.close(haunted, terminal)

    # The zombie streams on at the final epoch; the closed view rejects
    # every straggler, at and below it.
    Stamper.emit(stamper, :text_delta, %{content: "Anyone there?"})
    Stamper.emit(stamper, :tool_use_start, %{tool_use_id: "tu_ghost", name: "bash"})
    silenced = drain_into(closed)

    assert silenced == closed
    assert silenced.text == "Before the partition. Ghost of epoch one."
    assert silenced.tools == %{}

    # Exactly one terminal writer, exactly one projection.
    assert [{"run_1", %Result.Interrupted{}}] = MemoryLifecycle.projections(store)
  end
end
