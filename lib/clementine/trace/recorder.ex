defmodule Clementine.Trace.Recorder do
  @moduledoc false
  # The trace buffer of one execution, between the engine that records
  # entries and the writes that store them. The runner makes one per claim
  # and hands it to the rollout (`trace:`), which records each entry as it
  # happens and flushes at every iteration boundary through the runner's
  # write, fenced on the epoch. Whatever is still pending when the rollout
  # returns rides the terminal or suspend write, so it commits with the
  # run's end.
  #
  # The buffer lives in a private ETS table owned by the runner's process,
  # where the rollout also executes, rather than in the rollout's own
  # state: a rollout that raises loses its state, and the runner still
  # finishes the run failed with everything recorded up to the raise.

  alias Clementine.Trace.Entry

  @enforce_keys [:run_id, :epoch, :table, :seq, :flush]
  defstruct [:run_id, :epoch, :table, :seq, :flush]

  @type flush_result :: :ok | {:error, :lost_lease} | {:error, term()}

  @type t :: %__MODULE__{
          run_id: term(),
          epoch: non_neg_integer(),
          table: :ets.tid(),
          seq: :atomics.atomics_ref(),
          flush: ([Entry.t()] -> flush_result())
        }

  @doc """
  A recorder for the execution `epoch` of `run_id`. `flush` writes a batch
  of entries, fenced on the epoch: `:ok`, `{:error, :lost_lease}` when the
  run is no longer this execution's, or `{:error, reason}` for a transient
  failure, after which the entries stay pending for the next write.
  """
  @spec new(term(), non_neg_integer(), ([Entry.t()] -> flush_result())) :: t()
  def new(run_id, epoch, flush) when is_function(flush, 1) do
    %__MODULE__{
      run_id: run_id,
      epoch: epoch,
      table: :ets.new(__MODULE__, [:ordered_set, :private]),
      seq: :atomics.new(1, signed: false),
      flush: flush
    }
  end

  @doc "Records one entry, numbered after the last."
  @spec record(t(), Entry.kind(), map()) :: :ok
  def record(%__MODULE__{} = recorder, kind, payload) when is_map(payload) do
    seq = :atomics.add_get(recorder.seq, 1, 1)

    entry = %Entry{
      run_id: recorder.run_id,
      epoch: recorder.epoch,
      seq: seq,
      kind: kind,
      payload: payload
    }

    true = :ets.insert(recorder.table, {seq, entry})
    :ok
  end

  @doc "The entries not yet written, oldest first."
  @spec pending(t()) :: [Entry.t()]
  def pending(%__MODULE__{table: table}) do
    table |> :ets.tab2list() |> Enum.map(fn {_seq, entry} -> entry end)
  end

  @doc """
  Writes the pending entries. `:lost_lease` means the run is no longer
  this execution's and the caller must unwind; a transient failure keeps
  the entries pending and answers `:ok`, since the next boundary or the
  end writes them.
  """
  @spec flush(t()) :: :ok | :lost_lease
  def flush(%__MODULE__{} = recorder) do
    case pending(recorder) do
      [] ->
        :ok

      entries ->
        case recorder.flush.(entries) do
          :ok ->
            %Entry{seq: last} = List.last(entries)
            :ets.select_delete(recorder.table, [{{:"$1", :_}, [{:"=<", :"$1", last}], [true]}])
            :ok

          {:error, :lost_lease} ->
            :lost_lease

          {:error, _transient} ->
            :ok
        end
    end
  end

  @doc "Drops the buffer."
  @spec close(t()) :: :ok
  def close(%__MODULE__{table: table}) do
    :ets.delete(table)
    :ok
  end
end
