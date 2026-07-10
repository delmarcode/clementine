defmodule Clementine.LLM.ChatCompletionsStreamParserTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.ChatCompletionsStreamParser, as: Parser

  defp chunk(data), do: "data: " <> Jason.encode!(data) <> "\n\n"

  defp delta_chunk(delta, opts \\ []) do
    choice =
      %{"index" => 0, "delta" => delta}
      |> Map.put("finish_reason", Keyword.get(opts, :finish_reason))

    data = %{"choices" => [choice]}

    data =
      case Keyword.get(opts, :usage) do
        nil -> data
        usage -> Map.put(data, "usage", usage)
      end

    chunk(data)
  end

  defp parse_all(payloads) do
    {events, _state} =
      Enum.reduce(payloads, {[], Parser.new()}, fn payload, {events, state} ->
        {new_events, state} = Parser.parse(state, payload)
        {events ++ new_events, state}
      end)

    events
  end

  test "emits text deltas and closes on [DONE]" do
    events =
      parse_all([
        delta_chunk(%{"role" => "assistant", "content" => "Hel"}),
        delta_chunk(%{"content" => "lo"}, finish_reason: "stop", usage: %{"total_tokens" => 7}),
        "data: [DONE]\n\n"
      ])

    assert events == [
             {:text_delta, "Hel"},
             {:text_delta, "lo"},
             {:message_delta, %{"stop_reason" => "end_turn"}, %{"total_tokens" => 7}},
             {:message_stop}
           ]
  end

  test "buffers events split across data boundaries" do
    payload =
      delta_chunk(%{"content" => "Hello"}) <>
        delta_chunk(%{"content" => " world"}, finish_reason: "stop") <> "data: [DONE]\n\n"

    {first, second} = String.split_at(payload, div(byte_size(payload), 2) + 3)

    assert parse_all([first, second]) == [
             {:text_delta, "Hello"},
             {:text_delta, " world"},
             {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
             {:message_stop}
           ]
  end

  test "assembles a streamed tool call" do
    events =
      parse_all([
        delta_chunk(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call_1",
              "type" => "function",
              "function" => %{"name" => "echo", "arguments" => ""}
            }
          ]
        }),
        delta_chunk(%{
          "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => ~s({"message":)}}]
        }),
        delta_chunk(%{
          "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => ~s("hi"})}}]
        }),
        delta_chunk(%{}, finish_reason: "tool_calls"),
        "data: [DONE]\n\n"
      ])

    assert events == [
             {:tool_use_start, "call_1", "echo"},
             {:input_json_delta, "call_1", ~s({"message":)},
             {:input_json_delta, "call_1", ~s("hi"})},
             {:content_block_stop, 0},
             {:message_delta, %{"stop_reason" => "tool_use"}, %{}},
             {:message_stop}
           ]
  end

  test "tracks parallel tool calls by index and synthesizes missing ids" do
    events =
      parse_all([
        delta_chunk(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call_a",
              "function" => %{"name" => "echo", "arguments" => "{}"}
            },
            %{"index" => 1, "function" => %{"name" => "add", "arguments" => "{}"}}
          ]
        }),
        delta_chunk(%{}, finish_reason: "tool_calls"),
        "data: [DONE]\n\n"
      ])

    assert events == [
             {:tool_use_start, "call_a", "echo"},
             {:input_json_delta, "call_a", "{}"},
             {:tool_use_start, "tool_call_1", "add"},
             {:input_json_delta, "tool_call_1", "{}"},
             {:content_block_stop, 0},
             {:content_block_stop, 1},
             {:message_delta, %{"stop_reason" => "tool_use"}, %{}},
             {:message_stop}
           ]
  end

  test "parallel tool calls survive accumulation into a response" do
    alias Clementine.LLM.Message.Content
    alias Clementine.LLM.Response
    alias Clementine.LLM.StreamParser.Accumulator

    events =
      parse_all([
        delta_chunk(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call_a",
              "function" => %{"name" => "echo", "arguments" => ~s({"message":)}
            },
            %{"index" => 1, "id" => "call_b", "function" => %{"name" => "add", "arguments" => ""}}
          ]
        }),
        delta_chunk(%{
          "tool_calls" => [
            %{"index" => 1, "function" => %{"arguments" => ~s({"a":1,"b":2})}},
            %{"index" => 0, "function" => %{"arguments" => ~s("hi"})}}
          ]
        }),
        delta_chunk(%{}, finish_reason: "tool_calls"),
        "data: [DONE]\n\n"
      ])

    response =
      events
      |> Enum.reduce(Accumulator.new(), &Accumulator.process(&2, &1))
      |> Accumulator.to_response()

    assert %Response{
             stop_reason: "tool_use",
             content: [
               %Content.ToolUse{id: "call_a", name: "echo", input: %{"message" => "hi"}},
               %Content.ToolUse{id: "call_b", name: "add", input: %{"a" => 1, "b" => 2}}
             ]
           } = response
  end

  test "maps length finish_reason to max_tokens" do
    events =
      parse_all([
        delta_chunk(%{"content" => "truncat"}, finish_reason: "length"),
        "data: [DONE]\n\n"
      ])

    assert {:message_delta, %{"stop_reason" => "max_tokens"}, %{}} in events
  end

  test "passes through unknown finish_reasons" do
    events =
      parse_all([
        delta_chunk(%{"content" => "x"}, finish_reason: "content_filter"),
        "data: [DONE]\n\n"
      ])

    assert {:message_delta, %{"stop_reason" => "content_filter"}, %{}} in events
  end

  test "ignores SSE comment payloads" do
    assert parse_all([": OPENROUTER PROCESSING\n\n", ":\n\n"]) == []
  end

  test "emits errors for error chunks" do
    error = %{"code" => 402, "message" => "Insufficient credits"}
    assert parse_all([chunk(%{"error" => error})]) == [{:error, error}]
  end

  test "emits a parse error for malformed JSON" do
    assert [{:error, %{"type" => "stream_parse_error"}}] = parse_all(["data: {nope\n\n"])
  end

  test "a duplicate [DONE] sentinel emits nothing" do
    events =
      parse_all([
        delta_chunk(%{"content" => "hi"}, finish_reason: "stop"),
        "data: [DONE]\n\n",
        "data: [DONE]\n\n"
      ])

    assert Enum.count(events, &match?({:message_stop}, &1)) == 1
  end
end
