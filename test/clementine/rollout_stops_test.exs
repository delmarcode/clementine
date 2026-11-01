defmodule Clementine.RolloutStopsTest do
  @moduledoc """
  How a run ends on its final turn's stop reason, in process, against
  `Clementine.LLM.Anthropic.Fake`: a refusal fails it `:refused` and runs
  none of the turn's tools; a final answer cut off at `max_tokens` or the
  context window fails it `:truncated`; a whole answer completes with its
  stop reason. Rollout telemetry says the same, and no turn of no blocks
  leaves an empty message or text block in the history a thread replays.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Mox

  alias Clementine.{Agent, Error, Result}
  alias Clementine.LLM.Anthropic.Fake
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}
  alias Clementine.Test.Tools.Echo

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
    test "after the tools' results completes with no message, and the thread replays valid" do
      script([
        {[{:tool_use, "toolu_1", "echo", %{"message" => "hi"}}], []},
        {[], []}
      ])

      assert {:ok, %Result.Completed{output: "", stop_reason: "end_turn"} = completed} =
               Clementine.run(agent(), "Echo, and say nothing.")

      assert [%AssistantMessage{}, %ToolResultMessage{}] = completed.messages
      refute Enum.any?(completed.messages, &empty?/1)

      # The strict fake refuses an empty message or text block, as the
      # API does: the next turn replays the thread and is answered.
      thread = [completed.input_message | completed.messages]
      script([{[{:text, "Hello."}], []}])

      assert {:ok, %Result.Completed{output: "Hello."}} =
               Clementine.run(agent(), "Anything else?", messages: thread)
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

    test "the strict fake refuses a history holding an empty text block, as the API does" do
      thread = [UserMessage.new("Hi"), AssistantMessage.new([Content.text("")])]
      script([{[{:text, "Hello."}], []}])

      assert {:error, %Result.Failed{error: error}} =
               Clementine.run(agent(), "Again?", messages: thread)

      assert %Error{code: :invalid_request} = error
      assert error.message =~ "messages.1.content.0.text: text content blocks must be non-empty"
    end
  end

  defp empty?(%AssistantMessage{content: content}),
    do: content == [] or Enum.any?(content, &match?(%Content.Text{text: ""}, &1))

  defp empty?(_message), do: false
end
