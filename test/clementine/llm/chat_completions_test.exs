defmodule Clementine.LLM.ChatCompletionsTest do
  use ExUnit.Case, async: false

  alias Clementine.LLM.ChatCompletions
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}
  alias Clementine.LLM.Response

  defmodule TokenSource do
    def fetch, do: "vertex-token-123"
  end

  @env_keys [
    :models,
    :retry,
    :openrouter_base_url,
    :openrouter_api_key,
    :bedrock_base_url,
    :bedrock_api_key,
    :bedrock_region,
    :vertex_base_url,
    :vertex_access_token,
    :vertex_project,
    :vertex_region,
    :openai_compatible_base_url,
    :openai_compatible_api_key
  ]

  setup do
    bypass = Bypass.open()

    previous = Enum.map(@env_keys, fn key -> {key, Application.get_env(:clementine, key)} end)

    Enum.each(@env_keys, fn key -> Application.delete_env(:clementine, key) end)

    Application.put_env(:clementine, :retry, max_attempts: 3, base_delay: 0, max_delay: 0)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:clementine, key)
        {key, value} -> Application.put_env(:clementine, key, value)
      end)
    end)

    %{bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp text_response(text) do
    Jason.encode!(%{
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4}
    })
  end

  describe ":openrouter" do
    setup %{base_url: base_url} do
      Application.put_env(:clementine, :openrouter_base_url, base_url <> "/api/v1")
      Application.put_env(:clementine, :openrouter_api_key, "test-openrouter-key")

      Application.put_env(:clementine, :models,
        deepseek: [provider: :openrouter, id: "deepseek/deepseek-v3.2"],
        deepseek_reasoning: [
          provider: :openrouter,
          id: "deepseek/deepseek-v3.2",
          reasoning: [effort: :high, max_tokens: 2000]
        ]
      )

      :ok
    end

    test "call/5 sends a chat completions request", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert Plug.Conn.get_req_header(conn, "authorization") ==
                 ["Bearer test-openrouter-key"]

        assert request["model"] == "deepseek/deepseek-v3.2"
        assert request["max_tokens"] == 8192

        assert request["messages"] == [
                 %{"role" => "system", "content" => "system"},
                 %{"role" => "user", "content" => "Hi"}
               ]

        refute Map.has_key?(request, "reasoning")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Hello from OpenRouter"))
      end)

      assert {:ok, %Response{} = response} =
               ChatCompletions.call(:deepseek, "system", [UserMessage.new("Hi")], [])

      assert [%Content.Text{text: "Hello from OpenRouter"}] = response.content
      assert response.stop_reason == "end_turn"
      assert response.usage["completion_tokens"] == 4
    end

    test "call/5 includes configured reasoning", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["reasoning"] == %{"effort" => "high", "max_tokens" => 2000}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Configured reasoning"))
      end)

      assert {:ok, %Response{}} =
               ChatCompletions.call(:deepseek_reasoning, "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 lets request opts override configured reasoning", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["reasoning"] == %{"effort" => "low"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Overridden"))
      end)

      assert {:ok, %Response{}} =
               ChatCompletions.call(
                 :deepseek_reasoning,
                 "system",
                 [UserMessage.new("Hi")],
                 [],
                 reasoning: :low
               )
    end

    test "call/5 rejects invalid reasoning opts" do
      assert_raise ArgumentError, ~r/unsupported OpenRouter reasoning effort/, fn ->
        ChatCompletions.call(:deepseek, "system", [UserMessage.new("Hi")], [], reasoning: :ultra)
      end
    end

    test "call/5 encodes tools and multi-turn tool conversations", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert [tool] = request["tools"]
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "echo"
        assert %{"type" => "object"} = tool["function"]["parameters"]
        assert request["tool_choice"] == "auto"

        assert [
                 %{"role" => "system"},
                 %{"role" => "user", "content" => "Hi"},
                 %{
                   "role" => "assistant",
                   "content" => "Let me check.",
                   "tool_calls" => [
                     %{
                       "id" => "call_1",
                       "type" => "function",
                       "function" => %{"name" => "echo", "arguments" => ~s({"message":"hi"})}
                     }
                   ]
                 },
                 %{"role" => "tool", "tool_call_id" => "call_1", "content" => "hi"}
               ] = request["messages"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Echoed"))
      end)

      messages = [
        UserMessage.new("Hi"),
        %AssistantMessage{
          content: [
            Content.text("Let me check."),
            Content.tool_use("call_1", "echo", %{"message" => "hi"})
          ]
        },
        %ToolResultMessage{content: [Content.tool_result("call_1", "hi")]}
      ]

      assert {:ok, %Response{}} =
               ChatCompletions.call(:deepseek, "system", messages, [Clementine.Test.Tools.Echo])
    end

    test "call/5 decodes tool call responses", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        response =
          Jason.encode!(%{
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => nil,
                  "tool_calls" => [
                    %{
                      "id" => "call_9",
                      "type" => "function",
                      "function" => %{"name" => "echo", "arguments" => ~s({"message":"yo"})}
                    }
                  ]
                },
                "finish_reason" => "tool_calls"
              }
            ],
            "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 9}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      assert {:ok, %Response{} = response} =
               ChatCompletions.call(:deepseek, "system", [UserMessage.new("Hi")], [])

      assert [%Content.ToolUse{id: "call_9", name: "echo", input: %{"message" => "yo"}}] =
               response.content

      assert response.stop_reason == "tool_use"
    end

    test "stream/5 emits chat completions events", %{bypass: bypass} do
      sse =
        Enum.join([
          ~s(data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"},"finish_reason":null}]}\n\n),
          ~s(data: {"choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":"stop"}],"usage":{"completion_tokens":2}}\n\n),
          "data: [DONE]\n\n"
        ])

      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["stream"] == true

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, sse)
      end)

      events =
        ChatCompletions.stream(:deepseek, "system", [UserMessage.new("Hi")], [])
        |> Enum.to_list()

      assert {:text_delta, "Hel"} in events
      assert {:text_delta, "lo"} in events

      assert {:message_delta, %{"stop_reason" => "end_turn"}, %{"completion_tokens" => 2}} in events

      assert List.last(events) == {:message_stop}
    end

    test "stream/5 surfaces the provider error body on a non-200 response", %{bypass: bypass} do
      error_body =
        ~s({"error":{"message":"No endpoints found for deepseek/deepseek-v3.2","code":404}})

      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, error_body)
      end)

      events =
        ChatCompletions.stream(:deepseek, "system", [UserMessage.new("Hi")], [])
        |> Enum.to_list()

      assert [{:error, {:api_error, 404, ^error_body}}] = events
    end

    test "stream/5 carries the provider error body after exhausting retries", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      error_body = ~s({"error":{"message":"Provider returned error","code":502}})

      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        Agent.update(counter, fn n -> n + 1 end)
        Plug.Conn.resp(conn, 502, error_body)
      end)

      events =
        ChatCompletions.stream(:deepseek, "system", [UserMessage.new("Hi")], [])
        |> Enum.to_list()

      assert {:error, {:api_error, 502, error_body}} in events

      # max_attempts is 3
      assert Agent.get(counter, & &1) == 3

      Agent.stop(counter)
    end
  end

  describe ":bedrock" do
    test "call/5 authenticates with the Bedrock API key and maps reasoning_effort", %{
      bypass: bypass,
      base_url: base_url
    } do
      Application.put_env(:clementine, :bedrock_base_url, base_url <> "/v1")
      Application.put_env(:clementine, :bedrock_api_key, "test-bedrock-key")

      Application.put_env(:clementine, :models,
        qwen: [provider: :bedrock, id: "qwen.qwen3-235b-a22b-2507-v1:0", reasoning: :low]
      )

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-bedrock-key"]
        assert request["model"] == "qwen.qwen3-235b-a22b-2507-v1:0"
        assert request["reasoning_effort"] == "low"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Hello from Bedrock"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Hello from Bedrock"}]}} =
               ChatCompletions.call(:qwen, "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 raises without a Bedrock endpoint configuration" do
      Application.put_env(:clementine, :bedrock_api_key, "test-bedrock-key")
      Application.put_env(:clementine, :models, qwen: [provider: :bedrock, id: "qwen.qwen3"])

      assert_raise RuntimeError, ~r/:bedrock_base_url or :bedrock_region/, fn ->
        ChatCompletions.call(:qwen, "system", [UserMessage.new("Hi")], [])
      end
    end
  end

  describe ":vertex" do
    test "call/5 resolves the access token through an MFA", %{
      bypass: bypass,
      base_url: base_url
    } do
      Application.put_env(:clementine, :vertex_base_url, base_url <> "/v1/endpoints/openapi")
      Application.put_env(:clementine, :vertex_access_token, {TokenSource, :fetch, []})

      Application.put_env(:clementine, :models, glm: [provider: :vertex, id: "zai/glm-4.7-maas"])

      Bypass.expect(bypass, "POST", "/v1/endpoints/openapi/chat/completions", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer vertex-token-123"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Hello from Vertex"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Hello from Vertex"}]}} =
               ChatCompletions.call(:glm, "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 raises without a Vertex endpoint configuration" do
      Application.put_env(:clementine, :vertex_access_token, "test-vertex-token")
      Application.put_env(:clementine, :models, glm: [provider: :vertex, id: "zai/glm-4.7-maas"])

      assert_raise RuntimeError, ~r/:vertex_base_url or :vertex_project/, fn ->
        ChatCompletions.call(:glm, "system", [UserMessage.new("Hi")], [])
      end
    end
  end

  describe ":openai_compatible" do
    test "call/5 uses the model's base_url and env-resolved api key", %{
      bypass: bypass,
      base_url: base_url
    } do
      System.put_env("CLEMENTINE_CC_TEST_KEY", "sk-finetune")
      on_exit(fn -> System.delete_env("CLEMENTINE_CC_TEST_KEY") end)

      Application.put_env(:clementine, :models,
        qwen_finetune: [
          provider: :openai_compatible,
          id: "tinker://run:train:0/sampler_weights/000080",
          base_url: base_url <> "/oai/api/v1",
          api_key: {:system, "CLEMENTINE_CC_TEST_KEY"}
        ]
      )

      Bypass.expect(bypass, "POST", "/oai/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-finetune"]
        assert request["model"] == "tinker://run:train:0/sampler_weights/000080"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Hello from the finetune"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Hello from the finetune"}]}} =
               ChatCompletions.call(:qwen_finetune, "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 sends no authorization header for keyless servers", %{
      bypass: bypass,
      base_url: base_url
    } do
      Application.put_env(:clementine, :models,
        local: [provider: :openai_compatible, id: "my-model", base_url: base_url <> "/v1"]
      )

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Hello from vLLM"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Hello from vLLM"}]}} =
               ChatCompletions.call(:local, "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 raises without a base_url" do
      Application.put_env(:clementine, :models,
        local: [provider: :openai_compatible, id: "my-model"]
      )

      assert_raise RuntimeError, ~r/:base_url in model config/, fn ->
        ChatCompletions.call(:local, "system", [UserMessage.new("Hi")], [])
      end
    end
  end

  test "message encoding skips Anthropic thinking blocks in cross-provider history" do
    encoded =
      Clementine.LLM.ChatCompletions.Messages.encode_all([
        %AssistantMessage{
          content: [
            Content.thinking("carried over", "sig123"),
            Content.redacted_thinking("opaque123"),
            Content.text("Answer.")
          ]
        }
      ])

    assert encoded == [%{"role" => "assistant", "content" => "Answer."}]
  end

  test "call/5 rejects models configured for non chat-completions providers" do
    Application.put_env(:clementine, :models,
      claude_test: [provider: :anthropic, id: "claude-sonnet-5"]
    )

    assert_raise RuntimeError, ~r/not an OpenAI-compatible chat completions provider/, fn ->
      ChatCompletions.call(:claude_test, "system", [UserMessage.new("Hi")], [])
    end
  end
end
