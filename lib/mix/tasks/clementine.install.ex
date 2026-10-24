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

    The runtime lives in Clementine: the `agent_runs` schema, the Oban
    worker, the reaper, and the drain. This task writes only the glue,
    which is yours to read and change from then on:

      * `{Clementine, repo: MyApp.Repo, oban: Oban, queue: :agents, agents: []}`
        in your application's children, right after Oban
      * a migration that builds `agent_runs` with
        `Clementine.Migration.up(version: 1)`
      * the `agents` Oban queue, Clementine's provider key, a model alias,
        and the `run_id` logger metadata key in `config/config.exs`
      * `MyApp.Agents.LLMMock` as Clementine's model client in
        `config/test.exs`, so no test reaches a real provider
      * `MyApp.AgentsCase` in `test/support/agents_case.ex`: the SQL
        sandbox, Oban's testing helpers, and helpers to script the model
      * `mox` as a test dependency

    `mix clementine.gen.agent` then adds agents to the child's `agents:`.

    Running it again changes nothing. It never overwrites a file or a
    config key that exists, and never moves a child that is already in the
    supervision tree. When it cannot find Oban among the application's
    children, it edits nothing there and prints the line to add by hand.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

      * `--repo` or `-r` — the Ecto repo that holds `agent_runs`; defaults to
        the app's first repo
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Clementine.Install do
    @shortdoc __MODULE__.Docs.short_doc()

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :clementine,
        example: __MODULE__.Docs.example(),
        schema: [repo: :string],
        aliases: [r: :repo]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      ctx = Mix.Clementine.context(igniter)

      with {:ok, repo} <- repo(igniter, ctx, igniter.args.options[:repo]),
           :ok <- require_oban(igniter, ctx) do
        ctx = Map.put(ctx, :repo, repo)

        igniter
        |> migration(ctx)
        |> test_support(ctx)
        |> config(ctx)
        |> child(ctx)
        |> mox()
        |> Igniter.add_notice(next_steps(ctx))
      else
        {:error, igniter} -> igniter
      end
    end

    defp repo(igniter, ctx, nil) do
      case Igniter.Libs.Ecto.list_repos(igniter) do
        {_igniter, [repo | _]} ->
          {:ok, repo}

        _none ->
          {:error,
           Igniter.add_issue(igniter, """
           No Ecto repo found for #{inspect(ctx.app_name)}. Clementine's durable runtime
           stores runs in Postgres through Ecto; add a repo, or pass --repo.
           """)}
      end
    end

    defp repo(igniter, _ctx, name) do
      repo = Igniter.Project.Module.parse(name)

      case Igniter.Project.Module.module_exists(igniter, repo) do
        {true, _igniter} ->
          {:ok, repo}

        {false, _igniter} ->
          {:error, Igniter.add_issue(igniter, "Repo #{inspect(repo)} does not exist.")}
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

    defp migration(igniter, ctx) do
      body = EEx.eval_file(Mix.Clementine.template("clementine.install/add_clementine.exs.eex"))

      Igniter.Libs.Ecto.gen_migration(igniter, ctx.repo, "add_clementine",
        body: body,
        on_exists: :skip
      )
    end

    defp test_support(igniter, ctx) do
      case_module = Module.concat(ctx.app_module, AgentsCase)

      Mix.Clementine.create_once(
        igniter,
        "clementine.install/agents_case.ex.eex",
        Igniter.Project.Module.proper_location(igniter, case_module, :test_support),
        app_module: inspect(ctx.app_module),
        agents: inspect(ctx.agents),
        repo: inspect(ctx.repo)
      )
    end

    defp config(igniter, ctx) do
      mock = Module.concat(ctx.agents, LLMMock)

      igniter
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        ctx.app_name,
        [Oban, :queues, :agents],
        10
      )
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
      # Clementine's worker tags its logs with the run, and the formatter
      # prints only the metadata keys it lists.
      |> Igniter.Project.Config.configure(
        "config.exs",
        :logger,
        [:default_formatter, :metadata],
        [:run_id],
        updater: &Igniter.Code.List.append_new_to_list(&1, :run_id)
      )
      |> Igniter.Project.Config.configure_new("test.exs", :clementine, [:llm_client], mock)
    end

    # After Oban: the runtime checks Oban is running when it starts, and
    # stops first at shutdown, draining its runs while Oban still owes
    # them the grace period.
    defp child(igniter, ctx) do
      Mix.Clementine.add_child(
        igniter,
        "{Clementine, repo: #{inspect(ctx.repo)}, oban: Oban, queue: :agents, agents: []}",
        Clementine,
        {:after, Oban}
      )
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
      Clementine's durable runtime is set up. Next:

        * mix ecto.migrate
        * mix clementine.gen.agent Weather  (an agent, a tool, and a test)
        * set ANTHROPIC_API_KEY where the app runs

      Start a run with Clementine.Runs.start(#{inspect(ctx.agents)}.Weather, prompt).
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
