defmodule Clementine.LLM.OpenAITest do
  use ExUnit.Case, async: false

  alias Clementine.LLM
  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Message.UserMessage
  alias Clementine.LLM.OpenAI
  alias Clementine.LLM.Response

  # GPT-6.1 Sol: effort :medium by default, prompt_cache_options TTLs.
  @model "gpt-6.1-sol"

  setup do
    bypass = Bypass.open()

    prev_models = Application.get_env(:clementine, :models)
    prev_retry = Application.get_env(:clementine, :retry)

    Clementine.TestPlatforms.put(
      openai: [api_key: "test-openai-key", base_url: "http://localhost:#{bypass.port}/v1"]
    )

    Application.put_env(:clementine, :retry, max_attempts: 3, base_delay: 0, max_delay: 0)

    on_exit(fn ->
      restore_env(:models, prev_models)
      restore_env(:retry, prev_retry)
    end)

    %{bypass: bypass}
  end

  test "call/5 parses text output", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "gpt-6.1-sol"
      assert request["instructions"] == "system"

      response = %{
        "id" => "resp_1",
        "output" => [
          %{
            "type" => "message",
            "id" => "msg_1",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "Hello from OpenAI"}]
          }
        ],
        "usage" => %{"input_tokens" => 12, "output_tokens" => 4}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    assert {:ok, %Response{} = response} =
             OpenAI.call(@model, "system", [UserMessage.new("Hi")], [])

    assert [%Content.Text{text: "Hello from OpenAI"}] = response.content
    assert response.stop_reason == "end_turn"
    assert response.usage["output_tokens"] == 4
  end

  test "call/5 sends the model's max_output_tokens and default effort", %{bypass: bypass} do
    test = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, text_response("Defaults"))
    end)

    assert {:ok, %Response{content: [%Content.Text{text: "Defaults"}]}} =
             OpenAI.call(@model, "system", [UserMessage.new("Hi")], [])

    assert_received {:request, request}
    assert request["max_output_tokens"] == 16_000
    assert request["reasoning"] == %{"effort" => "medium"}

    # GPT-4.1 does not reason, so no reasoning field goes.
    assert {:ok, %Response{}} = OpenAI.call("gpt-4.1", "system", [UserMessage.new("Hi")], [])

    assert_received {:request, request}
    assert request["model"] == "gpt-4.1"
    assert request["max_output_tokens"] == 16_000
    refute Map.has_key?(request, "reasoning")
  end

  test "call/5 sends the agent's max_tokens, effort, and summary", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["max_output_tokens"] == 1024
      assert request["reasoning"] == %{"effort" => "high", "summary" => "auto"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, text_response("Chosen"))
    end)

    assert {:ok, %Response{content: [%Content.Text{text: "Chosen"}]}} =
             OpenAI.call(@model, "system", [UserMessage.new("Hi")], [],
               max_tokens: 1024,
               effort: :high,
               provider_options: [summary: :auto]
             )
  end

  test "max_output_tokens defaults to a declared model's ceiling where it is under 16,000", %{
    bypass: bypass
  } do
    Application.put_env(:clementine, :models, %{
      "gpt-6.1-sol" => [max_output: 8_000],
      "ft:gpt-6.1-sol:acme:triage:abc123" => [
        vendor: :openai,
        context: 1_050_000,
        max_output: 4_096,
        platforms: [openai: []]
      ]
    })

    test = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, text_response("ok"))
    end)

    assert {:ok, %Response{}} = OpenAI.call(@model, "system", [UserMessage.new("Hi")], [])
    assert_received {:request, %{"max_output_tokens" => 8_000}}

    fine_tuned = "ft:gpt-6.1-sol:acme:triage:abc123"
    assert {:ok, %Response{}} = OpenAI.call(fine_tuned, "system", [UserMessage.new("Hi")], [])
    assert_received {:request, request}
    assert request["model"] == fine_tuned
    assert request["max_output_tokens"] == 4_096
    refute Map.has_key?(request, "reasoning")
  end

  test "call/5 refuses, before sending, what the model's sheet refuses" do
    call = fn model, opts -> OpenAI.call(model, "system", [UserMessage.new("Hi")], [], opts) end

    assert_raise ArgumentError, ~r/takes effort \[:low, :medium, :high, :xhigh, :max\]/, fn ->
      call.("gpt-6.1-sol", effort: :none)
    end

    assert_raise ArgumentError, ~r/takes no effort setting/, fn ->
      call.("gpt-4.1", effort: :low)
    end

    assert_raise ArgumentError, ~r/provider_options: /, fn ->
      call.(@model, provider_options: [budget_tokens: 2048])
    end

    assert_raise ArgumentError, ~r/unknown model "gpt-7"/, fn ->
      call.("gpt-7", [])
    end

    assert_raise ArgumentError, ~r/goes to :anthropic over :messages, not Responses/, fn ->
      call.("claude-sonnet-5-5", [])
    end
  end

  test "message encoding skips Anthropic thinking blocks in cross-provider history" do
    alias Clementine.LLM.Message.AssistantMessage

    encoded =
      Clementine.LLM.OpenAI.Messages.encode_all([
        %AssistantMessage{
          content: [
            Content.thinking("carried over", "sig123"),
            Content.redacted_thinking("opaque123"),
            Content.text("Answer.")
          ]
        }
      ])

    assert encoded == [%{"type" => "message", "role" => "assistant", "content" => "Answer."}]
  end

  test "message encoding skips a tool search the Anthropic API ran, keeping the call it led to" do
    alias Clementine.LLM.Message.AssistantMessage

    encoded =
      Clementine.LLM.OpenAI.Messages.encode_all([
        %AssistantMessage{
          content: [
            Content.server_tool_use("srvtoolu_1", "tool_search_tool_regex", %{"pattern" => "x"}),
            Content.server_tool_result("srvtoolu_1", "tool_search_tool_result", %{}),
            Content.tool_use("toolu_1", "echo", %{"message" => "hi"})
          ]
        }
      ])

    assert [%{"type" => "function_call", "call_id" => "toolu_1", "name" => "echo"}] = encoded
  end

  test "call/5 sends deferred tools as ordinary tools: no tool search here", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert [%{"name" => "echo"} = echo, %{"name" => "add"} = add] = request["tools"]
      refute Map.has_key?(echo, "defer_loading")
      refute Map.has_key?(add, "defer_loading")

      response = %{
        "id" => "resp_3",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "ok"}]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 1}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    tools = [Clementine.Test.Tools.Echo, Clementine.Test.Tools.Add]

    assert {:ok, %Response{}} =
             OpenAI.call(@model, "system", [UserMessage.new("Hi")], tools,
               deferred: [Clementine.Test.Tools.Add]
             )
  end

  test "call/5 sends an output schema as strict Structured Outputs in text.format",
       %{bypass: bypass} do
    schema = %{
      "type" => "object",
      "properties" => %{"verdict" => %{"type" => "string"}},
      "required" => ["verdict"],
      "additionalProperties" => false
    }

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["text"] == %{
               "format" => %{
                 "type" => "json_schema",
                 "name" => "output",
                 "schema" => schema,
                 "strict" => true
               }
             }

      # Function calls stay as they were.
      assert [%{"type" => "function", "name" => "echo"}] = request["tools"]
      assert request["tool_choice"] == "auto"

      response = %{
        "id" => "resp_4",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => ~s({"verdict":"pass"})}]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    assert {:ok, %Response{content: [%Content.Text{text: ~s({"verdict":"pass"})}]}} =
             OpenAI.call(
               @model,
               "system",
               [UserMessage.new("Hi")],
               [Clementine.Test.Tools.Echo],
               output_schema: schema
             )
  end

  test "call/5 sends no text.format without an output schema", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute Map.has_key?(Jason.decode!(body), "text")

      response = %{
        "id" => "resp_5",
        "output" => [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 1}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    assert {:ok, %Response{}} = OpenAI.call(@model, "system", [UserMessage.new("Hi")], [])
  end

  test "call/5 reads a refusal and a cut-off response by their stop reasons", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      response =
        case Jason.decode!(body)["input"] do
          [%{"content" => "Refuse"}] ->
            # A refusal beats the call beside it.
            %{
              "status" => "completed",
              "output" => [
                %{
                  "type" => "message",
                  "content" => [%{"type" => "refusal", "refusal" => "I can't help with that."}]
                },
                %{
                  "type" => "function_call",
                  "call_id" => "call_1",
                  "name" => "echo",
                  "arguments" => "{}",
                  "status" => "completed"
                }
              ]
            }

          _cut_off ->
            %{
              "status" => "incomplete",
              "incomplete_details" => %{"reason" => "max_output_tokens"},
              "output" => [
                %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "{"}]},
                # A call the cut fell inside is no call.
                %{
                  "type" => "function_call",
                  "call_id" => "call_2",
                  "name" => "echo",
                  "arguments" => ~s({"mess),
                  "status" => "incomplete"
                }
              ]
            }
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(Map.put(response, "usage", %{})))
    end)

    assert {:ok, %Response{} = refused} =
             OpenAI.call(@model, "system", [UserMessage.new("Refuse")], [])

    assert [%Content.Text{text: "I can't help with that."}, %Content.ToolUse{}] = refused.content
    assert refused.stop_reason == "refusal"

    assert {:ok, %Response{stop_reason: "max_tokens", content: [%Content.Text{text: "{"}]}} =
             OpenAI.call(@model, "system", [UserMessage.new("Cut off")], [])
  end

  test "call/5 parses tool calls", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      response = %{
        "id" => "resp_2",
        "output" => [
          %{
            "type" => "function_call",
            "id" => "fc_1",
            "call_id" => "call_1",
            "name" => "search",
            "arguments" => ~s({"query":"elixir"})
          }
        ],
        "usage" => %{"input_tokens" => 20, "output_tokens" => 3}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    assert {:ok, %Response{} = response} =
             OpenAI.call(@model, "system", [UserMessage.new("Find docs")], [])

    assert [
             %Content.ToolUse{
               id: "call_1",
               name: "search",
               input: %{"query" => "elixir"}
             }
           ] =
             response.content

    assert response.stop_reason == "tool_use"
  end

  test "stream/5 emits text and can be collected", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, text_stream_sse("Hello stream"))
    end)

    events = OpenAI.stream(@model, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()
    assert Enum.any?(events, &match?({:text_delta, "Hello stream"}, &1))
    assert Enum.any?(events, &match?({:message_stop}, &1))

    assert {:ok, %Response{} = response} =
             OpenAI.stream(@model, "system", [UserMessage.new("Hi")], [])
             |> LLM.collect_stream()

    assert [%Content.Text{text: "Hello stream"}] = response.content
  end

  test "stream/5 surfaces the provider error body on a non-200 response", %{bypass: bypass} do
    error_body =
      ~s({"error":{"message":"The requested model 'gpt-5' does not exist.","type":"invalid_request_error"}})

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(404, error_body)
    end)

    events = OpenAI.stream(@model, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()

    assert [{:error, {:api_error, 404, ^error_body}}] = events
  end

  test "stream/5 carries the provider error body after exhausting retries", %{bypass: bypass} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    error_body = ~s({"error":{"message":"The server had an error.","type":"server_error"}})

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      Agent.update(counter, fn n -> n + 1 end)
      Plug.Conn.resp(conn, 500, error_body)
    end)

    events = OpenAI.stream(@model, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()

    assert {:error, {:api_error, 500, error_body}} in events

    # max_attempts is 3
    assert Agent.get(counter, & &1) == 3

    Agent.stop(counter)
  end

  test "stream/5 emits tool use events and can be collected", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, tool_stream_sse("call_abc", "search", ~s({"query":"phoenix"})))
    end)

    assert {:ok, %Response{} = response} =
             OpenAI.stream(@model, "system", [UserMessage.new("search for phoenix")], [])
             |> LLM.collect_stream()

    assert [
             %Content.ToolUse{
               id: "call_abc",
               name: "search",
               input: %{"query" => "phoenix"}
             }
           ] =
             response.content

    assert response.stop_reason == "tool_use"
  end

  test "stream/5 does not duplicate done-only function call arguments", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        tool_stream_done_only_arguments_sse(
          "call_done_only",
          "search",
          ~s({"query":"elixir docs"})
        )
      )
    end)

    assert {:ok, %Response{} = response} =
             OpenAI.stream(@model, "system", [UserMessage.new("search elixir docs")], [])
             |> LLM.collect_stream()

    assert [
             %Content.ToolUse{
               id: "call_done_only",
               name: "search",
               input: %{"query" => "elixir docs"}
             }
           ] = response.content
  end

  test "stream/5 replays unfinished parallel function calls correctly", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, parallel_unfinished_tool_calls_sse())
    end)

    assert {:ok, %Response{} = response} =
             OpenAI.stream(@model, "system", [UserMessage.new("parallel tools")], [])
             |> LLM.collect_stream()

    assert [
             %Content.ToolUse{
               id: "call_1",
               name: "search",
               input: %{"query" => "elixir"}
             },
             %Content.ToolUse{
               id: "call_2",
               name: "read_file",
               input: %{"path" => "README.md"}
             }
           ] = response.content

    assert response.stop_reason == "tool_use"
  end

  test "call/5 retries on 429 and succeeds", %{bypass: bypass} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      call_num = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      if call_num == 1 do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, ~s({"error":{"message":"rate limit"}}))
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "resp_retry",
            "output" => [
              %{
                "type" => "message",
                "id" => "msg_1",
                "role" => "assistant",
                "content" => [%{"type" => "output_text", "text" => "Recovered"}]
              }
            ],
            "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
          })
        )
      end
    end)

    assert {:ok, %Response{content: [%Content.Text{text: "Recovered"}]}} =
             OpenAI.call(@model, "system", [UserMessage.new("Hi")], [])

    assert Agent.get(counter, & &1) == 2
    Agent.stop(counter)
  end

  test "a clamped usage names the model's vendor and the platform, in calls and streams", %{
    bypass: bypass
  } do
    # A model an app declares on :openai need not be OpenAI's.
    Application.put_env(:clementine, :models, %{
      "acme-reasoner" => [
        vendor: :acme,
        context: 200_000,
        max_output: 8_000,
        platforms: [openai: []]
      ]
    })

    test = self()
    ref = make_ref()

    :telemetry.attach(
      "openai-clamped-#{inspect(ref)}",
      [:clementine, :llm, :usage_clamped],
      fn _event, _measurements, metadata, _config -> send(test, {:clamped, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("openai-clamped-#{inspect(ref)}") end)

    # More cached tokens than input: the normalizer raises the total and
    # says so.
    usage = %{
      "input_tokens" => 10,
      "input_tokens_details" => %{"cached_tokens" => 50},
      "output_tokens" => 3
    }

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if Jason.decode!(body)["stream"] do
        completed =
          sse("response.completed", %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_1",
              "status" => "completed",
              "output" => [],
              "usage" => usage
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, completed <> "\n\n")
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"id" => "resp_1", "output" => [], "usage" => usage})
        )
      end
    end)

    meta = %{provider: :acme, platform: :openai, model: "acme-reasoner"}

    assert {:ok, %Response{}} =
             OpenAI.call("acme-reasoner", "system", [UserMessage.new("Hi")], [])

    assert_received {:clamped, ^meta}

    OpenAI.stream("acme-reasoner", "system", [UserMessage.new("Hi")], []) |> Enum.to_list()
    assert_received {:clamped, ^meta}
  end

  defp restore_env(key, nil), do: Application.delete_env(:clementine, key)
  defp restore_env(key, value), do: Application.put_env(:clementine, key, value)

  defp text_response(text) do
    Jason.encode!(%{
      "id" => "resp_text",
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_1",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ],
      "usage" => %{"input_tokens" => 12, "output_tokens" => 4}
    })
  end

  defp text_stream_sse(text) do
    events = [
      sse("response.output_text.delta", %{
        "type" => "response.output_text.delta",
        "item_id" => "msg_1",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => text
      }),
      sse("response.completed", %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_1",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "id" => "msg_1",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => text}]
            }
          ],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 3}
        }
      })
    ]

    Enum.join(events, "\n\n") <> "\n\n"
  end

  defp tool_stream_sse(call_id, tool_name, arguments_json) do
    events = [
      sse("response.output_item.added", %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => call_id,
          "name" => tool_name,
          "arguments" => ""
        }
      }),
      sse("response.function_call_arguments.delta", %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc_1",
        "delta" => arguments_json
      }),
      sse("response.output_item.done", %{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => call_id,
          "name" => tool_name,
          "arguments" => arguments_json
        }
      }),
      sse("response.completed", %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_2",
          "status" => "completed",
          "output" => [
            %{
              "type" => "function_call",
              "id" => "fc_1",
              "call_id" => call_id,
              "name" => tool_name,
              "arguments" => arguments_json
            }
          ],
          "usage" => %{"input_tokens" => 11, "output_tokens" => 4}
        }
      })
    ]

    Enum.join(events, "\n\n") <> "\n\n"
  end

  defp tool_stream_done_only_arguments_sse(call_id, tool_name, arguments_json) do
    events = [
      sse("response.output_item.added", %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => call_id,
          "name" => tool_name,
          "arguments" => ""
        }
      }),
      sse("response.function_call_arguments.done", %{
        "type" => "response.function_call_arguments.done",
        "item_id" => "fc_1",
        "arguments" => arguments_json
      }),
      sse("response.output_item.done", %{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => call_id,
          "name" => tool_name,
          "arguments" => arguments_json
        }
      }),
      sse("response.completed", %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_done_only",
          "status" => "completed",
          "output" => [
            %{
              "type" => "function_call",
              "id" => "fc_1",
              "call_id" => call_id,
              "name" => tool_name,
              "arguments" => arguments_json
            }
          ],
          "usage" => %{"input_tokens" => 11, "output_tokens" => 4}
        }
      })
    ]

    Enum.join(events, "\n\n") <> "\n\n"
  end

  defp parallel_unfinished_tool_calls_sse do
    events = [
      sse("response.output_item.added", %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_1",
          "name" => "search",
          "arguments" => ""
        }
      }),
      sse("response.output_item.added", %{
        "type" => "response.output_item.added",
        "output_index" => 1,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_2",
          "call_id" => "call_2",
          "name" => "read_file",
          "arguments" => ""
        }
      }),
      sse("response.completed", %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_parallel",
          "status" => "completed",
          "output" => [
            %{
              "type" => "function_call",
              "id" => "fc_1",
              "call_id" => "call_1",
              "name" => "search",
              "arguments" => ~s({"query":"elixir"})
            },
            %{
              "type" => "function_call",
              "id" => "fc_2",
              "call_id" => "call_2",
              "name" => "read_file",
              "arguments" => ~s({"path":"README.md"})
            }
          ],
          "usage" => %{"input_tokens" => 11, "output_tokens" => 4}
        }
      })
    ]

    Enum.join(events, "\n\n") <> "\n\n"
  end

  defp sse(event, data) do
    "event: #{event}\ndata: #{Jason.encode!(data)}"
  end
end
