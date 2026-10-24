defmodule Mix.Tasks.Clementine.Gen.Agent.Docs do
  @moduledoc false

  def short_doc do
    "Generates a Clementine agent with a tool and a test."
  end

  def example do
    "mix clementine.gen.agent Weather --tool forecast"
  end

  def long_doc do
    """
    #{short_doc()}

    Needs the `{Clementine, ...}` child that `mix clementine.install` adds
    to your application. For `Weather` it writes:

      * `MyApp.Agents.Weather`, a `use Clementine.Agent` module with the key
        `"weather"`
      * `MyApp.Agents.Weather.Tools.Lookup`, a `Clementine.Tool` to replace
        with a real one
      * `test/my_app/agents/weather_test.exs`, which runs the agent end to
        end against a scripted model

    and adds `MyApp.Agents.Weather` to the child's `agents:`. Start a run
    with `Clementine.Runs.start(MyApp.Agents.Weather, prompt)`.

    Running it again changes nothing: existing files are left as they are,
    and the agent is listed once.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

      * `--tool` — the tool's name in snake_case; defaults to `lookup`
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Clementine.Gen.Agent do
    @shortdoc __MODULE__.Docs.short_doc()

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :clementine,
        example: __MODULE__.Docs.example(),
        positional: [:name],
        schema: [tool: :string],
        defaults: [tool: "lookup"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      name = igniter.args.positional.name
      tool = igniter.args.options[:tool]
      ctx = Mix.Clementine.context(igniter)

      with :ok <- validate(name, tool),
           {:ok, igniter} <- require_runtime(igniter),
           {:ok, igniter} <- available(igniter, ctx, name) do
        generate(igniter, ctx, name, tool)
      else
        {:error, %Igniter{} = igniter} -> igniter
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    # The generated test aliases the agent and its tool and calls
    # Clementine.Runs: neither short name may shadow `Clementine`, nor
    # each other.
    @taken_short_names ~w(Clementine)

    defp validate(name, tool) do
      agent_short = name |> String.split(".") |> List.last()
      tool_short = Macro.camelize(tool)

      cond do
        not Regex.match?(~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/, name) ->
          {:error,
           "Agent name must be a module name like Weather or Billing.Triage, got: #{name}"}

        not Regex.match?(~r/^[a-z][a-z0-9_]*$/, tool) ->
          {:error, "--tool must be a snake_case name like lookup_order, got: #{tool}"}

        agent_short in @taken_short_names or tool_short in @taken_short_names ->
          {:error,
           "#{agent_short} and #{tool_short} must not be one of " <>
             "#{Enum.join(@taken_short_names, ", ")}. Pick another name."}

        agent_short == tool_short ->
          {:error, "The agent and its tool would both be #{agent_short}. Pass another --tool."}

        true ->
          :ok
      end
    end

    defp short_name(module), do: module |> Module.split() |> List.last()

    # The agent is listed in the runtime's child spec, so the runtime must
    # be among the application's children.
    defp require_runtime(igniter) do
      with app when not is_nil(app) <- Mix.Clementine.app_module(igniter),
           {:ok, {igniter, _source, zipper}} <- Igniter.Project.Module.find_module(igniter, app),
           {:ok, _child} <- Mix.Clementine.find_child(zipper, Clementine) do
        {:ok, igniter}
      else
        _missing ->
          {:error,
           "The application has no {Clementine, ...} child. " <>
             "Run `mix clementine.install` first."}
      end
    end

    # The model mock test/support/agents_case.ex defines.
    @reserved ~w(LLMMock)

    # An existing module is only ever left alone. It may be listed when it
    # already is an agent (a second run, or an agent written by hand); any
    # other module of that name makes the name unavailable, because the
    # runtime refuses to start with a module in `agents:` that is not an
    # agent.
    defp available(_igniter, ctx, name) when name in @reserved do
      {:error,
       "#{inspect(Module.concat(ctx.agents, name))} is the model mock in " <>
         "test/support/agents_case.ex. Pick another name."}
    end

    defp available(igniter, ctx, name) do
      module = Module.concat(ctx.agents, name)

      case Igniter.Project.Module.find_module(igniter, module) do
        {:error, igniter} ->
          {:ok, igniter}

        {:ok, {igniter, _source, zipper}} ->
          if Mix.Clementine.agent?(zipper) do
            {:ok, igniter}
          else
            {:error,
             "#{inspect(module)} already exists and is not an agent " <>
               "(it does not use Clementine.Agent). Pick another name."}
          end
      end
    end

    defp generate(igniter, ctx, name, tool) do
      module = Module.concat(ctx.agents, name)
      tool_module = Module.concat([module, Tools, Macro.camelize(tool)])
      key = name |> Macro.underscore() |> String.replace("/", "_")

      assigns = [
        app_module: inspect(ctx.app_module),
        module: inspect(module),
        alias: short_name(module),
        key: key,
        human: String.replace(key, "_", " "),
        tool_module: inspect(tool_module),
        tool_alias: short_name(tool_module),
        tool_name: tool
      ]

      igniter
      |> Mix.Clementine.create_once(
        "clementine.gen.agent/agent.ex.eex",
        Igniter.Project.Module.proper_location(igniter, module),
        assigns
      )
      |> Mix.Clementine.create_once(
        "clementine.gen.agent/tool.ex.eex",
        Igniter.Project.Module.proper_location(igniter, tool_module),
        assigns
      )
      |> Mix.Clementine.create_once(
        "clementine.gen.agent/agent_test.exs.eex",
        Igniter.Project.Module.proper_location(
          igniter,
          Module.concat(ctx.agents, "#{name}Test"),
          :test
        ),
        assigns
      )
      |> register(module)
    end

    # The agents the runtime runs are the `agents:` list of its child, so
    # registering is an append that skips a module already listed. A child
    # whose options are not a literal keyword list (read from config, or
    # built by a function) is left alone, with the edit to make by hand.
    defp register(igniter, module) do
      app = Mix.Clementine.app_module(igniter)

      Igniter.Project.Module.find_and_update_module!(igniter, app, fn zipper ->
        with {:ok, child} <- Mix.Clementine.find_child(zipper, Clementine),
             {:ok, opts} <- Igniter.Code.Tuple.tuple_elem(child, 1),
             {:ok, zipper} <-
               Igniter.Code.Keyword.set_keyword_key(
                 opts,
                 :agents,
                 [module],
                 &Igniter.Code.List.append_new_to_list(&1, module)
               ) do
          {:ok, zipper}
        else
          _not_literal ->
            {:warning,
             """
             Clementine could not list #{inspect(module)} in the agents: of the
             {Clementine, ...} child in #{inspect(app)}. Add it by hand:

                 agents: [..., #{inspect(module)}]
             """}
        end
      end)
    end
  end
else
  defmodule Mix.Tasks.Clementine.Gen.Agent do
    @shortdoc "Install `igniter` to run clementine.gen.agent."

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'clementine.gen.agent' requires igniter. Add it to your deps:

          {:igniter, "~> 0.8", only: [:dev, :test]}

      then run `mix deps.get` and try again.
      """)

      exit({:shutdown, 1})
    end
  end
end
