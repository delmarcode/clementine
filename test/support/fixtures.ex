defmodule Clementine.Test.Fixtures do
  @moduledoc """
  Test fixtures for Clementine tests.
  """

  @doc """
  Returns a sample Anthropic API response with text content.
  """
  def anthropic_text_response(text \\ "Hello, I'm Claude!") do
    %{
      "id" => "msg_#{random_id()}",
      "type" => "message",
      "role" => "assistant",
      "content" => [
        %{"type" => "text", "text" => text}
      ],
      "model" => "claude-sonnet-4-20250514",
      "stop_reason" => "end_turn",
      "stop_sequence" => nil,
      "usage" => %{
        "input_tokens" => 100,
        "output_tokens" => 50
      }
    }
  end

  @doc """
  Returns a sample Anthropic API response with tool use.
  """
  def anthropic_tool_use_response(tool_name, tool_input) do
    %{
      "id" => "msg_#{random_id()}",
      "type" => "message",
      "role" => "assistant",
      "content" => [
        %{
          "type" => "tool_use",
          "id" => "toolu_#{random_id()}",
          "name" => tool_name,
          "input" => tool_input
        }
      ],
      "model" => "claude-sonnet-4-20250514",
      "stop_reason" => "tool_use",
      "stop_sequence" => nil,
      "usage" => %{
        "input_tokens" => 100,
        "output_tokens" => 50
      }
    }
  end

  @doc """
  Returns sample SSE stream data for a text response.
  """
  def sse_text_stream(text) do
    chunks = chunk_text(text, 10)

    events = [
      sse_event("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_#{random_id()}",
          "type" => "message",
          "role" => "assistant",
          "content" => [],
          "model" => "claude-sonnet-4-20250514"
        }
      }),
      sse_event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      })
    ]

    text_deltas =
      Enum.map(chunks, fn chunk ->
        sse_event("content_block_delta", %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => chunk}
        })
      end)

    ending = [
      sse_event("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      sse_event("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 50}
      }),
      sse_event("message_stop", %{"type" => "message_stop"})
    ]

    Enum.join(events ++ text_deltas ++ ending, "\n\n")
  end

  @doc """
  Returns sample SSE stream data for a tool use response.
  """
  def sse_tool_use_stream(tool_name, tool_input) do
    tool_id = "toolu_#{random_id()}"
    input_json = Jason.encode!(tool_input)
    input_chunks = chunk_text(input_json, 20)

    events = [
      sse_event("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_#{random_id()}",
          "type" => "message",
          "role" => "assistant",
          "content" => [],
          "model" => "claude-sonnet-4-20250514"
        }
      }),
      sse_event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => tool_id, "name" => tool_name, "input" => %{}}
      })
    ]

    input_deltas =
      Enum.map(input_chunks, fn chunk ->
        sse_event("content_block_delta", %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => chunk}
        })
      end)

    ending = [
      sse_event("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      sse_event("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 50}
      }),
      sse_event("message_stop", %{"type" => "message_stop"})
    ]

    Enum.join(events ++ input_deltas ++ ending, "\n\n")
  end

  # Helper functions

  defp random_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end

  defp sse_event(event_type, data) do
    "event: #{event_type}\ndata: #{Jason.encode!(data)}"
  end

  defp chunk_text(text, size) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end
end
