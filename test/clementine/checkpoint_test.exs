defmodule Clementine.CheckpointTest do
  use ExUnit.Case, async: true

  alias Clementine.{Checkpoint, Error, ToolResult, Usage}
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}
  alias Clementine.Pending.ToolApproval

  defp full_checkpoint do
    %Checkpoint{
      version: 2,
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
      skills: ["records", "audit"],
      usage: %Usage{
        input_tokens: 1200,
        output_tokens: 340,
        cache_read_tokens: 1000,
        cache_write_tokens: 150
      },
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
    assert decoded.version == 1
  end

  test "with no skill loaded, encodes as version 1, with exactly the keys version 1 wrote" do
    encoded = Checkpoint.encode(%{full_checkpoint() | version: 1, skills: []})

    assert encoded["version"] == 1

    assert encoded |> Map.keys() |> Enum.sort() ==
             ~w(cursor iteration messages pending rollout_id usage version)

    assert {:ok, %Checkpoint{version: 1, skills: []}} =
             encoded |> Jason.encode!() |> Jason.decode!() |> Checkpoint.decode()
  end

  test "writes the lowest version that holds it, never lower than the one it was read as" do
    fresh = %Checkpoint{rollout_id: "r1"}

    assert Checkpoint.version_for(fresh) == 1
    assert Checkpoint.version_for(%{fresh | skills: ["records"]}) == 2
    assert Checkpoint.version_for(%{fresh | version: 2}) == 2

    # An approval the tool policy asked for needs version 2; one the
    # tool's declaration asked for does not.
    asked = %ToolApproval{tool_use_id: "tu_1", tool_name: "refund", policy: :require_approval}
    assert Checkpoint.version_for(%{fresh | pending: asked}) == 2
    assert Checkpoint.version_for(%{fresh | pending: %{asked | policy: nil}}) == 1
    assert Checkpoint.encode(%{fresh | version: 2})["skills"] == []
  end

  test "version 2 records the loaded skills, in load order" do
    encoded = Checkpoint.encode(%{full_checkpoint() | version: 1})

    assert encoded["version"] == 2
    assert encoded["skills"] == ["records", "audit"]
  end

  test "a version-1 envelope decodes with no skills loaded" do
    v1 = full_checkpoint() |> Checkpoint.encode() |> Map.delete("skills") |> Map.put("version", 1)

    assert {:ok, %Checkpoint{version: 1, skills: []} = decoded} =
             v1 |> Jason.encode!() |> Jason.decode!() |> Checkpoint.decode()

    assert decoded.messages == full_checkpoint().messages
    assert decoded.pending == full_checkpoint().pending

    # Version 1 had no skills: a key one carries is not read as loaded.
    assert {:ok, %Checkpoint{skills: []}} = Checkpoint.decode(Map.put(v1, "skills", ["records"]))
  end

  test "a version-2 envelope without skills decodes with none loaded" do
    data = full_checkpoint() |> Checkpoint.encode() |> Map.delete("skills")

    assert {:ok, %Checkpoint{version: 2, skills: []}} = Checkpoint.decode(data)
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
      %{encoded | "messages" => "not-a-list"},
      %{encoded | "usage" => "lots"},
      %{encoded | "pending" => %{"shape" => "quantum"}},
      %{encoded | "pending" => Map.put(encoded["pending"], "policy", "maybe")},
      %{encoded | "cursor" => "not-a-cursor"},
      %{encoded | "skills" => "records"},
      %{encoded | "skills" => [%{"name" => "records"}]},
      %{"version" => "one"},
      :not_even_a_map
    ]

    for payload <- malformed do
      assert {:error, %Error{code: :incompatible_checkpoint}} = Checkpoint.decode(payload)
    end
  end

  test "a pending approval the tool policy asked for keeps its verdict through JSON" do
    pending = %{full_checkpoint().pending | policy: :require_approval}
    encoded = Checkpoint.encode(%{full_checkpoint() | pending: pending})

    assert encoded["pending"]["policy"] == "require_approval"

    assert {:ok, %Checkpoint{pending: %ToolApproval{policy: :require_approval}}} =
             encoded |> Jason.encode!() |> Jason.decode!() |> Checkpoint.decode()

    # One without a verdict encodes exactly as before the policy existed.
    refute Map.has_key?(Checkpoint.encode(full_checkpoint())["pending"], "policy")
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
