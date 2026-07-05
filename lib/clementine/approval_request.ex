defmodule Clementine.ApprovalRequest do
  @moduledoc """
  What a human is being asked to approve: one gated tool call.

  Carried in `{:approval, request}` suspension reasons and (token-free) in
  `approval_requested` events. Who may approve, how many approvers, and the
  approval UI are host-app meaning; this struct is only the mechanism's
  description of the gated call.
  """

  @enforce_keys [:tool_use_id, :tool_name]
  defstruct tool_use_id: nil, tool_name: nil, args: %{}

  @type t :: %__MODULE__{
          tool_use_id: String.t(),
          tool_name: String.t(),
          args: map()
        }
end
