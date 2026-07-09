defmodule Clementine.Loop.StoredInput do
  @moduledoc """
  One inbox row as the host seam returns it: the decoded input, the
  host's row reference (what consumption, marks, and
  `{:input_failed, ref, _}` name), the attempts counter the head-blame
  rule reads, the row's `dedup_key` (nilable; machinery-appended
  completions and elapses always carry their canonical key, which the
  doctor matches vocabulary-free), and the row's stamps — `inserted_at`
  for age (the doctor's stuck detector reads it), plus
  `dead_at`/`dead_reason` on rows the optional `dead_letters/3` callback
  returns (always nil on `pending/4`'s live rows).

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
  alias Clementine.Loop.{Input, StepCommit}

  @enforce_keys [:ref, :input]
  defstruct ref: nil,
            input: nil,
            attempts: 0,
            decode_error: nil,
            dedup_key: nil,
            inserted_at: nil,
            dead_at: nil,
            dead_reason: nil

  @type t :: %__MODULE__{
          ref: term(),
          input: Input.t(),
          attempts: non_neg_integer(),
          decode_error: Error.t() | nil,
          dedup_key: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          dead_at: DateTime.t() | nil,
          dead_reason: StepCommit.dead_reason() | nil
        }
end
