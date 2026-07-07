defmodule Clementine.Loop.StoredInput do
  @moduledoc """
  One pending inbox row as the host's `pending/3` returns it: the decoded
  input, the host's row reference (what consumption, marks, and
  `{:input_failed, ref, _}` name), and the attempts counter the head-blame
  rule reads.

  Hosts should decode row payloads into `Clementine.Loop.Input` lazily and
  per-row: a payload the current code cannot decode is poison for *that*
  input, and must dead-letter through the head-blame path rather than fail
  the whole fetch.
  """

  alias Clementine.Loop.Input

  @enforce_keys [:ref, :input]
  defstruct ref: nil, input: nil, attempts: 0

  @type t :: %__MODULE__{
          ref: term(),
          input: Input.t(),
          attempts: non_neg_integer()
        }
end
