defmodule Clementine.Runs.Courier do
  @moduledoc false
  # Delivers one execution's events to the host's run_event/2, in order,
  # from a process of its own, so the host's callback never runs in the
  # run's process or inside a transaction.
  #
  # Backpressure is bounded both ways. The run sends events without
  # waiting, but every `window` events it waits for the courier to catch
  # up, so the callback is never more than `window` events behind and the
  # courier's mailbox never grows past that. A wait that takes longer than
  # `timeout` (a callback that hangs, or a courier that died) cuts the
  # host off for the rest of the execution: events are advisory, so the
  # run goes on without them rather than stall.
  #
  # The lifecycle flushes before each write the run makes (Runs.Lifecycle),
  # so every event emitted before a transition reaches the host before
  # the host hears of the transition.
  #
  # The courier and its run are not linked, so nothing that happens to
  # the courier reaches the run: not a raise in the callback, and not a
  # crash of a process the callback linked to it. A guard process links
  # them the other way: when the run dies, it kills the courier, even one
  # blocked in a callback, and the events still queued are dropped. A run
  # that ends normally has stopped its courier first (stop/1).

  @behaviour Clementine.Events

  require Logger

  alias Clementine.{Event, Lease}

  @window 64
  @timeout 5_000

  # :atomics indices: events sent, and whether the host is cut off.
  @sent 1
  @cut_off 2

  @enforce_keys [:pid, :state, :host, :run_id, :window, :timeout]
  defstruct [:pid, :state, :host, :run_id, :window, :timeout]

  @type t :: %__MODULE__{}

  @doc false
  # The worker's sink: the courier rides in the lease's ctx.
  @impl Clementine.Events
  def emit(%Lease{ctx: %{courier: %__MODULE__{} = courier}}, %Event{} = event) do
    deliver(courier, event)
  end

  def emit(_lease, _event), do: :ok

  @doc false
  # `run` is what the host's callback receives with every event. The
  # options exist for tests.
  @spec start(module(), struct(), keyword()) :: t()
  def start(host, run, opts \\ []) do
    owner = self()
    pid = spawn(fn -> loop(host, run) end)
    spawn(fn -> guard(owner, pid) end)

    %__MODULE__{
      pid: pid,
      state: :atomics.new(2, signed: false),
      host: host,
      run_id: run.id,
      window: Keyword.get(opts, :window, @window),
      timeout: Keyword.get(opts, :timeout, @timeout)
    }
  end

  @doc false
  # Replaces the run the callback receives. The lifecycle sends the claimed
  # run from the run's own process before its first event, so every event
  # arrives with the run as its claim committed it.
  @spec put_run(t(), struct()) :: :ok
  def put_run(%__MODULE__{pid: pid}, run) do
    send(pid, {:run, run})
    :ok
  end

  @doc false
  @spec deliver(t(), Event.t()) :: :ok
  def deliver(%__MODULE__{} = courier, %Event{} = event) do
    if cut_off?(courier) do
      :ok
    else
      send(courier.pid, {:event, event})
      sent = :atomics.add_get(courier.state, @sent, 1)
      if rem(sent, courier.window) == 0, do: sync(courier), else: :ok
    end
  end

  @doc false
  # Returns once the host's callback has returned for every event
  # delivered so far, or once the host is cut off.
  @spec flush(t()) :: :ok
  def flush(%__MODULE__{} = courier) do
    if cut_off?(courier), do: :ok, else: sync(courier)
  end

  @doc false
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{} = courier) do
    flush(courier)
    send(courier.pid, :stop)
    :ok
  end

  defp cut_off?(%__MODULE__{state: state}), do: :atomics.get(state, @cut_off) == 1

  defp sync(%__MODULE__{pid: pid, timeout: timeout} = courier) do
    ref = Process.monitor(pid)
    send(pid, {:sync, self(), ref})

    receive do
      {^ref, :synced} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        cut_off(courier, "stopped (#{inspect(reason)})")
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)

        # A reply that raced the kill would otherwise sit in the run's
        # mailbox for good.
        receive do
          {^ref, :synced} -> :ok
        after
          0 -> :ok
        end

        cut_off(courier, "fell #{timeout} ms behind")
    end
  end

  defp cut_off(%__MODULE__{state: state} = courier, why) do
    if :atomics.compare_exchange(state, @cut_off, 0, 1) == :ok do
      Logger.warning(
        "#{inspect(courier.host)}.run_event/2 #{why}; the rest of this execution's " <>
          "events are dropped (run: #{courier.run_id})"
      )
    end

    :ok
  end

  # Kills the courier once its run is gone, and goes when the courier
  # does. A monitor on a process already gone fires at once.
  defp guard(owner, courier) do
    owner_ref = Process.monitor(owner)
    courier_ref = Process.monitor(courier)

    receive do
      {:DOWN, ^owner_ref, :process, _owner, _reason} -> Process.exit(courier, :kill)
      {:DOWN, ^courier_ref, :process, _courier, _reason} -> :ok
    end
  end

  defp loop(host, run) do
    receive do
      {:run, run} ->
        loop(host, run)

      {:event, event} ->
        call(host, run, event)
        loop(host, run)

      {:sync, from, ref} ->
        send(from, {ref, :synced})
        loop(host, run)

      :stop ->
        :ok
    end
  end

  defp call(host, run, event) do
    host.run_event(run, event)
  rescue
    e ->
      Logger.warning(
        "#{inspect(host)}.run_event/2 raised: #{Exception.message(e)} " <>
          "(run: #{run.id}, event: #{event.type})"
      )
  catch
    kind, reason ->
      Logger.warning(
        "#{inspect(host)}.run_event/2 #{kind}: #{inspect(reason)} " <>
          "(run: #{run.id}, event: #{event.type})"
      )
  end
end
