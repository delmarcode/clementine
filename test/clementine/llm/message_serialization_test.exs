defmodule Clementine.LLM.MessageSerializationTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.Message
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}

  describe "Content.to_map/1 and from_map/1 round trip" do
    test "text" do
      block = Content.text("hello world")
      assert Content.from_map(Content.to_map(block)) == block
    end

    test "tool_use with a non-empty input map" do
      block = Content.tool_use("id1", "search", %{"query" => "elixir", "limit" => 5})
      assert Content.from_map(Content.to_map(block)) == block
    end

    test "tool_result with is_error false" do
      block = Content.tool_result("id1", "ok", false)
      assert Content.from_map(Content.to_map(block)) == block
    end

    test "tool_result with is_error true" do
      block = Content.tool_result("id1", "boom", true)
      assert Content.from_map(Content.to_map(block)) == block
    end

    test "to_map produces string-keyed, tagged maps" do
      assert Content.to_map(Content.text("hi")) == %{"type" => "text", "text" => "hi"}

      assert Content.to_map(Content.tool_use("id1", "t", %{"a" => 1})) ==
               %{"type" => "tool_use", "id" => "id1", "name" => "t", "input" => %{"a" => 1}}

      assert Content.to_map(Content.tool_result("id1", "r", true)) ==
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "id1",
                 "content" => "r",
                 "is_error" => true
               }
    end

    test "from_map raises on unknown type" do
      assert_raise ArgumentError, ~r/unknown content type/, fn ->
        Content.from_map(%{"type" => "bogus"})
      end
    end

    test "from_map raises on missing type" do
      assert_raise ArgumentError, ~r/expected a content map/, fn ->
        Content.from_map(%{"text" => "no type"})
      end
    end

    test "from_map rejects extra keys" do
      assert_raise ArgumentError, ~r/unexpected text content field/, fn ->
        Content.from_map(%{"type" => "text", "text" => "hi", "extra" => "nope"})
      end
    end

    test "from_map raises on missing required fields for a known type" do
      assert_raise ArgumentError, ~r/expected content map to include "text"/, fn ->
        Content.from_map(%{"type" => "text"})
      end
    end

    test "to_map rejects tool_use input with non-string keys" do
      assert_raise ArgumentError, ~r/string keys/, fn ->
        Content.to_map(Content.tool_use("id1", "t", %{a: 1}))
      end
    end

    test "to_map rejects nested non-JSON-safe tool_use input" do
      assert_raise ArgumentError, ~r/JSON-safe/, fn ->
        Content.to_map(Content.tool_use("id1", "t", %{"a" => {:tuple, "bad"}}))
      end
    end
  end

  describe "Message.to_map/1 and from_map/1 round trip" do
    test "UserMessage with string content" do
      msg = UserMessage.new("hello")
      assert Message.from_map(Message.to_map(msg)) == msg
    end

    test "UserMessage with a list of content blocks" do
      msg = UserMessage.new([Content.text("hi"), Content.tool_result("id1", "r", false)])
      assert Message.from_map(Message.to_map(msg)) == msg
    end

    test "AssistantMessage with text and tool_use blocks" do
      msg =
        AssistantMessage.new([
          Content.text("thinking"),
          Content.tool_use("id1", "search", %{"q" => "x"})
        ])

      assert Message.from_map(Message.to_map(msg)) == msg
    end

    test "ToolResultMessage" do
      msg = ToolResultMessage.new([{"id1", {:ok, "done"}}, {"id2", {:error, "boom"}}])
      assert Message.from_map(Message.to_map(msg)) == msg
    end

    test "to_map carries an explicit kind discriminator" do
      assert %{"version" => 1, "kind" => "user", "role" => "user"} =
               Message.to_map(UserMessage.new("hi"))

      assert %{"version" => 1, "kind" => "assistant", "role" => "assistant"} =
               Message.to_map(AssistantMessage.text("hi"))

      assert %{"version" => 1, "kind" => "tool_result", "role" => "user"} =
               Message.to_map(ToolResultMessage.new([{"id", {:ok, "x"}}]))
    end

    test "from_map rejects missing version" do
      assert_raise ArgumentError, ~r/expected message map to include "version"/, fn ->
        Message.from_map(%{"kind" => "user", "role" => "user", "content" => "hi"})
      end
    end

    test "from_map rejects missing role" do
      assert_raise ArgumentError, ~r/expected message map to include "role"/, fn ->
        Message.from_map(%{"version" => 1, "kind" => "user", "content" => "hi"})
      end
    end

    test "from_map rejects extra keys" do
      assert_raise ArgumentError, ~r/unexpected message field/, fn ->
        UserMessage.new("hi")
        |> Message.to_map()
        |> Map.put("extra", "nope")
        |> Message.from_map()
      end
    end

    test "from_map rejects unsupported version" do
      assert_raise ArgumentError, ~r/unsupported message serialization version/, fn ->
        Message.from_map(%{"version" => 2, "kind" => "user", "role" => "user", "content" => "x"})
      end
    end

    test "from_map rejects kind and role mismatch" do
      assert_raise ArgumentError, ~r/does not match kind/, fn ->
        Message.from_map(%{
          "version" => 1,
          "kind" => "tool_result",
          "role" => "assistant",
          "content" => [Content.to_map(Content.tool_result("id1", "done"))]
        })
      end
    end

    test "from_map raises on unknown kind" do
      assert_raise ArgumentError, ~r/unknown message kind/, fn ->
        Message.from_map(%{"version" => 1, "kind" => "bogus", "role" => "user", "content" => "x"})
      end
    end

    test "from_map raises on missing kind" do
      assert_raise ArgumentError, ~r/expected a message map/, fn ->
        Message.from_map(%{"role" => "user", "content" => "x"})
      end
    end

    test "from_map raises on invalid content shape for kind" do
      assert_raise ArgumentError,
                   ~r/expected assistant message content to be a content list/,
                   fn ->
                     Message.from_map(%{
                       "version" => 1,
                       "kind" => "assistant",
                       "role" => "assistant",
                       "content" => "x"
                     })
                   end
    end
  end

  describe "full Jason.encode!/decode! round trip" do
    test "UserMessage with string content" do
      msg = UserMessage.new("hello")
      assert jason_round_trip(msg) == msg
    end

    test "UserMessage with a list of content blocks" do
      msg = UserMessage.new([Content.text("hi"), Content.tool_result("id1", "r", false)])
      assert jason_round_trip(msg) == msg
    end

    test "AssistantMessage with text and tool_use (string-keyed input)" do
      msg =
        AssistantMessage.new([
          Content.text("thinking"),
          Content.tool_use("id1", "search", %{"q" => "x", "limit" => 3})
        ])

      assert jason_round_trip(msg) == msg
    end

    test "ToolResultMessage" do
      msg = ToolResultMessage.new([{"id1", {:ok, "done", is_error: false}}])
      assert jason_round_trip(msg) == msg
    end

    defp jason_round_trip(msg) do
      msg
      |> Message.to_map()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Message.from_map()
    end
  end
end
