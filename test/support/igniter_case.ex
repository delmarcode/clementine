defmodule Clementine.IgniterCase do
  @moduledoc """
  The case for generator tests built on `Igniter.Test`, with an in-memory
  project shaped like a fresh Phoenix app after `mix oban.install`.

  `Igniter.Test` finds its in-memory project files by matching globs
  against paths expanded from the current directory, and a `**` glob does
  not cross a dot-directory. From a checkout under `.worktrees/` it would
  see no files at all, so every test here runs from the system temp
  directory instead. The working directory is global to the VM, so these
  tests are not async; ExUnit runs them after the async ones.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Igniter.Test
      import Clementine.IgniterCase, only: [project: 0, project: 1, content: 2]
    end
  end

  setup do
    cwd = File.cwd!()
    File.cd!(System.tmp_dir!())
    on_exit(fn -> File.cd!(cwd) end)
  end

  @mix_exs """
  defmodule MyApp.MixProject do
    use Mix.Project

    def project do
      [
        app: :my_app,
        version: "0.1.0",
        elixir: "~> 1.17",
        elixirc_paths: elixirc_paths(Mix.env()),
        deps: deps()
      ]
    end

    def application do
      [mod: {MyApp.Application, []}, extra_applications: [:logger]]
    end

    defp elixirc_paths(:test), do: ["lib", "test/support"]
    defp elixirc_paths(_), do: ["lib"]

    defp deps do
      [
        {:ecto_sql, "~> 3.10"},
        {:postgrex, ">= 0.0.0"},
        {:oban, "~> 2.19"}
      ]
    end
  end
  """

  @repo """
  defmodule MyApp.Repo do
    use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
  end
  """

  @application """
  defmodule MyApp.Application do
    @moduledoc false

    use Application

    @impl true
    def start(_type, _args) do
      children = [
        MyAppWeb.Telemetry,
        MyApp.Repo,
        {DNSCluster, query: Application.get_env(:my_app, :dns_cluster_query) || :ignore},
        # Jobs run once the repo is up.
        {Oban, Application.fetch_env!(:my_app, Oban)},
        {Phoenix.PubSub, name: MyApp.PubSub},
        MyAppWeb.Endpoint
      ]

      opts = [strategy: :one_for_one, name: MyApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  """

  @config """
  import Config

  config :my_app, ecto_repos: [MyApp.Repo]

  config :my_app, Oban, repo: MyApp.Repo, queues: [default: 10]

  config :logger, :default_formatter,
    format: "$time $metadata[$level] $message\\n",
    metadata: [:request_id]

  import_config "\#{config_env()}.exs"
  """

  @test_config """
  import Config

  config :my_app, Oban, testing: :manual
  """

  @doc "A file's current content in the igniter."
  def content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  @doc """
  The in-memory project for `:my_app`. `files:` replaces or adds files.
  """
  def project(opts \\ []) do
    files =
      Map.merge(
        %{
          "mix.exs" => @mix_exs,
          "lib/my_app/repo.ex" => @repo,
          "lib/my_app/application.ex" => @application,
          "config/config.exs" => @config,
          "config/dev.exs" => "import Config\n",
          "config/test.exs" => @test_config,
          "config/prod.exs" => "import Config\n"
        },
        Keyword.get(opts, :files, %{})
      )

    Igniter.Test.test_project(app_name: :my_app, files: files)
  end
end
