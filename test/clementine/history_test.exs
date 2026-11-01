defmodule Clementine.HistoryTest do
  use ExUnit.Case, async: true

  alias Clementine.History
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}

  defp thread(turns) do
    Enum.flat_map(1..turns, fn n -> [UserMessage.new("q#{n}"), AssistantMessage.text("a#{n}")] end)
  end

  test "replays the whole thread while it fits" do
    assert History.window(thread(3), max: 6) == thread(3)
  end

  test "cuts in steps of half the window, so the start holds while the thread grows" do
    starts =
      for turns <- 4..9 do
        [%UserMessage{content: first} | _] = History.window(thread(turns), max: 6)
        first
      end

    # 8 to 18 messages: the cut moves by three messages (to the next
    # prompt) only as the thread passes each step.
    assert starts == ["q3", "q4", "q4", "q6", "q7", "q7"]
    assert length(History.window(thread(9), max: 6)) <= 6
  end

  test "starts at a prompt and leaves out a tool exchange the thread ends inside" do
    open = [
      AssistantMessage.new([Content.tool_use("t1", "echo", %{})]),
      ToolResultMessage.new([{"t1", {:ok, "x"}}])
    ]

    messages = [ToolResultMessage.new([{"t0", {:ok, "x"}}]) | thread(2)] ++ open
    assert History.window(messages, max: 100) == thread(2)
  end

  test "takes a positive max" do
    assert_raise ArgumentError, fn -> History.window([], max: 0) end
  end
end
