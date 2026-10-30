defmodule Mix.Tasks.Clementine.InstallTest do
  # Not async: each test runs from a plain directory (see Clementine.IgniterCase).
  use Clementine.IgniterCase

  describe "a Phoenix app with Oban" do
    test "gets the glue: migration, test case, config, child, mox" do
      {:ok, igniter, %{tasks: tasks}} = project() |> install() |> apply_igniter()

      [migration] = migrations(igniter)
      migration = content(igniter, migration)
      assert migration =~ "defmodule MyApp.Repo.Migrations.AddClementine"
      assert migration =~ "def up, do: Clementine.Migration.up(version: 3)"
      assert migration =~ "def down, do: Clementine.Migration.down(version: 3)"

      agents_case = content(igniter, "test/support/agents_case.ex")

      assert agents_case =~
               "Mox.defmock(MyApp.Agents.LLMMock, for: Clementine.LLM.ClientBehaviour)"

      assert agents_case =~ "defmodule MyApp.AgentsCase do"
      assert agents_case =~ "use Oban.Testing, repo: MyApp.Repo"

      # The runtime is Clementine's: nothing of it is copied into the app.
      assert paths(igniter, "lib/my_app/agents") == []
      assert paths(igniter, "test/support/") == ["test/support/agents_case.ex"]
      assert paths(igniter, "test/my_app/") == []

      config = content(igniter, "config/config.exs")
      assert config =~ "queues: [default: 10, agents: 10]"
      assert config =~ ~s|anthropic_api_key: {:system, "ANTHROPIC_API_KEY"}|
      assert config =~ ~s|claude_sonnet: [provider: :anthropic, id: "claude-sonnet-5"]|
      assert config =~ "metadata: [:request_id, :run_id]"
      refute config =~ "Catalog"

      test_config = content(igniter, "config/test.exs")
      assert test_config =~ "config :clementine, llm_client: MyApp.Agents.LLMMock"
      refute test_config =~ "Reaper"

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

    test "the runtime starts right after Oban" do
      igniter = project() |> install() |> apply_igniter!()

      # Igniter's add_new_child would put a child with no placement first,
      # ahead of the Repo, and one with `after: [Repo]` past DNSCluster.
      assert children(igniter) == [
               "MyAppWeb.Telemetry,",
               "MyApp.Repo,",
               "{DNSCluster, query: Application.get_env(:my_app, :dns_cluster_query) || :ignore},",
               "# Jobs run once the repo is up.",
               "{Oban, Application.fetch_env!(:my_app, Oban)},",
               "{Clementine, repo: MyApp.Repo, oban: Oban, queue: :agents, agents: []},",
               "{Phoenix.PubSub, name: MyApp.PubSub},",
               "MyAppWeb.Endpoint"
             ]
    end

    test "--repo names the repo" do
      other = "defmodule MyApp.OtherRepo do\n  use Ecto.Repo, otp_app: :my_app\nend\n"

      igniter =
        project(files: %{"lib/my_app/other_repo.ex" => other})
        |> install(["--repo", "MyApp.OtherRepo"])
        |> apply_igniter!()

      assert [_migration] = migrations(igniter, "other_repo")
      assert content(igniter, "lib/my_app/application.ex") =~ "repo: MyApp.OtherRepo"
      assert content(igniter, "test/support/agents_case.ex") =~ "repo: MyApp.OtherRepo"
    end

    test "--repo must name a repo that exists" do
      project()
      |> install(["--repo", "MyApp.Missing"])
      |> assert_has_issue(&(&1 =~ "Repo MyApp.Missing does not exist"))
    end

    test "a file the host already changed is left alone" do
      agents_case = "defmodule MyApp.AgentsCase do\n  # ours now\nend\n"

      project(files: %{"test/support/agents_case.ex" => agents_case})
      |> install()
      |> assert_unchanged("test/support/agents_case.ex")
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
               "{Oban, Application.fetch_env!(:my_app, Oban)},",
               "{Clementine, repo: MyApp.Repo, oban: Oban, queue: :agents, agents: []},",
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

      refute content(igniter, "lib/my_app/application.ex") =~ "Clementine"
      assert [warning] = Enum.filter(warnings, &(&1 =~ "could not place a supervision child"))
      assert warning =~ "after Oban"
      assert warning =~ "{Clementine, repo: MyApp.Repo, oban: Oban, queue: :agents, agents: []}"
    end

    test "a module that calls Clementine elsewhere still gets the child" do
      application = """
      defmodule MyApp.Application do
        use Application

        @impl true
        def start(_type, _args) do
          children = [
            MyApp.Repo,
            {Oban, Application.fetch_env!(:my_app, Oban)}
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end

        def ask(agent, prompt), do: Clementine.run(agent, prompt)
      end
      """

      igniter =
        project(files: %{"lib/my_app/application.ex" => application})
        |> install()
        |> apply_igniter!()

      assert content(igniter, "lib/my_app/application.ex") =~
               "{Clementine, repo: MyApp.Repo, oban: Oban, queue: :agents, agents: []}"
    end

    test "a child the host moved is not added again" do
      application = """
      defmodule MyApp.Application do
        use Application

        @impl true
        def start(_type, _args) do
          children = [
            MyApp.Repo,
            {Oban, Application.fetch_env!(:my_app, Oban)}
          ] ++ agent_children()

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end

        defp agent_children, do: [{Clementine, Application.fetch_env!(:my_app, Clementine)}]
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

  # The repo's add_clementine migrations.
  defp migrations(igniter, repo \\ "repo") do
    igniter
    |> paths("priv/#{repo}/migrations/")
    |> Enum.filter(&String.ends_with?(&1, "_add_clementine.exs"))
  end

  defp paths(igniter, prefix) do
    igniter.rewrite
    |> Rewrite.sources()
    |> Enum.map(& &1.path)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.sort()
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
