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

    Needs the runtime from `mix clementine.install`. For `Weather` it
    writes:

      * `MyApp.Agents.Weather`, a `MyApp.Agents.Definition` with the key
        `"weather"`
      * `MyApp.Agents.Weather.Tools.Lookup`, a `Clementine.Tool` to replace
        with a real one
      * `test/my_app/agents/weather_test.exs`, which runs the agent end to
        end against a scripted model

    and lists the agent in `config :my_app, MyApp.Agents.Catalog, agents:`.
    Start a run with `MyApp.Agents.Runs.start("weather", prompt)`.

    Running it again changes nothing: existing files are left as they are,
    and the agent is listed in the catalog once.

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

    alias Mix.Clementine

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

      with :ok <- validate(name, tool),
           {:ok, ctx} <- Clementine.context(igniter, []),
           {:ok, igniter} <- require_runtime(igniter, ctx) do
        generate(igniter, ctx, name, tool)
      else
        {:error, %Igniter{} = igniter} -> igniter
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp validate(name, tool) do
      cond do
        not Regex.match?(~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/, name) ->
          {:error,
           "Agent name must be a module name like Weather or Billing.Triage, got: #{name}"}

        not Regex.match?(~r/^[a-z][a-z0-9_]*$/, tool) ->
          {:error, "--tool must be a snake_case name like lookup_order, got: #{tool}"}

        true ->
          :ok
      end
    end

    defp require_runtime(igniter, ctx) do
      catalog = Module.concat(ctx.agents, Catalog)

      case Igniter.Project.Module.module_exists(igniter, catalog) do
        {true, igniter} ->
          {:ok, igniter}

        {false, igniter} ->
          {:error,
           Igniter.add_issue(
             igniter,
             "#{inspect(catalog)} does not exist. Run `mix clementine.install` first."
           )}
      end
    end

    defp generate(igniter, ctx, name, tool) do
      module = Module.concat(ctx.agents, name)
      tool_module = Module.concat([module, Tools, Macro.camelize(tool)])
      key = name |> Macro.underscore() |> String.replace("/", "_")

      assigns = [
        app_module: inspect(ctx.app_module),
        agents: inspect(ctx.agents),
        module: inspect(module),
        key: key,
        human: String.replace(key, "_", " "),
        tool_module: inspect(tool_module),
        tool_name: tool
      ]

      igniter
      |> Clementine.create_once(
        "clementine.gen.agent/agent.ex.eex",
        Igniter.Project.Module.proper_location(igniter, module),
        assigns
      )
      |> Clementine.create_once(
        "clementine.gen.agent/tool.ex.eex",
        Igniter.Project.Module.proper_location(igniter, tool_module),
        assigns
      )
      |> Clementine.create_once(
        "clementine.gen.agent/agent_test.exs.eex",
        Igniter.Project.Module.proper_location(
          igniter,
          Module.concat(ctx.agents, "#{name}Test"),
          :test
        ),
        assigns
      )
      |> register(ctx, module)
    end

    # The catalog is a config list, so registering is an append that skips
    # a module already listed: Igniter's strongest kind of edit.
    defp register(igniter, ctx, module) do
      catalog = Module.concat(ctx.agents, Catalog)

      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        ctx.app_name,
        [catalog, :agents],
        [module],
        updater: &Igniter.Code.List.append_new_to_list(&1, module)
      )
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
