defmodule Clementine.HistoryTest do
  use ExUnit.Case, async: true

  alias Clementine.History

  alias Clementine.LLM.Message.{
    AssistantMessage,
    Content,
    SystemMessage,
    ToolResultMessage,
    UserMessage
  }

  defp thread(turns) do
    Enum.flat_map(1..turns//1, fn n ->
      [UserMessage.new("q#{n}"), AssistantMessage.text("a#{n}")]
    end)
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

  test "a last turn longer than half the window replays from its prompt" do
    long =
      Enum.flat_map(1..5, fn n ->
        [
          AssistantMessage.new([Content.tool_use("t#{n}", "echo", %{})]),
          ToolResultMessage.new([{"t#{n}", {:ok, "x"}}])
        ]
      end)

    # The cut lands inside q2's turn, and no prompt follows it.
    messages = thread(1) ++ [UserMessage.new("q2") | long] ++ [AssistantMessage.text("a2")]
    assert [%UserMessage{content: "q2"} | rest] = History.window(messages, max: 6)
    assert List.last(rest) == AssistantMessage.text("a2")

    # A thread with no prompt at all replays nothing.
    assert History.window(long, max: 4) == []
  end

  test "a thread that ends on a skill's system message leaves its exchange out" do
    open = [
      AssistantMessage.new([Content.tool_use("t1", "use_skill", %{"name" => "notes"})]),
      ToolResultMessage.new([{"t1", {:ok, "Loaded."}}]),
      SystemMessage.new([%Content.ToolAddition{definition: %{"name" => "note"}}], skill: "notes")
    ]

    assert History.window(thread(2) ++ open, max: 100) == thread(2)
  end

  test "carries the system messages before the cut to after the window's first prompt" do
    load = fn skill ->
      [
        UserMessage.new("load #{skill}"),
        AssistantMessage.new([Content.tool_use(skill, "use_skill", %{"name" => skill})]),
        ToolResultMessage.new([{skill, {:ok, "Loaded."}}]),
        SystemMessage.new([%Content.ToolAddition{definition: %{"name" => skill}}], skill: skill),
        AssistantMessage.text("Loaded #{skill}.")
      ]
    end

    messages = load.("notes") ++ load.("drafts") ++ thread(6)

    windows =
      for grown <- [0, 1] do
        History.window(messages ++ thread(grown), max: 8)
      end

    for window <- windows do
      assert [
               %UserMessage{content: first},
               %SystemMessage{skill: "notes"},
               %SystemMessage{skill: "drafts"},
               %AssistantMessage{} | _
             ] = window

      assert first =~ "q"
      assert Enum.count(window, &match?(%SystemMessage{}, &1)) == 2
    end

    # The window's start holds while it grows, and so do the carried
    # messages: the same prefix both times.
    [one, two] = windows
    assert Enum.take(two, length(one)) == one

    # A skill the window announces again is not carried twice.
    again = messages ++ load.("notes")
    window = History.window(again, max: 12)
    assert Enum.count(window, &match?(%SystemMessage{skill: "notes"}, &1)) == 1
  end

  test "takes a positive max" do
    assert_raise ArgumentError, fn -> History.window([], max: 0) end
  end
end
