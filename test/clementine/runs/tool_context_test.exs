defmodule Clementine.Runs.ToolContextTest do
  @moduledoc """
  What a durable run's tools see beyond the run: `agent/1`'s
  `tool_context:` under the runtime's keys, which win; and the built-in
  file tools' refusal to work without a `working_dir` set that way.
  """

  use Clementine.RunsCase

  alias Clementine.Tools.ReadFile

  defmodule Probe do
    @moduledoc false
    use Clementine.Tool,
      name: "probe",
      description: "Reports the context keys under test.",
      retry: :safe,
      parameters: []

    @impl true
    def run(_args, context) do
      {:ok, inspect(Map.take(context, [:run_id, :working_dir, :extra]))}
    end
  end

  defmodule Scoped do
    @moduledoc false
    # An agent that gives its tools a working directory, a key of its own,
    # and a runtime key it has no business setting.
    use Clementine.Agent, key: "test_scoped"

    @impl true
    def agent(run) do
      Clementine.Agent.new(
        model: :claude_sonnet,
        instructions: "Go.",
        tools: [Probe, ReadFile],
        tool_context: %{
          working_dir: run.metadata["dir"],
          capabilities: %{read: true},
          extra: "from-agent",
          run_id: "forged"
        }
      )
    end
  end

  defmodule Unscoped do
    @moduledoc false
    # An agent with the read capability and no working directory.
    use Clementine.Agent, key: "test_unscoped"

    @impl true
    def agent(_run) do
      Clementine.Agent.new(
        model: :claude_sonnet,
        instructions: "Go.",
        tools: [ReadFile],
        tool_context: %{capabilities: %{read: true}}
      )
    end
  end

  defmodule Malformed do
    @moduledoc false
    use Clementine.Agent, key: "test_malformed"

    @impl true
    def agent(_run) do
      Clementine.Agent.new(
        model: :claude_sonnet,
        instructions: "Go.",
        tool_context: [:not, :a, :map]
      )
    end
  end

  @moduletag runtime: false

  setup do
    Process.register(self(), :clementine_runs_test)

    start_supervised!(
      {Clementine,
       repo: TestRepo, agents: [Scoped, Unscoped, Malformed], host: Clementine.RunsCase.Host}
    )

    dir =
      Path.join(
        System.tmp_dir!(),
        "clementine_runs_tool_context_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "note.txt"), "the note")
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "an agent's tool_context reaches its tools under the runtime's keys, which win", %{
    dir: dir
  } do
    {:ok, run} = Runs.start(Scoped, "probe", metadata: %{"dir" => dir})
    run_id = run.id

    expect_turn(tool_events("toolu_1", "probe", %{}))

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      seen = inspect(messages, limit: :infinity, printable_limit: :infinity)
      assert seen =~ ~s(extra: \\"from-agent\\")
      assert seen =~ ~s(working_dir: \\"#{dir}\\")
      # The agent's "forged" run_id lost to the runtime's.
      assert seen =~ ~s(run_id: \\"#{run_id}\\")
      refute seen =~ "forged"
      text_events("Done.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "completed"} = Runs.get(run.id)
  end

  test "a built-in file tool works under the working_dir the agent set", %{dir: dir} do
    {:ok, run} = Runs.start(Scoped, "read", metadata: %{"dir" => dir})

    expect_turn(tool_events("toolu_1", "read_file", %{path: "note.txt"}))

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      assert inspect(messages, limit: :infinity, printable_limit: :infinity) =~ "the note"
      text_events("Done.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "completed"} = Runs.get(run.id)
  end

  test "a built-in file tool refuses without a working_dir: no fallback to the app's own directory" do
    {:ok, run} = Runs.start(Unscoped, "read")

    # mix.exs exists in the app's current directory; the refusal is what
    # keeps it out of the model's hands.
    expect_turn(tool_events("toolu_1", "read_file", %{path: "mix.exs"}))

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      seen = inspect(messages, limit: :infinity, printable_limit: :infinity)
      assert seen =~ "No working_dir"
      refute seen =~ "MixProject"
      text_events("Done.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "completed"} = Runs.get(run.id)
  end

  test "an agent whose tool_context is not a map is cancelled as unstartable" do
    {:ok, run} = Runs.start(Malformed, "go")

    assert {:cancel, reason} = perform_job(Worker, %{"run_id" => run.id})
    assert reason =~ "tool_context"
    assert %AgentRun{status: "cancelled"} = Runs.get(run.id)
  end
end
