defmodule Clementine.Models.BootTest do
  @moduledoc """
  What `{Clementine, ...}` does with a model's dates when it starts: it
  warns, never fails, and reads no network. Its errors come from the
  sheets and the app's config, the offer's included. (The offer's dates
  and the registry's age warn when Clementine itself starts:
  `Clementine.Models.WarningsTest`.)
  """

  use Clementine.RunsCase

  import ExUnit.CaptureLog

  alias Clementine.TestPlatforms

  @moduletag runtime: false

  @env [:models, :offer, :llm_client]

  setup do
    saved = Map.new(@env, &{&1, Application.get_env(:clementine, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:clementine, key)
        {key, value} -> Application.put_env(:clementine, key, value)
      end)
    end)
  end

  defmodule Judge do
    use Clementine.Agent, key: "boot_judge", model: "claude-haiku-4-5"
  end

  defmodule Screener do
    use Clementine.Agent, key: "boot_screener", model: "gpt-5"
  end

  test "a deprecated model, a passed date, and a reached shutdown date warn, and boot starts" do
    Application.put_env(:clementine, :models, %{
      "claude-sonnet-legacy" => [
        based_on: "claude-sonnet-5-5",
        lifecycle: [
          status: :deprecated,
          retires_on: ~D[2020-01-01],
          replacement: "claude-sonnet-5-5"
        ]
      ]
    })

    Application.put_env(:clementine, :offer, ["claude-sonnet-legacy"])

    log =
      capture_log(fn ->
        assert {:ok, _pid} =
                 start_supervised({Clementine, repo: TestRepo, agents: [Judge, Screener]})
      end)

    assert log =~ ~s(agent "boot_judge": claude-haiku-4-5's not-sooner-than date, 2026-10-15)
    assert log =~ ~s(agent "boot_screener": gpt-5 is deprecated)
    # Logged once, when Clementine itself starts, not again by each runtime.
    refute log =~ "offered:"
  end

  test "no network call happens at boot" do
    bypass = Bypass.open()
    test = self()

    Bypass.stub(bypass, :any, :any, fn conn ->
      send(test, {:network, conn.method, conn.request_path})
      Plug.Conn.resp(conn, 500, "")
    end)

    base = "http://localhost:#{bypass.port}"

    TestPlatforms.put(
      anthropic: [api_key: "sk-ant-boot", base_url: base],
      openai: [api_key: "sk-openai-boot", base_url: base <> "/v1"]
    )

    # The real router, as an app runs it, not the test's mock client.
    Application.put_env(:clementine, :llm_client, Clementine.LLM.Router)
    Application.put_env(:clementine, :offer, ["claude-opus-5-5", "gpt-6-astra"])

    capture_log(fn ->
      # Clementine's own start, then the runtime's.
      assert :ok = Clementine.Models.Warnings.log_start()

      assert {:ok, _pid} =
               start_supervised({Clementine, repo: TestRepo, agents: [Judge, Screener]})
    end)

    refute_receive {:network, _method, _path}, 200
  end

  describe "the offer" do
    test "an unknown offered id fails boot, naming the nearest known" do
      Application.put_env(:clementine, :offer, ["claude-sonet-5-5"])

      assert_raise ArgumentError,
                   ~r/offered model \(config :clementine, :offer\): unknown model "claude-sonet-5-5".*Nearest known: "claude-sonnet-5-5"/s,
                   fn -> Clementine.Runs.Config.new!(repo: TestRepo) end
    end

    test "a retired offered id fails boot, naming its replacement" do
      Application.put_env(:clementine, :offer, ["claude-sonnet-4-20250514"])

      assert_raise ArgumentError, ~r/is retired; its replacement is "claude-sonnet-5-5"/, fn ->
        Clementine.Runs.Config.new!(repo: TestRepo)
      end
    end

    test "is read from a function the app names, and kept on the config, with its choices" do
      Application.put_env(:clementine, :offer, {__MODULE__, :offer, []})

      assert %{offer: [{"claude-sonnet-5-5", [max_tokens: 64_000]}, {"gpt-6-astra", []}]} =
               Clementine.Runs.Config.new!(repo: TestRepo)
    end

    test "checks each entry's choices as an agent's" do
      Application.put_env(:clementine, :offer, [{"claude-opus-5-5", thinking: :off}])

      assert_raise ArgumentError,
                   ~r/offered model \(config :clementine, :offer\): "claude-opus-5-5": refuses thinking: :off/,
                   fn -> Clementine.Runs.Config.new!(repo: TestRepo) end
    end

    test "fails boot for an offered model whose platform has no credential" do
      Application.put_env(:clementine, :llm_client, Clementine.LLM.Router)
      TestPlatforms.put(openai: [])
      Application.put_env(:clementine, :offer, ["claude-sonnet-5-5", "gpt-6-astra"])

      assert_raise ArgumentError,
                   ~r/offered model \(config :clementine, :offer\): "gpt-6-astra" goes to :openai/,
                   fn -> Clementine.Runs.Config.new!(repo: TestRepo) end
    end

    test "checks an entry's credential on the platform its choices name" do
      Application.put_env(:clementine, :llm_client, Clementine.LLM.Router)
      Application.put_env(:clementine, :offer, [{"claude-opus-5-5", platform: :bedrock}])

      # Bedrock serves Opus 5.5; the Claude API's key is no credential there.
      TestPlatforms.put(bedrock: [region: "us-east-1"])

      assert_raise ArgumentError,
                   ~r/offered model \(config :clementine, :offer\): "claude-opus-5-5" goes to :bedrock, and config :clementine, :platforms, bedrock: \[api_key: \.\.\.\] is not set/,
                   fn -> Clementine.Runs.Config.new!(repo: TestRepo) end

      # A Bedrock-only app: no Claude API key, and its offer boots.
      TestPlatforms.put(anthropic: [], bedrock: [region: "us-east-1", api_key: "bedrock-key"])

      assert %{offer: [{"claude-opus-5-5", [platform: :bedrock]}]} =
               Clementine.Runs.Config.new!(repo: TestRepo)
    end

    test "refuses an entry whose platform does not serve the model" do
      Application.put_env(:clementine, :offer, [{"gpt-6-astra", platform: :foundry}])

      assert_raise ArgumentError, ~r/"gpt-6-astra": platform: :foundry does not serve it/, fn ->
        Clementine.Runs.Config.new!(repo: TestRepo)
      end
    end

    test "is a list of ids and {id, choices}" do
      for bad <- ["claude-sonnet-5-5", [:sonnet], [{"claude-sonnet-5-5", %{max_tokens: 1}}]] do
        Application.put_env(:clementine, :offer, bad)

        assert_raise ArgumentError,
                     ~r/^config :clementine, :offer is .*; the offer is a list whose entries are model ids or \{id, choices\}/,
                     fn -> Clementine.Models.offer() end
      end

      Application.put_env(:clementine, :offer, {__MODULE__, :not_ids, []})

      assert_raise ArgumentError,
                   ~r/^config :clementine, :offer \{Clementine.Models.BootTest, :not_ids, \[\]\} returned \[:sonnet\]; the offer is a list/,
                   fn -> Clementine.Models.offer() end
    end

    test "names a choice that is no choice" do
      Application.put_env(:clementine, :offer, [{"claude-sonnet-5-5", modle: "x"}])

      assert_raise ArgumentError, ~r/\[:modle\] are not choices; a choice is one of/, fn ->
        Clementine.Models.offer()
      end
    end

    test "says which config a function that raises came from" do
      Application.put_env(:clementine, :offer, {__MODULE__, :raising_offer, []})

      assert_raise ArgumentError,
                   ~r/^config :clementine, :offer: \{Clementine.Models.BootTest, :raising_offer, \[\]\} raised KeyError: key :models not found/,
                   fn -> Clementine.Models.offer() end
    end
  end

  def offer,
    do: [
      {"claude-sonnet-5-5", max_tokens: 64_000},
      "gpt-6-astra",
      {"claude-sonnet-5-5", max_tokens: 64_000}
    ]

  def not_ids, do: [:sonnet]
  def raising_offer, do: Keyword.fetch!([], :models)
end
