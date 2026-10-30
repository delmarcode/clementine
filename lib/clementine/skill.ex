defmodule Clementine.Skill do
  @moduledoc """
  A named body of instructions and the tools it needs, which the model
  loads when a task calls for it.

  An agent offers skills with `skills:` (`Clementine.Agent`). From the
  start the model sees each skill's name and description, in the
  description of a `use_skill` tool. When it loads one, it reads the
  skill's body as that call's result, and the skill's tools join the
  ones it may call from its next turn on. The system prompt never
  changes: a load sends the tool list again, once, and nothing else.

  Two forms, as agents have two. A skill written in code:

      defmodule MyApp.Skills.Refunds do
        use Clementine.Skill,
          name: "refunds",
          description: "Review or issue a refund. Use when the customer asks for money back.",
          tools: [MyApp.Tools.LookupOrder, MyApp.Tools.IssueRefund]

        @impl true
        def body(_context), do: MyApp.Skills.read!("refunds.md")
      end

  and a skill built from the app's rows, in `c:Clementine.Agent.agent/1`:

      Clementine.Skill.new(
        name: row.name,
        description: row.description,
        body: row.body,
        tools: MyApp.Tools.resolve(row.tool_names)
      )

  ## The body

  `c:body/1` runs when the model loads the skill, and only then, in the
  run's own process. It receives the context the run's tools see: on the
  durable runtime `run_id`, `agent_key`, `subject`, `actor`, `metadata`,
  and the rest (`c:Clementine.Agent.agent/1` documents them), so a body
  may differ by subject or actor. Keep it quick. A body that raises or
  returns anything but a string is an error the model sees, and the skill
  stays unloaded, and so does one that exits (a call that timed out) or
  throws. A skill built with `new/1` takes the body as a string,
  or as a one-argument function called the same way.

  ## What a load does

  - The first load of a skill answers with its body and one line naming
    the tools it brought, and the skill's tools are offered from the next
    model call on. Tools the agent already offered are not offered twice.
  - A second load of the same skill answers that it is already loaded,
    and changes nothing.
  - A name the agent does not offer is an error tool result. The engine
    looks a name up among the offered skills only, never as a module.
  - The trace records each load as a `:skill_load` entry
    (`Clementine.Trace`).

  A skill's tools are ordinary `Clementine.Tool` modules: `approval:`,
  `retry:`, and the tool context apply unchanged. A gated one parks the
  run, and the checkpoint records which skills were loaded, so the resume
  offers the same tools. The agent must still offer those skills when
  the run resumes: a checkpoint naming a skill it no longer offers fails
  the resume as `:incompatible_checkpoint`, as a gated tool it no longer
  carries does.

  ## Who may load what

  `c:Clementine.Agent.agent/1` chooses the offered skills at every claim,
  with the run's subject and actor resolved: that is where tenancy and
  authority are decided. The model chooses only among them.
  """

  alias Clementine.EngineTool

  @tool_name "use_skill"

  @enforce_keys [:name, :description, :body]
  defstruct name: nil, description: nil, body: nil, tools: []

  @typedoc "A body as text, or a function of the run's tool context that returns it."
  @type body :: String.t() | (map() -> String.t())

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          body: body(),
          tools: [module()]
        }

  @doc """
  The skill's instructions, which the model reads when it loads the skill.
  `context` is the map the run's tools see.
  """
  @callback body(context :: map()) :: String.t()

  @doc """
  Defines a skill module.

  ## Options

  - `:name` (required) - the name the model loads it by
  - `:description` (required) - when to use it, in a sentence or two: the
    model decides from this alone whether to load the skill
  - `:tools` - the `Clementine.Tool` modules it brings (default `[]`)
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Clementine.Skill

      @clementine_skill_name Keyword.fetch!(opts, :name)
      @clementine_skill_description Keyword.fetch!(opts, :description)
      @clementine_skill_tools Keyword.get(opts, :tools, [])

      Clementine.Skill.validate_fields!(
        @clementine_skill_name,
        @clementine_skill_description,
        @clementine_skill_tools
      )

      @doc false
      def __skill__ do
        %Clementine.Skill{
          name: @clementine_skill_name,
          description: @clementine_skill_description,
          tools: @clementine_skill_tools,
          body: &__MODULE__.body/1
        }
      end
    end
  end

  @doc """
  Builds a skill from values: the form for skills an app keeps as data.

  ## Options

  - `:name` (required) - the name the model loads it by
  - `:description` (required) - when to use it
  - `:body` (required) - the instructions, as a string, or a function
    the engine calls with the run's tool context when the model loads
    the skill
  - `:tools` - the `Clementine.Tool` modules it brings (default `[]`)
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    __MODULE__ |> struct!(opts) |> validate!()
  end

  defp validate!(%__MODULE__{} = skill) do
    validate_fields!(skill.name, skill.description, skill.tools)

    unless is_binary(skill.body) or is_function(skill.body, 1) do
      raise ArgumentError,
            "skill #{inspect(skill.name)} needs a body: a string, or a function of one " <>
              "argument, got: #{inspect(skill.body)}"
    end

    skill
  end

  @doc false
  # Raises unless the fields make a skill. Called at compile time by `use`.
  def validate_fields!(name, description, tools) do
    unless is_binary(name) and name != "" do
      raise ArgumentError, "a skill needs a non-empty string name:, got: #{inspect(name)}"
    end

    unless is_binary(description) and description != "" do
      raise ArgumentError,
            "skill #{inspect(name)} needs a non-empty string description:, " <>
              "got: #{inspect(description)}"
    end

    unless is_list(tools) and Enum.all?(tools, &is_atom/1) do
      raise ArgumentError,
            "skill #{inspect(name)} takes tools: as a list of tool modules, got: #{inspect(tools)}"
    end

    :ok
  end

  @doc false
  # An entry of an agent's `skills:` as a skill: a module that
  # `use`s Clementine.Skill, or a skill already built, checked as `new/1`
  # checks one, since a struct may be built without it.
  @spec from!(module() | t()) :: t()
  def from!(%__MODULE__{} = skill), do: validate!(skill)

  def from!(module) when is_atom(module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        if function_exported?(module, :__skill__, 0) do
          module.__skill__()
        else
          raise ArgumentError,
                "#{inspect(module)} is not a skill: it does not use Clementine.Skill"
        end

      {:error, reason} ->
        raise ArgumentError, "skill module #{inspect(module)} is not available: #{reason}"
    end
  end

  def from!(other) do
    raise ArgumentError,
          "skills: takes skill modules or Clementine.Skill structs, got: #{inspect(other)}"
  end

  @doc false
  # An agent's `skills:` entries as skills, checked against `tools`, every
  # tool module the agent offers of its own, and `deferred`, those of them
  # the model finds through the provider's tool search: each entry is a
  # skill, no two skills share a name, no two tools the model may be
  # offered (the agent's and every skill's) share a name, none is named
  # use_skill, and no skill brings a deferred tool, since a skill's tools
  # load in full. Two skills may bring the same tool module. Agent.new/1
  # raises on an error; the rollout fails the run with it, since an
  # agent/1 may set the field without new/1.
  @spec prepare([module() | t()], [module()], [module()]) :: {:ok, [t()]} | {:error, String.t()}
  def prepare(entries, tools, deferred \\ [])

  def prepare(entries, tools, deferred) when is_list(entries) and is_list(tools) do
    skills = Enum.map(entries, &from!/1)

    case for {name, n} <- Enum.frequencies_by(skills, & &1.name), n > 1, do: name do
      [] ->
        :ok

      repeated ->
        raise ArgumentError, "skills: offers more than one skill named #{inspect(repeated)}"
    end

    offered = Enum.uniq(tools ++ Enum.flat_map(skills, & &1.tools))

    for {name, [_, _ | _] = modules} <- Enum.group_by(offered, &tool_name!/1) do
      raise ArgumentError,
            "two tools the agent may offer share the name #{inspect(name)}: #{inspect(modules)}"
    end

    if tool = Enum.find(offered, &(tool_name!(&1) == @tool_name)) do
      raise ArgumentError,
            "#{inspect(tool)} is named #{inspect(@tool_name)}, the tool that loads skills: " <>
              "rename it"
    end

    if skill = Enum.find(skills, fn skill -> Enum.any?(skill.tools, &(&1 in deferred)) end) do
      raise ArgumentError,
            "skill #{inspect(skill.name)} brings a tool the agent lists in deferred: " <>
              "#{inspect(Enum.filter(skill.tools, &(&1 in deferred)))}; a skill's tools load " <>
              "in full when the skill loads, so list it in one place"
    end

    {:ok, skills}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  def prepare(entries, _tools, _deferred) do
    {:error, "skills: takes a list, got: #{inspect(entries)}"}
  end

  defp tool_name!(tool) do
    with true <- is_atom(tool),
         {:module, ^tool} <- Code.ensure_compiled(tool),
         true <- function_exported?(tool, :__name__, 0) do
      tool.__name__()
    else
      _ -> raise ArgumentError, "#{inspect(tool)} is not a Clementine.Tool module"
    end
  end

  @doc false
  # The name of the engine tool that loads skills.
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc false
  # The `use_skill` engine tool for an agent offering `skills`: `name` is
  # an enum of their names, and the description lists each one.
  @spec use_skill_tool([t(), ...]) :: EngineTool.t()
  def use_skill_tool([_ | _] = skills) do
    listing = Enum.map_join(skills, "\n", &"- #{&1.name}: #{&1.description}")

    %EngineTool{
      kind: :use_skill,
      name: @tool_name,
      description:
        "Load a skill: the instructions for one kind of task, and the tools it needs. " <>
          "When the task matches a skill's description, load it before you start; its " <>
          "instructions come back as this tool's result, and its tools become available " <>
          "to call.\n\nSkills:\n" <> listing,
      parameters: [
        name: [
          type: :string,
          required: true,
          enum: Enum.map(skills, & &1.name),
          description: "The skill to load"
        ]
      ]
    }
  end

  @doc false
  # Settles one `use_skill` call against the offered `skills`, given the
  # names already `loaded`: the first load of a skill answers with its
  # body (returned apart too, for the trace) and the tools it brought, a
  # second answers that it is loaded already, and a name that is not
  # offered (or no name) is an error. Only the first load changes the
  # execution; the engine applies it.
  @spec load([t()], [String.t()], map(), map()) ::
          {:loaded, t(), body :: String.t(), String.t()}
          | {:unchanged, String.t()}
          | {:error, String.t()}
  def load(skills, loaded, input, context) do
    with {:ok, name} <- requested(input, skills),
         {:ok, skill} <- offered(skills, name) do
      if name in loaded do
        {:unchanged, "The skill #{inspect(name)} is already loaded. " <> tools_line(skill)}
      else
        case body(skill, context) do
          {:ok, body} -> {:loaded, skill, body, body <> "\n\n" <> tools_line(skill)}
          {:error, _message} = error -> error
        end
      end
    end
  end

  defp requested(%{"name" => name}, _skills) when is_binary(name), do: {:ok, name}

  defp requested(_input, skills) do
    {:error, "use_skill needs the name of a skill: one of #{names(skills)}."}
  end

  defp offered(skills, name) do
    case Enum.find(skills, &(&1.name == name)) do
      nil ->
        {:error, "There is no skill named #{inspect(name)}. The skills are: #{names(skills)}."}

      skill ->
        {:ok, skill}
    end
  end

  defp names(skills), do: Enum.map_join(skills, ", ", & &1.name)

  defp tools_line(%__MODULE__{tools: []}), do: "This skill brings no tools."

  defp tools_line(%__MODULE__{tools: tools}) do
    "Its tools are available: #{Enum.map_join(tools, ", ", & &1.__name__())}."
  end

  # A body is the skill's own code: a raise, an exit (a call that timed
  # out), a throw, or a non-string is the model's error to read, as a
  # crashing tool's is, never the run's.
  defp body(%__MODULE__{body: body}, _context) when is_binary(body), do: {:ok, body}

  defp body(%__MODULE__{name: name, body: body}, context) when is_function(body, 1) do
    case body.(context) do
      text when is_binary(text) ->
        {:ok, text}

      other ->
        {:error,
         "The skill #{inspect(name)} could not be loaded: its body is not text " <>
           "(#{inspect(other, limit: 3, printable_limit: 80)})."}
    end
  rescue
    e ->
      {:error, "The skill #{inspect(name)} could not be loaded: #{Exception.message(e)}"}
  catch
    kind, reason ->
      {:error,
       "The skill #{inspect(name)} could not be loaded: #{kind} " <>
         inspect(reason, limit: 5, printable_limit: 120)}
  end
end
