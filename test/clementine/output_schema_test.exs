defmodule Clementine.OutputSchemaTest do
  @moduledoc """
  `output_schema:` on an agent: the final answer is JSON the engine
  decodes and checks, the run's tools stay free, and an agent without it
  answers in text as before. The durable path is in
  `Clementine.OutputSchemaDurableTest`.
  """
  use ExUnit.Case, async: true

  import Mox

  alias Clementine.{OutputSchema, Result, Rollout}
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}
  alias Clementine.Test.Tools.{Add, Echo}

  setup :verify_on_exit!

  @verdict %{
    "type" => "object",
    "properties" => %{
      "verdict" => %{"type" => "string", "enum" => ["pass", "fail"]},
      "score" => %{"type" => "integer"},
      "reasons" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "required" => ["verdict", "score", "reasons"],
    "additionalProperties" => false
  }

  defmodule Grader do
    @moduledoc false
    use Clementine.Agent,
      key: "output_schema_grader",
      model: :claude_sonnet,
      instructions: "Grade.",
      output_schema: %{
        type: :object,
        properties: %{verdict: %{type: :string}},
        required: [:verdict],
        additionalProperties: false
      }
  end

  describe "the agent" do
    test "takes output_schema: in both forms, as a schema with string keys" do
      expected = %{
        "type" => "object",
        "properties" => %{"verdict" => %{"type" => "string"}},
        "required" => ["verdict"],
        "additionalProperties" => false
      }

      assert %Clementine.Agent{output_schema: ^expected} = Grader.agent(nil)

      assert %Clementine.Agent{output_schema: @verdict} =
               Clementine.Agent.new(model: :claude_sonnet, output_schema: @verdict)

      assert %Clementine.Agent{output_schema: nil} = Clementine.Agent.new(model: :claude_sonnet)
    end

    test "refuses a schema whose answer is not an object, or that is not a schema" do
      assert_raise ArgumentError, ~r/root needs "type": "object"/, fn ->
        Clementine.Agent.new(model: :claude_sonnet, output_schema: %{"type" => "string"})
      end

      assert_raise ArgumentError, ~r/must be a JSON schema map/, fn ->
        Clementine.Agent.new(model: :claude_sonnet, output_schema: "verdict")
      end

      assert_raise ArgumentError, ~r/does not encode as JSON/, fn ->
        Clementine.Agent.new(model: :claude_sonnet, output_schema: %{"type" => {:object}})
      end
    end
  end

  describe "the run" do
    test "uses its tools freely, then completes with the decoded answer" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, tools, opts ->
        assert tools == [Echo, Add]
        assert opts[:output_schema] == @verdict
        tool_events("toolu_1", "echo", %{"message" => "rubric"})
      end)

      answer = ~s({"verdict": "pass", "score": 9, "reasons": ["clear", "sourced"]})

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, opts ->
        assert opts[:output_schema] == @verdict

        assert [
                 %UserMessage{},
                 %AssistantMessage{},
                 %ToolResultMessage{content: [%Content.ToolResult{content: "Echo: rubric"}]}
               ] = messages

        text_events(answer)
      end)

      assert {:ok, %Result.Completed{} = result} =
               Rollout.execute(rollout(tools: [Echo, Add], output_schema: @verdict))

      assert result.output == %{
               "verdict" => "pass",
               "score" => 9,
               "reasons" => ["clear", "sourced"]
             }

      # The transcript keeps the answer as the model wrote it.
      assert [_tool_turn, _results, %AssistantMessage{content: [%Content.Text{text: ^answer}]}] =
               result.messages
    end

    test "a final answer that does not match fails the run with :invalid_output" do
      expect_turn(text_events(~s({"verdict": "maybe", "score": "high"})))

      assert {:error, %Clementine.Error{} = error} =
               Rollout.execute(rollout(tools: [], output_schema: @verdict))

      assert %Clementine.Error{kind: :rollout, code: :invalid_output, retryable?: false} = error
      assert error.message =~ ~s(/verdict: expected one of ["pass","fail"])
      assert error.message =~ "/score: expected integer, got a string"
      assert error.message =~ ~s(/: missing required property "reasons")
      assert error.raw["output"] == ~s({"verdict": "maybe", "score": "high"})
    end

    test "a final answer that is not JSON fails the run, naming a cut-off answer as such" do
      expect_turn([
        {:text_delta, ~s({"verdict": "pa)},
        {:message_delta, %{"stop_reason" => "max_tokens"},
         %{"input_tokens" => 7, "output_tokens" => 3}}
      ])

      assert {:error, %Clementine.Error{code: :invalid_output} = error} =
               Rollout.execute(rollout(tools: [], output_schema: @verdict))

      assert error.message =~ "the answer is not JSON"
      assert error.message =~ "hit max_tokens"
      assert error.raw["stop_reason"] == "max_tokens"
    end

    test "prose before a tool search, then the JSON: the answer is what the turn wrote last" do
      json = ~s({"verdict": "pass", "score": 8, "reasons": ["on rubric"]})
      expect_turn(searched_turn("Let me find the rubric.", json, "end_turn"))

      assert {:ok, %Result.Completed{} = result} =
               Rollout.execute(rollout(tools: [Echo], output_schema: @verdict))

      assert result.output == %{"verdict" => "pass", "score" => 8, "reasons" => ["on rubric"]}

      assert [
               %AssistantMessage{
                 content: [
                   %Content.Text{text: "Let me find the rubric."},
                   %Content.ServerToolUse{id: "srvtoolu_1"},
                   %Content.ServerToolResult{tool_use_id: "srvtoolu_1"},
                   %Content.Text{text: ^json}
                 ]
               }
             ] = result.messages
    end

    test "a mismatch after a search fails, and raw keeps all of the turn's text" do
      expect_turn(searched_turn("Let me find the rubric.", ~s({"verdict": "pass"}), "end_turn"))

      assert {:error, %Clementine.Error{code: :invalid_output} = error} =
               Rollout.execute(rollout(tools: [Echo], output_schema: @verdict))

      assert error.message =~ ~s(/: missing required property "score")
      refute error.message =~ "not JSON"
      assert error.raw["output"] == ~s(Let me find the rubric.\n\n{"verdict": "pass"})
    end

    test "JSON the provider split across a paused turn and its continuation decodes whole" do
      expect_turn(searched_turn("Let me look.", ~s({"verdict": "pass", ), "pause_turn"))

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, opts ->
        assert opts[:output_schema] == @verdict
        assert [%UserMessage{}, %AssistantMessage{}] = messages
        text_events(~s("score": 7, "reasons": []}))
      end)

      assert {:ok, %Result.Completed{} = result} =
               Rollout.execute(rollout(tools: [Echo], output_schema: @verdict))

      assert result.output == %{"verdict" => "pass", "score" => 7, "reasons" => []}

      # One turn, one message: the continuation joined the paused turn.
      assert [%AssistantMessage{content: [_text, _search, _result, _head, _tail]}] =
               result.messages
    end

    test "fails as a Result.Failed through the runner" do
      expect_turn(text_events("I would rather not."))

      agent = Clementine.Agent.new(model: :claude_sonnet, output_schema: @verdict)

      assert {:error, %Result.Failed{error: %Clementine.Error{code: :invalid_output}}} =
               Clementine.run(agent, "Grade it.")
    end

    test "an agent without output_schema answers in text and sends no schema" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, opts ->
        refute Keyword.has_key?(opts, :output_schema)
        text_events(~s({"verdict": "pass"}))
      end)

      assert {:ok, %Result.Completed{output: ~s({"verdict": "pass"})}} =
               Rollout.execute(rollout(tools: []))
    end
  end

  describe "decode/3" do
    test "trims whitespace around the JSON and names an empty answer" do
      assert {:ok, %{"verdict" => "x"}} =
               OutputSchema.decode(%{"type" => "object"}, ~s(\n  {"verdict": "x"}\n))

      assert {:error, %Clementine.Error{message: message}} =
               OutputSchema.decode(%{"type" => "object"}, " \n", "refusal")

      assert message =~ "the answer is empty"
      assert message =~ "(the model refused)"
    end
  end

  describe "decode/3 on a turn's blocks" do
    test "a turn that ends on a block other than text has no answer; raw keeps its text" do
      blocks = [
        Content.text("Searching."),
        Content.server_tool_use("srvtoolu_1", "tool_search_tool_regex", %{"pattern" => "x"})
      ]

      assert {:error, %Clementine.Error{message: message, raw: raw}} =
               OutputSchema.decode(%{"type" => "object"}, blocks)

      assert message =~ "the answer is empty"
      assert raw["output"] == "Searching."
    end
  end

  describe "validate/2" do
    test "an answer of another type, at the root or below" do
      assert {:error, ["/: expected object, got an array"]} =
               OutputSchema.validate(%{"type" => "object"}, [1])

      schema = %{"type" => "object", "properties" => %{"items" => item_list()}}

      assert {:error, ["/items/1/name: expected string, got null"]} =
               OutputSchema.validate(schema, %{"items" => [%{"name" => "a"}, %{"name" => nil}]})
    end

    test "nullable types, and integers JSON wrote with a fraction of zero" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "note" => %{"type" => ["string", "null"]},
          "count" => %{"type" => "integer"}
        }
      }

      assert :ok = OutputSchema.validate(schema, %{"note" => nil, "count" => 3.0})

      assert {:error, ["/count: expected integer, got a number"]} =
               OutputSchema.validate(schema, %{"count" => 3.5})
    end

    test "additionalProperties: false refuses, a schema checks, and absent allows" do
      closed = %{"type" => "object", "additionalProperties" => false}
      typed = %{"type" => "object", "additionalProperties" => %{"type" => "integer"}}

      assert {:error, [~s(/: unexpected property "extra")]} =
               OutputSchema.validate(closed, %{"extra" => 1})

      assert {:error, ["/n: expected integer, got a string"]} =
               OutputSchema.validate(typed, %{"n" => "1"})

      assert :ok = OutputSchema.validate(%{"type" => "object"}, %{"extra" => 1})
    end

    test "const, anyOf, and allOf" do
      assert {:error, [~s(/: expected "yes")]} = OutputSchema.validate(%{"const" => "yes"}, "no")

      any = %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}]}
      assert :ok = OutputSchema.validate(any, 1)

      assert {:error, ["/: matches none of the 2 schemas in anyOf"]} =
               OutputSchema.validate(any, true)

      all = %{"allOf" => [%{"type" => "object", "required" => ["a"]}, %{"required" => ["b"]}]}

      assert {:error, [~s(/: missing required property "b")]} =
               OutputSchema.validate(all, %{"a" => 1})
    end

    test "$ref into the schema's own definitions, and one that leads nowhere" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "step" => %{"$ref" => "#/$defs/step"},
          "older" => %{"$ref" => "#/definitions/step"},
          "first" => %{"$ref" => "#/$defs/list/items"}
        },
        "$defs" => %{"step" => item(), "list" => item_list()},
        "definitions" => %{"step" => item()}
      }

      assert :ok =
               OutputSchema.validate(schema, %{
                 "step" => %{"name" => "a"},
                 "older" => %{"name" => "b"},
                 "first" => %{"name" => "c"}
               })

      assert {:error, ["/step/name: expected string, got an integer"]} =
               OutputSchema.validate(schema, %{"step" => %{"name" => 1}})

      assert {:error, [~s(/: the schema's $ref "#/$defs/gone" does not resolve)]} =
               OutputSchema.validate(%{"$ref" => "#/$defs/gone"}, %{})

      assert {:error, [~s(/: the schema's $ref "https://example.com/s" does not resolve)]} =
               OutputSchema.validate(%{"$ref" => "https://example.com/s"}, %{})
    end

    test "a recursive schema checks as deep as the answer goes, and a $ref loop is named" do
      tree = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "children" => %{"type" => "array", "items" => %{"$ref" => "#"}}
        }
      }

      answer = %{"name" => "a", "children" => [%{"name" => "b", "children" => [%{"name" => 3}]}]}

      assert {:error, ["/children/0/children/0/name: expected string, got an integer"]} =
               OutputSchema.validate(tree, answer)

      looped = %{"$defs" => %{"a" => %{"$ref" => "#/$defs/b"}, "b" => %{"$ref" => "#/$defs/a"}}}

      assert {:error, [~s(/: the schema's $ref "#/$defs/a" refers to itself)]} =
               OutputSchema.validate(Map.put(looped, "$ref", "#/$defs/a"), %{})
    end

    test "keys with a slash or a tilde are escaped in the path" do
      schema = %{"type" => "object", "properties" => %{"a/b~c" => %{"type" => "string"}}}

      assert {:error, ["/a~1b~0c: expected string, got a boolean"]} =
               OutputSchema.validate(schema, %{"a/b~c" => true})
    end
  end

  defp item do
    %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
  end

  defp item_list, do: %{"type" => "array", "items" => item()}

  defp rollout(opts) do
    agent =
      Clementine.Agent.new(
        model: :claude_sonnet,
        instructions: "test",
        tools: Keyword.fetch!(opts, :tools),
        output_schema: Keyword.get(opts, :output_schema)
      )

    Rollout.new(agent: agent, input: "go")
  end

  defp expect_turn(events) do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      events
    end)
  end

  defp tool_events(id, name, input) do
    [
      {:tool_use_start, id, name},
      {:input_json_delta, id, Jason.encode!(input)},
      {:content_block_stop, 0},
      {:message_delta, %{"stop_reason" => "tool_use"},
       %{"input_tokens" => 7, "output_tokens" => 3}}
    ]
  end

  # A final turn as the engine receives it from the Anthropic client: text,
  # a tool search the API ran, its result, then more text, ending with
  # `stop_reason`.
  defp searched_turn(prose, answer, stop_reason) do
    [
      {:content_block_start, 0, :text},
      {:text_delta, prose},
      {:content_block_stop, 0},
      {:content_block_start, 1, :server_tool_use},
      {:server_tool_use_start, "srvtoolu_1", "tool_search_tool_regex"},
      {:server_tool_input_delta, "srvtoolu_1", ~s({"pattern":"rubric"})},
      {:content_block_stop, 1},
      {:content_block_start, 2, :server_tool_result},
      {:server_tool_result,
       %{
         "type" => "tool_search_tool_result",
         "tool_use_id" => "srvtoolu_1",
         "content" => %{"type" => "tool_search_tool_search_result", "tool_references" => []}
       }},
      {:content_block_stop, 2},
      {:content_block_start, 3, :text},
      {:text_delta, answer},
      {:content_block_stop, 3},
      {:message_delta, %{"stop_reason" => stop_reason},
       %{"input_tokens" => 7, "output_tokens" => 3}}
    ]
  end

  defp text_events(text) do
    [
      {:text_delta, text},
      {:message_delta, %{"stop_reason" => "end_turn"},
       %{"input_tokens" => 7, "output_tokens" => 3}}
    ]
  end
end
