defmodule Clementine.LLM.MessageTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.Message
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}

  describe "UserMessage.new/1" do
    test "creates from string" do
      msg = UserMessage.new("hello")
      assert %UserMessage{role: :user, content: "hello"} = msg
    end

    test "creates from list of Content structs" do
      content = [Content.text("hello")]
      msg = UserMessage.new(content)
      assert %UserMessage{role: :user, content: ^content} = msg
    end

    test "raises on non-Content elements in list" do
      assert_raise ArgumentError, ~r/expected %Content{} struct/, fn ->
        UserMessage.new([%{type: :text, text: "bad"}])
      end
    end
  end

  describe "AssistantMessage.new/1" do
    test "creates from list of Content structs" do
      content = [Content.text("hi"), Content.tool_use("id1", "tool", %{})]
      msg = AssistantMessage.new(content)
      assert %AssistantMessage{role: :assistant, content: ^content} = msg
    end

    test "raises on non-Content elements in list" do
      assert_raise ArgumentError, ~r/expected %Content{} struct/, fn ->
        AssistantMessage.new([%{type: :text, text: "bad"}])
      end
    end
  end

  describe "ToolResultMessage.new/1" do
    test "handles {:ok, content} 2-tuple" do
      msg = ToolResultMessage.new([{"id1", {:ok, "result"}}])

      assert [
               %Content{
                 type: :tool_result,
                 tool_use_id: "id1",
                 content: "result",
                 is_error: false
               }
             ] = msg.content
    end

    test "handles {:error, reason}" do
      msg = ToolResultMessage.new([{"id1", {:error, "boom"}}])

      assert [
               %Content{
                 type: :tool_result,
                 tool_use_id: "id1",
                 content: "Error: boom",
                 is_error: true
               }
             ] = msg.content
    end

    test "handles {:ok, content, is_error: true} 3-tuple" do
      msg = ToolResultMessage.new([{"id1", {:ok, "Exit code: 1\nfailed", is_error: true}}])

      assert [
               %Content{
                 type: :tool_result,
                 tool_use_id: "id1",
                 content: "Exit code: 1\nfailed",
                 is_error: true
               }
             ] = msg.content
    end

    test "handles {:ok, content, is_error: false} 3-tuple" do
      msg = ToolResultMessage.new([{"id1", {:ok, "output", is_error: false}}])

      assert [
               %Content{
                 type: :tool_result,
                 tool_use_id: "id1",
                 content: "output",
                 is_error: false
               }
             ] = msg.content
    end

    test "handles {:ok, content, []} 3-tuple defaulting is_error to false" do
      msg = ToolResultMessage.new([{"id1", {:ok, "output", []}}])

      assert [
               %Content{
                 type: :tool_result,
                 tool_use_id: "id1",
                 content: "output",
                 is_error: false
               }
             ] = msg.content
    end

    test "handles mixed result types" do
      results = [
        {"id1", {:ok, "good"}},
        {"id2", {:ok, "non-zero exit", is_error: true}},
        {"id3", {:error, "crashed"}}
      ]

      msg = ToolResultMessage.new(results)
      assert length(msg.content) == 3
      assert Enum.at(msg.content, 0).is_error == false
      assert Enum.at(msg.content, 1).is_error == true
      assert Enum.at(msg.content, 2).is_error == true
    end
  end

  describe "Message.to_anthropic/1" do
    test "converts UserMessage with string content" do
      assert %{"role" => "user", "content" => "hi"} =
               Message.to_anthropic(UserMessage.new("hi"))
    end

    test "converts UserMessage with Content list" do
      msg = UserMessage.new([Content.tool_result("id1", "result", false)])
      api = Message.to_anthropic(msg)
      assert %{"role" => "user", "content" => [%{"type" => "tool_result"}]} = api
    end

    test "converts AssistantMessage" do
      msg = AssistantMessage.new([Content.text("hello")])
      api = Message.to_anthropic(msg)
      assert %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "hello"}]} = api
    end

    test "converts ToolResultMessage" do
      msg = ToolResultMessage.new([{"id1", {:ok, "done"}}])
      api = Message.to_anthropic(msg)

      assert %{
               "role" => "user",
               "content" => [%{"type" => "tool_result", "tool_use_id" => "id1"}]
             } = api
    end
  end
end
