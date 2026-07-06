defmodule Clementine.Events.Null do
  @moduledoc """
  The no-op sink, for the ephemeral path and any caller that does not
  observe. Events are advisory, so discarding them is always legal.
  """

  @behaviour Clementine.Events

  @impl true
  def emit(_lease, _event), do: :ok
end
