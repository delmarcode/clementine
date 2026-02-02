defmodule Clementine.LLM.Response do
  @moduledoc """
  Struct representing a complete LLM response.

  Formalizes the `%{content, stop_reason, usage}` map that flows through
  the system into a proper struct with typed fields.
  """

  alias Clementine.LLM.Message.Content

  @type t :: %__MODULE__{
          content: [Content.t()],
          stop_reason: String.t() | nil,
          usage: map()
        }

  defstruct content: [], stop_reason: nil, usage: %{}
end
