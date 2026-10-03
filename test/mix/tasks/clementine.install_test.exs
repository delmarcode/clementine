defmodule Mix.Tasks.Clementine.InstallTest do
  # Not async: each test runs from a plain directory (see Clementine.IgniterCase).
  use Clementine.IgniterCase

  @runtime_files ~w(
    lib/my_app/agents/agent_run.ex
    lib/my_app/agents/lifecycle.ex
    lib/my_app/agents/definition.ex
    lib/my_app/agents/catalog.ex
    lib/my_app/agents/runs.ex
    lib/my_app/agents/run_worker.ex
    lib/my_app/agents/reaper.ex
    lib/my_app/agents/drain_notifier.ex
    test/support/agents_case.ex
    test/my_app/agents/lifecycle_test.exs
    test/my_app/agents/runs_test.exs
    test/my_app/agents/run_worker_test.exs
    test/my_app/agents/reaper_test.exs
    test/my_app/agents/drain_notifier_test.exs
  )

  describe "a Phoenix app with Oban" do
    test "gets the runtime: migration, modules, test support, config, children, mox" do
      {:ok, igniter, %{tasks: tasks}} = project() |> install() |> apply_igniter()

      for path <- @runtime_files, do: assert(content(igniter, path) =~ "defmodule MyApp.")

      [migration] = migrations(igniter, "_create_agent_runs.exs")
      assert content(igniter, migration) =~ "defmodule MyApp.Repo.Migrations.CreateAgentRuns"
      # Pinned to a recipe version, so a later Clementine builds the same table.
      assert content(igniter, migration) =~ "Clementine.Lifecycle.Ecto.Migration.up(:agent_runs,"
      assert content(igniter, migration) =~ "version: 1,"
      assert content(igniter, migration) =~ "scope: [:subject_type, :subject_id]"
      refute content(igniter, migration) =~ "run_columns()"

      config = content(igniter, "config/config.exs")
      assert config =~ "queues: [default: 10, agents: 10]"
      assert config =~ "config :my_app, MyApp.Agents.Catalog, agents: []"
      assert config =~ ~s|anthropic_api_key: {:system, "ANTHROPIC_API_KEY"}|
      assert config =~ ~s|claude_sonnet: [provider: :anthropic, id: "claude-sonnet-5"]|
      assert config =~ "metadata: [:request_id, :run_id]"

      test_config = content(igniter, "config/test.exs")
      assert test_config =~ "config :my_app, MyApp.Agents.Reaper, enabled: false"
      assert test_config =~ "config :clementine, llm_client: MyApp.Agents.LLMMock"

      assert content(igniter, "mix.exs") =~ ~s|{:mox, "~> 1.1", only: :test}|
      assert {"deps.get", []} in tasks
    end

    test "running it twice changes nothing" do
      project()
      |> install()
      |> apply_igniter!()
      |> install()
      |> assert_unchanged()
    end

    test "the registry starts right before Oban, the reaper and drain notifier right after" do
      igniter = project() |> install() |> apply_igniter!()

      # Igniter's add_new_child would put a child with no placement first,
      # ahead of the Repo, and one with `after: [Repo]` past DNSCluster.
      assert children(igniter) == [
               "MyAppWeb.Telemetry,",
               "MyApp.Repo,",
               "{DNSCluster, query: Application.get_env(:my_app, :dns_cluster_query) || :ignore},",
               "{Registry, keys: :duplicate, name: MyApp.Agents.Runners},",
               "# Jobs run once the repo is up.",
               "{Oban, Application.fetch_env!(:my_app, Oban)},",
               "MyApp.Agents.Reaper,",
               "MyApp.Agents.DrainNotifier,",
               "{Phoenix.PubSub, name: MyApp.PubSub},",
               "MyAppWeb.Endpoint"
             ]
    end

    test "a file the host already changed is left alone" do
      runs = "defmodule MyApp.Agents.Runs do\n  # ours now\nend\n"

      project(files: %{"lib/my_app/agents/runs.ex" => runs})
      |> install()
      |> assert_unchanged("lib/my_app/agents/runs.ex")
    end

    test "config the host already set keeps its value" do
      config = """
      import Config

      config :my_app, ecto_repos: [MyApp.Repo]

      config :my_app, Oban, repo: MyApp.Repo, queues: [default: 10, agents: 3]

      config :clementine, anthropic_api_key: "from-vault"

      import_config "\#{config_env()}.exs"
      """

      igniter = project(files: %{"config/config.exs" => config}) |> install() |> apply_igniter!()

      config = content(igniter, "config/config.exs")
      assert config =~ "queues: [default: 10, agents: 3]"
      assert config =~ ~s|anthropic_api_key: "from-vault"|
      refute config =~ "ANTHROPIC_API_KEY"
    end

    test "--binary-id makes binary ids" do
      igniter = project() |> install(["--binary-id"]) |> apply_igniter!()

      [migration] = migrations(igniter, "_create_agent_runs.exs")
      assert content(igniter, migration) =~ "create table(:agent_runs, primary_key: false)"
      assert content(igniter, migration) =~ ~r/add[ (]:id, :binary_id, primary_key: true/

      assert content(igniter, "lib/my_app/agents/agent_run.ex") =~
               "@primary_key {:id, :binary_id, autogenerate: true}"

      assert content(igniter, "test/my_app/agents/lifecycle_test.exs") =~
               ~s|nonexistent_ref: "00000000-0000-0000-0000-000000000000"|
    end
  end

  describe "supervision placement" do
    test "finds Oban in a second list joined with ++ and places beside it" do
      # The shape where Igniter's own anchor lookup silently falls back to
      # the head of the first list.
      application = """
      defmodule MyApp.Application do
        use Application

        @impl true
        def start(_type, _args) do
          children =
            [
              MyApp.Repo,
              {Phoenix.PubSub, name: MyApp.PubSub}
            ] ++
              [
                {Oban, Application.fetch_env!(:my_app, Oban)},
                MyAppWeb.Endpoint
              ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end
      """

      igniter =
        project(files: %{"lib/my_app/application.ex" => application})
        |> install()
        |> apply_igniter!()

      assert children(igniter) == [
               "MyApp.Repo,",
               "{Phoenix.PubSub, name: MyApp.PubSub}",
               "] ++",
               "{Registry, keys: :duplicate, name: MyApp.Agents.Runners},",
               "{Oban, Application.fetch_env!(:my_app, Oban)},",
               "MyApp.Agents.Reaper,",
               "MyApp.Agents.DrainNotifier,",
               "MyAppWeb.Endpoint"
             ]

      igniter |> install() |> assert_unchanged()
    end

    test "edits no children and says what to add when Oban is not among them" do
      application = """
      defmodule MyApp.Application do
        use Application

        @impl true
        def start(_type, _args) do
          children = [MyApp.Repo, MyApp.JobSupervisor, MyAppWeb.Endpoint]
          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end
      """

      {:ok, igniter, %{warnings: warnings}} =
        project(files: %{"lib/my_app/application.ex" => application})
        |> install()
        |> apply_igniter()

      refute content(igniter, "lib/my_app/application.ex") =~ "MyApp.Agents"
      assert Enum.count(warnings, &(&1 =~ "could not place a supervision child")) == 3

      assert Enum.any?(
               warnings,
               &(&1 =~ "{Registry, keys: :duplicate, name: MyApp.Agents.Runners}")
             )
    end

    test "a child the host moved is not added again" do
      application = """
      defmodule MyApp.Application do
        use Application

        @impl true
        def start(_type, _args) do
          children = [
            MyApp.Repo,
            {Registry, keys: :duplicate, name: MyApp.Agents.Runners},
            {Oban, Application.fetch_env!(:my_app, Oban)}
          ] ++ agent_children()

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end

        defp agent_children, do: [MyApp.Agents.DrainNotifier, MyApp.Agents.Reaper]
      end
      """

      project(files: %{"lib/my_app/application.ex" => application})
      |> install()
      |> assert_unchanged("lib/my_app/application.ex")
    end
  end

  describe "without what the runtime needs" do
    test "an app without Oban gets an issue and no changes" do
      config = """
      import Config

      config :my_app, ecto_repos: [MyApp.Repo]
      """

      assert {:error, [issue]} =
               project(files: %{"config/config.exs" => config}) |> install() |> apply_igniter()

      assert issue =~ "mix igniter.install oban"
    end

    test "an app without a repo gets an issue" do
      igniter =
        test_project(app_name: :my_app, files: %{"config/config.exs" => "import Config\n"})
        |> install()

      assert_has_issue(igniter, &(&1 =~ "No Ecto repo found"))
    end
  end

  defp install(igniter, argv \\ []) do
    Igniter.compose_task(igniter, "clementine.install", argv)
  end

  defp migrations(igniter, suffix) do
    igniter.rewrite
    |> Rewrite.sources()
    |> Enum.map(& &1.path)
    |> Enum.filter(&String.ends_with?(&1, suffix))
  end

  # The application's children as trimmed lines, from the line after
  # `children =` up to the line that starts the supervisor.
  defp children(igniter) do
    igniter
    |> content("lib/my_app/application.ex")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.drop_while(&(not String.starts_with?(&1, "children =")))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, ["opts =", "Supervisor.start_link"])))
    |> Enum.reject(&(&1 in ["", "[", "]"]))
  end
end
