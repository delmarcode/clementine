defmodule Clementine.LLM.Response do
  @moduledoc """
  Struct representing a complete LLM response.

  Formalizes the `%{content, stop_reason, usage}` map that flows through
  the system into a proper struct with typed fields. `binding` is the
  digest of the request a model that binds its thinking answered
  (`Clementine.LLM.Message.AssistantMessage`), nil otherwise.
  `stop_details` is what the provider said about its stop, when it said
  anything: Anthropic's `stop_details` on a refusal (its `"category"`
  and `"explanation"`, never content), or the `"finish_reason"` of a
  Chat Completions server that Clementine reads as `"incomplete"`.
  """

  alias Clementine.LLM.Message.Content

  @type t :: %__MODULE__{
          content: [Content.t()],
          stop_reason: String.t() | nil,
          stop_details: map() | nil,
          usage: map(),
          binding: String.t() | nil
        }

  defstruct content: [], stop_reason: nil, stop_details: nil, usage: %{}, binding: nil
end
