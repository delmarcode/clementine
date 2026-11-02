defmodule Clementine.Models.BootTest do
  @moduledoc """
  What `{Clementine, ...}` does with a model's dates when it starts: it
  warns, never fails, and reads no network. Its errors come from the
  sheets and the app's config, the offer's included.
  """

  use Clementine.RunsCase

  import ExUnit.CaptureLog

  @moduletag runtime: false

  @env [:models, :offer, :anthropic_base_url, :openai_base_url, :llm_client]

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
      ],
      # based_on: leaves the base's dates behind, so this one never warns.
      "claude-sonnet-quiet" => [based_on: "claude-sonnet-5-5"]
    })

    Application.put_env(:clementine, :offer, ["claude-sonnet-legacy", "claude-sonnet-quiet"])

    log =
      capture_log(fn ->
        assert {:ok, _pid} =
                 start_supervised({Clementine, repo: TestRepo, agents: [Judge, Screener]})
      end)

    assert log =~ ~s(agent "boot_judge": claude-haiku-4-5's not-sooner-than date, 2026-10-15)
    assert log =~ ~s(agent "boot_screener": gpt-5 is deprecated)
    assert log =~ "offered: claude-sonnet-legacy's retirement date, 2020-01-01, has been reached"
    refute log =~ "offered: claude-sonnet-quiet"
  end

  test "no network call happens at boot" do
    bypass = Bypass.open()
    test = self()

    Bypass.stub(bypass, :any, :any, fn conn ->
      send(test, {:network, conn.method, conn.request_path})
      Plug.Conn.resp(conn, 500, "")
    end)

    base = "http://localhost:#{bypass.port}"
    Application.put_env(:clementine, :anthropic_base_url, base <> "/v1/messages")
    Application.put_env(:clementine, :openai_base_url, base <> "/v1/responses")
    # The real router, as an app runs it, not the test's mock client.
    Application.put_env(:clementine, :llm_client, Clementine.LLM.Router)
    Application.put_env(:clementine, :offer, ["claude-opus-5-5", "gpt-6-astra"])

    capture_log(fn ->
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

    test "is read from a function the app names, and kept on the config" do
      Application.put_env(:clementine, :offer, {__MODULE__, :offered, []})

      assert %{offered: ["claude-sonnet-5-5", "gpt-6-astra"]} =
               Clementine.Runs.Config.new!(repo: TestRepo)
    end

    test "is a list of ids" do
      Application.put_env(:clementine, :offer, "claude-sonnet-5-5")

      assert_raise ArgumentError, ~r/the offer is a list of model ids/, fn ->
        Clementine.Models.offered()
      end

      Application.put_env(:clementine, :offer, {__MODULE__, :not_ids, []})

      assert_raise ArgumentError, ~r/returned \[:sonnet\]; the offer is a list/, fn ->
        Clementine.Models.offered()
      end
    end
  end

  def offered, do: ["claude-sonnet-5-5", "gpt-6-astra", "claude-sonnet-5-5"]
  def not_ids, do: [:sonnet]
end
