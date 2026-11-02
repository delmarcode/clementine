defmodule Clementine.RolloutStopsTest do
  @moduledoc """
  How a run ends on its final turn's stop reason, in process, against
  `Clementine.LLM.Anthropic.Fake`: a refusal fails it `:refused` and runs
  none of the turn's tools; a final answer cut off at `max_tokens` or the
  context window fails it `:truncated`, and so does a cut inside a tool
  call, whatever else the turn called; a run that wrote nothing and
  called no tools fails `:empty`; a whole answer completes with its stop
  reason. Rollout telemetry says the same. A final turn of no blocks is
  kept as an empty assistant message, which closes its exchange, and no
  provider is sent one, nor an empty or blank text block.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Mox

  alias Clementine.{Agent, Error, History, Result}
  alias Clementine.LLM.Anthropic.Fake

  alias Clementine.LLM.Message.{
    AssistantMessage,
    Content,
    SystemMessage,
    ToolResultMessage,
    UserMessage
  }

  alias Clementine.Test.Tools.Echo

  defmodule Notes do
    @moduledoc false
    use Clementine.Skill,
      name: "notes",
      description: "Take notes.",
      tools: [Clementine.Test.Tools.SafeEcho]

    @impl true
    def body(_context), do: "Keep notes short."
  end

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:clementine, :models)

    Application.put_env(
      :clementine,
      :models,
      Keyword.put(previous, :sonnet_55, provider: :anthropic, id: "claude-sonnet-5-5")
    )

    on_exit(fn -> Application.put_env(:clementine, :models, previous) end)

    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [[:clementine, :rollout, :stop], [:clementine, :rollout, :exception]],
      fn event, _measurements, metadata, _config -> send(test, {:rollout, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp agent(opts \\ []) do
    Agent.new(Keyword.merge([model: :sonnet_55, instructions: "Be brief.", tools: [Echo]], opts))
  end

  # Each script answers one model call, through the fake.
  defp script(scripts) do
    for {script, fake_opts} <- scripts do
      expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
        Fake.stream(model, system, messages, tools, opts, script, fake_opts)
      end)
    end
  end

  describe "a refusal" do
    test "before any output fails the run :refused, and telemetry never says success" do
      script([{[], stop_reason: "refusal"}])

      assert {:error, %Result.Failed{error: error, usage: usage}} =
               Clementine.run(agent(), "Something it will not do.")

      assert %Error{kind: :rollout, code: :refused, retryable?: false} = error
      assert error.raw == %{"stop_reason" => "refusal"}
      assert usage.input_tokens == 10

      assert_received {:rollout, [:clementine, :rollout, :exception],
                       %{error_code: :refused, error_kind: :rollout}}

      refute_received {:rollout, [:clementine, :rollout, :stop], _metadata}
    end

    test "mid-answer fails the run too: the partial answer is not the answer" do
      script([{[{:text, "Here is how you"}], stop_reason: "refusal"}])

      assert {:error, %Result.Failed{error: %Error{code: :refused}}} =
               Clementine.run(agent(), "Something it stops doing.")
    end

    test "runs none of the turn's tools, a call it began included" do
      script([
        {[{:text, "Calling."}, {:tool_use, "toolu_1", "echo", %{"message" => "hi"}}],
         stop_reason: "refusal"}
      ])

      events = Clementine.stream(agent(), "Echo something.") |> Enum.to_list()

      assert {:result, %Result.Failed{error: %Error{code: :refused}}} = List.last(events)
      refute Enum.any?(events, &match?(%Clementine.Event{type: :tool_result}, &1))
    end

    test "keeps the provider's stop details, the category named, and never content" do
      details = %{
        "type" => "refusal",
        "category" => "reasoning_extraction",
        "explanation" => "The request asks for the model's reasoning in its answer."
      }

      script([{[{:text, "Step one: I"}], stop_reason: "refusal", stop_details: details}])

      assert {:error, %Result.Failed{error: %Error{code: :refused} = error}} =
               Clementine.run(agent(), "Show your reasoning verbatim.")

      assert error.raw == %{"stop_reason" => "refusal", "stop_details" => details}
      assert error.message =~ "category: reasoning_extraction"
      refute error.message =~ "Step one"
    end

    test "inside a tool call fails :refused, with the call it stopped in" do
      script([
        {[{:unfinished_tool_use, "toolu_1", "echo", ~s({"message": "he)}], stop_reason: "refusal"}
      ])

      assert {:error, %Result.Failed{error: %Error{code: :refused} = error}} =
               Clementine.run(agent(), "Echo something.")

      assert %{"tool_use_id" => "toolu_1", "tool_name" => "echo"} = error.raw["unfinished_call"]
    end

    test "after earlier turns that called tools fails the run, as a final one does" do
      script([
        {[{:tool_use, "toolu_1", "echo", %{"message" => "hi"}}], []},
        {[], stop_reason: "refusal"}
      ])

      assert {:error, %Result.Failed{error: %Error{code: :refused}}} =
               Clementine.run(agent(), "Echo, then answer.")
    end
  end

  describe "a final answer cut off" do
    test "at max_tokens fails the run :truncated" do
      script([{[{:text, "The first of three reasons is"}], stop_reason: "max_tokens"}])

      assert {:error, %Result.Failed{error: error}} = Clementine.run(agent(), "Three reasons.")
      assert %Error{kind: :rollout, code: :truncated, retryable?: false} = error
      assert error.message =~ "max_tokens"

      assert_received {:rollout, [:clementine, :rollout, :exception],
                       %{error_code: :truncated, error_kind: :rollout}}

      refute_received {:rollout, [:clementine, :rollout, :stop], _metadata}
    end

    test "at the model's context window fails the run :truncated" do
      script([{[{:text, "Long"}], stop_reason: "model_context_window_exceeded"}])

      assert {:error, %Result.Failed{error: %Error{code: :truncated} = error}} =
               Clementine.run(agent(), "Go on.")

      assert error.raw == %{"stop_reason" => "model_context_window_exceeded"}
    end

    test "inside a tool call fails :truncated, not :unknown, and runs none of the turn's calls" do
      test = self()

      :telemetry.attach(
        {__MODULE__, :llm_stop},
        [:clementine, :llm, :stop],
        fn _event, _measurements, metadata, _config ->
          send(test, {:llm_stop, metadata.stop_reason})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, :llm_stop}) end)

      script([
        {[
           {:tool_use, "toolu_1", "echo", %{"message" => "first"}},
           {:unfinished_tool_use, "toolu_2", "echo", ~s({"message": "the second, cut)}
         ], []}
      ])

      events = Clementine.stream(agent(), "Echo twice.") |> Enum.to_list()

      assert {:result, %Result.Failed{error: %Error{} = error}} = List.last(events)
      assert %Error{kind: :rollout, code: :truncated, retryable?: false} = error
      assert error.message =~ "max_tokens" and error.message =~ "inside a call to echo"
      assert error.raw["stop_reason"] == "max_tokens"

      # The parse error stays in raw, naming the call the cut fell in.
      assert %{"type" => "stream_parse_error", "tool_use_id" => "toolu_2", "tool_name" => "echo"} =
               error.raw["unfinished_call"]

      refute Enum.any?(events, &match?(%Clementine.Event{type: :tool_result}, &1))
      assert_received {:llm_stop, "max_tokens"}

      assert_received {:rollout, [:clementine, :rollout, :exception],
                       %{error_code: :truncated, error_kind: :rollout}}
    end

    test "before any of a call's input fails :truncated: a call with no input at a cut is unfinished" do
      script([{[{:unfinished_tool_use, "toolu_1", "echo", ""}], []}])

      assert {:error, %Result.Failed{error: %Error{code: :truncated} = error}} =
               Clementine.run(agent(), "Echo.")

      assert %{"tool_use_id" => "toolu_1", "reason" => "It closed with no input."} =
               error.raw["unfinished_call"]
    end

    test "a whole turn's call with no input is a call without arguments, and runs" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:tool_use_start, "toolu_1", "echo"},
          {:content_block_stop, 0},
          {:message_delta, %{"stop_reason" => "tool_use"}, %{"input_tokens" => 10}}
        ]
      end)

      script([{[{:text, "Done."}], []}])

      events = Clementine.stream(agent(), "Echo.") |> Enum.to_list()
      assert {:result, %Result.Completed{output: "Done."}} = List.last(events)
      assert Enum.any?(events, &match?(%Clementine.Event{type: :tool_result}, &1))
    end

    test "with its tool calls whole runs them: only a final answer is judged" do
      script([
        {[{:tool_use, "toolu_1", "echo", %{"message" => "hi"}}], stop_reason: "max_tokens"},
        {[{:text, "Echoed."}], []}
      ])

      assert {:ok, %Result.Completed{output: "Echoed.", stop_reason: "end_turn"}} =
               Clementine.run(agent(), "Echo.")
    end
  end

  describe "a whole answer" do
    test "completes with its stop reason, and telemetry says success" do
      script([{[{:text, "Hello."}], []}])

      assert {:ok, %Result.Completed{output: "Hello.", stop_reason: "end_turn"}} =
               Clementine.run(agent(), "Hi")

      assert_received {:rollout, [:clementine, :rollout, :stop], %{status: :success}}
    end

    test "ending on a stop sequence completes" do
      script([{[{:text, "Done"}], stop_reason: "stop_sequence"}])

      assert {:ok, %Result.Completed{output: "Done", stop_reason: "stop_sequence"}} =
               Clementine.run(agent(), "Stop at the word.")
    end

    test "a paused turn goes back, and the turn that continues it completes" do
      script([
        {[{:text, "Searching. "}], stop_reason: "pause_turn"},
        {[{:text, "Found it."}], []}
      ])

      assert {:ok, %Result.Completed{} = completed} = Clementine.run(agent(), "Search.")
      assert completed.output == "Searching. Found it."
      assert [%AssistantMessage{}] = completed.messages
    end
  end

  describe "a turn of no blocks" do
    test "after the tools' results completes empty, and is kept as a turn that closes the exchange" do
      script([
        {[{:tool_use, "toolu_1", "echo", %{"message" => "hi"}}], []},
        {[], []}
      ])

      assert {:ok, %Result.Completed{output: "", stop_reason: "empty"} = completed} =
               Clementine.run(agent(), "Echo, and say nothing.")

      assert [%AssistantMessage{}, %ToolResultMessage{}, %AssistantMessage{content: []} = last] =
               completed.messages

      assert is_binary(last.binding)

      # A window (and an app's trim like it) drops an open exchange at a
      # thread's end; this one is closed, so the call it made stays, and
      # the next turn does not make it again.
      thread = [completed.input_message | completed.messages]
      assert History.window(thread, max: 100) == thread

      # The strict fake refuses an empty message or text block, as the
      # API does: the next turn replays the thread and is answered.
      script([{[{:text, "Hello."}], []}])

      assert {:ok, %Result.Completed{output: "Hello."}} =
               Clementine.run(agent(), "Anything else?", messages: thread)
    end

    test "after a skill loads, it is the assistant turn the skill's system message needs" do
      # Without it, the thread ends on the system message, and the next
      # prompt follows it, which the API refuses.
      script([
        {[{:tool_use, "toolu_1", "use_skill", %{"name" => "notes"}}], []},
        {[], []}
      ])

      agent = agent(skills: [Notes])

      assert {:ok, %Result.Completed{output: "", stop_reason: "empty"} = completed} =
               Clementine.run(agent, "Load your notes.")

      assert [
               %AssistantMessage{},
               %ToolResultMessage{},
               %SystemMessage{skill: "notes"},
               %AssistantMessage{content: []}
             ] = completed.messages

      thread = [completed.input_message | completed.messages]
      assert History.window(thread, max: 100) == thread

      # Without the empty turn, the API refuses the next prompt.
      next = UserMessage.new("Take a note.")

      assert {:error, {:api_error, 400, body}} =
               Fake.check(:sonnet_55, nil, Enum.drop(thread, -1) ++ [next], [], [], strict: false)

      assert body["error"]["message"] =~ "a system message must follow a user message"

      script([{[{:text, "Noted."}], []}])

      assert {:ok, %Result.Completed{output: "Noted."}} =
               Clementine.run(agent, "Take a note.", messages: thread)
    end

    test "refused leaves nothing to store, and the next turn replays valid" do
      script([{[], stop_reason: "refusal"}])

      assert {:error, %Result.Failed{error: %Error{code: :refused}}} =
               Clementine.run(agent(), "Something it will not do.")

      # A host stores turns from Completed, so the refused prompt is all
      # the thread may hold of it. Two user messages in a row are valid.
      thread = [UserMessage.new("Something it will not do.")]
      script([{[{:text, "Sure."}], []}])

      assert {:ok, %Result.Completed{output: "Sure."}} =
               Clementine.run(agent(), "Something else, then.", messages: thread)
    end

    test "cut off at max_tokens inside a thinking block that never closed fails :truncated" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:content_block_start, 0, :thinking},
          {:thinking_delta, 0, "Weighing the record"},
          {:message_delta, %{"stop_reason" => "max_tokens"},
           %{"input_tokens" => 10, "output_tokens" => 4096}}
        ]
      end)

      assert {:error, %Result.Failed{error: %Error{code: :truncated}}} =
               Clementine.run(agent(), "Think hard.")
    end

    test "a turn stored as one empty text block replays without it, which the API accepts" do
      # How Clementine stored a turn of no blocks before it stopped
      # writing them; the strict fake refuses the block, as the API does.
      thread = [UserMessage.new("Hi"), AssistantMessage.new([Content.text("")])]
      test = self()

      expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
        send(test, {:request, messages})
        Fake.stream(model, system, messages, tools, opts, [{:text, "Hello."}])
      end)

      assert {:ok, %Result.Completed{output: "Hello."}} =
               Clementine.run(agent(), "Again?", messages: thread)

      assert_received {:request, [_hi, %AssistantMessage{}, %UserMessage{}]}
    end

    test "a final turn of only whitespace after tools completes empty, its text not kept" do
      script([
        {[{:tool_use, "toolu_1", "echo", %{"message" => "hi"}}], []},
        {[{:text, "\n\n"}], []}
      ])

      assert {:ok, %Result.Completed{output: "", stop_reason: "empty"} = completed} =
               Clementine.run(agent(), "Echo, and say nothing.")

      assert %AssistantMessage{content: []} = List.last(completed.messages)
    end

    test "a stored text block of only whitespace replays without it" do
      thread = [UserMessage.new("Hi"), AssistantMessage.new([Content.text("\n\n")])]
      script([{[{:text, "Hello."}], []}])

      assert {:ok, %Result.Completed{output: "Hello."}} =
               Clementine.run(agent(), "Again?", messages: thread)
    end
  end

  describe "a run that did nothing" do
    test "wrote no text and called no tools: it fails :empty, and telemetry never says success" do
      script([{[], []}])

      assert {:error, %Result.Failed{error: error}} = Clementine.run(agent(), "Say something.")
      assert %Error{kind: :rollout, code: :empty, retryable?: false} = error
      assert error.raw == %{"stop_reason" => "end_turn"}
      assert error.message =~ "no text and called no tool"

      assert_received {:rollout, [:clementine, :rollout, :exception],
                       %{error_code: :empty, error_kind: :rollout}}

      refute_received {:rollout, [:clementine, :rollout, :stop], _metadata}
    end

    test "wrote only whitespace: that is no text either" do
      script([{[{:text, "\n\n"}], []}])

      assert {:error, %Result.Failed{error: %Error{code: :empty}}} =
               Clementine.run(agent(), "Say something.")
    end
  end
end
