defmodule Clementine.Runs.DrainNotifier do
  @moduledoc false
  # Sends {:clementine, :drain} to every executing run when the node begins
  # shutting down.
  #
  # It starts under {Clementine, ...}, which sits after Oban in the host's
  # tree, so it stops before Oban waits out its shutdown_grace_period.
  # Runners unwind inside that window: a run that has not touched the world
  # is requeued for the next node, and one that has finishes
  # interrupted(:drain). The reaper stays the fallback for a node that
  # never got to drain.
  #
  # Workers register in Clementine.Runs.Registry, which Clementine's own
  # application starts, so it outlives the host's tree.

  use GenServer

  @registry Clementine.Runs.Registry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def register, do: Registry.register(@registry, :active, nil)

  @impl GenServer
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    Registry.dispatch(@registry, :active, fn entries ->
      for {pid, _value} <- entries, do: send(pid, {:clementine, :drain})
    end)
  end
end
