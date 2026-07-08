defmodule Clementine.Loop.StoredInput do
  @moduledoc """
  One pending inbox row as the host's `pending/3` returns it: the decoded
  input, the host's row reference (what consumption, marks, and
  `{:input_failed, ref, _}` name), and the attempts counter the head-blame
  rule reads.

  Hosts should decode row payloads into `Clementine.Loop.Input` lazily and
  per-row: a payload the current code cannot decode is poison for *that*
  input, and must dead-letter through the head-blame path rather than fail
  the whole fetch. Such a row comes back with `decode_error` set (and a
  kind-only placeholder in `input`); the step runner fails the step when
  one sits in the drained batch — after the attempts bump, so the failure
  is counted, blamed on the head, and dead-lettered at the threshold like
  any other deterministic poison (matrix row L7). Inputs are innocent of
  deploys: a vocabulary that shrank gets its dead-letter threshold of
  chances to deploy back before the row is marked.
  """

  alias Clementine.Error
  alias Clementine.Loop.Input

  @enforce_keys [:ref, :input]
  defstruct ref: nil, input: nil, attempts: 0, decode_error: nil

  @type t :: %__MODULE__{
          ref: term(),
          input: Input.t(),
          attempts: non_neg_integer(),
          decode_error: Error.t() | nil
        }
end
