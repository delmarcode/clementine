defmodule Clementine.EngineTool do
  @moduledoc """
  A tool the engine executes itself, because calling it changes the
  execution rather than the world.

  The model sees an engine tool like any other: a name, a description,
  and a schema in the request's tool list. But no `Clementine.Tool` module
  runs it, and `Clementine.Rollout` handles its calls itself. An engine
  tool never raises the effect fence and never reaches
  `Clementine.ToolRunner`, so it emits no `[:clementine, :tool, ...]`
  telemetry. Its calls are traced and reported like any other: a
  `:tool_call` trace entry and a `:tool_result` event each.

  Engine tools come in two kinds by when a call settles:

  - **Settles now.** `use_skill` (`Clementine.Skill`) changes the toolset,
    so its calls settle first in their batch, in place, and the batch's
    other calls resolve against the execution they leave.
  - **Parks.** `delegate` (`Clementine.Delegation`) waits for other
    agents' runs, so its calls are checked first (a call the engine can
    refuse at once settles as an error then), and the rest settle when
    the run resumes: the batch parks for them once its other calls have
    settled, approval-gated ones included, and the children start in the
    transaction that parks it.

  The engine builds them from the agent: `use_skill` when the agent
  offers `skills:`, `delegate` when it offers `delegates:`. Their schemas
  are values, not modules, because they name what this agent offers (the
  skills, the agents, as enums): two agents' `use_skill` differ.
  `Clementine.Tool.to_schema/1` gives a provider client the schema of
  either kind of tool. An agent that offers an engine tool may have no
  tool of its own by that name.
  """

  alias Clementine.Tool

  @enforce_keys [:kind, :name, :description]
  defstruct kind: nil, name: nil, description: nil, parameters: []

  @typedoc """
  Which engine tool it is: what the engine does with a call. The name is
  what the model calls it by.
  """
  @type kind :: :use_skill | :delegate

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t(),
          description: String.t(),
          parameters: keyword()
        }

  @doc false
  # Whether calls of `tool` park the run rather than settle in place.
  @spec parks?(t()) :: boolean()
  def parks?(%__MODULE__{kind: :delegate}), do: true
  def parks?(%__MODULE__{}), do: false

  @doc """
  The tool's provider-neutral schema, the shape a `Clementine.Tool`
  module's `__schema__/0` returns.
  """
  @spec schema(t()) :: %{name: String.t(), description: String.t(), input_schema: map()}
  def schema(%__MODULE__{} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: Tool.params_to_json_schema(tool.parameters)
    }
  end
end
