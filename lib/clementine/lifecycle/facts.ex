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
  """

  @statuses [:queued, :running, :waiting, :completed, :failed, :cancelled, :interrupted]
  @terminal [:completed, :failed, :cancelled, :interrupted]
  @active [:queued, :running, :waiting]

  defstruct ref: nil,
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

  @type t :: %__MODULE__{
          ref: term(),
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
end
