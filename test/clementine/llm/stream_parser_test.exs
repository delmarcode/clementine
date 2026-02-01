defmodule Clementine.LLM.StreamParserTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.StreamParser
  alias Clementine.LLM.StreamParser.Accumulator

  describe "parse_event/1" do
    test "parses message_start event" do
      event = """
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-20250514"}}
      """

      events = StreamParser.parse_event(event)

      assert [{:message_start, message}] = events
      assert message["id"] == "msg_123"
      assert message["role"] == "assistant"
    end

    test "parses text content_block_start event" do
      event = """
      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
      """

      events = StreamParser.parse_event(event)

      assert [{:content_block_start, 0, :text}] = events
    end

    test "parses tool_use content_block_start event" do
      event = """
      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_123","name":"read_file","input":{}}}
      """

      events = StreamParser.parse_event(event)

      assert [{:content_block_start, 0, :tool_use}, {:tool_use_start, "toolu_123", "read_file"}] = events
    end

    test "parses text_delta event" do
      event = """
      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
      """

      events = StreamParser.parse_event(event)

      assert [{:text_delta, "Hello"}] = events
    end

    test "parses input_json_delta event" do
      event = """
      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":"}}
      """

      events = StreamParser.parse_event(event)

      assert [{:input_json_delta, "{\"path\":"}] = events
    end

    test "parses content_block_stop event" do
      event = """
      event: content_block_stop
      data: {"type":"content_block_stop","index":0}
      """

      events = StreamParser.parse_event(event)

      assert [{:content_block_stop, 0}] = events
    end

    test "parses message_delta event with stop_reason" do
      event = """
      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":50}}
      """

      events = StreamParser.parse_event(event)

      assert [{:message_delta, delta, usage}] = events
      assert delta["stop_reason"] == "end_turn"
      assert usage["output_tokens"] == 50
    end

    test "parses message_stop event" do
      event = """
      event: message_stop
      data: {"type":"message_stop"}
      """

      events = StreamParser.parse_event(event)

      assert [{:message_stop}] = events
    end

    test "parses ping event" do
      event = """
      event: ping
      data: {"type":"ping"}
      """

      events = StreamParser.parse_event(event)

      assert [{:ping}] = events
    end

    test "parses error event" do
      event = """
      event: error
      data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
      """

      events = StreamParser.parse_event(event)

      assert [{:error, error}] = events
      assert error["type"] == "overloaded_error"
    end

    test "returns empty list for empty string" do
      assert [] = StreamParser.parse_event("")
    end

    test "returns empty list for unknown event type" do
      event = """
      event: unknown_event
      data: {"type":"unknown"}
      """

      assert [] = StreamParser.parse_event(event)
    end
  end

  describe "parse/2 with state" do
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
        |> Accumulator.process({:input_json_delta, "{\"path\":"})
        |> Accumulator.process({:input_json_delta, "\"test.txt\"}"})
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
        |> Accumulator.process({:message_delta, %{"stop_reason" => "end_turn"}, %{"output_tokens" => 50}})

      assert acc.stop_reason == "end_turn"
      assert acc.usage["output_tokens"] == 50
    end

    test "to_response builds complete response with text" do
      acc =
        Accumulator.new()
        |> Accumulator.process({:text_delta, "Hello World"})
        |> Accumulator.process({:message_delta, %{"stop_reason" => "end_turn"}, %{}})

      response = Accumulator.to_response(acc)

      assert response.stop_reason == "end_turn"
      assert [%{type: :text, text: "Hello World"}] = response.content
    end

    test "to_response builds complete response with tool use" do
      acc =
        Accumulator.new()
        |> Accumulator.process({:tool_use_start, "toolu_123", "read_file"})
        |> Accumulator.process({:input_json_delta, "{\"path\":\"test.txt\"}"})
        |> Accumulator.process({:content_block_stop, 0})
        |> Accumulator.process({:message_delta, %{"stop_reason" => "tool_use"}, %{}})

      response = Accumulator.to_response(acc)

      assert response.stop_reason == "tool_use"
      assert [%{type: :tool_use, id: "toolu_123", name: "read_file", input: %{"path" => "test.txt"}}] =
               response.content
    end

    test "to_response handles mixed text and tool use" do
      acc =
        Accumulator.new()
        |> Accumulator.process({:text_delta, "Let me read that file"})
        |> Accumulator.process({:content_block_stop, 0})
        |> Accumulator.process({:tool_use_start, "toolu_123", "read_file"})
        |> Accumulator.process({:input_json_delta, "{\"path\":\"test.txt\"}"})
        |> Accumulator.process({:content_block_stop, 1})

      response = Accumulator.to_response(acc)

      assert length(response.content) == 2
      assert Enum.at(response.content, 0).type == :text
      assert Enum.at(response.content, 1).type == :tool_use
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
end
