defmodule Clementine.Result do
  @moduledoc """
  The terminal semantic outcome of a run — a closed sum.

  Every variant carries `usage`; tokens burn on failures too. `Completed`
  separates the materialized `input_message` from the generated `messages`
  so that history-as-a-fold (`history ++ [input_message] ++ messages`)
  cannot silently drop user input; hosts that persist the user message at
  enqueue time append `messages` alone and treat their own row as the
  input. The terminal result — not the event stream — is truth.
  """

  alias Clementine.{Error, InterruptReason, Usage}

  defmodule Completed do
    @moduledoc "The rollout produced a final answer."
    defstruct input_message: nil, messages: [], output: nil, usage: %Clementine.Usage{}

    @type t :: %__MODULE__{
            input_message: Clementine.LLM.Message.message() | nil,
            messages: [Clementine.LLM.Message.message()],
            output: String.t() | nil,
            usage: Clementine.Usage.t()
          }
  end

  defmodule Failed do
    @moduledoc "The rollout failed with a normalized error."
    @enforce_keys [:error]
    defstruct error: nil, usage: %Clementine.Usage{}

    @type t :: %__MODULE__{error: Clementine.Error.t(), usage: Clementine.Usage.t()}
  end

  defmodule Cancelled do
    @moduledoc "A requested stop — user, control plane, or policy."
    defstruct reason: nil, usage: %Clementine.Usage{}

    @type t :: %__MODULE__{reason: term(), usage: Clementine.Usage.t()}
  end

  defmodule Interrupted do
    @moduledoc "Execution infrastructure stopped before a terminal result."
    @enforce_keys [:reason]
    defstruct reason: nil, usage: %Clementine.Usage{}

    @type t :: %__MODULE__{
            reason: Clementine.InterruptReason.t(),
            usage: Clementine.Usage.t()
          }
  end

  @type t :: Completed.t() | Failed.t() | Cancelled.t() | Interrupted.t()

  @spec completed(keyword()) :: Completed.t()
  def completed(fields \\ []), do: struct!(Completed, fields)

  @spec failed(Error.t() | term(), Usage.t()) :: Failed.t()
  def failed(error, usage \\ %Usage{})
  def failed(%Error{} = error, usage), do: %Failed{error: error, usage: usage}
  def failed(reason, usage), do: %Failed{error: Error.normalize(reason), usage: usage}

  @spec cancelled(term(), Usage.t()) :: Cancelled.t()
  def cancelled(reason, usage \\ %Usage{}), do: %Cancelled{reason: reason, usage: usage}

  @spec interrupted(InterruptReason.t() | InterruptReason.code(), Usage.t()) :: Interrupted.t()
  def interrupted(reason, usage \\ %Usage{})

  def interrupted(%InterruptReason{} = reason, usage),
    do: %Interrupted{reason: reason, usage: usage}

  def interrupted(code, usage),
    do: %Interrupted{reason: InterruptReason.new(code), usage: usage}

  @doc "The lifecycle status a result terminalizes into."
  @spec status(t()) :: :completed | :failed | :cancelled | :interrupted
  def status(%Completed{}), do: :completed
  def status(%Failed{}), do: :failed
  def status(%Cancelled{}), do: :cancelled
  def status(%Interrupted{}), do: :interrupted

  @doc "Usage is present on every variant, by design."
  @spec usage(t()) :: Usage.t()
  def usage(%Completed{usage: usage}), do: usage
  def usage(%Failed{usage: usage}), do: usage
  def usage(%Cancelled{usage: usage}), do: usage
  def usage(%Interrupted{usage: usage}), do: usage
end
