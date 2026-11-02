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

  # Models an app declares under config :clementine, :models: Clementine
  # ships no sheet for them, so each names its platform and its facts.
  @deepseek "deepseek/deepseek-v3.2"
  @qwen "qwen/qwen3-235b-a22b"

  defp deepseek(facts \\ [features: [structured_outputs: true]]) do
    Keyword.merge(
      [vendor: :deepseek, context: 163_840, max_output: 65_536, platforms: [openrouter: []]],
      facts
    )
  end

  defp qwen do
    [
      vendor: :qwen,
      context: 131_072,
      max_output: 32_768,
      thinking: [
        default: :adaptive,
        types: [:adaptive],
        efforts: [:low, :medium, :high],
        default_effort: :medium
      ],
      platforms: [openrouter: []]
    ]
  end

  defp put_models(models), do: Application.put_env(:clementine, :models, models)

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

      put_models(%{@deepseek => deepseek(), @qwen => qwen()})

      :ok
    end

    test "call/5 sends a chat completions request", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert Plug.Conn.get_req_header(conn, "authorization") ==
                 ["Bearer test-openrouter-key"]

        assert request["model"] == "deepseek/deepseek-v3.2"
        # The policy's default: min(16_000, the sheet's max_output).
        assert request["max_tokens"] == 16_000

        assert request["messages"] == [
                 %{"role" => "system", "content" => "system"},
                 %{"role" => "user", "content" => "Hi"}
               ]

        # A model whose sheet takes no effort gets no reasoning field.
        refute Map.has_key?(request, "reasoning")
        refute Map.has_key?(request, "reasoning_effort")
        refute Map.has_key?(request, "response_format")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Hello from OpenRouter"))
      end)

      assert {:ok, %Response{} = response} =
               ChatCompletions.call(@deepseek, "system", [UserMessage.new("Hi")], [])

      assert [%Content.Text{text: "Hello from OpenRouter"}] = response.content
      assert response.stop_reason == "end_turn"

      assert response.usage == %{
               "input_tokens" => 12,
               "output_tokens" => 4,
               "cache_read_tokens" => 0,
               "cache_write_tokens" => 0
             }
    end

    test "call/5 sends the request's max_tokens, up to the sheet's max_output", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["max_tokens"] == 65_536

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Long"))
      end)

      assert {:ok, %Response{}} =
               ChatCompletions.call(@deepseek, "system", [UserMessage.new("Hi")], [],
                 max_tokens: 65_536
               )

      assert_raise ArgumentError,
                   ~r/max_tokens: 65537 is over the model's ceiling of 65536/,
                   fn ->
                     ChatCompletions.call(@deepseek, "system", [UserMessage.new("Hi")], [],
                       max_tokens: 65_537
                     )
                   end
    end

    test "call/5 sends an output schema as response_format", %{bypass: bypass} do
      schema = %{
        "type" => "object",
        "properties" => %{"verdict" => %{"type" => "string"}},
        "required" => ["verdict"],
        "additionalProperties" => false
      }

      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["response_format"] == %{
                 "type" => "json_schema",
                 "json_schema" => %{"name" => "output", "schema" => schema, "strict" => true}
               }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response(~s({"verdict": "pass"})))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: ~s({"verdict": "pass"})}]}} =
               ChatCompletions.call(@deepseek, "system", [UserMessage.new("Hi")], [],
                 output_schema: schema
               )
    end

    test "call/5 sends no response_format to a model whose sheet lacks structured_outputs",
         %{bypass: bypass} do
      # The same model, declared without the fact: a grammar-enforcing
      # server would take its tools away, so the instructions describe
      # the answer instead.
      put_models(%{@deepseek => deepseek([])})

      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        refute Map.has_key?(Jason.decode!(body), "response_format")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response(~s({"verdict": "pass"})))
      end)

      assert {:ok, %Response{}} =
               ChatCompletions.call(@deepseek, "system", [UserMessage.new("Hi")], [],
                 output_schema: %{"type" => "object"}
               )
    end

    test "call/5 reads a refusal as the turn's text with stop reason refusal", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        body =
          Jason.encode!(%{
            "choices" => [
              %{
                "index" => 0,
                "message" => %{
                  "role" => "assistant",
                  "content" => nil,
                  "refusal" => "I can't help with that."
                },
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 6}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, %Response{} = response} =
               ChatCompletions.call(@deepseek, "system", [UserMessage.new("Hi")], [])

      assert [%Content.Text{text: "I can't help with that."}] = response.content
      assert response.stop_reason == "refusal"
    end

    test "call/5 sends the sheet's default effort as OpenRouter's reasoning", %{
      bypass: bypass
    } do
      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["reasoning"] == %{"effort" => "medium"}
        refute Map.has_key?(request, "reasoning_effort")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Default reasoning"))
      end)

      assert {:ok, %Response{}} =
               ChatCompletions.call(@qwen, "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 sends the request's effort and OpenRouter's reasoning options", %{
      bypass: bypass
    } do
      test = self()

      Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:reasoning, Jason.decode!(body)["reasoning"]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Chosen reasoning"))
      end)

      assert {:ok, %Response{}} =
               ChatCompletions.call(@qwen, "system", [UserMessage.new("Hi")], [],
                 effort: :high,
                 provider_options: [max_tokens: 2000]
               )

      assert_received {:reasoning, %{"effort" => "high", "max_tokens" => 2000}}

      assert {:ok, %Response{}} =
               ChatCompletions.call(@qwen, "system", [UserMessage.new("Hi")], [],
                 effort: :low,
                 provider_options: [exclude: true]
               )

      assert_received {:reasoning, %{"effort" => "low", "exclude" => true}}
    end

    test "call/5 refuses an effort the sheet does not offer, before sending" do
      assert_raise ArgumentError, ~r/takes effort \[:low, :medium, :high\], got: :ultra/, fn ->
        ChatCompletions.call(@qwen, "system", [UserMessage.new("Hi")], [], effort: :ultra)
      end

      assert_raise ArgumentError, ~r/takes effort \[:low, :medium, :high\], got: :xhigh/, fn ->
        ChatCompletions.call(@qwen, "system", [UserMessage.new("Hi")], [], effort: :xhigh)
      end

      assert_raise ArgumentError, ~r/takes no effort setting/, fn ->
        ChatCompletions.call(@deepseek, "system", [UserMessage.new("Hi")], [], effort: :low)
      end

      assert_raise ArgumentError, ~r/provider_options: unknown options \[:budget_tokens\]/, fn ->
        ChatCompletions.call(@qwen, "system", [UserMessage.new("Hi")], [],
          provider_options: [budget_tokens: 1024]
        )
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
               ChatCompletions.call(@deepseek, "system", messages, [Clementine.Test.Tools.Echo])
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
               ChatCompletions.call(@deepseek, "system", [UserMessage.new("Hi")], [])

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
        ChatCompletions.stream(@deepseek, "system", [UserMessage.new("Hi")], [])
        |> Enum.to_list()

      assert {:text_delta, "Hel"} in events
      assert {:text_delta, "lo"} in events

      assert {:message_delta, %{"stop_reason" => "end_turn"}, %{"output_tokens" => 2}} in events

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
        ChatCompletions.stream(@deepseek, "system", [UserMessage.new("Hi")], [])
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
        ChatCompletions.stream(@deepseek, "system", [UserMessage.new("Hi")], [])
        |> Enum.to_list()

      assert {:error, {:api_error, 502, error_body}} in events

      # max_attempts is 3
      assert Agent.get(counter, & &1) == 3

      Agent.stop(counter)
    end
  end

  describe ":bedrock" do
    setup do
      put_models(%{
        "qwen.qwen3-235b-a22b-2507-v1:0" => [
          vendor: :qwen,
          context: 262_144,
          max_output: 32_768,
          thinking: [default: :adaptive, types: [:adaptive], efforts: [:low, :medium, :high]],
          platforms: [bedrock: []]
        ]
      })

      :ok
    end

    test "call/5 authenticates with the Bedrock API key and maps reasoning_effort", %{
      bypass: bypass,
      base_url: base_url
    } do
      Application.put_env(:clementine, :bedrock_base_url, base_url <> "/v1")
      Application.put_env(:clementine, :bedrock_api_key, "test-bedrock-key")

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-bedrock-key"]
        assert request["model"] == "qwen.qwen3-235b-a22b-2507-v1:0"
        assert request["reasoning_effort"] == "low"
        refute Map.has_key?(request, "reasoning")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Hello from Bedrock"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Hello from Bedrock"}]}} =
               ChatCompletions.call(
                 "qwen.qwen3-235b-a22b-2507-v1:0",
                 "system",
                 [UserMessage.new("Hi")],
                 [],
                 effort: :low
               )
    end

    test "call/5 refuses OpenRouter's reasoning options on Bedrock" do
      Application.put_env(:clementine, :bedrock_api_key, "test-bedrock-key")

      assert_raise ArgumentError, ~r/provider_options: :bedrock takes none/, fn ->
        ChatCompletions.call(
          "qwen.qwen3-235b-a22b-2507-v1:0",
          "system",
          [UserMessage.new("Hi")],
          [],
          provider_options: [max_tokens: 2000]
        )
      end
    end

    test "call/5 raises without a Bedrock endpoint configuration" do
      Application.put_env(:clementine, :bedrock_api_key, "test-bedrock-key")

      assert_raise RuntimeError, ~r/:bedrock_base_url or :bedrock_region/, fn ->
        ChatCompletions.call(
          "qwen.qwen3-235b-a22b-2507-v1:0",
          "system",
          [UserMessage.new("Hi")],
          []
        )
      end
    end
  end

  describe ":vertex" do
    setup do
      put_models(%{
        "zai/glm-4.7-maas" => [
          vendor: :zai,
          context: 200_000,
          max_output: 128_000,
          platforms: [vertex: []]
        ]
      })

      :ok
    end

    test "call/5 resolves the access token through an MFA", %{
      bypass: bypass,
      base_url: base_url
    } do
      Application.put_env(:clementine, :vertex_base_url, base_url <> "/v1/endpoints/openapi")
      Application.put_env(:clementine, :vertex_access_token, {TokenSource, :fetch, []})

      Bypass.expect(bypass, "POST", "/v1/endpoints/openapi/chat/completions", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer vertex-token-123"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Hello from Vertex"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Hello from Vertex"}]}} =
               ChatCompletions.call("zai/glm-4.7-maas", "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 raises without a Vertex endpoint configuration" do
      Application.put_env(:clementine, :vertex_access_token, "test-vertex-token")

      assert_raise RuntimeError, ~r/:vertex_base_url or :vertex_project/, fn ->
        ChatCompletions.call("zai/glm-4.7-maas", "system", [UserMessage.new("Hi")], [])
      end
    end
  end

  describe ":openai_compatible" do
    test "call/5 uses the platform entry's base_url and env-resolved api key", %{
      bypass: bypass,
      base_url: base_url
    } do
      System.put_env("CLEMENTINE_CC_TEST_KEY", "sk-finetune")
      on_exit(fn -> System.delete_env("CLEMENTINE_CC_TEST_KEY") end)

      # App config the platform entry overrides.
      Application.put_env(:clementine, :openai_compatible_base_url, "http://unused.invalid/v1")
      Application.put_env(:clementine, :openai_compatible_api_key, "sk-unused")

      put_models(%{
        "tinker://run:train:0/sampler_weights/000080" => [
          vendor: :qwen,
          context: 32_768,
          max_output: 8_192,
          platforms: [
            openai_compatible: [
              base_url: base_url <> "/oai/api/v1",
              api_key: {:system, "CLEMENTINE_CC_TEST_KEY"}
            ]
          ]
        ]
      })

      Bypass.expect(bypass, "POST", "/oai/api/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-finetune"]
        assert request["model"] == "tinker://run:train:0/sampler_weights/000080"
        # min(16_000, max_output)
        assert request["max_tokens"] == 8_192

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Hello from the finetune"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Hello from the finetune"}]}} =
               ChatCompletions.call(
                 "tinker://run:train:0/sampler_weights/000080",
                 "system",
                 [UserMessage.new("Hi")],
                 []
               )
    end

    test "call/5 sends the id the platform entry names, on the app's base_url", %{
      bypass: bypass,
      base_url: base_url
    } do
      Application.put_env(:clementine, :openai_compatible_base_url, base_url <> "/v1")

      put_models(%{
        "qwen3-8b-local" => [
          vendor: :qwen,
          context: 32_768,
          max_output: 8_192,
          platforms: [openai_compatible: [id: "Qwen/Qwen3-8B"]]
        ]
      })

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["model"] == "Qwen/Qwen3-8B"
        # A keyless server: no key anywhere, and no authorization header.
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Hello from vLLM"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Hello from vLLM"}]}} =
               ChatCompletions.call("qwen3-8b-local", "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 raises without a base_url" do
      put_models(%{
        "qwen3-8b-local" => [
          vendor: :qwen,
          context: 32_768,
          max_output: 8_192,
          platforms: [openai_compatible: []]
        ]
      })

      assert_raise RuntimeError, ~r/:base_url in model config/, fn ->
        ChatCompletions.call("qwen3-8b-local", "system", [UserMessage.new("Hi")], [])
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

  test "message encoding skips a tool search the Anthropic API ran, keeping the call it led to" do
    encoded =
      Clementine.LLM.ChatCompletions.Messages.encode_all([
        %AssistantMessage{
          content: [
            Content.text("Searching."),
            Content.server_tool_use("srvtoolu_1", "tool_search_tool_regex", %{"pattern" => "x"}),
            Content.server_tool_result("srvtoolu_1", "tool_search_tool_result", %{}),
            Content.tool_use("call_1", "echo", %{"message" => "hi"})
          ]
        }
      ])

    assert [
             %{
               "role" => "assistant",
               "content" => "Searching.",
               "tool_calls" => [%{"id" => "call_1"}]
             }
           ] = encoded
  end

  test "call/5 refuses a model that goes to a platform outside the Chat Completions dialect" do
    assert_raise ArgumentError,
                 ~r/"claude-sonnet-5" goes to :anthropic, not a Chat Completions/,
                 fn ->
                   ChatCompletions.call("claude-sonnet-5", "system", [UserMessage.new("Hi")], [])
                 end

    assert_raise ArgumentError, ~r/"gpt-6.1-sol" goes to :openai, not a Chat Completions/, fn ->
      ChatCompletions.call("gpt-6.1-sol", "system", [UserMessage.new("Hi")], [])
    end
  end

  test "call/5 refuses an id no sheet or declaration names" do
    assert_raise ArgumentError, ~r/unknown model "deepseek\/deepseek-v9"/, fn ->
      ChatCompletions.call("deepseek/deepseek-v9", "system", [UserMessage.new("Hi")], [])
    end
  end
end
