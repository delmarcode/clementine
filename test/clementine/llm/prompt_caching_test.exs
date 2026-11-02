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

  @env_keys [:models, :retry]

  @key "clementine-0123456789abcdef0123456789abcdef"
  @claude "claude-sonnet-5"
  @or_claude "anthropic/claude-sonnet-5"

  setup do
    bypass = Bypass.open()
    previous = Enum.map(@env_keys, &{&1, Application.get_env(:clementine, &1)})
    base = "http://localhost:#{bypass.port}"

    Application.put_env(:clementine, :retry, max_attempts: 1, base_delay: 0, max_delay: 0)

    Clementine.TestPlatforms.put(
      anthropic: [api_key: "test-anthropic-key", base_url: base],
      openai: [api_key: "test-openai-key", base_url: base <> "/v1"],
      openrouter: [api_key: "test-openrouter-key", base_url: base <> "/api/v1"],
      # Bedrock's base_url is the Mantle host both of its wires share.
      bedrock: [api_key: "test-bedrock-key", base_url: base <> "/bedrock"],
      vertex: [access_token: "test-vertex-token", base_url: base <> "/vertex/v1"],
      openai_compatible: [base_url: base <> "/oai/v1"]
    )

    # Shipped sheets ("claude-sonnet-5", "gpt-5", "gpt-5.6-sol",
    # "gpt-6.1-sol") carry their own cache facts; the models below are
    # declarations, and their cache.ttls decide what goes on the wire.
    Application.put_env(:clementine, :models, %{
      # Claude on OpenRouter: cache_control markers.
      "anthropic/claude-sonnet-5" =>
        declared(:anthropic, [openrouter: []], cache: [ttls: [:five_minutes, :one_hour]]),
      # Claude behind a LiteLLM proxy, which takes the vendor's id.
      "proxy/claude-sonnet-5" =>
        declared(:anthropic, [openai_compatible: [id: "claude-sonnet-5"]],
          cache: [ttls: [:five_minutes, :one_hour]]
        ),
      # GPT-5.6 on OpenRouter and Bedrock: billed for 30 minutes, no TTL sent.
      "openai/gpt-5.6-sol" =>
        declared(:openai, [openrouter: []], cache: [ttls: [:thirty_minutes]]),
      "global.openai.gpt-5.6-sol" =>
        declared(:openai, [bedrock: []], cache: [ttls: [:thirty_minutes]]),
      # Models that cache on their own, if at all.
      "deepseek/deepseek-v3.2" => declared(:deepseek, openrouter: []),
      "openai.gpt-oss-120b-1:0" => declared(:openai, bedrock: []),
      "deepseek-ai/deepseek-v3.2-maas" => declared(:deepseek, vertex: []),
      "qwen3" => declared(:qwen, openai_compatible: [])
    })

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
      request = anthropic_request(bypass, @claude, "Be brief.", [Echo])

      assert request["system"] == [
               %{"type" => "text", "text" => "Be brief.", "cache_control" => ephemeral()}
             ]

      assert request["cache_control"] == ephemeral()
      assert [%{"name" => "echo"} = echo] = request["tools"]
      refute Map.has_key?(echo, "cache_control")
    end

    test "cache: [ttl: :one_hour] marks both breakpoints with it", %{bypass: bypass} do
      request = anthropic_request(bypass, @claude, "Be brief.", [], cache: [ttl: :one_hour])
      hour = %{"type" => "ephemeral", "ttl" => "1h"}

      assert [%{"cache_control" => ^hour}] = request["system"]
      assert request["cache_control"] == hour
    end

    test "without a system prompt, the last tool loaded up front carries the breakpoint", %{
      bypass: bypass
    } do
      request =
        anthropic_request(bypass, @claude, nil, [Echo, Add, GatedDeploy], deferred: [GatedDeploy])

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
      request = anthropic_request(bypass, @claude, "Be brief.", [Echo], cache: false)

      assert request["system"] == "Be brief."
      refute Map.has_key?(request, "cache_control")
      refute Map.has_key?(hd(request["tools"]), "cache_control")
    end

    test "the stream's usage counts cache reads and writes as parts of the input", %{
      bypass: bypass
    } do
      stream_back(bypass, "/v1/messages", anthropic_stream(final_usage: %{"output_tokens" => 42}))

      assert {:ok, response} =
               @claude
               |> Anthropic.stream("Be brief.", [UserMessage.new("Hi")], [])
               |> LLM.collect_stream()

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 20 + 1_500 + 9_000,
               output_tokens: 42,
               cache_read_tokens: 9_000,
               cache_write_tokens: 1_500
             }
    end

    test "an end that reports its cache counts as null leaves the start's", %{bypass: bypass} do
      final = %{
        "input_tokens" => 60,
        "cache_creation_input_tokens" => nil,
        "cache_read_input_tokens" => nil,
        "output_tokens" => 42
      }

      stream_back(bypass, "/v1/messages", anthropic_stream(final_usage: final))

      assert {:ok, response} =
               @claude
               |> Anthropic.stream("Be brief.", [UserMessage.new("Hi")], [])
               |> LLM.collect_stream()

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 60 + 1_500 + 9_000,
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
               @claude
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

      assert {:ok, response} = Anthropic.call(@claude, "Be brief.", [UserMessage.new("Hi")], [])

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 4_007,
               output_tokens: 3,
               cache_read_tokens: 4_000
             }
    end
  end

  describe "OpenAI Responses" do
    test "sends the lane's prompt_cache_key; a sheet offering no TTL gets no cache options", %{
      bypass: bypass
    } do
      # GPT-5's sheet offers no TTL: it keeps its own retention.
      request = openai_request(bypass, "gpt-5", cache_key: @key)

      assert request["prompt_cache_key"] == @key
      refute Map.has_key?(request, "prompt_cache_options")
    end

    test "a sheet offering prompt_cache_options TTLs gets the write's lifetime", %{
      bypass: bypass
    } do
      for id <- ["gpt-5.6-sol", "gpt-6.1-sol"] do
        request = openai_request(bypass, id, cache_key: @key)
        assert request["prompt_cache_options"] == %{"ttl" => "30m"}, id
        assert request["prompt_cache_key"] == @key
      end

      assert openai_request(bypass, "gpt-6.1-sol", cache: [ttl: :twelve_hours])[
               "prompt_cache_options"
             ] == %{"ttl" => "12h"}
    end

    test "cache: false turns caching off where the sheet allows, and sends no key", %{
      bypass: bypass
    } do
      off = openai_request(bypass, "gpt-6.1-sol", cache_key: @key, cache: false)
      assert off["prompt_cache_options"] == %{"mode" => "explicit"}
      refute Map.has_key?(off, "prompt_cache_key")

      older = openai_request(bypass, "gpt-5", cache_key: @key, cache: false)
      refute Map.has_key?(older, "prompt_cache_options")
      refute Map.has_key?(older, "prompt_cache_key")
    end

    test "a TTL the sheet does not offer is refused before anything is sent" do
      assert_raise ArgumentError, ~r/cache: \[ttl: :thirty_minutes\] is not offered/, fn ->
        OpenAI.stream("gpt-5", "Be brief.", [UserMessage.new("Hi")], [],
          cache: [ttl: :thirty_minutes]
        )
      end

      assert_raise ArgumentError, ~r/cache: \[ttl: :one_hour\] is not offered/, fn ->
        OpenAI.stream("gpt-6.1-sol", "Be brief.", [UserMessage.new("Hi")], [],
          cache: [ttl: :one_hour]
        )
      end
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
               "gpt-6.1-sol"
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
    test "OpenRouter marks a model offering marker TTLs, and keys the lane", %{
      bypass: bypass
    } do
      request = chat_request(bypass, "/api/v1/chat/completions", @or_claude, cache_key: @key)

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

    test "OpenRouter carries a one-hour TTL on its markers", %{bypass: bypass} do
      request =
        chat_request(bypass, "/api/v1/chat/completions", @or_claude, cache: [ttl: :one_hour])

      hour = %{"type" => "ephemeral", "ttl" => "1h"}

      assert [%{"content" => [%{"cache_control" => ^hour}]} | _] = request["messages"]
      assert request["cache_control"] == hour
    end

    test "OpenRouter leaves a model offering no TTL to cache on its own, on the lane's key", %{
      bypass: bypass
    } do
      request =
        chat_request(bypass, "/api/v1/chat/completions", "deepseek/deepseek-v3.2",
          cache_key: @key
        )

      assert [%{"role" => "system", "content" => "Be brief."} | _] = request["messages"]
      refute Map.has_key?(request, "cache_control")
      refute Map.has_key?(request, "prompt_cache_options")
      assert request["prompt_cache_key"] == @key
    end

    test "OpenRouter with cache: false sends neither markers nor a key", %{bypass: bypass} do
      request =
        chat_request(bypass, "/api/v1/chat/completions", @or_claude,
          cache_key: @key,
          cache: false
        )

      assert [%{"role" => "system", "content" => "Be brief."} | _] = request["messages"]
      refute Map.has_key?(request, "cache_control")
      refute Map.has_key?(request, "prompt_cache_key")
      # Marker TTLs have no explicit mode to turn off.
      refute Map.has_key?(request, "prompt_cache_options")
    end

    test "Bedrock, Vertex, and a self-hosted server get no cache fields", %{bypass: bypass} do
      for {model, path} <- [
            {"openai.gpt-oss-120b-1:0", "/bedrock/v1/chat/completions"},
            {"deepseek-ai/deepseek-v3.2-maas", "/vertex/v1/chat/completions"},
            {"qwen3", "/oai/v1/chat/completions"}
          ] do
        request = chat_request(bypass, path, model, cache_key: @key)

        assert [%{"role" => "system", "content" => "Be brief."} | _] = request["messages"]
        refute Map.has_key?(request, "cache_control")
        refute Map.has_key?(request, "prompt_cache_key")
        refute Map.has_key?(request, "prompt_cache_options")
        assert request["stream_options"] == %{"include_usage" => true}
      end
    end

    test "marker TTLs send the markers through a proxy, under the id it takes", %{
      bypass: bypass
    } do
      request =
        chat_request(bypass, "/oai/v1/chat/completions", "proxy/claude-sonnet-5", cache_key: @key)

      assert request["model"] == "claude-sonnet-5"

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
               @or_claude
               |> ChatCompletions.stream("Be brief.", [UserMessage.new("Hi")], [])
               |> LLM.collect_stream()

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 10_339,
               output_tokens: 60,
               cache_read_tokens: 10_000,
               cache_write_tokens: 300
             }
    end

    test "cache: false turns off the caching of a model offering prompt_cache_options TTLs", %{
      bypass: bypass
    } do
      for {model, path} <- [
            {"openai/gpt-5.6-sol", "/api/v1/chat/completions"},
            {"global.openai.gpt-5.6-sol", "/bedrock/v1/chat/completions"}
          ] do
        request = chat_request(bypass, path, model, cache_key: @key, cache: false)

        assert request["prompt_cache_options"] == %{"mode" => "explicit"}
        refute Map.has_key?(request, "prompt_cache_key")
        refute Map.has_key?(request, "cache_control")

        # With caching on, it caches on its own: no TTL goes, and no markers.
        request = chat_request(bypass, path, model, [])
        refute Map.has_key?(request, "prompt_cache_options")
        refute Map.has_key?(request, "cache_control")
      end

      # Nothing to turn off on a model whose sheet offers no TTL.
      request =
        chat_request(bypass, "/bedrock/v1/chat/completions", "openai.gpt-oss-120b-1:0",
          cache: false
        )

      refute Map.has_key?(request, "prompt_cache_options")
    end

    test "a TTL the model does not offer on its platform is refused before anything is sent" do
      for {model, ttl} <- [
            {@or_claude, :thirty_minutes},
            {"openai/gpt-5.6-sol", :twelve_hours},
            {"deepseek/deepseek-v3.2", :five_minutes}
          ] do
        assert_raise ArgumentError, ~r/cache: \[ttl: #{inspect(ttl)}\] is not offered/, fn ->
          ChatCompletions.stream(model, "Be brief.", [UserMessage.new("Hi")], [],
            cache: [ttl: ttl]
          )
        end
      end
    end

    test "OpenRouter's last chunk carries its usage beside the finish", %{bypass: bypass} do
      body =
        Enum.map_join(
          [
            %{"choices" => [%{"index" => 0, "delta" => %{"content" => "ok"}}]},
            %{
              "id" => "gen-1",
              "provider" => "Anthropic",
              "choices" => [
                %{
                  "index" => 0,
                  "delta" => %{"role" => "assistant", "content" => ""},
                  "finish_reason" => "stop",
                  "native_finish_reason" => "end_turn"
                }
              ],
              "usage" => %{
                "prompt_tokens" => 12_000,
                "completion_tokens" => 9,
                "total_tokens" => 12_009,
                "cost" => 0.0042,
                "prompt_tokens_details" => %{
                  "cached_tokens" => 11_000,
                  "cache_write_tokens" => 900
                },
                "completion_tokens_details" => %{"reasoning_tokens" => 0}
              }
            }
          ],
          &("data: " <> Jason.encode!(&1) <> "\n\n")
        ) <> "data: [DONE]\n\n"

      stream_back(bypass, "/api/v1/chat/completions", body)

      assert {:ok, response} =
               @or_claude
               |> ChatCompletions.stream("Be brief.", [UserMessage.new("Hi")], [])
               |> LLM.collect_stream()

      assert response.stop_reason == "end_turn"

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 12_000,
               output_tokens: 9,
               cache_read_tokens: 11_000,
               cache_write_tokens: 900
             }
    end

    test "Vertex's usage on its last content chunk, and null details, are read", %{
      bypass: bypass
    } do
      body =
        Enum.map_join(
          [
            %{"choices" => [%{"index" => 0, "delta" => %{"content" => "o"}}]},
            %{
              "choices" => [
                %{"index" => 0, "delta" => %{"content" => "k"}, "finish_reason" => "stop"}
              ],
              "usage" => %{
                "prompt_tokens" => 5_000,
                "completion_tokens" => 2,
                "total_tokens" => 5_002,
                "prompt_tokens_details" => nil
              }
            }
          ],
          &("data: " <> Jason.encode!(&1) <> "\n\n")
        ) <> "data: [DONE]\n\n"

      stream_back(bypass, "/vertex/v1/chat/completions", body)

      assert {:ok, response} =
               "deepseek-ai/deepseek-v3.2-maas"
               |> ChatCompletions.stream("Be brief.", [UserMessage.new("Hi")], [])
               |> LLM.collect_stream()

      assert [%Content.Text{text: "ok"}] = response.content
      assert Usage.new(response.usage) == %Usage{input_tokens: 5_000, output_tokens: 2}
    end

    test "a LiteLLM proxy's Anthropic cache writes are read", %{bypass: bypass} do
      respond(bypass, "/oai/v1/chat/completions", %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}
        ],
        "usage" => %{
          "prompt_tokens" => 2_006,
          "completion_tokens" => 300,
          "prompt_tokens_details" => %{"cached_tokens" => 1_920},
          "cache_creation_input_tokens" => 86
        }
      })

      assert {:ok, response} =
               ChatCompletions.call(
                 "proxy/claude-sonnet-5",
                 "Be brief.",
                 [UserMessage.new("Hi")],
                 []
               )

      assert Usage.new(response.usage) == %Usage{
               input_tokens: 2_006,
               output_tokens: 300,
               cache_read_tokens: 1_920,
               cache_write_tokens: 86
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
               ChatCompletions.call("qwen3", "Be brief.", [UserMessage.new("Hi")], [])

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

    @claude |> Anthropic.stream("Be brief.", history, [Add]) |> Stream.run()

    assert_received {:request, request}
    assert request["cache_control"] == ephemeral()

    # History goes as it is: no block in it is marked, so the replayed
    # turns stay byte-identical from one call to the next.
    refute request["messages"] |> Jason.encode!() |> String.contains?("cache_control")
  end

  defp ephemeral, do: %{"type" => "ephemeral"}

  defp declared(vendor, platforms, facts \\ []) do
    Keyword.merge(
      [vendor: vendor, context: 200_000, max_output: 32_000, platforms: platforms],
      facts
    )
  end

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
