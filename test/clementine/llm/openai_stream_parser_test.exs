defmodule Clementine.LLM.OpenAIStreamParserTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.OpenAIStreamParser

  test "emits parse error for malformed event JSON" do
    data = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":

    """

    {events, _state} = OpenAIStreamParser.parse(OpenAIStreamParser.new(), data)

    assert [
             {:error,
              %{
                "type" => "stream_parse_error",
                "message" => "Malformed SSE JSON",
                "reason" => reason
              }}
           ] = events

    assert is_binary(reason)
  end

  test "continues ignoring the OpenAI done sentinel" do
    data = "data: [DONE]\n\n"

    assert {[], _state} = OpenAIStreamParser.parse(OpenAIStreamParser.new(), data)
  end

  defp sse(type, data),
    do: "event: #{type}\ndata: #{Jason.encode!(Map.put(data, "type", type))}\n\n"

  defp parse_all(payloads) do
    {events, _state} =
      Enum.reduce(payloads, {[], OpenAIStreamParser.new()}, fn payload, {events, state} ->
        {new_events, state} = OpenAIStreamParser.parse(state, payload)
        {events ++ new_events, state}
      end)

    events
  end

  test "a refusal streams as the turn's text and stops with refusal" do
    refusal = %{"type" => "refusal", "refusal" => "I can't help with that."}

    events =
      parse_all([
        sse("response.refusal.delta", %{"item_id" => "msg_1", "delta" => "I can't "}),
        sse("response.refusal.delta", %{"item_id" => "msg_1", "delta" => "help with that."}),
        sse("response.refusal.done", %{
          "item_id" => "msg_1",
          "refusal" => "I can't help with that."
        }),
        sse("response.completed", %{
          "response" => %{
            "status" => "completed",
            "output" => [%{"type" => "message", "content" => [refusal]}],
            "usage" => %{"input_tokens" => 5, "output_tokens" => 6}
          }
        })
      ])

    assert events == [
             {:text_delta, "I can't "},
             {:text_delta, "help with that."},
             {:message_delta, %{"stop_reason" => "refusal"},
              %{
                "input_tokens" => 5,
                "output_tokens" => 6,
                "cache_read_tokens" => 0,
                "cache_write_tokens" => 0
              }},
             {:message_stop}
           ]
  end

  test "a response cut off at max_output_tokens stops with max_tokens" do
    events =
      parse_all([
        sse("response.output_text.delta", %{"delta" => ~s({"verdict": "pa)}),
        sse("response.incomplete", %{
          "response" => %{
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => "max_output_tokens"},
            "output" => [],
            "usage" => %{"input_tokens" => 5, "output_tokens" => 8}
          }
        })
      ])

    assert events == [
             {:text_delta, ~s({"verdict": "pa)},
             {:message_delta, %{"stop_reason" => "max_tokens"},
              %{
                "input_tokens" => 5,
                "output_tokens" => 8,
                "cache_read_tokens" => 0,
                "cache_write_tokens" => 0
              }},
             {:message_stop}
           ]

    assert [{:message_delta, %{"stop_reason" => "content_filter"}, %{}}, {:message_stop}] =
             parse_all([
               sse("response.incomplete", %{
                 "response" => %{
                   "status" => "incomplete",
                   "incomplete_details" => %{"reason" => "content_filter"}
                 }
               })
             ])
  end

  test "an incomplete response's unfinished call is no tool use: the turn stops on its cut" do
    unfinished = %{"type" => "function_call", "call_id" => "call_1", "name" => "echo"}

    assert [{:message_delta, %{"stop_reason" => "max_tokens"}, _usage}, {:message_stop}] =
             parse_all([
               sse("response.output_item.added", %{"output_index" => 0, "item" => unfinished}),
               sse("response.incomplete", %{
                 "response" => %{
                   "status" => "incomplete",
                   "incomplete_details" => %{"reason" => "max_output_tokens"},
                   "output" => [unfinished]
                 }
               })
             ])
             |> Enum.reject(&match?({:tool_use_start, _, _}, &1))
  end

  test "a refusal beats the turn's calls, streamed or not, so none runs" do
    call = %{
      "type" => "function_call",
      "id" => "fc_1",
      "call_id" => "call_1",
      "name" => "echo",
      "arguments" => ~s({"message":"hi"}),
      "status" => "completed"
    }

    refusal = %{"type" => "message", "content" => [%{"type" => "refusal", "refusal" => "No."}]}

    events =
      parse_all([
        sse("response.refusal.delta", %{"item_id" => "msg_1", "delta" => "No."}),
        sse("response.output_item.done", %{"output_index" => 1, "item" => call}),
        sse("response.completed", %{
          "response" => %{"status" => "completed", "output" => [refusal, call]}
        })
      ])

    assert {:message_delta, %{"stop_reason" => "refusal"}, _usage} = Enum.at(events, -2)
  end

  test "a content filter beats the calls that closed before it" do
    call = %{
      "type" => "function_call",
      "id" => "fc_1",
      "call_id" => "call_1",
      "name" => "echo",
      "arguments" => "{}",
      "status" => "completed"
    }

    events =
      parse_all([
        sse("response.output_item.done", %{"output_index" => 0, "item" => call}),
        sse("response.incomplete", %{
          "response" => %{
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => "content_filter"},
            "output" => [call]
          }
        })
      ])

    assert {:message_delta, %{"stop_reason" => "content_filter"}, _usage} = Enum.at(events, -2)
  end

  test "a call whose item ends incomplete never closes, so a cut inside it fails the turn" do
    alias Clementine.LLM.StreamParser.Accumulator

    whole = %{
      "type" => "function_call",
      "id" => "fc_1",
      "call_id" => "call_1",
      "name" => "echo",
      "arguments" => ~s({"message":"hi"}),
      "status" => "completed"
    }

    cut = %{
      "type" => "function_call",
      "id" => "fc_2",
      "call_id" => "call_2",
      "name" => "echo",
      "arguments" => ~s({"message":"hel),
      "status" => "incomplete"
    }

    events =
      parse_all([
        sse("response.output_item.done", %{"output_index" => 0, "item" => whole}),
        sse("response.output_item.done", %{"output_index" => 1, "item" => cut}),
        sse("response.incomplete", %{
          "response" => %{
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => "max_output_tokens"},
            "output" => [whole, cut]
          }
        })
      ])

    # It stops on its cut, not on the call that closed before it.
    assert {:content_block_stop, 0} in events
    refute {:content_block_stop, 1} in events
    assert {:message_delta, %{"stop_reason" => "max_tokens"}, _usage} = Enum.at(events, -2)
    acc = Enum.reduce(events, Accumulator.new(), &Accumulator.process(&2, &1))
    assert %{"tool_use_id" => "call_2"} = Accumulator.unfinished_call(acc)
  end

  test "any other incomplete response stops with incomplete, which fails a final turn" do
    for reason <- ["max_messages", "steered", nil] do
      response = %{"status" => "incomplete", "incomplete_details" => %{"reason" => reason}}
      assert Clementine.LLM.OpenAIStreamParser.incomplete_reason(response) == "incomplete"
    end

    assert Clementine.LLM.OpenAIStreamParser.incomplete_reason(%{"status" => "completed"}) ==
             "end_turn"
  end

  test "a failed response is an error, not an empty answer" do
    error = %{"code" => "server_error", "message" => "The model failed."}

    assert [{:error, ^error}] =
             parse_all([
               sse("response.failed", %{"response" => %{"status" => "failed", "error" => error}})
             ])

    assert [{:error, %{"message" => "The response failed without an error."}}] =
             parse_all([sse("response.failed", %{"response" => %{"status" => "failed"}})])
  end
end
