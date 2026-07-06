defmodule Clementine.Test.FlakyLifecycle do
  @moduledoc """
  Wraps `Clementine.Test.MemoryLifecycle` with scripted `apply` faults, for
  testing the protocol's transient-retry posture. `ctx` is
  `%{store: pid, faults: pid}`; the faults Agent holds a queue of
  `{:fail, reason}` | `:pass` entries consumed one per `apply` call (empty
  queue passes through).
  """

  @behaviour Clementine.Lifecycle

  alias Clementine.Test.MemoryLifecycle

  def start_faults(script) when is_list(script) do
    {:ok, faults} = Agent.start_link(fn -> script end)
    faults
  end

  @impl true
  def fetch(run_ref, %{store: store}), do: MemoryLifecycle.fetch(run_ref, store)

  @impl true
  def apply(transition, %{store: store, faults: faults}) do
    case Agent.get_and_update(faults, fn
           [] -> {:pass, []}
           [head | rest] -> {head, rest}
         end) do
      {:fail, reason} -> {:error, reason}
      :pass -> MemoryLifecycle.apply(transition, store)
    end
  end
end
