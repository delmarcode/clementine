defmodule Clementine.CheckpointTest do
  use ExUnit.Case, async: true

  alias Clementine.{Checkpoint, Error, Pending, ToolResult, Usage}
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}
  alias Clementine.Pending.ToolApproval

  defp full_checkpoint do
    %Checkpoint{
      rollout_id: "rollout_abc",
      iteration: 3,
      messages: [
        UserMessage.new("delete the stale records"),
        AssistantMessage.new([
          Content.text("I'll check first."),
          Content.tool_use("tu_read", "read_file", %{"path" => "records.csv"})
        ]),
        %ToolResultMessage{content: [Content.tool_result("tu_read", "42 rows", false)]},
        AssistantMessage.new([
          Content.tool_use("tu_del", "delete_records", %{"count" => 42}),
          Content.tool_use("tu_log", "append_log", %{"line" => "deleting"})
        ])
      ],
      pending: %ToolApproval{
        tool_use_id: "tu_del",
        tool_name: "delete_records",
        args: %{"count" => 42},
        completed_results: %{
          "tu_log" => %ToolResult{content: "logged", is_error: false}
        }
      },
      usage: %Usage{input_tokens: 1200, output_tokens: 340},
      cursor: {2, 57}
    }
  end

  test "encode/decode round-trips through JSON, canonical messages included" do
    checkpoint = full_checkpoint()

    assert {:ok, decoded} =
             checkpoint
             |> Checkpoint.encode()
             |> Jason.encode!()
             |> Jason.decode!()
             |> Checkpoint.decode()

    assert decoded == checkpoint
  end

  test "a minimal checkpoint (no pending, no cursor) round-trips" do
    checkpoint = %Checkpoint{rollout_id: "r1"}

    assert {:ok, decoded} =
             checkpoint
             |> Checkpoint.encode()
             |> Jason.encode!()
             |> Jason.decode!()
             |> Checkpoint.decode()

    assert decoded == checkpoint
    assert decoded.version == Checkpoint.version()
  end

  test "unknown versions fail cleanly as incompatible_checkpoint" do
    data = %{Checkpoint.encode(full_checkpoint()) | "version" => 999}

    assert {:error, %Error{kind: :rollout, code: :incompatible_checkpoint} = error} =
             Checkpoint.decode(data)

    assert error.message =~ "999"
    refute error.retryable?
  end

  test "malformed payloads fail cleanly, never raise" do
    encoded = Checkpoint.encode(full_checkpoint())

    malformed = [
      Map.delete(encoded, "rollout_id"),
      %{encoded | "messages" => [%{"kind" => "who_knows"}]},
      %{encoded | "pending" => %{"shape" => "quantum"}},
      %{encoded | "cursor" => "not-a-cursor"},
      %{"version" => "one"},
      :not_even_a_map
    ]

    for payload <- malformed do
      assert {:error, %Error{code: :incompatible_checkpoint}} = Checkpoint.decode(payload)
    end
  end

  test "pending tool-approval preserves completed sibling results" do
    {:ok, decoded} =
      full_checkpoint()
      |> Checkpoint.encode()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Checkpoint.decode()

    assert %ToolApproval{completed_results: %{"tu_log" => %ToolResult{content: "logged"}}} =
             decoded.pending
  end
end
