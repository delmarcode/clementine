defmodule Clementine.HeartbeatTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Clementine.{Events, Heartbeat, Usage}
  alias Clementine.Events.Stamper
  alias Clementine.Lifecycle.Protocol
  alias Clementine.Test.{FlakyLifecycle, MemoryLifecycle}

  setup do
    store = MemoryLifecycle.start_store()
    ref = make_ref()
    MemoryLifecycle.seed_queued(store, ref)

    {:ok, lease} =
      Protocol.claim(MemoryLifecycle, ref, executor: "test:heartbeat", ctx: store)

    {:ok, store: store, ref: ref, lease: lease}
  end

  test "renews heartbeat_at every interval", %{store: store, ref: ref, lease: lease} do
    claimed_at = MemoryLifecycle.facts!(store, ref).heartbeat_at

    {:ok, heartbeat} = Heartbeat.start_link(lease, notify: self(), interval: 20)
    Process.sleep(80)
    :ok = Heartbeat.stop(heartbeat)

    renewed_at = MemoryLifecycle.facts!(store, ref).heartbeat_at
    assert DateTime.compare(renewed_at, claimed_at) == :gt
    refute_received {:clementine, :lease_lost, _lease}
  end

  test "piggybacks the stamper's accumulated usage", %{store: store, ref: ref, lease: lease} do
    stamper = Events.stamper(Events.Null, lease)
    Stamper.emit(stamper, :usage_delta, %{input_tokens: 11, output_tokens: 6})

    {:ok, heartbeat} = Heartbeat.start_link(lease, notify: self(), usage: stamper, interval: 20)
    Process.sleep(60)
    :ok = Heartbeat.stop(heartbeat)

    assert MemoryLifecycle.facts!(store, ref).usage == %Usage{input_tokens: 11, output_tokens: 6}
  end

  test "signals lease loss to the runner and stops itself",
       %{store: store, ref: ref, lease: lease} do
    # Zombie simulation: a successor execution bumps the epoch.
    Agent.update(store, fn state ->
      update_in(state.runs[ref].epoch, &(&1 + 1))
    end)

    {:ok, heartbeat} = Heartbeat.start_link(lease, notify: self(), interval: 20)
    monitor = Process.monitor(heartbeat)

    assert_receive {:clementine, :lease_lost, ^lease}, 500
    assert_receive {:DOWN, ^monitor, :process, ^heartbeat, :normal}, 500
  end

  test "treats non-stale storage errors as transient and keeps beating",
       %{store: store, ref: ref, lease: lease} do
    faults = FlakyLifecycle.start_faults([{:fail, :db_blip}])
    flaky_lease = %{lease | lifecycle: FlakyLifecycle, ctx: %{store: store, faults: faults}}
    before = MemoryLifecycle.facts!(store, ref).heartbeat_at

    log =
      capture_log(fn ->
        {:ok, heartbeat} = Heartbeat.start_link(flaky_lease, notify: self(), interval: 20)
        Process.sleep(80)
        :ok = Heartbeat.stop(heartbeat)
      end)

    assert log =~ "transient storage error"
    # The blip was absorbed: a later beat still landed.
    assert DateTime.compare(MemoryLifecycle.facts!(store, ref).heartbeat_at, before) == :gt
    refute_received {:clementine, :lease_lost, _lease}
  end

  test "stop tolerates an already-stopped heartbeat", %{lease: lease} do
    {:ok, heartbeat} = Heartbeat.start_link(lease, notify: self(), interval: 1_000)
    assert :ok = Heartbeat.stop(heartbeat)
    assert :ok = Heartbeat.stop(heartbeat)
  end
end
