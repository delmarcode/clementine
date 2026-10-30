defmodule Clementine.EngineTool do
  @moduledoc """
  A tool the engine executes itself, because calling it changes the
  execution rather than the world.

  The model sees an engine tool like any other: a name, a description,
  and a schema in the request's tool list. But no `Clementine.Tool` module
  runs it. `Clementine.Rollout` settles its calls itself, before the rest
  of their batch, and the batch's other calls resolve against the
  execution those calls leave. An engine tool never raises the effect
  fence, never waits on an approval, and never reaches
  `Clementine.ToolRunner`, so it emits no `[:clementine, :tool, ...]`
  telemetry. Its calls are traced and reported like any other: a
  `:tool_call` trace entry and a `:tool_result` event each.

  The engine builds them from the agent: `use_skill` when the agent
  offers `skills:` (`Clementine.Skill`). Their schemas are values, not
  modules, because they name what this agent offers (the skills, as an
  enum): two agents' `use_skill` differ. `Clementine.Tool.to_schema/1`
  gives a provider client the schema of either kind of tool. An agent
  that offers an engine tool may have no tool of its own by that name.
  """

  alias Clementine.Tool

  @enforce_keys [:kind, :name, :description]
  defstruct kind: nil, name: nil, description: nil, parameters: []

  @typedoc """
  Which engine tool it is: what the engine does with a call. The name is
  what the model calls it by.
  """
  @type kind :: :use_skill

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t(),
          description: String.t(),
          parameters: keyword()
        }

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
