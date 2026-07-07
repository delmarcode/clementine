defmodule Clementine.Heartbeat do
  @moduledoc """
  The liveness process for one leased execution.

  Started by the runner after a successful claim, linked so that runner
  death takes the heartbeat down with it (the reaper's stale signal stays
  clean), and stopped by the runner only after the terminal or suspend
  write returns — the write retries transient storage errors under a
  still-live lease instead of racing the reaper.

  Each beat renews `heartbeat_at` through
  `Clementine.Lifecycle.Protocol.heartbeat/2`,
  piggybacking the stamper's accumulated usage so even interrupted runs
  carry billing-grade numbers. `:lost_lease` is definitive: the heartbeat
  sends `{:clementine, :lease_lost, lease}` to its `notify:` target — the
  rollout's blocking points match it and unwind — and stops. Any other
  error is transient: log, keep beating, and let the generous stale
  threshold absorb the gap (heartbeat proves liveness, not progress).
  """

  use GenServer

  require Logger

  alias Clementine.Events.Stamper
  alias Clementine.Lease
  alias Clementine.Lifecycle.Protocol

  @default_interval :timer.seconds(15)

  @doc """
  Starts a linked heartbeat for `lease`.

  ## Options

  - `:notify` (required) - pid to receive `{:clementine, :lease_lost, lease}`
  - `:usage` - a `Clementine.Events.Stamper` sampled on every beat
  - `:interval` - beat interval in ms (default #{@default_interval})
  """
  @spec start_link(Lease.t(), keyword()) :: GenServer.on_start()
  def start_link(%Lease{} = lease, opts) do
    GenServer.start_link(__MODULE__, {lease, opts})
  end

  @doc """
  Stops the heartbeat. Tolerates an already-stopped process — the
  heartbeat stops itself on lease loss.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init({%Lease{} = lease, opts}) do
    state = %{
      lease: lease,
      notify: Keyword.fetch!(opts, :notify),
      stamper: Keyword.get(opts, :usage),
      interval: Keyword.get(opts, :interval, @default_interval)
    }

    # heartbeat_at was stamped at claim; the first renewal is due one
    # interval later.
    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:beat, state) do
    case Protocol.heartbeat(state.lease, usage_sample(state.stamper)) do
      :ok ->
        {:noreply, schedule(state)}

      {:error, :lost_lease} ->
        send(state.notify, {:clementine, :lease_lost, state.lease})
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning(
          "Clementine heartbeat for #{inspect(state.lease.run_ref)} " <>
            "(epoch #{state.lease.epoch}) hit a transient storage error: " <>
            "#{inspect(reason)}; will retry next beat"
        )

        {:noreply, schedule(state)}
    end
  end

  defp schedule(state) do
    Process.send_after(self(), :beat, state.interval)
    state
  end

  defp usage_sample(nil), do: []
  defp usage_sample(%Stamper{} = stamper), do: [usage: Stamper.usage(stamper)]
end
