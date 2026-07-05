defmodule Clementine.InterruptReason do
  @moduledoc """
  Why a run was interrupted — standardized vocabulary, closed with an app
  escape hatch.

  Interruption reasons are library vocabulary because they describe
  execution mechanics (expired leases, vanished executors, policy ceilings),
  not product meaning. Hosts map them to user-visible copy however they
  like; `{:app, term}` namespaces anything genuinely app-specific.
  """

  @codes [
    :lease_expired,
    :claim_timeout,
    :job_missing,
    :job_cancelled,
    :job_discarded,
    :job_completed_without_terminal,
    :drain,
    :deadline_exceeded,
    :suspension_expired
  ]

  @enforce_keys [:code]
  defstruct code: nil, detail: nil

  @type code ::
          :lease_expired
          | :claim_timeout
          | :job_missing
          | :job_cancelled
          | :job_discarded
          | :job_completed_without_terminal
          | :drain
          | :deadline_exceeded
          | :suspension_expired
          | {:app, term()}

  @type t :: %__MODULE__{code: code(), detail: String.t() | nil}

  @spec codes() :: [atom()]
  def codes, do: @codes

  @doc """
  Builds a reason. The code set is closed: standard codes or `{:app, term}`.
  An unrecognized bare atom raises — silently minting new mechanism
  vocabulary is exactly what the closed set exists to prevent.
  """
  @spec new(code(), String.t() | nil) :: t()
  def new(code, detail \\ nil)
  def new(code, detail) when code in @codes, do: %__MODULE__{code: code, detail: detail}
  def new({:app, _} = code, detail), do: %__MODULE__{code: code, detail: detail}
end
