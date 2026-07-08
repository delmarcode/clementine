defmodule Clementine.Emissions do
  @moduledoc false
  # The post-commit emission seam: telemetry events, `after_transition/3`
  # hooks, and cancel pushes all describe *committed* state, so a caller
  # executing protocol operations inside its own enclosing atomic unit
  # (the loop adapter's `apply_step/2` cancelling children as cargo)
  # brackets that unit with begin/flush/drop — emissions stash in arrival
  # order, fire only after the unit commits, and drop when it rolls back.
  # No observer, metric, or push may describe a transition that never
  # happened.
  #
  # The stash is process-local because the enclosing transaction is: Ecto
  # transactions live on the calling process's connection. Without an
  # active bracket, `emit/1` fires immediately — zero cost, zero behavior
  # change on every path that never nests.

  @key :clementine_deferred_emissions

  @spec emit((-> any())) :: :ok
  def emit(fun) when is_function(fun, 0) do
    case Process.get(@key) do
      nil ->
        fun.()
        :ok

      stashed ->
        Process.put(@key, [fun | stashed])
        :ok
    end
  end

  @spec begin_deferral() :: :ok
  def begin_deferral do
    Process.put(@key, [])
    :ok
  end

  @spec flush() :: :ok
  def flush do
    case Process.delete(@key) do
      nil -> :ok
      stashed -> stashed |> Enum.reverse() |> Enum.each(& &1.())
    end

    :ok
  end

  @spec drop() :: :ok
  def drop do
    Process.delete(@key)
    :ok
  end
end
