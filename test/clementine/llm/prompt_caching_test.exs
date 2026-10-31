defmodule Clementine.LLM.PromptCachingTest do
  @moduledoc """
  What each provider client sends for prompt caching, and the cache
  reads and writes it reports in `Clementine.Usage`, against Bypass.
  """

  use ExUnit.Case, async: false

  alias Clementine.LLM
  alias Clementine.LLM.{Anthropic, ChatCompletions, OpenAI}
  alias Clementine.LLM.Message.{ToolResultMessage, UserMessage}
  alias Clementine.LLM.Message.Content
  alias Clementine.Test.Tools.{Add, Echo, GatedDeploy}
  alias Clementine.Usage

  @env_keys [
    :models,
    :retry,
    :anthropic_base_url,
    :anthropic_api_key,
    :openai_base_url,
    :openai_api_key,
    :openrouter_base_url,
    :openrouter_api_key,
    :bedrock_base_url,
    :bedrock_api_key,
    :vertex_base_url,
    :vertex_access_token,
    :openai_compatible_base_url
  ]

  @key "clementine-0123456789abcdef0123456789abcdef"

  setup do
    bypass = Bypass.open()
    previous = Enum.map(@env_keys, &{&1, Application.get_env(:clementine, &1)})
    base = "http://localhost:#{bypass.port}"

    Application.put_env(:clementine, :retry, max_attempts: 1, base_delay: 0, max_delay: 0)
    Application.put_env(:clementine, :anthropic_base_url, base <> "/v1/messages")
    Application.put_env(:clementine, :anthropic_api_key, "test-anthropic-key")
    Application.put_env(:clementine, :openai_base_url, base <> "/v1/responses")
    Application.put_env(:clementine, :openai_api_key, "test-openai-key")
    Application.put_env(:clementine, :openrouter_base_url, base <> "/api/v1")
    Application.put_env(:clementine, :openrouter_api_key, "test-openrouter-key")
    Application.put_env(:clementine, :bedrock_base_url, base <> "/bedrock/v1")
    Application.put_env(:clementine, :bedrock_api_key, "test-bedrock-key")
    Application.put_env(:clementine, :vertex_base_url, base <> "/vertex/v1")
    Application.put_env(:clementine, :vertex_access_token, "test-vertex-token")
    Application.put_env(:clementine, :openai_compatible_base_url, base <> "/oai/v1")

    Application.put_env(:clementine, :models,
      claude: [provider: :anthropic, id: "claude-sonnet-5"],
      claude_hour: [provider: :anthropic, id: "claude-sonnet-5", cache: [ttl: :one_hour]],
      claude_off: [provider: :anthropic, id: "claude-sonnet-5", cache: false],
      gpt_5: [provider: :openai, id: "gpt-5"],
      gpt_5_6: [provider: :openai, id: "gpt-5.6-sol"],
      gpt_5_6_long: [provider: :openai, id: "gpt-5.6-sol", cache: [ttl: :twelve_hours]],
      gpt_5_6_off: [provider: :openai, id: "gpt-5.6-sol", cache: false],
      gpt_5_off: [provider: :openai, id: "gpt-5", cache: false],
      or_claude: [provider: :openrouter, id: "anthropic/claude-sonnet-5"],
      or_claude_hour: [
        provider: :openrouter,
        id: "anthropic/claude-sonnet-5",
        cache: [ttl: :one_hour]
      ],
      or_deepseek: [provider: :openrouter, id: "deepseek/deepseek-v3.2"],
      or_off: [provider: :openrouter, id: "anthropic/claude-sonnet-5", cache: false],
      bedrock: [provider: :bedrock, id: "openai.gpt-oss-120b-1:0"],
      vertex: [provider: :vertex, id: "deepseek-ai/deepseek-v3.2-maas"],
      vllm: [provider: :openai_compatible, id: "qwen3"],
      proxy: [provider: :openai_compatible, id: "claude-sonnet-5", cache: [markers: true]]
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:clementine, key)
        {key, value} -> Application.put_env(:clementine, key, value)
      end)
    end)

    %{bypass: bypass}
  end

  describe "Anthropic" do
    test "marks the system prompt and the conversation's tail", %{bypass: bypass} do
      request = anthropic_request(bypass, :claude, "Be brief.", [Echo])

      assert request["system"] == [
               %{"type" => "text", "text" => "Be brief.", "cache_control" => ephemeral()}
             ]

      assert request["cache_control"] == ephemeral()
      assert [%{"name" => "echo"} = echo] = request["tools"]
      refute Map.has_key?(echo, "cache_control")
    end

    test "a one-hour alias marks both breakpoints with it", %{bypass: bypass} do
      request = anthropic_request(bypass, :claude_hour, "Be brief.", [])
      hour = %{"type" => "ephemeral", "ttl" => "1h"}

      assert [%{"cache_control" => ^hour}] = request["system"]
      assert request["cache_control"] == hour
    end

    test "without a system prompt, the last tool loaded up front carries the breakpoint", %{
      bypass: bypass
    } do
      request =
        anthropic_request(bypass, :claude, nil, [Echo, Add, GatedDeploy], deferred: [GatedDeploy])

      refute Map.has_key?(request, "system")

      assert [search, echo, add, deploy] = request["tools"]
      assert search["type"] == "tool_search_tool_regex_20251119"
      refute Map.has_key?(search, "cache_control")
      refute Map.has_key?(echo, "cache_control")
      assert add["cache_control"] == ephemeral()
      # A deferred tool may not carry cache_control: the API refuses it.
      assert deploy["defer_loading"] == true
      refute Map.has_key?(deploy, "cache_control")
      assert request["cache_control"] == ephemeral()
    end

    test "cache: false sends no breakpoints", %{bypass: bypass} do
      request = anthropic_request(bypass, :claude_off, "Be brief.", [Echo])

      assert request["system"] == "Be brief."
      refute Map.has_key?(request, "cache_control")
      refute Map.has_key?(hd(request["tools"]), "cache_control")
    end

    test "the stream's usage counts cache reads and writes as parts of the input", %{
      bypass: bypass
    } do
      stream_back(bypass, "/v1/messages", anthropic_stream(final_usage: %{"output_tokens" => 42}))

      assert {:ok, response} =
               :claude
               |> Anthropic.stream("Be brief.", [UserMessage.new("Hi")], [])
               |> LLM.collect_stream()

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 20 + 1_500 + 9_000,
               output_tokens: 42,
               cache_read_tokens: 9_000,
               cache_write_tokens: 1_500
             }
    end

    test "an end that reports cumulative input wins over the start's", %{bypass: bypass} do
      final = %{
        "input_tokens" => 60,
        "cache_creation_input_tokens" => 1_500,
        "cache_read_input_tokens" => 9_400,
        "output_tokens" => 42
      }

      stream_back(bypass, "/v1/messages", anthropic_stream(final_usage: final))

      assert {:ok, response} =
               :claude
               |> Anthropic.stream("Be brief.", [UserMessage.new("Hi")], [])
               |> LLM.collect_stream()

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 60 + 1_500 + 9_400,
               output_tokens: 42,
               cache_read_tokens: 9_400,
               cache_write_tokens: 1_500
             }
    end

    test "call/5 normalizes usage the same way", %{bypass: bypass} do
      respond(bypass, "/v1/messages", %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 7,
          "cache_creation_input_tokens" => 0,
          "cache_read_input_tokens" => 4_000,
          "output_tokens" => 3
        }
      })

      assert {:ok, response} = Anthropic.call(:claude, "Be brief.", [UserMessage.new("Hi")], [])

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 4_007,
               output_tokens: 3,
               cache_read_tokens: 4_000
             }
    end
  end

  describe "OpenAI Responses" do
    test "sends the lane's prompt_cache_key; a model before GPT-5.6 gets no cache options", %{
      bypass: bypass
    } do
      request = openai_request(bypass, :gpt_5, cache_key: @key)

      assert request["prompt_cache_key"] == @key
      refute Map.has_key?(request, "prompt_cache_options")
    end

    test "GPT-5.6 and later get the write's lifetime", %{bypass: bypass} do
      assert openai_request(bypass, :gpt_5_6, cache_key: @key)["prompt_cache_options"] ==
               %{"ttl" => "30m"}

      assert openai_request(bypass, :gpt_5_6_long, [])["prompt_cache_options"] ==
               %{"ttl" => "12h"}
    end

    test "cache: false turns caching off where the model allows, and sends no key", %{
      bypass: bypass
    } do
      off = openai_request(bypass, :gpt_5_6_off, cache_key: @key)
      assert off["prompt_cache_options"] == %{"mode" => "explicit"}
      refute Map.has_key?(off, "prompt_cache_key")

      older = openai_request(bypass, :gpt_5_off, cache_key: @key)
      refute Map.has_key?(older, "prompt_cache_options")
      refute Map.has_key?(older, "prompt_cache_key")
    end

    test "the stream's usage reads cached and written tokens out of the input", %{
      bypass: bypass
    } do
      usage = %{
        "input_tokens" => 12_000,
        "input_tokens_details" => %{
          "cached_tokens" => 4_000,
          "cache_write_tokens" => 7_000,
          "cache_write_tokens_details" => %{"ttl_30m_tokens" => 3_000, "ttl_12h_tokens" => 4_000}
        },
        "output_tokens" => 50,
        "output_tokens_details" => %{"reasoning_tokens" => 10}
      }

      stream_back(bypass, "/v1/responses", openai_stream(usage))

      assert {:ok, response} =
               :gpt_5_6
               |> OpenAI.stream("Be brief.", [UserMessage.new("Hi")], [])
               |> LLM.collect_stream()

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 12_000,
               output_tokens: 50,
               cache_read_tokens: 4_000,
               cache_write_tokens: 7_000
             }
    end
  end

  describe "Chat Completions" do
    test "OpenRouter marks an Anthropic model's system prompt and tail, and keys the lane", %{
      bypass: bypass
    } do
      request = chat_request(bypass, "/api/v1/chat/completions", :or_claude, cache_key: @key)

      assert [
               %{
                 "role" => "system",
                 "content" => [
                   %{
                     "type" => "text",
                     "text" => "Be brief.",
                     "cache_control" => %{"type" => "ephemeral"}
                   }
                 ]
               },
               %{"role" => "user", "content" => "Hi"}
             ] = request["messages"]

      assert request["cache_control"] == ephemeral()
      assert request["prompt_cache_key"] == @key
      assert request["stream_options"] == %{"include_usage" => true}
    end

    test "OpenRouter carries a one-hour alias's TTL on its markers", %{bypass: bypass} do
      request = chat_request(bypass, "/api/v1/chat/completions", :or_claude_hour, [])
      hour = %{"type" => "ephemeral", "ttl" => "1h"}

      assert [%{"content" => [%{"cache_control" => ^hour}]} | _] = request["messages"]
      assert request["cache_control"] == hour
    end

    test "OpenRouter leaves other models to cache on their own, on the lane's key", %{
      bypass: bypass
    } do
      request = chat_request(bypass, "/api/v1/chat/completions", :or_deepseek, cache_key: @key)

      assert [%{"role" => "system", "content" => "Be brief."} | _] = request["messages"]
      refute Map.has_key?(request, "cache_control")
      assert request["prompt_cache_key"] == @key
    end

    test "OpenRouter with cache: false sends neither markers nor a key", %{bypass: bypass} do
      request = chat_request(bypass, "/api/v1/chat/completions", :or_off, cache_key: @key)

      assert [%{"role" => "system", "content" => "Be brief."} | _] = request["messages"]
      refute Map.has_key?(request, "cache_control")
      refute Map.has_key?(request, "prompt_cache_key")
    end

    test "Bedrock, Vertex, and a self-hosted server get no cache fields", %{bypass: bypass} do
      for {model, path} <- [
            bedrock: "/bedrock/v1/chat/completions",
            vertex: "/vertex/v1/chat/completions",
            vllm: "/oai/v1/chat/completions"
          ] do
        request = chat_request(bypass, path, model, cache_key: @key)

        assert [%{"role" => "system", "content" => "Be brief."} | _] = request["messages"]
        refute Map.has_key?(request, "cache_control")
        refute Map.has_key?(request, "prompt_cache_key")
        assert request["stream_options"] == %{"include_usage" => true}
      end
    end

    test "markers: true sends them through a proxy", %{bypass: bypass} do
      request = chat_request(bypass, "/oai/v1/chat/completions", :proxy, cache_key: @key)

      assert [%{"content" => [%{"cache_control" => %{"type" => "ephemeral"}}]} | _] =
               request["messages"]

      assert request["cache_control"] == ephemeral()
      refute Map.has_key?(request, "prompt_cache_key")
    end

    test "usage reads cached and written tokens out of prompt_tokens", %{bypass: bypass} do
      usage = %{
        "prompt_tokens" => 10_339,
        "completion_tokens" => 60,
        "total_tokens" => 10_399,
        "prompt_tokens_details" => %{"cached_tokens" => 10_000, "cache_write_tokens" => 300}
      }

      stream_back(bypass, "/api/v1/chat/completions", chat_stream(usage))

      assert {:ok, response} =
               :or_claude
               |> ChatCompletions.stream("Be brief.", [UserMessage.new("Hi")], [])
               |> LLM.collect_stream()

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 10_339,
               output_tokens: 60,
               cache_read_tokens: 10_000,
               cache_write_tokens: 300
             }
    end

    test "a server that reports reads only has no writes", %{bypass: bypass} do
      respond(bypass, "/oai/v1/chat/completions", %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
        ],
        "usage" => %{
          "prompt_tokens" => 2_048,
          "completion_tokens" => 5,
          "prompt_tokens_details" => %{"cached_tokens" => 1_024}
        }
      })

      assert {:ok, response} =
               ChatCompletions.call(:vllm, "Be brief.", [UserMessage.new("Hi")], [])

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 2_048,
               output_tokens: 5,
               cache_read_tokens: 1_024
             }
    end
  end

  test "the tail breakpoint lands on tool results too: the API places it, not Clementine", %{
    bypass: bypass
  } do
    history = [
      UserMessage.new("Add them"),
      Clementine.LLM.Message.AssistantMessage.new([Content.tool_use("tu_1", "add", %{})]),
      ToolResultMessage.new([{"tu_1", {:ok, "3"}}])
    ]

    test = self()

    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(body)})
      sse(conn, Clementine.Test.Fixtures.sse_text_stream("ok"))
    end)

    :claude |> Anthropic.stream("Be brief.", history, [Add]) |> Stream.run()

    assert_received {:request, request}
    assert request["cache_control"] == ephemeral()

    # History goes as it is: no block in it is marked, so the replayed
    # turns stay byte-identical from one call to the next.
    refute request["messages"] |> Jason.encode!() |> String.contains?("cache_control")
  end

  defp ephemeral, do: %{"type" => "ephemeral"}

  defp anthropic_request(bypass, model, system, tools, opts \\ []) do
    test = self()

    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(body)})
      sse(conn, Clementine.Test.Fixtures.sse_text_stream("ok"))
    end)

    model |> Anthropic.stream(system, [UserMessage.new("Hi")], tools, opts) |> Stream.run()
    assert_received {:request, request}
    request
  end

  defp openai_request(bypass, model, opts) do
    test = self()

    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(body)})
      sse(conn, openai_stream(%{"input_tokens" => 1, "output_tokens" => 1}))
    end)

    model |> OpenAI.stream("Be brief.", [UserMessage.new("Hi")], [], opts) |> Stream.run()
    assert_received {:request, request}
    request
  end

  defp chat_request(bypass, path, model, opts) do
    test = self()

    Bypass.expect_once(bypass, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(body)})
      sse(conn, chat_stream(%{"prompt_tokens" => 1, "completion_tokens" => 1}))
    end)

    model
    |> ChatCompletions.stream("Be brief.", [UserMessage.new("Hi")], [], opts)
    |> Stream.run()

    assert_received {:request, request}
    request
  end

  defp stream_back(bypass, path, body) do
    Bypass.expect_once(bypass, "POST", path, fn conn -> sse(conn, body) end)
  end

  defp respond(bypass, path, body) do
    Bypass.expect_once(bypass, "POST", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp sse(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(200, body)
  end

  defp anthropic_stream(final_usage: final_usage) do
    [
      {"message_start",
       %{
         "type" => "message_start",
         "message" => %{
           "id" => "msg_1",
           "type" => "message",
           "role" => "assistant",
           "content" => [],
           "usage" => %{
             "input_tokens" => 20,
             "cache_creation_input_tokens" => 1_500,
             "cache_read_input_tokens" => 9_000,
             "output_tokens" => 1
           }
         }
       }},
      {"content_block_start",
       %{"index" => 0, "content_block" => %{"type" => "text", "text" => ""}}},
      {"content_block_delta",
       %{"index" => 0, "delta" => %{"type" => "text_delta", "text" => "ok"}}},
      {"content_block_stop", %{"index" => 0}},
      {"message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => final_usage}},
      {"message_stop", %{"type" => "message_stop"}}
    ]
    |> Enum.map_join(fn {event, data} -> "event: #{event}\ndata: #{Jason.encode!(data)}\n\n" end)
  end

  defp openai_stream(usage) do
    data = %{
      "type" => "response.completed",
      "response" => %{
        "status" => "completed",
        "output" => [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
        ],
        "usage" => usage
      }
    }

    "event: response.output_text.delta\ndata: " <>
      Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "ok"}) <>
      "\n\nevent: response.completed\ndata: " <> Jason.encode!(data) <> "\n\n"
  end

  defp chat_stream(usage) do
    Enum.map_join(
      [
        %{
          "choices" => [%{"index" => 0, "delta" => %{"content" => "ok"}, "finish_reason" => nil}]
        },
        %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]},
        %{"choices" => [], "usage" => usage}
      ],
      fn chunk -> "data: " <> Jason.encode!(chunk) <> "\n\n" end
    ) <> "data: [DONE]\n\n"
  end
end
