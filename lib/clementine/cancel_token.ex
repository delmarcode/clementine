defmodule Clementine.CancelToken do
  @moduledoc """
  A cooperative cancellation token for agent runs.

  A token is a process-safe, shareable flag backed by `:atomics`. It can be
  created in one process, handed to a run executing in another process, and
  flipped from anywhere — the run observes the cancellation at the next safe
  boundary it checks and tears down cooperatively.

  Unlike process death, this lets a run stop gracefully (emitting its
  `:loop_end` event and telemetry) rather than crashing.

  ## Example

      token = Clementine.CancelToken.new()

      # In some other process / later:
      Clementine.CancelToken.cancel(token)

      # The loop checks this at safe boundaries:
      Clementine.CancelToken.cancelled?(token)
      #=> true

  """

  @opaque t :: :atomics.atomics_ref()

  @doc """
  Creates a new, un-cancelled token.

  The returned reference can be shared across processes.
  """
  @spec new() :: t()
  def new do
    :atomics.new(1, signed: false)
  end

  @doc """
  Marks the token as cancelled.

  Idempotent: calling it more than once has no additional effect.
  """
  @spec cancel(t()) :: :ok
  def cancel(token) do
    :atomics.put(token, 1, 1)
  end

  @doc """
  Returns `true` if the token has been cancelled, `false` otherwise.
  """
  @spec cancelled?(t()) :: boolean()
  def cancelled?(token) do
    :atomics.get(token, 1) != 0
  end
end
