defmodule Clementine.FacadeTest do
  # set_mox_global: stream/3 runs the runner in a task process.
  use ExUnit.Case, async: false

  import Mox

  alias Clementine.{Error, Event, Result, Usage}
  alias Clementine.LLM.Message.UserMessage
  alias Clementine.Test.CollectingSink
  alias Clementine.Test.Tools.Echo

  setup :set_mox_global
  setup :verify_on_exit!

  defp agent(opts \\ []) do
    Clementine.Agent.new(
      Keyword.merge([model: :claude_sonnet, instructions: "test", tools: []], opts)
    )
  end

  defp expect_stream(events) do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      events
    end)
  end

  defp text_events(text) do
    [
      {:text_delta, text},
      {:message_delta, %{"stop_reason" => "end_turn"},
       %{"input_tokens" => 7, "output_tokens" => 3}}
    ]
  end

  defp tool_events(id, name, input) do
    [
      {:tool_use_start, id, name},
      {:input_json_delta, id, Jason.encode!(input)},
      {:content_block_stop, 0},
      {:message_delta, %{"stop_reason" => "tool_use"},
       %{"input_tokens" => 5, "output_tokens" => 2}}
    ]
  end

  defp streamed_text(events) do
    events
    |> Enum.filter(&(&1.type == :text_delta))
    |> Enum.map_join(& &1.payload.content)
  end

  describe "run/3" do
    test "one line to a completed result" do
      expect_stream(text_events("Hello!"))

      assert {:ok, %Result.Completed{} = result} = Clementine.run(agent(), "Hi")
      assert result.output == "Hello!"
      assert result.input_message == UserMessage.new("Hi")
      assert result.usage == %Usage{input_tokens: 7, output_tokens: 3}
    end

    test "non-completed terminals come back as {:error, result}" do
      expect_stream([{:error, {:api_error, 401, "bad key"}}])

      assert {:error, %Result.Failed{error: %Error{kind: :provider, code: :auth}}} =
               Clementine.run(agent(), "Hi")
    end

    test "max_iterations is enforced exactly as in production" do
      expect_stream(tool_events("tu_1", "echo", %{"message" => "loop"}))

      assert {:error, %Result.Failed{error: %Error{code: :max_iterations}}} =
               Clementine.run(agent(tools: [Echo]), "Loop", limits: [max_iterations: 1])
    end

    test "the deadline is enforced with no heartbeat and no reaper" do
      # A zero-width window: expired at the first boundary, before any
      # provider call.
      assert {:error, %Result.Failed{error: %Error{code: :deadline_exceeded}}} =
               Clementine.run(agent(), "Hi", limits: [max_duration: 0])
    end

    test "history rides ahead of the input message" do
      history = [UserMessage.new("earlier"), UserMessage.new("context")]

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
        assert length(messages) == 3
        text_events("With context")
      end)

      assert {:ok, %Result.Completed{messages: generated}} =
               Clementine.run(agent(), "Now answer", messages: history)

      # Generated only — history and input are not folded back in.
      assert length(generated) == 1
    end

    test "an events sink observes the run" do
      expect_stream(text_events("Observed"))

      assert {:ok, _result} = Clementine.run(agent(), "Hi", events: CollectingSink)

      assert_received {:clementine_event, %Event{type: :iteration_start, epoch: 1, seq: 1}}
      assert_received {:clementine_event, %Event{type: :text_delta}}
      assert_received {:clementine_event, %Event{type: :usage_delta}}
    end

    test "an approval-gated tool cannot park an ephemeral run: it fails loud" do
      # A parked run needs a survivor to resume it; a script's in-process
      # facts die with the call. Gated tools belong on the durable path.
      expect_stream(tool_events("tu_1", "gated_deploy", %{}))

      assert_raise RuntimeError, ~r/ephemeral runs cannot park/, fn ->
        Clementine.run(agent(tools: [Clementine.Test.Tools.GatedDeploy]), "deploy")
      end
    end
  end

  describe "stream/3" do
    test "yields execution events in (epoch, seq) order, ending with the result" do
      expect_stream(text_events("Streamed!"))

      output = Clementine.stream(agent(), "Hi") |> Enum.to_list()

      assert {:result, %Result.Completed{output: "Streamed!"}} = List.last(output)

      events = Enum.drop(output, -1)
      assert Enum.all?(events, &match?(%Event{epoch: 1}, &1))
      assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))

      text =
        events
        |> Enum.filter(&(&1.type == :text_delta))
        |> Enum.map_join(& &1.payload.content)

      assert text == "Streamed!"
    end

    test "tool activity is visible in the stream" do
      expect_stream(tool_events("tu_1", "echo", %{"message" => "hi"}))
      expect_stream(text_events("Done"))

      types =
        Clementine.stream(agent(tools: [Echo]), "Hi")
        |> Enum.flat_map(fn
          %Event{type: type} -> [type]
          {:result, _result} -> []
        end)

      assert :tool_use_start in types
      assert :tool_result in types
    end

    test "a failed run still ends with its result" do
      expect_stream([{:error, {:api_error, 500, "boom"}}])

      assert {:result, %Result.Failed{error: %Error{code: :provider_unavailable}}} =
               Clementine.stream(agent(), "Hi") |> Enum.to_list() |> List.last()
    end

    test "halting early aborts the run and leaks no messages" do
      # A stub, not an expectation: the killed runner task may or may not
      # have reached the provider call by the time the consumer halts.
      stub(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        text_events("A long answer streams here")
      end)

      assert [%Event{}] = Clementine.stream(agent(), "Hi") |> Enum.take(1)

      refute_receive {:clementine_stream_event, _tag, _event}, 50
    end

    test "concurrent streams in one process do not cross-deliver events" do
      stub(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
        case List.last(messages) do
          %UserMessage{content: "left"} -> text_events("Left")
          %UserMessage{content: "right"} -> text_events("Right")
        end
      end)

      {left_items, right_items} =
        Clementine.stream(agent(), "left")
        |> Stream.zip(Clementine.stream(agent(), "right"))
        |> Enum.to_list()
        |> Enum.unzip()

      assert {:result, %Result.Completed{output: "Left"}} = List.last(left_items)
      assert {:result, %Result.Completed{output: "Right"}} = List.last(right_items)

      left_events = Enum.drop(left_items, -1)
      right_events = Enum.drop(right_items, -1)

      # Each enumerable yields only its own run's events, in its own order.
      assert [left_run] = left_events |> Enum.map(& &1.run_ref) |> Enum.uniq()
      assert [right_run] = right_events |> Enum.map(& &1.run_ref) |> Enum.uniq()
      refute left_run == right_run

      assert streamed_text(left_events) == "Left"
      assert streamed_text(right_events) == "Right"
    end
  end
end
