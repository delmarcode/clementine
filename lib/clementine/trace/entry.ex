defmodule Clementine.Trace.Entry do
  @moduledoc """
  One entry of a run's trace: what the engine did, recorded as it did it.
  `Clementine.Runs.trace/1` reads them back oldest first.

  Identity is `{epoch, seq}`, as for `Clementine.Event`: the epoch of the
  execution that recorded it and a sequence number that starts at 1 for
  each execution. A run that resumes after an approval is a new
  execution of the same run, so its trace continues under the next
  epoch. `at` is when the entry was written, on the storage clock; it is
  `nil` until then. Entries are written at the iteration boundary after
  the one that produced them, so entries of one iteration share it, and
  the timing that matters rides in the payload (`duration_ms`).

  The `kind` names the payload, a map with string keys exactly as it is
  stored. `Clementine.Trace` lists every kind and its keys.
  """

  @kinds [:execution, :model_call, :tool_call, :skill_load]

  @enforce_keys [:kind, :payload]
  defstruct run_id: nil, epoch: nil, seq: nil, at: nil, kind: nil, payload: %{}

  @type kind :: :execution | :model_call | :tool_call | :skill_load

  @type t :: %__MODULE__{
          run_id: term(),
          epoch: non_neg_integer() | nil,
          seq: pos_integer() | nil,
          at: DateTime.t() | nil,
          kind: kind() | String.t(),
          payload: map()
        }

  @doc "The kinds this version of Clementine records."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The kind a stored `kind` column names: the atom of a known kind, or the
  string as stored for a kind this version does not record (written by a
  later version), so a read never fails on one.
  """
  @spec decode_kind(String.t()) :: kind() | String.t()
  def decode_kind(kind) when is_binary(kind) do
    Enum.find(@kinds, kind, &(Atom.to_string(&1) == kind))
  end
end
