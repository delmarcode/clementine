defmodule Clementine.LLM.AnthropicTest do
  use ExUnit.Case, async: false

  alias Clementine.LLM.Anthropic
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}
  alias Clementine.LLM.Response

  setup do
    bypass = Bypass.open()

    prev_url = Application.get_env(:clementine, :anthropic_base_url)
    prev_key = Application.get_env(:clementine, :anthropic_api_key)
    prev_models = Application.get_env(:clementine, :models)

    Application.put_env(
      :clementine,
      :anthropic_base_url,
      "http://localhost:#{bypass.port}/v1/messages"
    )

    Application.put_env(:clementine, :anthropic_api_key, "test-anthropic-key")

    Application.put_env(:clementine, :models,
      claude_test: [provider: :anthropic, id: "claude-sonnet-5", defaults: [max_tokens: 1024]],
      claude_reasoning: [
        provider: :anthropic,
        id: "claude-sonnet-5",
        reasoning: [thinking: :adaptive, effort: :high]
      ]
    )

    on_exit(fn ->
      restore_env(:anthropic_base_url, prev_url)
      restore_env(:anthropic_api_key, prev_key)
      restore_env(:models, prev_models)
    end)

    %{bypass: bypass}
  end

  describe "module structure" do
    test "exports call functions" do
      Code.ensure_loaded!(Clementine.LLM.Anthropic)
      funcs = Clementine.LLM.Anthropic.__info__(:functions)
      assert {:call, 4} in funcs
      assert {:call, 5} in funcs
    end

    test "exports stream functions" do
      Code.ensure_loaded!(Clementine.LLM.Anthropic)
      funcs = Clementine.LLM.Anthropic.__info__(:functions)
      assert {:stream, 4} in funcs
      assert {:stream, 5} in funcs
    end
  end

  describe "reasoning request fields" do
    test "call/5 omits reasoning fields when unconfigured", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["model"] == "claude-sonnet-5"
        refute Map.has_key?(request, "thinking")
        refute Map.has_key?(request, "output_config")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("No reasoning"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "No reasoning"}]}} =
               Anthropic.call(:claude_test, "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 includes configured reasoning", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["thinking"] == %{"type" => "adaptive"}
        assert request["output_config"] == %{"effort" => "high"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Configured reasoning"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Configured reasoning"}]}} =
               Anthropic.call(:claude_reasoning, "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 lets request opts override configured reasoning", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["thinking"] == %{"type" => "enabled", "budget_tokens" => 2048}
        refute Map.has_key?(request, "output_config")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Overridden reasoning"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Overridden reasoning"}]}} =
               Anthropic.call(:claude_reasoning, "system", [UserMessage.new("Hi")], [],
                 reasoning: [budget_tokens: 2048]
               )
    end

    test "call/5 rejects invalid Anthropic reasoning opts" do
      assert_raise ArgumentError, ~r/unsupported Anthropic reasoning effort/, fn ->
        Anthropic.call(:claude_test, "system", [UserMessage.new("Hi")], [], reasoning: :ultra)
      end
    end
  end

  describe "thinking blocks" do
    test "call/5 parses thinking blocks and skips unknown block types", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        response =
          Jason.encode!(%{
            "content" => [
              %{"type" => "thinking", "thinking" => "Let me reason.", "signature" => "sig123"},
              %{"type" => "redacted_thinking", "data" => "opaque123"},
              %{"type" => "some_future_block", "payload" => "ignored"},
              %{"type" => "text", "text" => "Answer."}
            ],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      assert {:ok, %Response{} = response} =
               Anthropic.call(:claude_reasoning, "system", [UserMessage.new("Hi")], [])

      assert [
               %Content.Thinking{thinking: "Let me reason.", signature: "sig123"},
               %Content.RedactedThinking{data: "opaque123"},
               %Content.Text{text: "Answer."}
             ] = response.content
    end

    test "call/5 replays thinking blocks in assistant history", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert [
                 %{"role" => "user", "content" => "Hi"},
                 %{
                   "role" => "assistant",
                   "content" => [
                     %{
                       "type" => "thinking",
                       "thinking" => "Let me reason.",
                       "signature" => "sig123"
                     },
                     %{"type" => "redacted_thinking", "data" => "opaque123"},
                     %{"type" => "tool_use", "id" => "toolu_1", "name" => "echo", "input" => %{}}
                   ]
                 },
                 %{"role" => "user", "content" => [%{"type" => "tool_result"} = _result]}
               ] = request["messages"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Done"))
      end)

      messages = [
        UserMessage.new("Hi"),
        %AssistantMessage{
          content: [
            Content.thinking("Let me reason.", "sig123"),
            Content.redacted_thinking("opaque123"),
            Content.tool_use("toolu_1", "echo", %{})
          ]
        },
        %ToolResultMessage{content: [Content.tool_result("toolu_1", "hi")]}
      ]

      assert {:ok, %Response{}} = Anthropic.call(:claude_test, "system", messages, [])
    end
  end

  describe "streaming errors" do
    test "stream/5 surfaces the provider error body on a non-200 response", %{bypass: bypass} do
      error_body =
        ~s({"type":"error","error":{"type":"not_found_error","message":"model: claude-sonnet-4-20250514"}})

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, error_body)
      end)

      events =
        Anthropic.stream(:claude_test, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()

      assert [{:error, {:api_error, 404, ^error_body}}] = events
    end
  end

  defp text_response(text) do
    Jason.encode!(%{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 12, "output_tokens" => 4}
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:clementine, key)
  defp restore_env(key, value), do: Application.put_env(:clementine, key, value)
end
