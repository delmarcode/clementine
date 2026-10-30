defmodule Clementine.OutputSchemaDurableTest do
  @moduledoc """
  `output_schema:` on the durable runtime: a loop starts a grading child
  whose agent answers in JSON, and the decoded map is what the host's
  `run_finished/2` receives, what the row stores, and what the loop
  hears. A malformed answer fails the child, and the loop hears that.
  """
  use Clementine.RunsCase

  alias Clementine.Result
  alias Clementine.Runs.StepWorker

  defmodule Grader do
    @moduledoc false
    use Clementine.Agent,
      key: "test_output_grader",
      model: :claude_sonnet,
      instructions: "Grade the essay.",
      tools: [Clementine.RunsCase.Context],
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "verdict" => %{"type" => "string", "enum" => ["pass", "fail"]},
          "reasons" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["verdict", "reasons"],
        "additionalProperties" => false
      }
  end

  defmodule Review do
    @moduledoc "Grades an essay with a child and decides on the child's verdict."
    use Clementine.Loop, key: "test_output_review", vocabulary: [:grade]

    alias Clementine.Result

    def init(%{"essay" => essay}) do
      child = %{"agent" => "test_output_grader", "prompt" => essay}
      {:ok, %{"decided" => nil}, [{:run, {:grade, 1}, child}]}
    end

    def handle(
          {:completed, {:grade, 1}, %Result.Completed{output: %{"verdict" => verdict}}},
          state
        ),
        do: {:ok, %{state | "decided" => verdict}, []}

    def handle({:completed, {:grade, 1}, %Result.Failed{error: error}}, state),
      do: {:ok, %{state | "decided" => "failed: #{error.code}"}, []}

    def handle(_input, state), do: {:ok, state, []}
  end

  @moduletag runtime: false

  setup do
    Process.register(self(), :clementine_runs_test)

    start_supervised!(
      {Clementine, repo: TestRepo, agents: [Grader, Review], host: Clementine.RunsCase.Host}
    )

    :ok
  end

  test "the child's answer is a map to run_finished/2, the row, and the loop that decides on it" do
    {:ok, loop} = Runs.start_loop(Review, %{"essay" => "An essay."}, subject: {"ticket", 1})
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    assert {:ok, %AgentRun{} = child} = Runs.child(loop.id, {:grade, 1})

    # The run uses its tool, then answers in JSON.
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, opts ->
      assert opts[:output_schema]["required"] == ["verdict", "reasons"]
      tool_events("toolu_1", "context", %{})
    end)

    expect_turn(text_events(~s({"verdict": "pass", "reasons": ["argued", "sourced"]})))

    assert :ok = perform_job(Worker, %{"run_id" => child.id})

    answer = %{"verdict" => "pass", "reasons" => ["argued", "sourced"]}
    child_id = child.id

    assert_received {:run_finished, %AgentRun{id: ^child_id}, %Result.Completed{output: ^answer}}

    assert %AgentRun{status: "completed", result: %{"output" => ^answer}} = Runs.get(child.id)

    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    assert decided(loop) == "pass"
  end

  test "a malformed answer fails the child, and the loop hears the failure" do
    {:ok, loop} = Runs.start_loop(Review, %{"essay" => "An essay."}, subject: {"ticket", 2})
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    assert {:ok, %AgentRun{} = child} = Runs.child(loop.id, {:grade, 1})

    expect_turn(text_events("It passes, I think."))
    assert :ok = perform_job(Worker, %{"run_id" => child.id})

    child_id = child.id

    assert_received {:run_finished, %AgentRun{id: ^child_id},
                     %Result.Failed{error: %Clementine.Error{code: :invalid_output}}}

    assert %AgentRun{status: "failed", error: %{"code" => "invalid_output"}, result: nil} =
             Runs.get(child.id)

    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    assert decided(loop) == "failed: invalid_output"
  end

  defp decided(loop) do
    %AgentRun{envelope: %{"state" => stored}} = Runs.get(loop.id)
    Clementine.Loop.Codec.decode(stored, vocabulary: [:grade])["decided"]
  end
end
