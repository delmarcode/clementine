defmodule Clementine.Lifecycle.Transition do
  @moduledoc """
  One guarded write, as a value: an exact `(status, epoch)` expectation,
  the partial facts to set, an operation tag, and — on every transition
  into a terminal status — the `Clementine.Result` the host projection
  consumes.

  Semantics the host `apply` must honor:

  - The write is atomic and conditional on the stored facts matching
    `expect` exactly; a non-match returns `{:error, :stale}` and changes
    nothing. `expect` is never a set and never a wildcard.
  - In `set`, an absent key means *leave the stored value untouched*; an
    explicitly present `nil` means *write NULL*. The core never includes a
    key it does not intend to write.
  - Timestamps in `set` are symbolic — `:now` or `{:now_plus, ms}` — and
    the host resolves them against the *storage* clock, never the app
    node's. This keeps staleness arithmetic on a single time source.
  - When `result` is present, the host projection runs in the same atomic
    unit; if the projection raises, the transition must not commit.
  """

  @ops [
    :claim,
    :heartbeat,
    :mark_effects,
    :suspend,
    :resume,
    :requeue,
    :cancel_request,
    :finish,
    :interrupt
  ]

  @enforce_keys [:op, :run_ref, :expect, :set]
  defstruct op: nil, run_ref: nil, expect: nil, set: %{}, result: nil, meta: %{}

  @type op ::
          :claim
          | :heartbeat
          | :mark_effects
          | :suspend
          | :resume
          | :requeue
          | :cancel_request
          | :finish
          | :interrupt

  @type stamp :: :now | {:now_plus, non_neg_integer()}

  @type expect :: %{
          status: Clementine.Lifecycle.Facts.status(),
          epoch: non_neg_integer()
        }

  @type t :: %__MODULE__{
          op: op(),
          run_ref: term(),
          expect: expect(),
          set: map(),
          result: Clementine.Result.t() | nil,
          meta: map()
        }

  @spec ops() :: [op()]
  def ops, do: @ops

  @doc "True when this transition lands in a terminal status (`result` present)."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{result: nil}), do: false
  def terminal?(%__MODULE__{}), do: true
end
