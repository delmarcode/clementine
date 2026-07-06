defmodule Clementine.RunViewTest do
  use ExUnit.Case, async: true

  alias Clementine.Event
  alias Clementine.Lifecycle.Facts
  alias Clementine.RunView
  alias Clementine.Usage

  defp event(epoch, seq, type, payload) do
    %Event{run_ref: "run_1", epoch: epoch, seq: seq, type: type, payload: payload}
  end

  defp fold(view \\ RunView.new("run_1"), events) do
    Enum.reduce(events, view, &RunView.apply(&2, &1))
  end

  describe "new/1" do
    test "starts empty, open, at cursor {0, 0} — below any real execution" do
      view = RunView.new("run_1")

      assert view.run_ref == "run_1"
      assert RunView.cursor(view) == {0, 0}
      refute RunView.closed?(view)
      assert view.text == ""
      assert view.tools == %{}
      assert view.usage == %Usage{}
      assert view.status == nil
      assert view.final == nil
    end
  end

  describe "content assembly" do
    test "text deltas concatenate; iteration tracks the latest start" do
      view =
        fold([
          event(1, 1, :iteration_start, %{n: 1}),
          event(1, 2, :text_delta, %{content: "Hello, "}),
          event(1, 3, :text_delta, %{content: "world"}),
          event(1, 4, :iteration_start, %{n: 2})
        ])

      assert view.text == "Hello, world"
      assert view.iteration == 2
      assert RunView.cursor(view) == {1, 4}
    end

    test "a tool call is in flight from start until its result lands" do
      started =
        fold([
          event(1, 1, :tool_use_start, %{tool_use_id: "tu_1", name: "search"}),
          event(1, 2, :tool_input_delta, %{tool_use_id: "tu_1", content: ~s({"q":)}),
          event(1, 3, :tool_input_delta, %{tool_use_id: "tu_1", content: ~s("cats"})})
        ])

      assert started.tools == %{
               "tu_1" => %{name: "search", input: ~s({"q":"cats"}), approval_requested?: false}
             }

      settled =
        RunView.apply(
          started,
          event(1, 4, :tool_result, %{tool_use_id: "tu_1", result: "ok", is_error: false})
        )

      assert settled.tools == %{}
      assert RunView.cursor(settled) == {1, 4}
    end

    test "approval_requested marks the parked call — visible to a reconnecting observer" do
      view =
        fold([
          event(1, 1, :tool_use_start, %{tool_use_id: "tu_9", name: "delete_records"}),
          event(1, 2, :approval_requested, %{tool_use_id: "tu_9", name: "delete_records"})
        ])

      assert %{"tu_9" => %{approval_requested?: true, name: "delete_records"}} = view.tools
    end

    test "tool events whose start was lost still fold — gaps are transport loss" do
      view = fold([event(1, 5, :tool_input_delta, %{tool_use_id: "tu_2", content: "{"})])

      assert %{"tu_2" => %{name: nil, input: "{"}} = view.tools

      # A result for a call the view never saw is tolerated the same way.
      assert fold([event(1, 1, :tool_result, %{tool_use_id: "ghost"})]).tools == %{}
    end

    test "usage deltas accumulate; error events advance the cursor only" do
      view =
        fold([
          event(1, 1, :usage_delta, %{input_tokens: 10, output_tokens: 1}),
          event(1, 2, :error, %{message: "rate limited"}),
          event(1, 3, :usage_delta, %{input_tokens: 5, output_tokens: 2})
        ])

      assert view.usage == %Usage{input_tokens: 15, output_tokens: 3}
      assert RunView.cursor(view) == {1, 3}
    end

    test "malformed payloads are tolerated, never a crash — the view is advisory" do
      view =
        fold([
          event(1, 1, :text_delta, %{content: 42}),
          event(1, 2, :text_delta, %{}),
          event(1, 3, :iteration_start, %{n: "two"}),
          event(1, 4, :tool_use_start, %{}),
          event(1, 5, :tool_input_delta, %{tool_use_id: "tu", content: :nope}),
          event(1, 6, :usage_delta, %{input_tokens: -3, output_tokens: "x"})
        ])

      assert view.text == ""
      assert view.iteration == 0
      assert %{"tu" => %{input: ""}} = view.tools
      assert view.usage == %Usage{}
      assert RunView.cursor(view) == {1, 6}
    end
  end

  describe "ordering discipline" do
    test "an event at or below the cursor is dropped — duplicates and replays" do
      view = fold([event(1, 1, :text_delta, %{content: "a"})])

      assert RunView.apply(view, event(1, 1, :text_delta, %{content: "a"})) == view
      assert RunView.apply(view, event(1, 0, :text_delta, %{content: "z"})) == view
    end

    test "within-epoch gaps apply — loss is tolerated, not amplified" do
      view =
        fold([
          event(1, 1, :text_delta, %{content: "a"}),
          event(1, 7, :text_delta, %{content: "b"})
        ])

      assert view.text == "ab"
      assert RunView.cursor(view) == {1, 7}
    end

    test "a superseded epoch's stragglers are dropped without a database check" do
      view =
        fold([
          event(2, 1, :text_delta, %{content: "fresh"}),
          event(1, 99, :text_delta, %{content: "stale"})
        ])

      assert view.text == "fresh"
      assert RunView.cursor(view) == {2, 1}
    end

    test "a higher epoch resets execution-scoped state — the new execution owns the run" do
      view =
        fold([
          event(1, 1, :iteration_start, %{n: 3}),
          event(1, 2, :text_delta, %{content: "Hello wor"}),
          event(1, 3, :tool_use_start, %{tool_use_id: "tu_1", name: "search"}),
          event(1, 4, :usage_delta, %{input_tokens: 50, output_tokens: 9}),
          event(2, 1, :text_delta, %{content: "Hello world"})
        ])

      assert view.text == "Hello world"
      assert view.iteration == 0
      assert view.tools == %{}
      assert view.usage == %Usage{}
      assert RunView.cursor(view) == {2, 1}
    end
  end

  describe "close/2" do
    test "terminal facts pin the view; the cursor keeps its last live position" do
      view = fold([event(1, 1, :text_delta, %{content: "partial"})])
      facts = %Facts{ref: "run_1", status: :completed, epoch: 1}

      closed = RunView.close(view, facts)

      assert RunView.closed?(closed)
      assert closed.status == :completed
      assert closed.final == facts
      assert closed.text == "partial"
      assert RunView.cursor(closed) == {1, 1}
    end

    test "non-terminal facts are a contract violation, not a close" do
      view = RunView.new("run_1")

      for status <- Facts.active_statuses() do
        assert_raise ArgumentError, ~r/terminal/, fn ->
          RunView.close(view, %Facts{ref: "run_1", status: status, epoch: 1})
        end
      end
    end

    test "closing is idempotent — terminal facts are unique per run" do
      facts = %Facts{ref: "run_1", status: :cancelled, epoch: 2}
      closed = RunView.close(RunView.new("run_1"), facts)

      assert RunView.close(closed, %Facts{ref: "run_1", status: :completed, epoch: 2}) == closed
    end

    test "a closed view rejects every further event — below, at, and above the final epoch" do
      view = fold([event(2, 3, :text_delta, %{content: "ghost bait"})])
      closed = RunView.close(view, %Facts{ref: "run_1", status: :interrupted, epoch: 2})

      for {epoch, seq} <- [{1, 99}, {2, 3}, {2, 4}, {3, 1}] do
        assert RunView.apply(closed, event(epoch, seq, :text_delta, %{content: "ghost"})) ==
                 closed
      end
    end
  end

  describe "reconnect: snapshot + cursor + close" do
    test "a snapshotted view resumes mid-stream and the fold discards the overlap" do
      live = [
        event(1, 1, :iteration_start, %{n: 1}),
        event(1, 2, :text_delta, %{content: "The answer "}),
        event(1, 3, :text_delta, %{content: "is "}),
        event(1, 4, :usage_delta, %{input_tokens: 20, output_tokens: 4}),
        event(1, 5, :text_delta, %{content: "42."})
      ]

      # The host cached the view as of seq 3; the observer snapshots it...
      snapshot = fold(Enum.take(live, 3))
      assert RunView.cursor(snapshot) == {1, 3}

      # ...subscribes, and replays everything from seq 2 on (overlap included).
      resumed = fold(snapshot, Enum.drop(live, 1))

      assert resumed.text == "The answer is 42."
      assert resumed.usage == %Usage{input_tokens: 20, output_tokens: 4}
      assert resumed == fold(live)

      # The terminal notification ends the story.
      closed = RunView.close(resumed, %Facts{ref: "run_1", status: :completed, epoch: 1})
      assert RunView.closed?(closed)
    end
  end
end
