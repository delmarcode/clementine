defmodule Clementine.Runs.CourierTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Clementine.{Event, Lease}
  alias Clementine.Runs.Courier

  defmodule Host do
    @moduledoc false
    # Reports each event to the test, after holding until released or
    # raising when its payload says so.
    def run_event(%{test: test}, %Event{seq: seq, payload: payload}) do
      if payload[:hold], do: hold(test)
      if payload[:raise], do: raise("event #{seq} raised")
      send(test, {:delivered, seq, self()})
    end

    defp hold(test) do
      send(test, {:holding, self()})

      receive do
        :release -> :ok
      end
    end
  end

  defp run, do: %{id: "run-1", test: self()}

  defp event(seq, payload \\ %{}) do
    %Event{run_ref: "run-1", epoch: 1, seq: seq, type: :text_delta, payload: payload}
  end

  defp delivered do
    receive do
      {:delivered, seq, _courier} -> [seq | delivered()]
    after
      0 -> []
    end
  end

  test "delivers a run's events in order, from a process of its own" do
    courier = Courier.start(Host, run())

    for seq <- 1..200, do: Courier.deliver(courier, event(seq))
    Courier.stop(courier)

    assert delivered() == Enum.to_list(1..200)
    refute courier.pid == self()
  end

  test "flush returns once the host has every event delivered so far" do
    courier = Courier.start(Host, run(), window: 1_000)

    for seq <- 1..10, do: Courier.deliver(courier, event(seq))
    assert :ok = Courier.flush(courier)

    # Already in the mailbox: flush waited for the callbacks to return.
    assert delivered() == Enum.to_list(1..10)
  end

  test "the run waits for the host once it is a window behind, and no longer" do
    courier = Courier.start(Host, run(), window: 4)
    test = self()

    producer =
      spawn_link(fn ->
        Courier.deliver(courier, event(1, %{hold: true}))
        for seq <- 2..4, do: Courier.deliver(courier, event(seq))
        send(test, :delivered_four)
      end)

    assert_receive {:holding, held}

    # Four events out with the first one held: the producer waits.
    refute_receive :delivered_four, 100
    assert {:status, :waiting} = Process.info(producer, :status)

    send(held, :release)
    assert_receive :delivered_four
    assert delivered() == [1, 2, 3, 4]
  end

  test "a host that stays behind past the timeout is cut off, and the run goes on" do
    courier = Courier.start(Host, run(), window: 1, timeout: 50)

    log =
      capture_log(fn ->
        assert :ok = Courier.deliver(courier, event(1, %{hold: true}))
      end)

    assert log =~ "Clementine.Runs.CourierTest.Host.run_event/2 fell 50 ms behind"
    assert log =~ "the rest of this execution's events are dropped (run: run-1)"
    refute Process.alive?(courier.pid)

    # Later events are dropped without waiting, and flush and stop return.
    assert :ok = Courier.deliver(courier, event(2))
    assert :ok = Courier.flush(courier)
    assert :ok = Courier.stop(courier)
    assert delivered() == []
  end

  test "a courier that is gone cuts the host off at the next wait" do
    courier = Courier.start(Host, run(), window: 1_000)

    Process.exit(courier.pid, :kill)

    log = capture_log(fn -> assert :ok = Courier.flush(courier) end)

    assert log =~ ~r"run_event/2 stopped \(:(killed|noproc)\)"
    assert :ok = Courier.deliver(courier, event(1))
    assert delivered() == []
  end

  test "a raising host is logged, and the next event still arrives" do
    courier = Courier.start(Host, run())

    log =
      capture_log(fn ->
        Courier.deliver(courier, event(1, %{raise: true}))
        Courier.deliver(courier, event(2))
        Courier.flush(courier)
      end)

    assert log =~ "Clementine.Runs.CourierTest.Host.run_event/2 raised: event 1 raised"
    assert log =~ "(run: run-1, event: text_delta)"
    assert delivered() == [2]
  end

  test "a crash the callback links to the courier never reaches the run" do
    courier = Courier.start(Host, run(), window: 1_000)

    # The callback's own child takes the courier down; the run hears of it
    # only at its next wait, as a cut-off.
    ref = Process.monitor(courier.pid)

    spawn(fn ->
      Process.link(courier.pid)
      exit(:callback_child_failed)
    end)

    assert_receive {:DOWN, ^ref, :process, _pid, :callback_child_failed}
    log = capture_log(fn -> assert :ok = Courier.flush(courier) end)

    assert log =~ ~r"run_event/2 stopped \(:(callback_child_failed|noproc)\)"
    assert Process.alive?(self())
  end

  test "a run that is killed takes its courier along, even mid-callback" do
    test = self()

    owner =
      spawn(fn ->
        courier = Courier.start(Host, %{id: "run-1", test: test})
        send(test, {:courier, courier.pid})
        Courier.deliver(courier, event(1, %{hold: true}))

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:courier, pid}
    assert_receive {:holding, ^pid}
    ref = Process.monitor(pid)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  test "a run that ends without stopping its courier takes it along" do
    test = self()

    spawn(fn ->
      courier = Courier.start(Host, %{id: "run-1", test: test})
      send(test, {:courier, courier.pid})
    end)

    assert_receive {:courier, pid}
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:killed, :noproc]
  end

  test "as a sink, it delivers through the courier in the lease's ctx and ignores any other" do
    courier = Courier.start(Host, run())

    lease = %Lease{
      run_ref: "run-1",
      epoch: 1,
      executor_id: "x",
      lifecycle: nil,
      ctx: %{courier: courier}
    }

    assert :ok = Courier.emit(lease, event(1))
    assert :ok = Courier.emit(%{lease | ctx: %{courier: nil}}, event(2))
    Courier.flush(courier)

    assert delivered() == [1]
  end
end
