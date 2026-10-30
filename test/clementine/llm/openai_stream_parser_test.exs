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
              %{"input_tokens" => 5, "output_tokens" => 6}},
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
              %{"input_tokens" => 5, "output_tokens" => 8}},
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
