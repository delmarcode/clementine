defmodule Mix.Tasks.Clementine.Install.Docs do
  @moduledoc false

  def short_doc do
    "Adds Clementine's durable agent runtime to a Phoenix app with Oban."
  end

  def example do
    "mix clementine.install"
  end

  def long_doc do
    """
    #{short_doc()}

    This is the Durable Execution guide as a generator. It writes ordinary
    code into your app, which is yours to read and change from then on:

      * a migration for an `agent_runs` table: your product columns plus
        Clementine's column recipe and the single-active index, pinned to
        recipe version 1 so a later Clementine builds the same table
      * `MyApp.Agents.AgentRun`, the schema
      * `MyApp.Agents.Lifecycle`, the storage contract and its projection
      * `MyApp.Agents.Definition` and `MyApp.Agents.Catalog`, how agents are
        defined and found (`mix clementine.gen.agent` adds to the catalog)
      * `MyApp.Agents.Runs`: start, execute, cancel, resume, and sweep
      * `MyApp.Agents.RunWorker`, the Oban worker on the `agents` queue
      * `MyApp.Agents.Reaper` and `MyApp.Agents.DrainNotifier`
      * `MyApp.AgentsCase` with a Mox model and test agents, the
        conformance suite for your lifecycle, and tests for `Runs`,
        `RunWorker`, `Reaper`, and `DrainNotifier`

    It also adds the `agents` Oban queue, Clementine's provider key, a
    model alias, and the `run_id` logger metadata key to
    `config/config.exs`, the test settings to
    `config/test.exs`, `mox` as a test dependency, and three children to
    your application: the runner registry right before Oban, and the reaper
    and drain notifier right after it.

    Running it again changes nothing. It never overwrites a file or a
    config key that exists, and never moves a child that is already in the
    supervision tree. When it cannot find Oban among the application's
    children, it edits nothing there and prints the lines to add by hand.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

      * `--repo` or `-r` — the Ecto repo that holds `agent_runs`; defaults to
        the app's first repo
      * `--binary-id` — use binary ids for `agent_runs`; defaults to the
        app's `config :my_app, :generators, binary_id: true`
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Clementine.Install do
    @shortdoc __MODULE__.Docs.short_doc()

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Mix.Clementine

    @modules ~w(agent_run lifecycle definition catalog runs run_worker reaper drain_notifier)a

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :clementine,
        example: __MODULE__.Docs.example(),
        schema: [repo: :string, binary_id: :boolean],
        aliases: [r: :repo]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options

      with {:ok, ctx} <- Clementine.context(igniter, opts),
           :ok <- require_oban(igniter, ctx) do
        assigns = assigns(ctx, opts)

        igniter
        |> migration(ctx, assigns)
        |> modules(ctx, assigns)
        |> test_support(ctx, assigns)
        |> config(ctx)
        |> children(ctx)
        |> mox()
        |> Igniter.add_notice(next_steps(ctx))
      else
        {:error, igniter} -> igniter
      end
    end

    defp require_oban(igniter, ctx) do
      if Igniter.Project.Config.configures_key?(igniter, "config.exs", ctx.app_name, Oban) do
        :ok
      else
        {:error,
         Igniter.add_issue(igniter, """
         Clementine's durable runtime executes runs on Oban, and
         config/config.exs has no `config #{inspect(ctx.app_name)}, Oban`.
         Install Oban first (`mix igniter.install oban`), then run this again.
         """)}
      end
    end

    defp assigns(ctx, opts) do
      [
        app_name: ctx.app_name,
        app_module: inspect(ctx.app_module),
        agents: inspect(ctx.agents),
        repo: inspect(ctx.repo),
        binary_id: binary_id?(ctx, opts)
      ]
    end

    defp binary_id?(ctx, opts) do
      case Keyword.fetch(opts, :binary_id) do
        {:ok, value} ->
          value

        :error ->
          ctx.app_name
          |> Application.get_env(:generators, [])
          |> Keyword.get(:binary_id, false)
      end
    end

    defp migration(igniter, ctx, assigns) do
      body =
        EEx.eval_file(Clementine.template("clementine.install/create_agent_runs.exs.eex"),
          assigns: assigns
        )

      Igniter.Libs.Ecto.gen_migration(igniter, ctx.repo, "create_agent_runs",
        body: body,
        on_exists: :skip
      )
    end

    defp modules(igniter, ctx, assigns) do
      Enum.reduce(@modules, igniter, fn name, igniter ->
        module = Module.concat(ctx.agents, Macro.camelize(Atom.to_string(name)))

        Clementine.create_once(
          igniter,
          "clementine.install/#{name}.ex.eex",
          Igniter.Project.Module.proper_location(igniter, module),
          assigns
        )
      end)
    end

    @tests ~w(lifecycle_test runs_test run_worker_test reaper_test drain_notifier_test)a

    defp test_support(igniter, ctx, assigns) do
      case_module = Module.concat(ctx.app_module, AgentsCase)

      igniter =
        Clementine.create_once(
          igniter,
          "clementine.install/agents_case.ex.eex",
          Igniter.Project.Module.proper_location(igniter, case_module, :test_support),
          assigns
        )

      Enum.reduce(@tests, igniter, fn name, igniter ->
        module = Module.concat(ctx.agents, Macro.camelize(Atom.to_string(name)))

        Clementine.create_once(
          igniter,
          "clementine.install/#{name}.exs.eex",
          Igniter.Project.Module.proper_location(igniter, module, :test),
          assigns
        )
      end)
    end

    defp config(igniter, ctx) do
      app = ctx.app_name
      catalog = Module.concat(ctx.agents, Catalog)
      reaper = Module.concat(ctx.agents, Reaper)
      mock = Module.concat(ctx.agents, LLMMock)

      igniter
      |> Igniter.Project.Config.configure_new("config.exs", app, [Oban, :queues, :agents], 10)
      |> Igniter.Project.Config.configure_new("config.exs", app, [catalog, :agents], [])
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        :clementine,
        [:anthropic_api_key],
        {:code, Sourceror.parse_string!(~s|{:system, "ANTHROPIC_API_KEY"}|)}
      )
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        :clementine,
        [:models, :claude_sonnet],
        {:code, Sourceror.parse_string!(~s|[provider: :anthropic, id: "claude-sonnet-5"]|)}
      )
      # RunWorker tags its logs with the run; the formatter prints only the
      # metadata keys it lists, and credo's MissedMetadataKeyInLoggerConfig
      # checks that it lists them.
      |> Igniter.Project.Config.configure(
        "config.exs",
        :logger,
        [:default_formatter, :metadata],
        [:run_id],
        updater: &Igniter.Code.List.append_new_to_list(&1, :run_id)
      )
      |> Igniter.Project.Config.configure_new("test.exs", app, [reaper, :enabled], false)
      |> Igniter.Project.Config.configure_new("test.exs", :clementine, [:llm_client], mock)
    end

    # The registry must exist before Oban starts running jobs, which
    # register in it. The reaper sweeps through Oban and the drain notifier
    # must stop before Oban waits out its grace period, so both follow it.
    defp children(igniter, ctx) do
      registry = Module.concat(ctx.agents, Runners)
      reaper = Module.concat(ctx.agents, Reaper)
      drain = Module.concat(ctx.agents, DrainNotifier)

      igniter
      |> Clementine.add_child(
        "{Registry, keys: :duplicate, name: #{inspect(registry)}}",
        registry,
        {:before, Oban}
      )
      |> Clementine.add_child(inspect(drain), drain, {:after, Oban})
      |> Clementine.add_child(inspect(reaper), reaper, {:after, Oban})
    end

    # The generated test case scripts the model with a Mox mock.
    defp mox(igniter) do
      if Igniter.Project.Deps.has_dep?(igniter, :mox) do
        igniter
      else
        igniter
        |> Igniter.Project.Deps.add_dep({:mox, "~> 1.1", only: :test})
        |> Igniter.add_task("deps.get")
      end
    end

    defp next_steps(ctx) do
      """
      Clementine's durable runtime is in #{inspect(ctx.agents)}. Next:

        * mix ecto.migrate
        * mix clementine.gen.agent Weather  (an agent, a tool, and a test)
        * set ANTHROPIC_API_KEY where the app runs

      Start a run with #{inspect(ctx.agents)}.Runs.start("weather", prompt).
      """
    end
  end
else
  defmodule Mix.Tasks.Clementine.Install do
    @shortdoc "Install `igniter` to run clementine.install."

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'clementine.install' requires igniter. Add it to your deps:

          {:igniter, "~> 0.8", only: [:dev, :test]}

      then run `mix deps.get` and try again.
      """)

      exit({:shutdown, 1})
    end
  end
end
