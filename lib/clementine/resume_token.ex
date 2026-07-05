defmodule Clementine.ResumeToken do
  @moduledoc """
  An epoch-stamped reference for resuming one specific suspension.

  A *staleness* defense, not authorization: resume validates it against
  current facts (waiting status, matching epoch, matching reason type) so
  stale approvals, double-fires, and cross-wired references die with
  precise errors. But its fields are guessable, it carries no secret, and
  it must never be treated as permission — who may resume is host-app
  meaning, enforced before calling resume. Tokens are read from stored
  suspensions by authorized code and are never broadcast in the event
  stream.
  """

  @enforce_keys [:run_ref, :epoch, :reason_type]
  defstruct run_ref: nil, epoch: 0, reason_type: nil

  @type t :: %__MODULE__{
          run_ref: term(),
          epoch: non_neg_integer(),
          reason_type: :approval | :external | :until
        }
end
