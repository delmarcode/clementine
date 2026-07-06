defmodule Clementine.Event do
  @moduledoc """
  An observable execution fact: ordered, append-only, immutable — and
  advisory. Anything an observer derives from events must be re-derivable
  from the terminal result plus lifecycle facts; the event stream is never
  truth.

  Identity is `{epoch, seq}`: the epoch of the emitting execution and a
  runner-local sequence number, gapless and monotonic within an epoch.
  Total order is lexicographic — the same `(term, index)` construction as
  Raft, applied to observation. Consumers drop events from an epoch lower
  than the highest seen (a superseded executor's stragglers), and a closed
  RunView rejects everything at or below its final epoch (a reaped run's
  ghosts).
  """

  @enforce_keys [:run_ref, :epoch, :seq, :type]
  defstruct run_ref: nil, epoch: 0, seq: 0, type: nil, payload: %{}

  @type t :: %__MODULE__{
          run_ref: term(),
          epoch: non_neg_integer(),
          seq: non_neg_integer(),
          type: atom(),
          payload: map()
        }

  @doc "Lexicographic `(epoch, seq)` comparison."
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{epoch: e1, seq: s1}, %__MODULE__{epoch: e2, seq: s2}) do
    cond do
      {e1, s1} < {e2, s2} -> :lt
      {e1, s1} > {e2, s2} -> :gt
      true -> :eq
    end
  end

  @spec cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def cursor(%__MODULE__{epoch: epoch, seq: seq}), do: {epoch, seq}
end
