defmodule Clementine.Emissions do
  @moduledoc false
  # The post-commit emission seam: telemetry events, `after_transition/3`
  # hooks, and cancel pushes all describe *committed* state, so a caller
  # executing protocol operations inside its own enclosing atomic unit
  # (the loop adapter's `apply_step/2` cancelling children as cargo, the
  # lifecycle adapter's terminal transaction running projection glue)
  # brackets that unit with begin/flush/drop — emissions stash in arrival
  # order, fire only after the unit commits, and drop when it rolls back.
  # No observer, metric, or push may describe a transition that never
  # happened.
  #
  # Brackets nest: `begin_deferral/0` pushes a frame and returns its
  # token; `flush/1` closes the frame — firing its emissions when it was
  # outermost, otherwise handing them to the enclosing frame, because an
  # inner Ecto "transaction" inside an outer one is a savepoint and its
  # work is durable only when the *outer* unit commits. `drop/1` discards
  # the frame alone. Both no-op when the token's frame is already closed,
  # so the `after`-block `drop/1` is safe following a `flush/1`.
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

      [{token, frame} | rest] ->
        Process.put(@key, [{token, [fun | frame]} | rest])
        :ok
    end
  end

  @spec begin_deferral() :: reference()
  def begin_deferral do
    token = make_ref()
    Process.put(@key, [{token, []} | Process.get(@key) || []])
    token
  end

  @spec flush(reference()) :: :ok
  def flush(token) do
    case Process.get(@key) do
      [{^token, frame}] ->
        Process.delete(@key)
        frame |> Enum.reverse() |> Enum.each(& &1.())

      [{^token, frame}, {parent, parent_frame} | rest] ->
        Process.put(@key, [{parent, frame ++ parent_frame} | rest])

      _already_closed ->
        :ok
    end

    :ok
  end

  @spec drop(reference()) :: :ok
  def drop(token) do
    case Process.get(@key) do
      [{^token, _frame}] -> Process.delete(@key)
      [{^token, _frame} | rest] -> Process.put(@key, rest)
      _already_closed -> :ok
    end

    :ok
  end
end
