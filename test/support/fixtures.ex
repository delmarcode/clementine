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
        "content_block" => %{
          "type" => "tool_use",
          "id" => tool_id,
          "name" => tool_name,
          "input" => %{}
        }
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

  @doc """
  Returns SSE stream data for a turn in which Claude searches its deferred
  tools and calls the one it found, in the shape of the Messages API's
  tool search documentation: text, the `server_tool_use` search (its input
  streamed), the `tool_search_tool_result` (whole in its start event),
  more text, then the `tool_use` of the tool the search loaded.
  """
  def sse_tool_search_stream(opts \\ []) do
    search_id = Keyword.get(opts, :search_id, "srvtoolu_01ABC123")
    tool_id = Keyword.get(opts, :tool_id, "toolu_01XYZ789")
    tool_name = Keyword.get(opts, :tool_name, "get_weather")
    tool_input = Keyword.get(opts, :tool_input, %{"location" => "San Francisco"})

    events = [
      sse_event("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_#{random_id()}",
          "type" => "message",
          "role" => "assistant",
          "content" => [],
          "model" => "claude-sonnet-5",
          "usage" => %{"input_tokens" => 120, "output_tokens" => 1}
        }
      }),
      sse_event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      sse_event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "I'll search for a tool."}
      }),
      sse_event("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      sse_event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{
          "type" => "server_tool_use",
          "id" => search_id,
          "name" => "tool_search_tool_regex"
        }
      }),
      sse_event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"pattern\":"}
      }),
      sse_event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "\"weather\"}"}
      }),
      sse_event("content_block_stop", %{"type" => "content_block_stop", "index" => 1}),
      sse_event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 2,
        "content_block" => %{
          "type" => "tool_search_tool_result",
          "tool_use_id" => search_id,
          "content" => %{
            "type" => "tool_search_tool_search_result",
            "tool_references" => [%{"type" => "tool_reference", "tool_name" => tool_name}]
          }
        }
      }),
      sse_event("content_block_stop", %{"type" => "content_block_stop", "index" => 2}),
      sse_event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 3,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      sse_event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 3,
        "delta" => %{"type" => "text_delta", "text" => "Found one."}
      }),
      sse_event("content_block_stop", %{"type" => "content_block_stop", "index" => 3}),
      sse_event("content_block_start", %{
        "type" => "content_block_start",
        "index" => 4,
        "content_block" => %{
          "type" => "tool_use",
          "id" => tool_id,
          "name" => tool_name,
          "input" => %{}
        }
      }),
      sse_event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 4,
        "delta" => %{"type" => "input_json_delta", "partial_json" => Jason.encode!(tool_input)}
      }),
      sse_event("content_block_stop", %{"type" => "content_block_stop", "index" => 4}),
      sse_event("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 60}
      }),
      sse_event("message_stop", %{"type" => "message_stop"})
    ]

    Enum.join(events, "\n\n") <> "\n\n"
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
