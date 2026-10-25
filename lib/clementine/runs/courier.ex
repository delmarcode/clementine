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
  # The courier is linked to its run, so a run that is killed takes it
  # along, even mid-callback, and the events still queued are dropped. A
  # run that ends normally stops it (stop/1), and the courier's own exits
  # never reach the run: callbacks cannot crash it, and the cut-off unlinks
  # before it kills.

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
    pid = spawn_link(fn -> init(owner, host, run) end)

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
        Process.unlink(pid)
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

  defp init(owner, host, run) do
    loop(Process.monitor(owner), host, run)
  end

  # Messages from the run arrive in the order it sent them, and before its
  # DOWN, so a run that exits normally without stop/1 has its events
  # delivered first.
  defp loop(owner_ref, host, run) do
    receive do
      {:event, event} ->
        call(host, run, event)
        loop(owner_ref, host, run)

      {:sync, from, ref} ->
        send(from, {ref, :synced})
        loop(owner_ref, host, run)

      :stop ->
        :ok

      {:DOWN, ^owner_ref, :process, _owner, _reason} ->
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
