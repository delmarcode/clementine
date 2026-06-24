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
      assert %{"kind" => "user"} = Message.to_map(UserMessage.new("hi"))
      assert %{"kind" => "assistant"} = Message.to_map(AssistantMessage.text("hi"))

      assert %{"kind" => "tool_result"} =
               Message.to_map(ToolResultMessage.new([{"id", {:ok, "x"}}]))
    end

    test "from_map raises on unknown kind" do
      assert_raise ArgumentError, ~r/unknown message kind/, fn ->
        Message.from_map(%{"kind" => "bogus", "content" => "x"})
      end
    end

    test "from_map raises on missing kind" do
      assert_raise ArgumentError, ~r/expected a message map/, fn ->
        Message.from_map(%{"role" => "user", "content" => "x"})
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
