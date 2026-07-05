defmodule Clementine.Lease do
  @moduledoc """
  The current right to execute a run: a process-local runtime handle minted
  by a successful claim, never serialized.

  A lease carries the `(run_ref, epoch)` identity plus the lifecycle module
  and host context, so every leased protocol operation is self-contained.
  There is no lock object anywhere in the design — a lease is knowledge of
  which epoch you are, enforced by the `(status, epoch)` guard on every
  write. Losing the lease is never detected proactively; it is discovered
  when a write returns stale.

  When the claimed facts held a suspension and a resume payload, `resume`
  carries `{checkpoint, payload}` for the runner to hand to the rollout.
  """

  @enforce_keys [:run_ref, :epoch, :executor_id, :lifecycle]
  defstruct run_ref: nil,
            epoch: 0,
            executor_id: nil,
            deadline: nil,
            resume: nil,
            lifecycle: nil,
            ctx: nil,
            claimed_at: nil

  @type resume :: nil | {Clementine.Checkpoint.t(), payload :: term()}
  @type t :: %__MODULE__{
          run_ref: term(),
          epoch: pos_integer(),
          executor_id: String.t(),
          deadline: DateTime.t() | nil,
          resume: resume(),
          lifecycle: module(),
          ctx: term(),
          claimed_at: DateTime.t() | nil
        }
end
