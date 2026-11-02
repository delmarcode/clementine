defmodule Clementine.LLM.PlatformsTest do
  # The request each platform documents, read 2026-11-01:
  # platform.claude.com's "Claude in Amazon Bedrock" and "Claude in
  # Microsoft Foundry" pages (endpoint, credential header,
  # anthropic-version, the model field), and AWS's "API keys" page (the
  # Bedrock bearer token). And an agent moving between platforms with
  # one line.
  use ExUnit.Case, async: false

  alias Clementine.LLM.{Anthropic, ChatCompletions}
  alias Clementine.LLM.Message.{SystemMessage, UserMessage}
  alias Clementine.Test.Fixtures

  defmodule OnAnthropic do
    use Clementine.Agent,
      key: "platforms_screener",
      model: "claude-sonnet-5-5",
      instructions: "Screen the message."
  end

  # OnAnthropic with one line added.
  defmodule OnBedrock do
    use Clementine.Agent,
      key: "platforms_screener",
      model: "claude-sonnet-5-5",
      platform: :bedrock,
      instructions: "Screen the message."
  end

  setup do
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"

    previous =
      Enum.map([:models, :retry, :llm_client], &{&1, Application.get_env(:clementine, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:clementine, key)
        {key, value} -> Application.put_env(:clementine, key, value)
      end)
    end)

    Application.put_env(:clementine, :retry, max_attempts: 1, base_delay: 0, max_delay: 0)

    Clementine.TestPlatforms.put(
      anthropic: [api_key: "test-anthropic-key", base_url: base],
      # The Mantle host; Messages and Chat Completions are paths on it.
      bedrock: [api_key: {__MODULE__, :bedrock_token, []}, base_url: base],
      foundry: [
        api_key: "test-azure-key",
        base_url: base <> "/anthropic",
        deployments: %{"claude-sonnet-5-5" => "sonnet-chat"}
      ]
    )

    %{bypass: bypass}
  end

  # A short-term Amazon Bedrock API key lasts 12 hours at most, so an app
  # gives an {m, f, a} that mints a fresh one; it is called per request.
  def bedrock_token, do: "bedrock-short-term-token"

  defp capture(bypass, path) do
    test = self()

    Bypass.expect_once(bypass, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.req_headers, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, Fixtures.sse_text_stream("ok"))
    end)
  end

  defp header(headers, name) do
    for {^name, value} <- headers, do: value
  end

  defp stream_claude(opts, messages \\ [UserMessage.new("Hi")]) do
    "claude-sonnet-5-5" |> Anthropic.stream("Be brief.", messages, [], opts) |> Stream.run()
    assert_received {:request, headers, body}
    {headers, body}
  end

  describe "Claude on each platform" do
    test ":anthropic: x-api-key, the version header, and the vendor id", %{bypass: bypass} do
      capture(bypass, "/v1/messages")
      {headers, body} = stream_claude([])

      assert header(headers, "x-api-key") == ["test-anthropic-key"]
      assert header(headers, "anthropic-version") == ["2023-06-01"]
      assert header(headers, "authorization") == []
      assert body["model"] == "claude-sonnet-5-5"
      assert body["stream"] == true
    end

    test ":bedrock: the Mantle Messages path, the bearer token in x-api-key, anthropic.<id>",
         %{bypass: bypass} do
      capture(bypass, "/anthropic/v1/messages")
      {headers, body} = stream_claude(platform: :bedrock)

      assert header(headers, "x-api-key") == ["bedrock-short-term-token"]
      assert header(headers, "anthropic-version") == ["2023-06-01"]
      assert header(headers, "content-type") == ["application/json"]
      assert header(headers, "authorization") == []
      assert body["model"] == "anthropic.claude-sonnet-5-5"
      # The same body as the Claude API's: Bedrock's Messages endpoint
      # takes the first-party shape.
      assert body["max_tokens"] == 16_000
      assert body["messages"] == [%{"role" => "user", "content" => "Hi"}]
    end

    test ":foundry: api-key, the version header, and the deployment name", %{bypass: bypass} do
      capture(bypass, "/anthropic/v1/messages")
      {headers, body} = stream_claude(platform: :foundry)

      assert header(headers, "api-key") == ["test-azure-key"]
      assert header(headers, "x-api-key") == []
      assert header(headers, "anthropic-version") == ["2023-06-01"]
      assert body["model"] == "sonnet-chat"

      # A model with no deployment mapped goes by its own id, Foundry's
      # default deployment name.
      capture(bypass, "/anthropic/v1/messages")

      "claude-opus-5-5"
      |> Anthropic.stream("Be brief.", [UserMessage.new("Hi")], [], platform: :foundry)
      |> Stream.run()

      assert_received {:request, _headers, %{"model" => "claude-opus-5-5"}}
    end

    test ":foundry with a Microsoft Entra ID token sends it as a bearer", %{bypass: bypass} do
      Clementine.TestPlatforms.put(
        foundry: [
          access_token: "entra-token",
          base_url: "http://localhost:#{bypass.port}/anthropic"
        ]
      )

      capture(bypass, "/anthropic/v1/messages")
      {headers, body} = stream_claude(platform: :foundry)

      assert header(headers, "authorization") == ["Bearer entra-token"]
      assert header(headers, "api-key") == []
      assert body["model"] == "claude-sonnet-5-5"
    end

    test "call/5 takes the platform too", %{bypass: bypass} do
      test = self()

      Bypass.expect_once(bypass, "POST", "/anthropic/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(Fixtures.anthropic_text_response("ok")))
      end)

      assert {:ok, _response} =
               Anthropic.call("claude-sonnet-5-5", "Be brief.", [UserMessage.new("Hi")], [],
                 platform: :bedrock
               )

      assert_received {:request, %{"model" => "anthropic.claude-sonnet-5-5"}}
    end

    test "Foundry withholds what it lacks: a system message folds into the system prompt",
         %{bypass: bypass} do
      messages = [UserMessage.new("Hi"), SystemMessage.new("Answer in French.")]

      capture(bypass, "/v1/messages")
      {_headers, anthropic} = stream_claude([], messages)

      assert List.last(anthropic["messages"])["role"] == "system"

      capture(bypass, "/anthropic/v1/messages")
      {_headers, foundry} = stream_claude([platform: :foundry], messages)

      assert foundry["messages"] == [%{"role" => "user", "content" => "Hi"}]
      assert [%{"text" => "Be brief.\n\nAnswer in French."}] = foundry["system"]
    end
  end

  describe "an open model on Bedrock" do
    test "goes to Chat Completions on the same host, the same key as a bearer", %{bypass: bypass} do
      Application.put_env(:clementine, :models, %{
        "openai.gpt-oss-120b-1:0" => [
          vendor: :openai,
          context: 128_000,
          max_output: 32_000,
          platforms: [bedrock: []]
        ]
      })

      test = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, conn.req_headers, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "choices" => [
              %{
                "message" => %{"role" => "assistant", "content" => "ok"},
                "finish_reason" => "stop"
              }
            ]
          })
        )
      end)

      assert {:ok, _response} =
               ChatCompletions.call("openai.gpt-oss-120b-1:0", "sys", [UserMessage.new("Hi")], [])

      assert_received {:request, headers, body}
      assert header(headers, "authorization") == ["Bearer bedrock-short-term-token"]
      assert header(headers, "x-api-key") == []
      assert body["model"] == "openai.gpt-oss-120b-1:0"
    end
  end

  describe "an agent moves from :anthropic to :bedrock with one line" do
    setup do
      Application.put_env(:clementine, :llm_client, Clementine.LLM.Router)
      test = self()
      handler = "platforms-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:clementine, :llm, :stop],
        &__MODULE__.forward/4,
        test
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "its requests, its labels, and its cost go where it runs", %{bypass: bypass} do
      capture(bypass, "/v1/messages")
      assert {:ok, %{output: "ok"}} = Clementine.run(OnAnthropic, "Hi")
      assert_received {:request, _headers, %{"model" => "claude-sonnet-5-5"}}
      assert_received {:llm_stop, %{provider: :anthropic, platform: :anthropic}}

      capture(bypass, "/anthropic/v1/messages")
      assert {:ok, %{output: "ok", usage: usage}} = Clementine.run(OnBedrock, "Hi")
      assert_received {:request, headers, %{"model" => "anthropic.claude-sonnet-5-5"}}
      assert header(headers, "x-api-key") == ["bedrock-short-term-token"]
      assert_received {:llm_stop, %{provider: :anthropic, platform: :bedrock}}

      assert %Clementine.Cost{currency: "USD"} =
               Clementine.Cost.of(usage, "claude-sonnet-5-5", platform: :bedrock)
    end

    test "boot checks the platform it names, and an eval's model keeps it" do
      config = Clementine.Runs.Config.new!(repo: Clementine.TestRepo, agents: [OnBedrock])
      assert %{agents: %{"platforms_screener" => OnBedrock}} = config

      Clementine.TestPlatforms.put(bedrock: [base_url: "http://localhost:1"])

      error =
        assert_raise ArgumentError, fn ->
          Clementine.Runs.Config.new!(repo: Clementine.TestRepo, agents: [OnBedrock])
        end

      assert error.message =~ "goes to :bedrock"
      assert error.message =~ "bedrock: [api_key: ...] is not set"

      # An agent/1 that picks another model for a run keeps use's
      # platform: where the app's credentials are.
      agent =
        Clementine.Agent.declared!(OnBedrock, Clementine.Agent.new(model: "claude-opus-5-5"))

      assert agent.platform == :bedrock
    end
  end

  def forward(_event, _measurements, metadata, test), do: send(test, {:llm_stop, metadata})
end
