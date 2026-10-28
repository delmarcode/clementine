defmodule Clementine.LoopCase.ConformanceLoop do
  @moduledoc false
  # The deterministic controller `Clementine.LoopCase` drives: message
  # payloads carry the action list to emit (`%{"actions" => [...]}`), a
  # halt instruction (`%{"halt" => output}`), or a poison marker
  # (`%{"boom" => true}`, which raises: the deterministic in-step failure
  # the poison battery walks to its threshold). Every callback invocation
  # appends to the JSON-safe `"log"` in state, which the battery reads
  # back out of committed envelopes: delivery is asserted through storage,
  # never through process state.

  use Clementine.Loop,
    key: "conformance_loop",
    state_version: 1,
    vocabulary: [:run, :send, :timer, :cancel_timer, :cancel, :reply, :retry, :poll]

  alias Clementine.Result

  def init(args) do
    {:ok, %{"log" => ["init"]}, Map.get(args, "actions", [])}
  end

  def handle({:message, %{"halt" => output}}, state) do
    {:halt, Result.completed(output: output), log(state, "halt:#{output}")}
  end

  def handle({:message, %{"boom" => true}}, _state) do
    raise "conformance poison payload"
  end

  def handle({:message, payload}, state) when is_map(payload) do
    {:ok, log(state, "message:#{payload["id"]}"), Map.get(payload, "actions", [])}
  end

  def handle({:completed, tag, result}, state) do
    {:ok, log(state, "completed:#{inspect(tag)}:#{variant(result)}"), []}
  end

  # The watcher (LOOP_RFC §Worked Examples): the fired tag re-arms in the
  # very fold that consumed it, the live-key lifetime the L6 probe reads.
  def handle({:elapsed, :poll}, state) do
    {:ok, log(state, "elapsed::poll"), [{:timer, :poll, 60_000}]}
  end

  def handle({:elapsed, tag}, state) do
    {:ok, log(state, "elapsed:#{inspect(tag)}"), []}
  end

  def handle({:input_failed, _ref, error}, state) do
    {:ok, log(state, "input_failed:#{error.code}"), []}
  end

  defp variant(%Result.Completed{}), do: "completed"
  defp variant(%Result.Failed{}), do: "failed"
  defp variant(%Result.Cancelled{}), do: "cancelled"
  defp variant(%Result.Interrupted{}), do: "interrupted"

  defp log(state, entry), do: Map.update!(state, "log", &(&1 ++ [entry]))
end

defmodule Clementine.LoopCase.Task do
  @moduledoc false
  # A task agent for the battery's children: one model turn answers.
  use Clementine.Agent,
    key: "conformance_task",
    model: :claude_sonnet,
    instructions: "Do the task."
end

defmodule Clementine.LoopCase.Turn do
  @moduledoc false
  # A turn agent for the battery's children. Its history/1 reports what it
  # saw to the test process, so the battery can assert the child built at
  # its claim with its subject resolved. Its one tool reports what a tool
  # sees of its run.
  use Clementine.Agent,
    key: "conformance_turn",
    turn: true,
    model: :claude_sonnet,
    instructions: "Answer the thread.",
    tools: [Clementine.LoopCase.ContextTool]

  @impl true
  def history(run) do
    Clementine.LoopCase.Host.report({:history, run})
    []
  end
end

defmodule Clementine.LoopCase.ContextTool do
  @moduledoc false
  use Clementine.Tool,
    name: "context",
    description: "Reports the run's context.",
    retry: :safe,
    parameters: []

  @impl true
  def run(_args, context) do
    Clementine.LoopCase.Host.report({:tool_context, context})
    {:ok, "ok"}
  end
end

defmodule Clementine.LoopCase.Host do
  @moduledoc false
  # The battery's host: resolves "thread" subjects and "user" actors, and
  # reports every callback to the process registered as
  # :clementine_loop_case, so tests assert what the host heard and when.

  @behaviour Clementine.Host

  @impl true
  def resolve_subject("thread", id), do: {:ok, %{thread: id}}
  def resolve_subject("gone", _id), do: {:error, :subject_gone}
  def resolve_subject(_type, _id), do: {:ok, nil}

  @impl true
  def resolve_actor("user", id), do: {:ok, %{user: id}}
  def resolve_actor(_type, _id), do: {:ok, nil}

  @impl true
  def run_event(run, event), do: report({:run_event, run, event})

  @impl true
  def run_transition(run, transition), do: report({:run_transition, run, transition})

  @impl true
  def run_finished(run, result), do: report({:run_finished, run, result})

  @impl true
  def run_committed(run, result), do: report({:run_committed, run, result})

  @doc false
  def report(message) do
    if pid = Process.whereis(:clementine_loop_case), do: send(pid, message)
    :ok
  end
end
