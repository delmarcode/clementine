defmodule Mix.Tasks.Clementine.Gen.AgentTest do
  # Not async: each test runs from a plain directory (see Clementine.IgniterCase).
  use Clementine.IgniterCase

  test "generates an agent, its tool, and its test, and lists the agent in the child spec" do
    igniter = installed() |> gen_agent(["Weather"]) |> apply_igniter!()

    agent = content(igniter, "lib/my_app/agents/weather.ex")
    assert agent =~ "defmodule MyApp.Agents.Weather do"
    assert agent =~ "use Clementine.Agent,"
    assert agent =~ ~s|key: "weather",|
    assert agent =~ "tools: [MyApp.Agents.Weather.Tools.Lookup]"
    assert agent =~ "Clementine.Runs.start(MyApp.Agents.Weather, prompt)"

    tool = content(igniter, "lib/my_app/agents/weather/tools/lookup.ex")
    assert tool =~ "defmodule MyApp.Agents.Weather.Tools.Lookup do"
    assert tool =~ ~s|name: "lookup"|

    test = content(igniter, "test/my_app/agents/weather_test.exs")
    assert test =~ "defmodule MyApp.Agents.WeatherTest do"
    assert test =~ "use MyApp.AgentsCase"
    assert test =~ ~s|Clementine.Runs.start(Weather, "Look something up")|
    assert test =~ ~s|tool_events("toolu_1", "lookup", %{query: "something"})|
    assert test =~ ~s|perform_job(Clementine.Runs.Worker, %{"run_id" => run.id})|

    assert runtime_child(igniter) =~ "agents: [MyApp.Agents.Weather]"
  end

  test "running it twice changes nothing and lists the agent once" do
    installed()
    |> gen_agent(["Weather"])
    |> apply_igniter!()
    |> gen_agent(["Weather"])
    |> assert_unchanged()
  end

  test "a second agent is appended to agents:" do
    igniter =
      installed()
      |> gen_agent(["Weather"])
      |> apply_igniter!()
      |> gen_agent(["Billing.Triage", "--tool", "lookup_order"])
      |> apply_igniter!()

    assert runtime_child(igniter) =~
             "agents: [MyApp.Agents.Weather, MyApp.Agents.Billing.Triage]"

    agent = content(igniter, "lib/my_app/agents/billing/triage.ex")
    assert agent =~ ~s|key: "billing_triage",|
    assert agent =~ "tools: [MyApp.Agents.Billing.Triage.Tools.LookupOrder]"

    assert content(igniter, "lib/my_app/agents/billing/triage/tools/lookup_order.ex") =~
             ~s|name: "lookup_order"|

    test = content(igniter, "test/my_app/agents/billing/triage_test.exs")
    assert test =~ "defmodule MyApp.Agents.Billing.TriageTest do"
    assert test =~ "alias MyApp.Agents.Billing.Triage\n"
    assert test =~ "alias MyApp.Agents.Billing.Triage.Tools.LookupOrder\n"
  end

  test "adds agents: to a child that has none" do
    igniter =
      installed(application("{Clementine, repo: MyApp.Repo}"))
      |> gen_agent(["Weather"])
      |> apply_igniter!()

    assert runtime_child(igniter) =~
             "{Clementine, repo: MyApp.Repo, agents: [MyApp.Agents.Weather]}"
  end

  test "says what to add when the child's options are not a literal keyword list" do
    child = "{Clementine, Application.fetch_env!(:my_app, Clementine)}"

    {:ok, igniter, %{warnings: [warning]}} =
      installed(application(child))
      |> gen_agent(["Weather"])
      |> apply_igniter()

    assert warning =~ "could not list MyApp.Agents.Weather"
    assert warning =~ "agents: [..., MyApp.Agents.Weather]"
    refute content(igniter, "lib/my_app/application.ex") =~ "MyApp.Agents.Weather"
    # The agent, its tool, and its test are written all the same.
    assert content(igniter, "lib/my_app/agents/weather.ex") =~ "use Clementine.Agent"
  end

  test "refuses the model mock's name" do
    igniter = installed() |> gen_agent(["LLMMock"])

    assert_has_issue(igniter, &(&1 =~ "MyApp.Agents.LLMMock is the model mock"))
  end

  test "refuses names whose aliases would collide in the generated test" do
    installed() |> gen_agent(["Clementine"]) |> assert_has_issue(&(&1 =~ "must not be one of"))

    installed()
    |> gen_agent(["Weather", "--tool", "clementine"])
    |> assert_has_issue(&(&1 =~ "must not be one of"))

    installed() |> gen_agent(["Lookup"]) |> assert_has_issue(&(&1 =~ "Pass another --tool"))
  end

  test "refuses the name of a module that exists and is not an agent" do
    billing = "defmodule MyApp.Agents.Billing do\n  def total, do: 0\nend\n"

    installed()
    |> Igniter.create_new_file("lib/my_app/agents/billing.ex", billing)
    |> apply_igniter!()
    |> gen_agent(["Billing"])
    |> assert_has_issue(&(&1 =~ "MyApp.Agents.Billing already exists and is not an agent"))
  end

  test "lists an agent written by hand without touching its file" do
    agent = """
    defmodule MyApp.Agents.Triage do
      use Clementine.Agent, key: "triage"

      @impl true
      def agent(_run), do: Clementine.Agent.new(model: :claude_sonnet)
    end
    """

    igniter =
      installed()
      |> Igniter.create_new_file("lib/my_app/agents/triage.ex", agent)
      |> apply_igniter!()
      |> gen_agent(["Triage"])
      |> assert_unchanged("lib/my_app/agents/triage.ex")
      |> apply_igniter!()

    assert runtime_child(igniter) =~ "agents: [MyApp.Agents.Triage]"
  end

  test "a module declaring the behaviour through an alias is an agent too" do
    agent = """
    defmodule MyApp.Agents.Triage do
      alias Clementine.Agent, as: AgentDef

      @behaviour AgentDef

      @impl true
      def key, do: "triage"

      @impl true
      def agent(_run), do: AgentDef.new(model: :claude_sonnet)
    end
    """

    igniter =
      installed()
      |> Igniter.create_new_file("lib/my_app/agents/triage.ex", agent)
      |> apply_igniter!()
      |> gen_agent(["Triage"])
      |> apply_igniter!()

    assert runtime_child(igniter) =~ "agents: [MyApp.Agents.Triage]"
  end

  test "needs the runtime from clementine.install" do
    project() |> gen_agent(["Weather"]) |> assert_has_issue(&(&1 =~ "mix clementine.install"))
  end

  test "refuses a name that is not a module name" do
    installed() |> gen_agent(["weather"]) |> assert_has_issue(&(&1 =~ "module name"))
  end

  test "refuses a tool name that is not snake_case" do
    installed()
    |> gen_agent(["Weather", "--tool", "LookUp"])
    |> assert_has_issue(&(&1 =~ "snake_case"))
  end

  defp gen_agent(igniter, argv), do: Igniter.compose_task(igniter, "clementine.gen.agent", argv)

  defp installed(files \\ %{}) do
    project(files: files) |> Igniter.compose_task("clementine.install", []) |> apply_igniter!()
  end

  # An application module whose children are the repo, Oban, and `child`.
  defp application(child) do
    %{
      "lib/my_app/application.ex" => """
      defmodule MyApp.Application do
        use Application

        @impl true
        def start(_type, _args) do
          children = [
            MyApp.Repo,
            {Oban, Application.fetch_env!(:my_app, Oban)},
            #{child}
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
        end
      end
      """
    }
  end

  # The {Clementine, ...} child, on one line.
  defp runtime_child(igniter) do
    [_before, child] =
      igniter
      |> content("lib/my_app/application.ex")
      |> String.split("{Clementine,", parts: 2)

    [child | _after] = String.split(child, "}", parts: 2)
    String.replace("{Clementine," <> child <> "}", ~r/\s+/, " ")
  end
end
