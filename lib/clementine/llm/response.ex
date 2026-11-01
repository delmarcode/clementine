defmodule Clementine.LLM.Response do
  @moduledoc """
  Struct representing a complete LLM response.

  Formalizes the `%{content, stop_reason, usage}` map that flows through
  the system into a proper struct with typed fields. `binding` is the
  digest of the request a model that binds its thinking answered
  (`Clementine.LLM.Message.AssistantMessage`), nil otherwise.
  """

  alias Clementine.LLM.Message.Content

  @type t :: %__MODULE__{
          content: [Content.t()],
          stop_reason: String.t() | nil,
          usage: map(),
          binding: String.t() | nil
        }

  defstruct content: [], stop_reason: nil, usage: %{}, binding: nil
end
