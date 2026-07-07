defmodule Clementine.Loop.Input do
  @moduledoc """
  What wakes a loop (LOOP_RFC §Vocabulary): a message, a child completion,
  a timer expiration, or the machinery's own poison evidence.

  One struct, kind-discriminated — the durable value the inbox stores and
  the host seam decodes. `handle/2` never sees the struct; it receives
  `to_callback/1`'s tuple form:

      {:message, payload}
      {:completed, tag, Clementine.Result.t()}
      {:elapsed, tag}
      {:input_failed, input_ref, Clementine.Error.t()}

  Tags and payloads are terms under the `Clementine.Loop.Codec` contract;
  `result` and `error` are live structs, encoded by the host seam (the
  inbox recipe), not by the loop codec.
  """

  alias Clementine.{Error, Result}

  @kinds [:message, :completed, :elapsed, :input_failed]

  @enforce_keys [:kind]
  defstruct kind: nil, payload: nil, tag: nil, result: nil, input_ref: nil, error: nil

  @type kind :: :message | :completed | :elapsed | :input_failed

  @type t :: %__MODULE__{
          kind: kind(),
          payload: term(),
          tag: term(),
          result: Result.t() | nil,
          input_ref: term(),
          error: Error.t() | nil
        }

  @type callback_form ::
          {:message, term()}
          | {:completed, term(), Result.t()}
          | {:elapsed, term()}
          | {:input_failed, term(), Error.t()}

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec message(term()) :: t()
  def message(payload), do: %__MODULE__{kind: :message, payload: payload}

  @spec completed(term(), Result.t()) :: t()
  def completed(tag, result), do: %__MODULE__{kind: :completed, tag: tag, result: result}

  @spec elapsed(term()) :: t()
  def elapsed(tag), do: %__MODULE__{kind: :elapsed, tag: tag}

  @spec input_failed(term(), Error.t()) :: t()
  def input_failed(input_ref, %Error{} = error) do
    %__MODULE__{kind: :input_failed, input_ref: input_ref, error: error}
  end

  @doc "The tuple form `handle/2` receives."
  @spec to_callback(t()) :: callback_form()
  def to_callback(%__MODULE__{kind: :message, payload: payload}), do: {:message, payload}

  def to_callback(%__MODULE__{kind: :completed, tag: tag, result: result}),
    do: {:completed, tag, result}

  def to_callback(%__MODULE__{kind: :elapsed, tag: tag}), do: {:elapsed, tag}

  def to_callback(%__MODULE__{kind: :input_failed, input_ref: ref, error: error}),
    do: {:input_failed, ref, error}
end
