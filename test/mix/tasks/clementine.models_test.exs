defmodule Mix.Tasks.Clementine.ModelsTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Clementine.Models, as: Task

  @fixtures Path.expand("../../fixtures/models_api", __DIR__)
  @env [:offer, :anthropic_api_key, :anthropic_base_url, :openai_api_key, :openai_base_url]

  setup do
    saved = Map.new(@env, &{&1, Application.get_env(:clementine, &1)})
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(shell)

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:clementine, key)
        {key, value} -> Application.put_env(:clementine, key, value)
      end)
    end)
  end

  # The installer's sample app: the generated Weather agent and the chat
  # example (scripts/installer-smoke), on the models they declare.
  defmodule Weather do
    use Clementine.Agent, key: "weather", model: "claude-sonnet-5-5"
  end

  defmodule Chat do
    use Clementine.Agent, key: "chat", turn: true, model: "claude-sonnet-5"

    @impl true
    def history(_run), do: []
  end

  defmodule Judge do
    use Clementine.Agent, key: "judge", model: "claude-haiku-4-5"
  end

  defmodule PerRow do
    use Clementine.Agent, key: "per_row"

    @impl true
    def agent(_run), do: Clementine.Agent.new(model: "claude-sonnet-5-5")
  end

  test "the report from section 5, for the installer's sample app" do
    report = Task.report(agents: [Weather, Chat], today: ~D[2026-11-02])

    assert Task.text(report) == """
           agent    model              platform   lifecycle                              newest in line     differs on the newest
           chat     claude-sonnet-5    anthropic  active, retires not before 2027-06-30  claude-sonnet-5-5  binding none->prefix; thinking +between_tools -off; cache read 0.1x->0.05x; min prefix 1024->512
           weather  claude-sonnet-5-5  anthropic  active, retires not before 2027-09-28  -                  -

           Clementine's model sheets were read 2026-11-01. mix clementine.models --check compares them with the vendors' Models APIs.\
           """

    assert Task.status(report) == 0
  end

  test "a passed date, the offer, a model chosen per run, and what boot refuses" do
    Application.put_env(:clementine, :offer, ["gpt-5"])

    report =
      Task.report(agents: [Judge, PerRow], model: "claude-sonnt-5", today: ~D[2026-11-02])

    text = Task.text(report)

    assert text =~
             ~r/^judge +claude-haiku-4-5 +anthropic +active, date passed 2026-10-15 +claude-haiku-5-5 +binding none->prefix; thinking \+adaptive -enabled; min prefix 4096->512; context 200K->1M; price in\/out 1\/5->0.10\/0.50; tier none->over 100K$/m

    assert text =~ ~r/^per_row +\(agent\/1\) +- +- +- +-$/m

    assert text =~
             ~r/^\(offered\) +gpt-5 +openai +deprecated, shuts down 2026-12-11, replaced by gpt-5.6-sol +- +-$/m

    assert text =~ ~r/^\(--model\) +claude-sonnt-5 +- +error/m
    assert text =~ ~s(--model claude-sonnt-5: unknown model "claude-sonnt-5")
    assert text =~ ~s(agent "per_row" picks its model in agent/1)

    assert text =~ "Warnings (dates compared with today, 2026-11-02; never errors):"
    assert text =~ ~s(agent "judge": claude-haiku-4-5's not-sooner-than date, 2026-10-15)
    assert text =~ "offered: gpt-5 is deprecated"

    # What boot refuses fails the task; warnings never do.
    assert Task.status(report) == 1
    assert Task.status(Task.report(agents: [Judge], today: ~D[2026-11-02])) == 0
  end

  test "--json, for CI" do
    report = Task.report(agents: [Chat], today: ~D[2026-11-02])

    assert %{
             "today" => "2026-11-02",
             "registry" => %{"read" => "2026-11-01", "stale" => false},
             "agents" => [
               %{
                 "agent" => "chat",
                 "model" => "claude-sonnet-5",
                 "platform" => "anthropic",
                 "lifecycle" => %{"status" => "active", "retires_not_before" => "2027-06-30"},
                 "newest" => "claude-sonnet-5-5",
                 "differs" => [%{"fact" => "binding", "from" => "none", "to" => "prefix"} | _],
                 "error" => nil
               }
             ],
             "models" => [],
             "warnings" => [],
             "check" => nil
           } = Jason.decode!(Task.json(report))
  end

  test "run/1 with --check: the findings, and exit 1 on a difference" do
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"
    Application.put_env(:clementine, :anthropic_base_url, base <> "/v1/messages")
    Application.put_env(:clementine, :openai_base_url, base <> "/v1/responses")
    Application.put_env(:clementine, :anthropic_api_key, "sk-ant-recorded")
    Application.delete_env(:clementine, :openai_api_key)

    Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      page = if conn.query_params["after_id"], do: 2, else: 1

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, File.read!(Path.join(@fixtures, "anthropic_page_#{page}.json")))
    end)

    assert catch_exit(Task.run(["--check", "--model", "claude-sonnet-5-5"])) == {:shutdown, 1}

    assert_received {:mix_shell, :info, [text]}

    assert text =~
             "Anthropic's Models API lists 6 models: 6 differences from the sheets (sheet -> API)"

    assert text =~
             ~r/claude-sonnet-6 +not in the sheets \(lifecycle active, line sonnet, released 2026-11-20\)/

    assert text =~ ~r/claude-sonnet-5 +lifecycle active -> deprecated/
    assert text =~ ~r/claude-sonnet-5 +retires_at none -> 2027-02-15/

    assert text =~
             ~r/claude-haiku-5-5 +thinking \[adaptive, off\] -> \[adaptive, between_tools, off\]/

    assert text =~ "OpenAI's Models API: skipped; config :clementine, openai_api_key: is not set"
    refute text =~ "sk-ant-recorded"
  end

  test "run/1 with --json prints the report and exits 0 when nothing would fail" do
    assert Task.run(["--json", "--model", "claude-sonnet-5-5"]) == :ok

    assert_received {:mix_shell, :info, [json]}

    assert %{"models" => [%{"source" => "cli", "model" => "claude-sonnet-5-5"}]} =
             Jason.decode!(json)
  end

  test "refuses an argument it does not take" do
    assert_raise Mix.Error, ~r/takes --check, --json, and --model ID; got: "--bogus"/, fn ->
      Task.run(["--bogus"])
    end
  end

  test "finds every Clementine.Agent module in the project's compiled code" do
    agents = Task.agents()

    # The runtime tests' agents, compiled from test/support in this
    # project; a loop controller and a tool are not agents.
    assert Clementine.RunsCase.Echo in agents
    assert Clementine.RunsCase.Lookup in agents
    refute Clementine.Thread in agents
    refute Clementine.Tools.ReadFile in agents
  end
end
