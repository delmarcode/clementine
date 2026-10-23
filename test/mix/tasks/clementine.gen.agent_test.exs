defmodule Mix.Tasks.Clementine.Gen.AgentTest do
  # Not async: each test runs from a plain directory (see Clementine.IgniterCase).
  use Clementine.IgniterCase

  test "generates an agent, its tool, and its test, and lists the agent in the catalog" do
    igniter = installed() |> gen_agent(["Weather"]) |> apply_igniter!()

    agent = content(igniter, "lib/my_app/agents/weather.ex")
    assert agent =~ "defmodule MyApp.Agents.Weather do"
    assert agent =~ "@behaviour MyApp.Agents.Definition"
    assert agent =~ ~s|def key, do: "weather"|
    assert agent =~ "tools: [MyApp.Agents.Weather.Tools.Lookup]"

    tool = content(igniter, "lib/my_app/agents/weather/tools/lookup.ex")
    assert tool =~ "defmodule MyApp.Agents.Weather.Tools.Lookup do"
    assert tool =~ ~s|name: "lookup"|

    test = content(igniter, "test/my_app/agents/weather_test.exs")
    assert test =~ "defmodule MyApp.Agents.WeatherTest do"
    assert test =~ "use MyApp.AgentsCase"
    assert test =~ ~s|tool_events("toolu_1", "lookup", %{query: "something"})|

    assert content(igniter, "config/config.exs") =~
             "config :my_app, MyApp.Agents.Catalog, agents: [MyApp.Agents.Weather]"
  end

  test "running it twice changes nothing and lists the agent once" do
    installed()
    |> gen_agent(["Weather"])
    |> apply_igniter!()
    |> gen_agent(["Weather"])
    |> assert_unchanged()
  end

  test "a second agent is appended to the catalog" do
    igniter =
      installed()
      |> gen_agent(["Weather"])
      |> apply_igniter!()
      |> gen_agent(["Billing.Triage", "--tool", "lookup_order"])
      |> apply_igniter!()

    assert content(igniter, "config/config.exs") =~
             "agents: [MyApp.Agents.Weather, MyApp.Agents.Billing.Triage]"

    agent = content(igniter, "lib/my_app/agents/billing/triage.ex")
    assert agent =~ ~s|def key, do: "billing_triage"|
    assert agent =~ "tools: [MyApp.Agents.Billing.Triage.Tools.LookupOrder]"

    assert content(igniter, "lib/my_app/agents/billing/triage/tools/lookup_order.ex") =~
             ~s|name: "lookup_order"|

    assert content(igniter, "test/my_app/agents/billing/triage_test.exs") =~
             "defmodule MyApp.Agents.Billing.TriageTest do"
  end

  test "refuses a runtime module's name" do
    igniter = installed() |> gen_agent(["Reaper"])

    assert_has_issue(igniter, &(&1 =~ "MyApp.Agents.Reaper is part of Clementine's runtime"))
  end

  test "refuses names whose aliases would collide in the generated test" do
    installed() |> gen_agent(["Shop.Catalog"]) |> assert_has_issue(&(&1 =~ "must not be one of"))
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
      alias MyApp.Agents.Definition

      @behaviour Definition

      @impl true
      def key, do: "triage"

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

    assert content(igniter, "config/config.exs") =~ "agents: [MyApp.Agents.Triage]"
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

  defp installed do
    project() |> Igniter.compose_task("clementine.install", []) |> apply_igniter!()
  end
end
