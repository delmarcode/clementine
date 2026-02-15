defmodule Clementine.LLM.StreamParserTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Response
  alias Clementine.LLM.StreamParser
  alias Clementine.LLM.StreamParser.Accumulator

  # Helper: parse a single SSE event through the stateful parser
  defp parse_one(event_str) do
    data = String.trim(event_str) <> "\n\n"
    {events, _state} = StreamParser.parse(StreamParser.new(), data)
    events
  end

  describe "parse/2 event parsing" do
    test "parses message_start event" do
      events =
        parse_one("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-20250514"}}
        """)

      assert [{:message_start, message}] = events
      assert message["id"] == "msg_123"
      assert message["role"] == "assistant"
    end

    test "parses text content_block_start event" do
      events =
        parse_one("""
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        """)

      assert [{:content_block_start, 0, :text}] = events
    end

    test "parses tool_use content_block_start event" do
      events =
        parse_one("""
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_123","name":"read_file","input":{}}}
        """)

      assert [{:content_block_start, 0, :tool_use}, {:tool_use_start, "toolu_123", "read_file"}] =
               events
    end

    test "parses text_delta event" do
      events =
        parse_one("""
        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
        """)

      assert [{:text_delta, "Hello"}] = events
    end

    test "parses input_json_delta event with tool ID from prior state" do
      state = StreamParser.new()

      # First: tool_use_start sets the tool ID in state
      tool_start =
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_123\",\"name\":\"read_file\",\"input\":{}}}\n\n"

      {_, state} = StreamParser.parse(state, tool_start)

      # Then: input_json_delta is enriched with that tool ID
      json_delta =
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\"}}\n\n"

      {events, _state} = StreamParser.parse(state, json_delta)

      assert [{:input_json_delta, "toolu_123", "{\"path\":"}] = events
    end

    test "parses content_block_stop event" do
      events =
        parse_one("""
        event: content_block_stop
        data: {"type":"content_block_stop","index":0}
        """)

      assert [{:content_block_stop, 0}] = events
    end

    test "parses message_delta event with stop_reason" do
      events =
        parse_one("""
        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":50}}
        """)

      assert [{:message_delta, delta, usage}] = events
      assert delta["stop_reason"] == "end_turn"
      assert usage["output_tokens"] == 50
    end

    test "parses message_stop event" do
      events =
        parse_one("""
        event: message_stop
        data: {"type":"message_stop"}
        """)

      assert [{:message_stop}] = events
    end

    test "parses ping event" do
      events =
        parse_one("""
        event: ping
        data: {"type":"ping"}
        """)

      assert [{:ping}] = events
    end

    test "parses error event" do
      events =
        parse_one("""
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
        """)

      assert [{:error, error}] = events
      assert error["type"] == "overloaded_error"
    end

    test "returns empty list for empty data" do
      {events, _state} = StreamParser.parse(StreamParser.new(), "")
      assert events == []
    end

    test "returns empty list for unknown event type" do
      events =
        parse_one("""
        event: unknown_event
        data: {"type":"unknown"}
        """)

      assert events == []
    end
  end

  describe "parse/2 buffering and sequencing" do
    test "handles complete events" do
      state = StreamParser.new()

      data = """
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_123","role":"assistant","content":[]}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      """

      {events, _state} = StreamParser.parse(state, data)

      assert length(events) == 2
      assert {:message_start, _} = Enum.at(events, 0)
      assert {:content_block_start, 0, :text} = Enum.at(events, 1)
    end

    test "buffers incomplete events" do
      state = StreamParser.new()

      # First chunk - incomplete
      data1 = "event: message_start\ndata: {\"type\":\"mess"
      {events1, state} = StreamParser.parse(state, data1)
      assert events1 == []

      # Second chunk - completes the event
      data2 = "age_start\",\"message\":{\"id\":\"msg_123\"}}\n\n"
      {events2, _state} = StreamParser.parse(state, data2)

      assert [{:message_start, message}] = events2
      assert message["id"] == "msg_123"
    end

    test "handles multiple events in sequence" do
      state = StreamParser.new()

      data1 = """
      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

      """

      {events1, state} = StreamParser.parse(state, data1)
      assert [{:text_delta, "Hello"}] = events1

      data2 = """
      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" World"}}

      """

      {events2, _state} = StreamParser.parse(state, data2)
      assert [{:text_delta, " World"}] = events2
    end
  end

  describe "parse/2 tool ID enrichment" do
    test "attaches tool ID to input_json_delta events" do
      state = StreamParser.new()

      data =
        sse_event("content_block_start", %{
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_abc",
            "name" => "bash",
            "input" => %{}
          }
        }) <>
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"cmd\":"}
          }) <>
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "\"ls\"}"}
          })

      {events, _state} = StreamParser.parse(state, data)

      assert [
               {:content_block_start, 0, :tool_use},
               {:tool_use_start, "toolu_abc", "bash"},
               {:input_json_delta, "toolu_abc", "{\"cmd\":"},
               {:input_json_delta, "toolu_abc", "\"ls\"}"}
             ] = events
    end

    test "resets tool ID after content_block_stop" do
      state = StreamParser.new()

      data =
        sse_event("content_block_start", %{
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "bash",
            "input" => %{}
          }
        }) <>
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"cmd\":\"ls\"}"}
          }) <>
          sse_event("content_block_stop", %{"index" => 0})

      {events, state} = StreamParser.parse(state, data)

      assert [
               {:content_block_start, 0, :tool_use},
               {:tool_use_start, "toolu_1", "bash"},
               {:input_json_delta, "toolu_1", "{\"cmd\":\"ls\"}"},
               {:content_block_stop, 0}
             ] = events

      # After stop, a new input_json_delta would get nil (no active tool)
      delta_data =
        sse_event("content_block_delta", %{
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "orphan"}
        })

      {events2, _state} = StreamParser.parse(state, delta_data)

      assert [{:input_json_delta, nil, "orphan"}] = events2
    end

    test "tracks tool IDs across multiple sequential tool blocks" do
      state = StreamParser.new()

      # First tool block
      data1 =
        sse_event("content_block_start", %{
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "read_file",
            "input" => %{}
          }
        }) <>
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":\"a.txt\"}"}
          }) <>
          sse_event("content_block_stop", %{"index" => 0})

      {events1, state} = StreamParser.parse(state, data1)

      assert {:input_json_delta, "toolu_1", _} = Enum.at(events1, 2)

      # Second tool block with different ID
      data2 =
        sse_event("content_block_start", %{
          "index" => 1,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_2",
            "name" => "write_file",
            "input" => %{}
          }
        }) <>
          sse_event("content_block_delta", %{
            "index" => 1,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":\"b.txt\"}"}
          }) <>
          sse_event("content_block_stop", %{"index" => 1})

      {events2, _state} = StreamParser.parse(state, data2)

      assert {:input_json_delta, "toolu_2", _} = Enum.at(events2, 2)
    end

    test "enriches tool ID across chunk boundaries" do
      state = StreamParser.new()

      # First chunk: tool_use_start
      chunk1 =
        sse_event("content_block_start", %{
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_split",
            "name" => "bash",
            "input" => %{}
          }
        })

      {_events, state} = StreamParser.parse(state, chunk1)

      # Second chunk: input_json_delta arrives in a separate parse call
      chunk2 =
        sse_event("content_block_delta", %{
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"cmd\":\"echo hi\"}"}
        })

      {events, _state} = StreamParser.parse(state, chunk2)

      assert [{:input_json_delta, "toolu_split", "{\"cmd\":\"echo hi\"}"}] = events
    end
  end

  describe "Accumulator" do
    test "accumulates text deltas" do
      acc =
        Accumulator.new()
        |> Accumulator.process({:text_delta, "Hello"})
        |> Accumulator.process({:text_delta, " "})
        |> Accumulator.process({:text_delta, "World"})

      assert acc.text == "Hello World"
    end

    test "accumulates tool uses" do
      acc =
        Accumulator.new()
        |> Accumulator.process({:tool_use_start, "toolu_123", "read_file"})
        |> Accumulator.process({:input_json_delta, "toolu_123", "{\"path\":"})
        |> Accumulator.process({:input_json_delta, "toolu_123", "\"test.txt\"}"})
        |> Accumulator.process({:content_block_stop, 0})

      assert length(acc.tool_uses) == 1
      [tool] = acc.tool_uses
      assert tool.id == "toolu_123"
      assert tool.name == "read_file"
      assert tool.input == %{"path" => "test.txt"}
    end

    test "tracks stop_reason and usage" do
      acc =
        Accumulator.new()
        |> Accumulator.process(
          {:message_delta, %{"stop_reason" => "end_turn"}, %{"output_tokens" => 50}}
        )

      assert acc.stop_reason == "end_turn"
      assert acc.usage["output_tokens"] == 50
    end

    test "to_response builds complete response with text" do
      acc =
        Accumulator.new()
        |> Accumulator.process({:text_delta, "Hello World"})
        |> Accumulator.process({:message_delta, %{"stop_reason" => "end_turn"}, %{}})

      response = Accumulator.to_response(acc)

      assert %Response{stop_reason: "end_turn"} = response
      assert [%Content{type: :text, text: "Hello World"}] = response.content
    end

    test "to_response builds complete response with tool use" do
      acc =
        Accumulator.new()
        |> Accumulator.process({:tool_use_start, "toolu_123", "read_file"})
        |> Accumulator.process({:input_json_delta, "toolu_123", "{\"path\":\"test.txt\"}"})
        |> Accumulator.process({:content_block_stop, 0})
        |> Accumulator.process({:message_delta, %{"stop_reason" => "tool_use"}, %{}})

      response = Accumulator.to_response(acc)

      assert %Response{stop_reason: "tool_use"} = response

      assert [
               %Content{
                 type: :tool_use,
                 id: "toolu_123",
                 name: "read_file",
                 input: %{"path" => "test.txt"}
               }
             ] =
               response.content
    end

    test "to_response handles mixed text and tool use" do
      acc =
        Accumulator.new()
        |> Accumulator.process({:text_delta, "Let me read that file"})
        |> Accumulator.process({:content_block_stop, 0})
        |> Accumulator.process({:tool_use_start, "toolu_123", "read_file"})
        |> Accumulator.process({:input_json_delta, "toolu_123", "{\"path\":\"test.txt\"}"})
        |> Accumulator.process({:content_block_stop, 1})

      response = Accumulator.to_response(acc)

      assert %Response{} = response
      assert length(response.content) == 2
      assert %Content{type: :text} = Enum.at(response.content, 0)
      assert %Content{type: :tool_use} = Enum.at(response.content, 1)
    end

    test "captures error event" do
      error = %{"type" => "overloaded_error", "message" => "Overloaded"}

      acc =
        Accumulator.new()
        |> Accumulator.process({:text_delta, "partial"})
        |> Accumulator.process({:error, error})

      assert Accumulator.error?(acc)
      assert acc.error == error
    end

    test "only captures the first error" do
      first_error = %{"type" => "overloaded_error", "message" => "Overloaded"}
      second_error = %{"type" => "api_error", "message" => "Server error"}

      acc =
        Accumulator.new()
        |> Accumulator.process({:error, first_error})
        |> Accumulator.process({:error, second_error})

      assert Accumulator.error?(acc)
      assert acc.error == first_error
    end

    test "error?/1 returns false for accumulator without error" do
      acc = Accumulator.new()
      refute Accumulator.error?(acc)
    end
  end

  # Helper: build a terminated SSE event string from type and data map
  defp sse_event(type, data) do
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end
end
