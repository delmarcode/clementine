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

  @fixtures Path.expand("../../fixtures/models_api", __DIR__)
  @keys [:anthropic_api_key, :anthropic_base_url, :openai_api_key, :openai_base_url]

  setup do
    saved = Map.new(@keys, &{&1, Application.get_env(:clementine, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:clementine, key)
        {key, value} -> Application.put_env(:clementine, key, value)
      end)
    end)

    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"
    Application.put_env(:clementine, :anthropic_base_url, base <> "/v1/messages")
    Application.put_env(:clementine, :openai_base_url, base <> "/v1/responses")
    Application.put_env(:clementine, :anthropic_api_key, "sk-ant-recorded")
    Application.put_env(:clementine, :openai_api_key, "sk-openai-recorded")

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

    test "is skipped without a configured key" do
      Application.delete_env(:clementine, :anthropic_api_key)

      assert %{status: :skipped, reason: reason} = Check.check(:anthropic)
      assert reason =~ "anthropic_api_key"

      Application.put_env(:clementine, :anthropic_api_key, {:system, "CLEMENTINE_UNSET_VAR"})
      assert %{status: :skipped} = Check.check(:anthropic)
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

  test "an app's own read date never moves OpenAI's cutoff for new ids" do
    models = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, models) end)

    Application.put_env(:clementine, :models, %{"gpt-6.1-sol" => [read: ~D[2026-12-31]]})

    new = %{"id" => "gpt-6.2-sol", "created" => 1_794_960_000, "owned_by" => "openai"}
    assert DateTime.to_date(DateTime.from_unix!(new["created"])) == ~D[2026-11-18]

    assert %{findings: [%{id: "gpt-6.2-sol", kind: :unknown}], unshipped: []} =
             Check.compare(:openai, [new])
  end

  test "the Models API sits beside the configured endpoint" do
    Application.put_env(
      :clementine,
      :anthropic_base_url,
      "https://proxy.example/anthropic/v1/messages"
    )

    assert Check.url(:anthropic) == "https://proxy.example/anthropic/v1/models"

    Application.delete_env(:clementine, :anthropic_base_url)
    Application.delete_env(:clementine, :openai_base_url)
    assert Check.url(:anthropic) == "https://api.anthropic.com/v1/models"
    assert Check.url(:openai) == "https://api.openai.com/v1/models"
  end

  test "compares a model the app declares, by its declared facts" do
    models = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, models) end)

    Application.put_env(:clementine, :models, %{
      "claude-sonnet-6" => [based_on: "claude-sonnet-5-5", line: :sonnet, context: 2_000_000]
    })

    entry =
      @fixtures
      |> Path.join("anthropic_page_1.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("data")
      |> Enum.find(&(&1["id"] == "claude-sonnet-6"))

    assert %{
             findings: [
               %{id: "claude-sonnet-6", kind: :context, sheet: 2_000_000, api: 1_000_000}
             ]
           } =
             Check.compare(:anthropic, [entry])
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

  defp by_model(findings, id) do
    for %{id: ^id, kind: kind, sheet: sheet, api: api} <- findings, do: {kind, sheet, api}
  end
end
