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
end
