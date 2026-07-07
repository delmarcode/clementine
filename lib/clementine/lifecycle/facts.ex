defmodule Clementine.Lifecycle.Facts do
  @moduledoc """
  The normalized view of a run's lifecycle state — the lingua franca
  between host storage and the protocol core.

  Hosts map their columns to this struct in `fetch` and back in `apply`;
  statuses are atoms here regardless of storage representation. Fields obey
  the hygiene rule: a fact never claims something the status makes
  meaningless (a `waiting` run has no `executor_id`, no `deadline`, and no
  `heartbeat_at` — suspend and requeue clear them).

  Terminal-detail fields are split by variant: `error` holds the normalized
  `Clementine.Error` for `:failed` runs; `interrupt` holds the
  `Clementine.InterruptReason` for `:interrupted` runs.

  `kind` discriminates what the run *is* (LOOP_RFC amendment A1): a
  `:rollout` run's executions are Gather → Act rollouts; a `:loop` run's
  executions are steps. The reaper's sweep, the cancel path, billing
  queries, and single-active indexes discriminate on it; the protocol's
  state machine does not — same facts, same CAS grain, same fencing.
  """

  @statuses [:queued, :running, :waiting, :completed, :failed, :cancelled, :interrupted]
  @terminal [:completed, :failed, :cancelled, :interrupted]
  @active [:queued, :running, :waiting]
  @kinds [:rollout, :loop]

  defstruct ref: nil,
            kind: :rollout,
            status: :queued,
            epoch: 0,
            executor_id: nil,
            heartbeat_at: nil,
            deadline: nil,
            cancel: nil,
            suspension: nil,
            resume: nil,
            effects?: false,
            usage: nil,
            error: nil,
            interrupt: nil,
            queued_at: nil,
            finished_at: nil

  @type status ::
          :queued | :running | :waiting | :completed | :failed | :cancelled | :interrupted

  @type kind :: :rollout | :loop

  @type t :: %__MODULE__{
          ref: term(),
          kind: kind(),
          status: status(),
          epoch: non_neg_integer(),
          executor_id: String.t() | nil,
          heartbeat_at: DateTime.t() | nil,
          deadline: DateTime.t() | nil,
          cancel: nil | %{reason: term(), requested_at: DateTime.t() | nil},
          suspension: Clementine.Suspension.t() | nil,
          resume: nil | %{payload: term(), resumed_at: DateTime.t() | nil},
          effects?: boolean(),
          usage: Clementine.Usage.t() | nil,
          error: Clementine.Error.t() | nil,
          interrupt: Clementine.InterruptReason.t() | nil,
          queued_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal

  @spec active_statuses() :: [status()]
  def active_statuses, do: @active

  @doc "Terminal statuses are dead ends — that dead-endedness is itself a fence."
  @spec terminal?(t() | status()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: terminal?(status)
  def terminal?(status) when status in @terminal, do: true
  def terminal?(status) when status in @active, do: false

  @spec active?(t() | status()) :: boolean()
  def active?(%__MODULE__{status: status}), do: active?(status)
  def active?(status) when status in @statuses, do: status in @active

  # Within one epoch the state machine can only move running -> waiting ->
  # queued -> terminal (suspend, resume, requeue, finish/interrupt/cancel);
  # entering :running mints a new epoch. So (epoch, rank) totally orders
  # every fact a run can ever produce.
  @observation_rank %{running: 0, waiting: 1, queued: 2}

  @doc """
  Observation order for transition notifications: notifications carry the
  new facts, and `(epoch, status)` orders itself — no sequence numbers
  needed. Facts with equal order (same status, same epoch: a heartbeat, a
  cancel flag) are same-slot updates; consumers should let the latest
  arrival win, i.e. replace held facts unless the incoming ones compare
  `:lt`.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    key_a = {a.epoch, observation_rank(a.status)}
    key_b = {b.epoch, observation_rank(b.status)}

    cond do
      key_a < key_b -> :lt
      key_a > key_b -> :gt
      true -> :eq
    end
  end

  @doc "True when `facts` strictly supersede `held` in observation order."
  @spec supersedes?(t(), t()) :: boolean()
  def supersedes?(%__MODULE__{} = facts, %__MODULE__{} = held) do
    compare(facts, held) == :gt
  end

  defp observation_rank(status) when status in @terminal, do: 3
  defp observation_rank(status), do: Map.fetch!(@observation_rank, status)
end
