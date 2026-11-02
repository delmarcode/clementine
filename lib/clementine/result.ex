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
    @moduledoc """
    The rollout produced a final answer.

    `output` is the answer's text, or, for an agent with an
    `output_schema:`, the answer decoded: a map with string keys that
    matched the schema (`Clementine.OutputSchema`).

    `stop_reason` is the final turn's, as the provider client normalized
    it: `"end_turn"`, `"stop_sequence"`, or `nil` when the stream named
    none (a scripted one, say). It is `"empty"` when the run called tools
    and its final turn wrote no text (Claude's empty `end_turn`, most
    often after tool results), and `output` is `""`: an agent whose
    answer is its tool calls is done, and a chat must show that the
    assistant did not reply, never silence. That final turn is in
    `messages` as an assistant message of no content, so the exchange
    before it reads as closed; no provider is sent it as one.

    A run never completes on a final turn the provider refused or cut
    off (`:refused`, `:truncated`, `Clementine.Error.stopped/2`), or on
    one that wrote nothing when the run called no tools (`:empty`,
    `Clementine.Error.empty/1`).
    """
    defstruct input_message: nil,
              messages: [],
              output: nil,
              stop_reason: nil,
              usage: %Clementine.Usage{}

    @type t :: %__MODULE__{
            input_message: Clementine.LLM.Message.message() | nil,
            messages: [Clementine.LLM.Message.message()],
            output: String.t() | map() | nil,
            stop_reason: String.t() | nil,
            usage: Clementine.Usage.t()
          }
  end

  defmodule Failed do
    @moduledoc """
    The rollout failed with a normalized error.

    A final turn the provider refused fails the run with `code: :refused`,
    and one it cut off with `code: :truncated` (`Clementine.Error.stopped/2`).
    A run that wrote nothing and called no tools fails with `code: :empty`
    (`Clementine.Error.empty/1`).
    """
    @enforce_keys [:error]
    defstruct error: nil, usage: %Clementine.Usage{}

    @type t :: %__MODULE__{error: Clementine.Error.t(), usage: Clementine.Usage.t()}
  end

  defmodule Cancelled do
    @moduledoc """
    A requested stop — user, control plane, or policy.

    `reason` is the cancel reason as it was stored on the run. On the
    durable runtime (`Clementine.Runs`) it is a map with a `"code"` and,
    when there is more to say, a `"detail"`: `%{"code" => "cancelled"}`
    from `Clementine.Runs.cancel/1`,
    `%{"code" => "unstartable", "detail" => why}` when the run could not
    be built at a claim (an agent, subject, actor, or history that no
    longer resolves), and for a loop's child,
    `%{"code" => "loop_cancel", "loop_id" => id}` when its loop's
    `{:cancel, tag}` action stopped it or
    `%{"code" => "loop_cascade", "loop_id" => id}` when its loop's own end
    did. Hosts read it from the result; nothing else decodes it. Outside
    the runtime it is whatever the caller passed as the cancel reason.
    """
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
