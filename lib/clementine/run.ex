defmodule Clementine.Run do
  @moduledoc """
  One durable attempt to execute a rollout — the lifecycle object, not the
  worker and not the process.

  `ref` is the host application's identifier for the run record its
  lifecycle implementation reads and writes; the lifecycle state itself
  (status, epoch, heartbeat, suspension) lives in host storage and is
  viewed through `Clementine.Lifecycle.Facts`.
  """

  @enforce_keys [:ref, :rollout]
  defstruct ref: nil, rollout: nil, metadata: %{}

  @type t :: %__MODULE__{
          ref: term(),
          rollout: Clementine.Rollout.t(),
          metadata: map()
        }

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)
end
