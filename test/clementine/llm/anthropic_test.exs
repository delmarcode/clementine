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

  describe "structured output" do
    @output_schema %{
      "type" => "object",
      "properties" => %{"verdict" => %{"type" => "string"}},
      "required" => ["verdict"],
      "additionalProperties" => false
    }

    test "call/5 sends the schema as output_config.format", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["output_config"] == %{
                 "format" => %{"type" => "json_schema", "schema" => @output_schema}
               }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response(~s({"verdict": "pass"})))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: ~s({"verdict": "pass"})}]}} =
               Anthropic.call(:claude_test, "system", [UserMessage.new("Hi")], [],
                 output_schema: @output_schema
               )
    end

    test "call/5 puts the format beside a configured reasoning effort", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["thinking"] == %{"type" => "adaptive"}

        assert request["output_config"] == %{
                 "effort" => "high",
                 "format" => %{"type" => "json_schema", "schema" => @output_schema}
               }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response(~s({"verdict": "pass"})))
      end)

      assert {:ok, %Response{}} =
               Anthropic.call(:claude_reasoning, "system", [UserMessage.new("Hi")], [],
                 output_schema: @output_schema
               )
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

  describe "deferred tools" do
    alias Clementine.Test.Tools.{Add, Echo, GatedDeploy}

    defmodule GetWeather do
      @moduledoc false
      use Clementine.Tool,
        name: "get_weather",
        description: "Get the weather at a specific location",
        parameters: [location: [type: :string, required: true]]

      @impl true
      def run(_args, _context), do: {:ok, "Sunny"}
    end

    test "stream/5 sends deferred tools with defer_loading, beside the tool search tool", %{
      bypass: bypass
    } do
      test = self()

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, Clementine.Test.Fixtures.sse_text_stream("ok"))
      end)

      :claude_test
      |> Anthropic.stream("system", [UserMessage.new("Hi")], [Echo, Add, GatedDeploy],
        deferred: [Add, GatedDeploy]
      )
      |> Stream.run()

      assert_received {:request, request}

      assert [
               %{
                 "type" => "tool_search_tool_regex_20251119",
                 "name" => "tool_search_tool_regex"
               } = search,
               %{"name" => "echo"} = echo,
               %{"name" => "add", "defer_loading" => true, "input_schema" => %{}},
               %{"name" => "gated_deploy", "defer_loading" => true, "description" => _}
             ] = request["tools"]

      refute Map.has_key?(search, "defer_loading")
      refute Map.has_key?(echo, "defer_loading")
    end

    test "call/5 without deferred tools sends neither the search tool nor defer_loading", %{
      bypass: bypass
    } do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert [%{"name" => "echo"} = echo, %{"name" => "add"} = add] = request["tools"]
        refute Map.has_key?(echo, "defer_loading")
        refute Map.has_key?(add, "defer_loading")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("ok"))
      end)

      assert {:ok, %Response{}} =
               Anthropic.call(:claude_test, "system", [UserMessage.new("Hi")], [Echo, Add],
                 deferred: []
               )
    end

    test "a model released before tool search gets its deferred tools as ordinary tools", %{
      bypass: bypass
    } do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["model"] == "claude-opus-4-1"
        assert [%{"name" => "echo"} = echo, %{"name" => "add"} = add] = request["tools"]
        refute Map.has_key?(echo, "defer_loading")
        refute Map.has_key?(add, "defer_loading")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("ok"))
      end)

      model = {:anthropic, "claude-opus-4-1"}
      messages = [UserMessage.new("Hi")]

      assert {:ok, %Response{}} =
               Anthropic.call(model, "system", messages, [Echo, Add], deferred: [Add])
    end

    test "tool search is for every model but those released before it" do
      for id <-
            ~w(claude-opus-4-0 claude-opus-4-1 claude-opus-4-20250514 claude-opus-4-1-20250805
               claude-sonnet-4-0 claude-sonnet-4-20250514 claude-3-7-sonnet-20250219
               claude-3-5-haiku-20241022 claude-3-opus-20240229 claude-2.1 claude-instant-1.2) do
        refute Anthropic.Tools.searchable?(id), id
      end

      for id <-
            ~w(claude-opus-4-5-20251101 claude-sonnet-4-5-20250929 claude-haiku-4-5
               claude-haiku-4-5-20251001 claude-opus-4-6 claude-sonnet-4-6 claude-opus-4-7
               claude-opus-4-8 claude-sonnet-5 claude-sonnet-5-5 claude-opus-5 claude-opus-5-5
               claude-haiku-5-5 claude-fable-5 claude-fable-5-1 claude-mythos-5-1) do
        assert Anthropic.Tools.searchable?(id), id
      end
    end

    test "a request without the search tool leaves past searches out of history", %{
      bypass: bypass
    } do
      test = self()

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("ok"))
      end)

      # No deferred tool left on a model with tool search, then deferred
      # tools on a model without it: neither request carries the search
      # tool, so neither may replay a search.
      Anthropic.call(:claude_test, "system", searched_history(), [Echo])

      Anthropic.call({:anthropic, "claude-opus-4-1"}, "system", searched_history(), [Echo, Add],
        deferred: [Add]
      )

      for _request <- 1..2 do
        assert_received {:request, request}
        refute Enum.any?(request["tools"], &Map.has_key?(&1, "type"))

        assert [
                 %{"role" => "user"},
                 %{"role" => "assistant", "content" => [%{"type" => "text"}]},
                 %{"role" => "user", "content" => "Next?"},
                 %{
                   "role" => "assistant",
                   "content" => [
                     %{"type" => "text"},
                     %{"type" => "text"},
                     %{"type" => "tool_use", "name" => "echo"}
                   ]
                 },
                 %{"role" => "user", "content" => [%{"type" => "tool_result"}]}
               ] = request["messages"]
      end
    end

    test "a request with the search tool replays only references to tools it carries", %{
      bypass: bypass
    } do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert [_user, _searched_only, _nothing_found, _next, %{"content" => content}, _results] =
                 request["messages"]

        assert [
                 %{"type" => "text"},
                 %{"type" => "server_tool_use", "id" => "srvtoolu_2"},
                 %{
                   "type" => "tool_search_tool_result",
                   "tool_use_id" => "srvtoolu_2",
                   "content" => %{
                     "type" => "tool_search_tool_search_result",
                     "tool_references" => [%{"type" => "tool_reference", "tool_name" => "echo"}]
                   }
                 },
                 %{"type" => "text"},
                 %{"type" => "tool_use"}
               ] = content

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("ok"))
      end)

      # "issue_refund" left the agent since the search found it.
      assert {:ok, %Response{}} =
               Anthropic.call(:claude_test, "system", searched_history(), [Add, Echo],
                 deferred: [Echo]
               )
    end

    test "stream/5 collects a tool search turn in the order the API sent it", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, Clementine.Test.Fixtures.sse_tool_search_stream())
      end)

      assert {:ok, %Response{stop_reason: "tool_use", content: content}} =
               :claude_test
               |> Anthropic.stream("system", [UserMessage.new("Weather in SF?")], [Echo, Add],
                 deferred: [Add]
               )
               |> Clementine.LLM.collect_stream()

      assert [
               %Content.Text{},
               %Content.ServerToolUse{id: "srvtoolu_01ABC123", input: %{"pattern" => "weather"}},
               %Content.ServerToolResult{
                 tool_use_id: "srvtoolu_01ABC123",
                 block_type: "tool_search_tool_result"
               },
               %Content.Text{},
               %Content.ToolUse{id: "toolu_01XYZ789", name: "get_weather"}
             ] = content
    end

    test "call/5 parses a tool search turn's blocks in place", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(tool_search_response()))
      end)

      assert {:ok, %Response{} = response} =
               Anthropic.call(:claude_test, "system", [UserMessage.new("Weather?")], [Echo])

      assert [
               %Content.Text{text: "I'll search for tools to help with the weather information."},
               %Content.ServerToolUse{
                 id: "srvtoolu_01ABC123",
                 name: "tool_search_tool_regex",
                 input: %{"pattern" => "weather", "limit" => 10}
               },
               %Content.ServerToolResult{
                 tool_use_id: "srvtoolu_01ABC123",
                 block_type: "tool_search_tool_result"
               },
               %Content.Text{},
               %Content.ToolUse{id: "toolu_01XYZ789", name: "get_weather"}
             ] = response.content

      assert Clementine.LLM.get_tool_uses(response) == [List.last(response.content)]
    end

    test "call/5 replays a tool search turn exactly as the API sent it", %{bypass: bypass} do
      assistant_turn = %{"role" => "assistant", "content" => tool_search_response()["content"]}

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert [
                 %{"role" => "user", "content" => "Weather?"},
                 ^assistant_turn,
                 %{
                   "role" => "user",
                   "content" => [
                     %{
                       "type" => "tool_result",
                       "tool_use_id" => "toolu_01XYZ789",
                       "content" => "Sunny"
                     }
                   ]
                 }
               ] = request["messages"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("It's sunny."))
      end)

      assistant = Clementine.LLM.Anthropic.Messages.decode_assistant(assistant_turn)

      messages = [
        UserMessage.new("Weather?"),
        assistant,
        %ToolResultMessage{content: [Content.tool_result("toolu_01XYZ789", "Sunny")]}
      ]

      assert {:ok, %Response{}} =
               Anthropic.call(:claude_test, "system", messages, [Echo, GetWeather],
                 deferred: [GetWeather]
               )
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

  # A thread with two searches: one stored as a message of its own that
  # found nothing, and one that loaded "issue_refund" and "echo" and led
  # to a call of "echo".
  defp searched_history do
    references = fn names ->
      %{
        "type" => "tool_search_tool_search_result",
        "tool_references" => Enum.map(names, &%{"type" => "tool_reference", "tool_name" => &1})
      }
    end

    [
      UserMessage.new("Hi"),
      %AssistantMessage{
        content: [
          Content.server_tool_use("srvtoolu_1", "tool_search_tool_regex", %{"pattern" => "x"}),
          Content.server_tool_result("srvtoolu_1", "tool_search_tool_result", references.([]))
        ]
      },
      %AssistantMessage{content: [Content.text("Nothing found.")]},
      UserMessage.new("Next?"),
      %AssistantMessage{
        content: [
          Content.text("Searching."),
          Content.server_tool_use("srvtoolu_2", "tool_search_tool_regex", %{"pattern" => "e"}),
          Content.server_tool_result(
            "srvtoolu_2",
            "tool_search_tool_result",
            references.(["issue_refund", "echo"])
          ),
          Content.text("Found it."),
          Content.tool_use("toolu_1", "echo", %{"message" => "hi"})
        ]
      },
      %ToolResultMessage{content: [Content.tool_result("toolu_1", "Echo: hi")]}
    ]
  end

  # The response format of the Messages API's tool search documentation.
  defp tool_search_response do
    %{
      "role" => "assistant",
      "content" => [
        %{
          "type" => "text",
          "text" => "I'll search for tools to help with the weather information."
        },
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_01ABC123",
          "name" => "tool_search_tool_regex",
          "input" => %{"pattern" => "weather", "limit" => 10}
        },
        %{
          "type" => "tool_search_tool_result",
          "tool_use_id" => "srvtoolu_01ABC123",
          "content" => %{
            "type" => "tool_search_tool_search_result",
            "tool_references" => [%{"type" => "tool_reference", "tool_name" => "get_weather"}]
          }
        },
        %{
          "type" => "text",
          "text" => "I found a weather tool. Let me get the weather for San Francisco."
        },
        %{
          "type" => "tool_use",
          "id" => "toolu_01XYZ789",
          "name" => "get_weather",
          "input" => %{"location" => "San Francisco", "unit" => "fahrenheit"}
        }
      ],
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 30, "output_tokens" => 40}
    }
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
