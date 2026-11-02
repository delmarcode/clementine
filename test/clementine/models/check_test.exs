defmodule Clementine.Models.CheckTest do
  @moduledoc """
  `mix clementine.models --check` against recorded Models API responses
  (`test/fixtures/models_api/`), served by Bypass; no test calls a
  vendor.

  The responses are in the shape each vendor's reference documents, read
  2026-11-01: Anthropic's `GET /v1/models`
  (https://platform.claude.com/docs/en/api/models/list), paged with
  `has_more` and `last_id`, and OpenAI's `GET /v1/models`
  (https://developers.openai.com/api/reference/resources/models/methods/list).
  They were built from those references and the shipped sheets, not
  captured from a live call, which this run does not make. Each entry
  agrees with its sheet except these, placed on purpose:

  - Anthropic: `claude-sonnet-6` is an id the sheets lack;
    `claude-sonnet-5` is deprecated (2026-11-15) and retires 2027-02-15;
    `claude-haiku-5-5` takes `between_tools` and caps output at 64,000.
  - OpenAI: `gpt-6.2-sol` is new since the sheets were read;
    `gpt-6.1-terra` has a shutdown date and `gpt-5.4-nano` a later one;
    `text-embedding-3-large` (older) and an organization's fine-tune
    are ids the sheets lack that are not findings.
  """

  use ExUnit.Case, async: false

  alias Clementine.Models.Check
  alias Clementine.TestPlatforms

  @fixtures Path.expand("../../fixtures/models_api", __DIR__)
  setup do
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    TestPlatforms.put(
      anthropic: [api_key: "sk-ant-recorded", base_url: base],
      openai: [api_key: "sk-openai-recorded", base_url: base <> "/v1"]
    )

    {:ok, bypass: bypass}
  end

  describe "Anthropic's Models API" do
    test "flags a lifecycle change and an unknown id, and nothing where the sheets agree",
         %{bypass: bypass} do
      serve_anthropic(bypass)

      assert %{vendor: :anthropic, status: :checked, listed: 6, findings: findings} =
               Check.check(:anthropic)

      assert %{id: "claude-sonnet-6", kind: :unknown, api: %{lifecycle: "active", line: "sonnet"}} =
               Enum.find(findings, &(&1.id == "claude-sonnet-6"))

      assert by_model(findings, "claude-sonnet-5") == [
               {:lifecycle, "active", "deprecated"},
               {:deprecated_at, nil, ~D[2026-11-15]},
               {:retires_at, nil, ~D[2027-02-15]}
             ]

      assert by_model(findings, "claude-haiku-5-5") == [
               {:max_output, 128_000, 64_000},
               {:thinking, [:adaptive, :off], [:adaptive, :between_tools, :off]}
             ]

      # Entries that agree with their sheets, a retired one included.
      for id <- ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-4-1-20250805"] do
        assert by_model(findings, id) == []
      end
    end

    test "asks for retired models too, pages with after_id, and sends the key as the clients do",
         %{bypass: bypass} do
      test = self()

      Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test, {:request, conn.query_string, Map.new(conn.req_headers)})
        page = if conn.query_params["after_id"], do: 2, else: 1
        respond(conn, "anthropic_page_#{page}.json")
      end)

      assert %{status: :checked, listed: 6} = Check.check(:anthropic)

      assert_received {:request, first, headers}
      assert URI.decode_query(first) == %{"limit" => "1000", "lifecycle[]" => "retired"}
      assert first =~ "lifecycle%5B%5D=active&lifecycle%5B%5D=deprecated&lifecycle%5B%5D=retired"
      assert headers["x-api-key"] == "sk-ant-recorded"
      assert headers["anthropic-version"] == "2023-06-01"

      assert_received {:request, second, _headers}
      assert URI.decode_query(second)["after_id"] == "claude-sonnet-5-5"
    end

    test "fails on an HTTP error with the vendor's message, never the key", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          401,
          ~s({"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}})
        )
      end)

      assert %{status: :failed, reason: reason, findings: []} = Check.check(:anthropic)
      assert reason =~ "answered 401: invalid x-api-key"
      refute reason =~ "sk-ant-recorded"
    end

    test "trims a key's trailing newline before it goes", %{bypass: bypass} do
      # A Kubernetes secret made with --from-file keeps the file's newline.
      put_key(bypass, "sk-ant-recorded\n")
      test = self()

      Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
        send(test, {:key, Plug.Conn.get_req_header(conn, "x-api-key")})
        conn = Plug.Conn.fetch_query_params(conn)
        page = if conn.query_params["after_id"], do: 2, else: 1
        respond(conn, "anthropic_page_#{page}.json")
      end)

      assert %{status: :checked} = Check.check(:anthropic)
      assert_received {:key, ["sk-ant-recorded"]}
    end

    test "refuses a key with a non-printable character, never printing it", %{bypass: bypass} do
      for key <- ["sk-ant-rec\norded", "sk-ant-rec\0orded", "sk-ant-récorded"] do
        put_key(bypass, key)

        assert %{status: :failed, reason: reason} = Check.check(:anthropic)

        assert reason ==
                 "config :clementine, :platforms, anthropic: [api_key: ...]: the key has " <>
                   "non-printable characters"
      end
    end

    test "reports a transport error by its reason's name", %{bypass: bypass} do
      Bypass.down(bypass)

      assert %{status: :failed, reason: reason} = Check.check(:anthropic)
      assert reason =~ ~r{^http://localhost:\d+/v1/models: econnrefused$}
    end

    test "scrubs the key from a vendor's message that echoes it", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          401,
          ~s({"type":"error","error":{"type":"authentication_error","message":"unknown key sk-ant-recorded"}})
        )
      end)

      assert %{status: :failed, reason: reason} = Check.check(:anthropic)
      assert reason =~ "answered 401: unknown key **redacted**"
    end

    test "names a credential function that fails by Mod.fun/arity, never its args or term",
         %{bypass: bypass} do
      secret = "sk-ant-mfa-secret"
      setting = "config :clementine, :platforms, anthropic: [api_key: ...] "

      for {credential, why} <- [
            {{__MODULE__, :raising_key, [secret]},
             "Clementine.Models.CheckTest.raising_key/1 raised RuntimeError"},
            {{Clementine.NoSuchVault, :key, [secret]},
             "Clementine.NoSuchVault.key/1 raised UndefinedFunctionError"},
            {{__MODULE__, :throwing_key, [secret]},
             "Clementine.Models.CheckTest.throwing_key/1 threw"},
            {{__MODULE__, :exiting_key, [secret]},
             "Clementine.Models.CheckTest.exiting_key/1 exited"},
            # Shapes a request refuses, refused here alike.
            {{__MODULE__, :ok_tuple_key, [secret]},
             "Clementine.Models.CheckTest.ok_tuple_key/1 returned an {:ok, value} tuple"},
            {{__MODULE__, :list_key, [secret]},
             "Clementine.Models.CheckTest.list_key/1 returned a list"}
          ] do
        put_key(bypass, credential)

        assert %{status: :failed, reason: reason} = Check.check(:anthropic)
        assert reason =~ setting <> why, reason
        refute reason =~ "mfa-secret"
      end
    end

    test "skips a platform with no api_key, naming those configured; fails one that resolves " <>
           "to nothing",
         %{bypass: bypass} do
      TestPlatforms.put(
        anthropic: [base_url: "http://localhost:#{bypass.port}"],
        bedrock: [region: "us-east-1", api_key: "bedrock-key"]
      )

      assert %{status: :skipped, reason: reason} = Check.check(:anthropic)

      assert reason =~
               "config :clementine, :platforms, anthropic: [api_key: ...] is not set. Bedrock, " <>
                 "Vertex, and Foundry serve Claude with no Models API --check reads (platforms " <>
                 "configured: ["

      assert reason =~ ":bedrock"

      # Configured, but the variable is unset where --check runs: a failure.
      put_key(bypass, {:system, "CLEMENTINE_UNSET_VAR"})
      assert %{status: :failed, reason: reason} = Check.check(:anthropic)

      assert reason ==
               "config :clementine, :platforms, anthropic: [api_key: ...] resolved to no " <>
                 "value: the environment variable CLEMENTINE_UNSET_VAR is unset or empty"

      put_key(bypass, " \n")

      assert %{
               status: :failed,
               reason: "config :clementine, :platforms, anthropic: [api_key: ...] is blank"
             } =
               Check.check(:anthropic)

      System.put_env("CLEMENTINE_CHECK_TEST_KEY", "sk-ant-recorded")
      on_exit(fn -> System.delete_env("CLEMENTINE_CHECK_TEST_KEY") end)
      put_key(bypass, {:system, "CLEMENTINE_CHECK_TEST_KEY"})
      serve_anthropic(bypass)
      assert %{status: :checked} = Check.check(:anthropic)
    end

    test "follows no redirect, so the key never reaches another host", %{bypass: bypass} do
      elsewhere = Bypass.open()
      test = self()

      Bypass.stub(elsewhere, :any, :any, fn conn ->
        send(test, {:elsewhere, Plug.Conn.get_req_header(conn, "x-api-key")})
        Plug.Conn.resp(conn, 200, "{}")
      end)

      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://localhost:#{elsewhere.port}/v1/models")
        |> Plug.Conn.resp(302, "")
      end)

      assert %{status: :failed, reason: reason} = Check.check(:anthropic)
      assert reason =~ "/v1/models answered 302"
      refute_receive {:elsewhere, _key}, 200
    end

    test "fails on a base_url with no scheme, as boot does" do
      TestPlatforms.put(anthropic: [api_key: "sk-ant-recorded", base_url: "api.anthropic.com"])

      assert %{status: :failed, reason: reason} = Check.check(:anthropic)
      assert reason =~ "anthropic: base_url: needs an http or https scheme and a host"

      assert_raise ArgumentError, ~r/base_url: needs an http or https scheme/, fn ->
        Clementine.Platform.validate_config!()
      end
    end

    test "fails on a platform entry that does not build, naming it" do
      TestPlatforms.put(anthropic: [api_key: 42])

      assert %{status: :failed, reason: reason} = Check.check(:anthropic)
      assert reason =~ "anthropic"
    end
  end

  describe "OpenAI's Models API" do
    test "flags shutdown dates and a new id; older and non-vendor ids are not findings",
         %{bypass: bypass} do
      test = self()

      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        send(test, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
        respond(conn, "openai_models.json")
      end)

      assert %{vendor: :openai, status: :checked, listed: 7} = result = Check.check(:openai)
      assert_received {:authorization, ["Bearer sk-openai-recorded"]}

      assert [%{id: "gpt-6.2-sol", kind: :unknown, api: %{created: ~D[2026-11-18]}}] =
               Enum.filter(result.findings, &(&1.kind == :unknown))

      assert by_model(result.findings, "gpt-6.1-terra") == [{:shutdown_date, nil, ~D[2027-10-26]}]

      assert by_model(result.findings, "gpt-5.4-nano") == [
               {:shutdown_date, ~D[2027-04-01], ~D[2027-05-01]}
             ]

      assert by_model(result.findings, "gpt-5") == []
      assert by_model(result.findings, "gpt-6.1-sol") == []

      assert Enum.map(result.unshipped, & &1.id) == [
               "text-embedding-3-large",
               "ft:gpt-6.1-terra:acme::B1x2y3z4"
             ]
    end
  end

  test "a retired id the sheets lack is counted, not flagged; an active one is flagged" do
    # Ids no sheet ships, as the API would list an old snapshot.
    retired = %{"id" => "claude-instant-0.9", "lifecycle" => "retired", "line" => nil}
    active = %{"id" => "claude-sonnet-6", "lifecycle" => "active", "line" => "sonnet"}

    assert %{
             findings: [%{id: "claude-sonnet-6", kind: :unknown}],
             unshipped: [%{id: "claude-instant-0.9", lifecycle: "retired"}]
           } = Check.compare(:anthropic, [retired, active])
  end

  test "a capability the API no longer states as supported is a difference" do
    entry =
      "anthropic_page_1.json"
      |> fixture_entry("claude-opus-5-5")
      |> put_in(["capabilities", "thinking", "types", "adaptive", "supported"], false)
      |> put_in(["capabilities", "effort", "max", "supported"], false)
      |> put_in(["capabilities", "structured_outputs", "supported"], false)

    assert %{findings: findings} = Check.compare(:anthropic, [entry])

    assert by_model(findings, "claude-opus-5-5") == [
             {:thinking, [:adaptive], []},
             {:effort, [:low, :medium, :high, :xhigh, :max], [:low, :medium, :high, :xhigh]},
             {:structured_outputs, true, false}
           ]
  end

  test "an app's own read date never moves OpenAI's cutoff for new ids" do
    models = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, models) end)

    Application.put_env(:clementine, :models, %{"gpt-6.1-sol" => [read: ~D[2026-12-31]]})

    new = %{"id" => "gpt-6.2-sol", "created" => 1_794_960_000, "owned_by" => "openai"}
    assert DateTime.to_date(DateTime.from_unix!(new["created"])) == ~D[2026-11-18]

    assert %{findings: [%{id: "gpt-6.2-sol", kind: :unknown}], unshipped: []} =
             Check.compare(:openai, [new])
  end

  test "the Models API is under each platform's base_url" do
    TestPlatforms.put(
      anthropic: [api_key: "k", base_url: "https://proxy.example/anthropic/"],
      openai: [api_key: "k", base_url: "https://proxy.example/openai/v1"]
    )

    assert Check.url(:anthropic) == "https://proxy.example/anthropic/v1/models"
    assert Check.url(:openai) == "https://proxy.example/openai/v1/models"

    TestPlatforms.put(anthropic: [api_key: "k"], openai: [api_key: "k"])
    assert Check.url(:anthropic) == "https://api.anthropic.com/v1/models"
    assert Check.url(:openai) == "https://api.openai.com/v1/models"
  end

  test "compares a model the app declares, by its declared facts" do
    models = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, models) end)

    Application.put_env(:clementine, :models, %{
      "claude-sonnet-6" => [based_on: "claude-sonnet-5-5", line: :sonnet, context: 2_000_000]
    })

    entry = fixture_entry("anthropic_page_1.json", "claude-sonnet-6")

    assert %{
             findings: [
               %{id: "claude-sonnet-6", kind: :context, sheet: 2_000_000, api: 1_000_000}
             ]
           } =
             Check.compare(:anthropic, [entry])
  end

  def raising_key(secret), do: raise("vault said #{secret} is sealed")
  def throwing_key(secret), do: throw({:vault, secret})
  def exiting_key(secret), do: exit({:vault, secret})
  def ok_tuple_key(secret), do: {:ok, secret}
  def list_key(secret), do: [secret]

  defp put_key(bypass, key) do
    TestPlatforms.put(anthropic: [api_key: key, base_url: "http://localhost:#{bypass.port}"])
  end

  defp serve_anthropic(bypass) do
    Bypass.expect(bypass, "GET", "/v1/models", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      page = if conn.query_params["after_id"] == "claude-sonnet-5-5", do: 2, else: 1
      respond(conn, "anthropic_page_#{page}.json")
    end)
  end

  defp respond(conn, fixture) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, File.read!(Path.join(@fixtures, fixture)))
  end

  defp fixture_entry(fixture, id) do
    @fixtures
    |> Path.join(fixture)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("data")
    |> Enum.find(&(&1["id"] == id))
  end

  defp by_model(findings, id) do
    for %{id: ^id, kind: kind, sheet: sheet, api: api} <- findings, do: {kind, sheet, api}
  end
end
