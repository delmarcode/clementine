defmodule Clementine.LLM.OpenAITest do
  use ExUnit.Case, async: false

  alias Clementine.LLM
  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Message.UserMessage
  alias Clementine.LLM.OpenAI
  alias Clementine.LLM.Response

  setup do
    bypass = Bypass.open()

    prev_url = Application.get_env(:clementine, :openai_base_url)
    prev_key = Application.get_env(:clementine, :openai_api_key)
    prev_models = Application.get_env(:clementine, :models)
    prev_retry = Application.get_env(:clementine, :retry)

    Application.put_env(
      :clementine,
      :openai_base_url,
      "http://localhost:#{bypass.port}/v1/responses"
    )

    Application.put_env(:clementine, :openai_api_key, "test-openai-key")

    Application.put_env(:clementine, :models,
      gpt_test: [provider: :openai, id: "gpt-5", defaults: [max_output_tokens: 1024]]
    )

    Application.put_env(:clementine, :retry, max_attempts: 3, base_delay: 0, max_delay: 0)

    on_exit(fn ->
      restore_env(:openai_base_url, prev_url)
      restore_env(:openai_api_key, prev_key)
      restore_env(:models, prev_models)
      restore_env(:retry, prev_retry)
    end)

    %{bypass: bypass}
  end

  test "call/5 parses text output", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "gpt-5"
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
             OpenAI.call(:gpt_test, "system", [UserMessage.new("Hi")], [])

    assert [%Content.Text{text: "Hello from OpenAI"}] = response.content
    assert response.stop_reason == "end_turn"
    assert response.usage["output_tokens"] == 4
  end

  test "call/5 supports direct tuple model references", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "gpt-5"

      response = %{
        "id" => "resp_direct",
        "output" => [
          %{
            "type" => "message",
            "id" => "msg_1",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "Direct model ref"}]
          }
        ],
        "usage" => %{"input_tokens" => 12, "output_tokens" => 4}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)

    assert {:ok, %Response{content: [%Content.Text{text: "Direct model ref"}]}} =
             OpenAI.call({:openai, "gpt-5"}, "system", [UserMessage.new("Hi")], [])
  end

  test "call/5 includes configured reasoning", %{bypass: bypass} do
    Application.put_env(:clementine, :models,
      gpt_reasoning: [
        provider: :openai,
        id: "gpt-5",
        reasoning: [effort: :high, summary: :auto]
      ]
    )

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["reasoning"] == %{"effort" => "high", "summary" => "auto"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, text_response("Configured reasoning"))
    end)

    assert {:ok, %Response{content: [%Content.Text{text: "Configured reasoning"}]}} =
             OpenAI.call(:gpt_reasoning, "system", [UserMessage.new("Hi")], [])
  end

  test "call/5 lets request opts override configured reasoning", %{bypass: bypass} do
    Application.put_env(:clementine, :models,
      gpt_reasoning: [provider: :openai, id: "gpt-5", reasoning: [effort: :high]]
    )

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["reasoning"] == %{"effort" => "low"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, text_response("Overridden reasoning"))
    end)

    assert {:ok, %Response{content: [%Content.Text{text: "Overridden reasoning"}]}} =
             OpenAI.call(:gpt_reasoning, "system", [UserMessage.new("Hi")], [], reasoning: :low)
  end

  test "call/5 rejects invalid OpenAI reasoning opts" do
    assert_raise ArgumentError, ~r/unsupported OpenAI reasoning effort/, fn ->
      OpenAI.call(:gpt_test, "system", [UserMessage.new("Hi")], [], reasoning: :max)
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
             OpenAI.call(:gpt_test, "system", [UserMessage.new("Find docs")], [])

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

    events = OpenAI.stream(:gpt_test, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()
    assert Enum.any?(events, &match?({:text_delta, "Hello stream"}, &1))
    assert Enum.any?(events, &match?({:message_stop}, &1))

    assert {:ok, %Response{} = response} =
             OpenAI.stream(:gpt_test, "system", [UserMessage.new("Hi")], [])
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

    events = OpenAI.stream(:gpt_test, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()

    assert [{:error, {:api_error, 404, ^error_body}}] = events
  end

  test "stream/5 carries the provider error body after exhausting retries", %{bypass: bypass} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    error_body = ~s({"error":{"message":"The server had an error.","type":"server_error"}})

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      Agent.update(counter, fn n -> n + 1 end)
      Plug.Conn.resp(conn, 500, error_body)
    end)

    events = OpenAI.stream(:gpt_test, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()

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
             OpenAI.stream(:gpt_test, "system", [UserMessage.new("search for phoenix")], [])
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
             OpenAI.stream(:gpt_test, "system", [UserMessage.new("search elixir docs")], [])
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
             OpenAI.stream(:gpt_test, "system", [UserMessage.new("parallel tools")], [])
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
             OpenAI.call(:gpt_test, "system", [UserMessage.new("Hi")], [])

    assert Agent.get(counter, & &1) == 2
    Agent.stop(counter)
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
