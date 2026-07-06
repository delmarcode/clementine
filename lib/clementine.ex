defmodule Clementine do
  @moduledoc """
  Clementine - an agent framework for Elixir.

  Clementine models agent work as inert definitions animated by explicit
  execution machinery: an `Clementine.Agent` is a capability definition, a
  `Clementine.Rollout` is one Gather → Act execution spec, a
  `Clementine.Run` is one durable attempt, and a `Clementine.Runner` turns
  the crank against the host's `Clementine.Lifecycle`.

  ## Quick Start

  The simplest consumption is one line — the same nouns production uses,
  animated by an in-memory lifecycle:

      agent =
        Clementine.Agent.new(
          model: :claude_sonnet,
          instructions: "You are a helpful assistant.",
          tools: [MyApp.Tools.ReadFile]
        )

      {:ok, %Clementine.Result.Completed{} = result} =
        Clementine.run(agent, "Summarize README.md")

      result.output

  Production apps use the nouns explicitly: build a `Clementine.Run`, call
  `Clementine.Runner.execute/2` from a host-owned worker with a durable
  `Clementine.Lifecycle` implementation. See the durable execution RFC in
  `docs/DURABLE_EXECUTION_RFC.md`.

  ## Core Concepts

  ### Tools

  Tools are functions the agent can call. Define them with `Clementine.Tool`:

      defmodule MyApp.Tools.Echo do
        use Clementine.Tool,
          name: "echo",
          description: "Echoes the input",
          parameters: [
            message: [type: :string, required: true, description: "Message to echo"]
          ]

        @impl true
        def run(%{message: msg}, _context) do
          {:ok, msg}
        end
      end

  ### Verifiers

  Verification is an outer-control concern, not part of the inner loop:
  judge a completed result and retry with feedback one floor above the
  rollout. See `Clementine.Verifier` for the judge-function shape.

      {:ok, result} = Clementine.run(agent, "Refactor the parser")
      :ok = Clementine.Verifier.run_all([MyApp.Verifiers.TestsPassing], result, context)

  ### Interactive agent processes

  `Clementine.AgentServer` wraps the same machinery in a GenServer for
  interactive local use — a porch, not the house. `run_async/2`, `await/3`,
  `status/2`, `get_history/1`, `clear_history/1`, and `fork/3` below
  operate on those processes.

  ## Configuration

      # config/config.exs
      config :clementine,
        anthropic_api_key: {:system, "ANTHROPIC_API_KEY"},
        openai_api_key: {:system, "OPENAI_API_KEY"},
        default_model: :claude_sonnet,
        max_iterations: 10

      config :clementine, :models,
        claude_sonnet: [
          provider: :anthropic,
          id: "claude-sonnet-4-20250514",
          defaults: [max_tokens: 8192]
        ]

  """

  alias Clementine.{AgentServer, Events, Result, Rollout, Run, Runner}
  alias Clementine.Lifecycle.{Ephemeral, Facts}

  @doc """
  Runs one rollout to a terminal result, in-process.

  The one-line script path: under it sit the same nouns production uses —
  a `Clementine.Rollout` built from the agent and prompt, a
  `Clementine.Run`, the `Clementine.Runner`, and the ephemeral in-memory
  lifecycle. Deadline (`max_duration:`) and `max_iterations:` limits are
  enforced exactly as in production; there is no heartbeat and no reaper
  because a single process cannot lose a lease, and a crash is the
  caller's crash.

  ## Options

  - `:messages` - starting message history (default `[]`)
  - `:context` - context map passed to tools (default `%{}`)
  - `:limits` - `[max_iterations: n, max_duration: ms]`; unset keys fall
    back to the agent's defaults
  - `:events` - a `Clementine.Events` sink for execution events (default
    `Clementine.Events.Null`)

  ## Returns

  - `{:ok, %Clementine.Result.Completed{}}` — final output, generated
    messages, and usage
  - `{:error, result}` — the other terminal `Clementine.Result` variants
    (`Failed`, `Cancelled`, `Interrupted`), each carrying usage

  ## Example

      {:ok, %Clementine.Result.Completed{} = result} =
        Clementine.run(agent, "What is 6 x 7?")

      result.output
  """
  @spec run(Clementine.Agent.t(), String.t(), keyword()) ::
          {:ok, Result.Completed.t()}
          | {:error, Result.Failed.t() | Result.Cancelled.t() | Result.Interrupted.t()}
  def run(%Clementine.Agent{} = agent, prompt, opts \\ []) when is_binary(prompt) do
    {ref, ctx} = Ephemeral.create()
    run = Run.new(ref: ref, rollout: build_rollout(agent, prompt, opts))

    try do
      case execute_ephemeral(run, ctx, Keyword.get(opts, :events, Events.Null)) do
        %Result.Completed{} = completed -> {:ok, completed}
        other -> {:error, other}
      end
    after
      Ephemeral.delete(ctx)
    end
  end

  @doc """
  Runs one rollout, streaming its execution events.

  Returns a lazy enumerable of `Clementine.Event` structs in `(epoch, seq)`
  order, ending with `{:result, result}` carrying the terminal
  `Clementine.Result` (any variant). The stream is caller-owned
  deliberately: a script is the rightful owner of its execution — consuming
  it runs the rollout, and abandoning it aborts the run.

  Options are as in `run/3`, minus `:events` — this stream is the event
  sink.

  ## Example

      Clementine.stream(agent, "Explain this code")
      |> Enum.each(fn
        %Clementine.Event{type: :text_delta, payload: %{content: text}} -> IO.write(text)
        {:result, %Clementine.Result.Completed{}} -> IO.puts("\\n[done]")
        _ -> :ok
      end)
  """
  @spec stream(Clementine.Agent.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(%Clementine.Agent{} = agent, prompt, opts \\ []) when is_binary(prompt) do
    Stream.resource(
      fn -> start_stream(agent, prompt, opts) end,
      &next_stream_event/1,
      &cleanup_stream/1
    )
  end

  defp build_rollout(agent, prompt, opts) do
    Rollout.new(
      agent: agent,
      input: prompt,
      messages: Keyword.get(opts, :messages, []),
      context: Keyword.get(opts, :context, %{}),
      limits: Keyword.get(opts, :limits, [])
    )
  end

  # The ephemeral translation of the worker contract: a drain requeue means
  # "re-enqueue", which in a single process is simply running it again;
  # any terminal reads the result the projection captured. The remaining
  # runner outcomes are unreachable here by construction — a single-writer
  # claim cannot lose, in-memory writes cannot fail transiently, and no
  # in-scope rollout parks — so they fail loud instead of leaking a shape.
  defp execute_ephemeral(run, ctx, sink) do
    outcome =
      Runner.execute(run,
        lifecycle: Ephemeral,
        ctx: ctx,
        events: sink,
        executor_id: "ephemeral:#{inspect(self())}",
        heartbeat: false
      )

    case outcome do
      {:finished, %Facts{status: :queued}} ->
        execute_ephemeral(run, ctx, sink)

      {:finished, %Facts{}} ->
        Ephemeral.result(ctx)

      {:suspended, _token} ->
        raise "ephemeral runs cannot park: approval-gated tools are not " <>
                "supported by Clementine.run/3 and Clementine.stream/3"

      other ->
        raise "ephemeral runner invariant violated: #{inspect(other)}"
    end
  end

  defp start_stream(agent, prompt, opts) do
    owner = self()

    task =
      Task.async(fn ->
        {ref, ctx} = Ephemeral.create(forward_to: owner)
        run = Run.new(ref: ref, rollout: build_rollout(agent, prompt, opts))
        execute_ephemeral(run, ctx, Events.Forwarder)
      end)

    %{task: task, done: false}
  end

  defp next_stream_event(%{done: true} = state), do: {:halt, state}

  defp next_stream_event(%{task: %Task{ref: ref}} = state) do
    receive do
      {:clementine_stream_event, %Clementine.Event{} = event} ->
        {[event], state}

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {[{:result, result}], %{state | done: true}}

      {:DOWN, ^ref, :process, _pid, reason} ->
        # No reaper on the ephemeral path: a crash is the caller's crash.
        exit(reason)
    end
  end

  defp cleanup_stream(%{task: task, done: done}) do
    unless done, do: Task.shutdown(task, :brutal_kill)
    flush_stream_events()
  end

  defp flush_stream_events do
    receive do
      {:clementine_stream_event, _event} -> flush_stream_events()
    after
      0 -> :ok
    end
  end

  @doc """
  Runs a prompt on an interactive `Clementine.AgentServer` asynchronously.

  Returns immediately with a task ID. Use `await/3` to get the result.
  Returns `{:error, {:agent_busy, task_ids}}` if another run is already active
  for the conversational agent.

  ## Example

      {:ok, task_id} = Clementine.run_async(agent, "Long running task")
      # ... do other things ...
      {:ok, result} = Clementine.await(agent, task_id)

  """
  defdelegate run_async(agent, prompt), to: AgentServer

  @doc """
  Awaits the result of an async task.

  Blocks until the task completes or the timeout expires (default: 5000ms).
  Returns the same `{:ok, text}` / `{:error, reason}` contract as
  `Clementine.AgentServer.run/2`. The task is removed from state after
  retrieval.

  ## Example

      {:ok, task_id} = Clementine.run_async(agent, "Long running task")
      {:ok, result} = Clementine.await(agent, task_id)

      # With custom timeout
      {:ok, result} = Clementine.await(agent, task_id, 30_000)

  """
  defdelegate await(agent, task_id, timeout \\ 5000), to: AgentServer

  @doc """
  Gets the status of an async task.

  Non-blocking, read-only check. Use `await/3` to retrieve results.

  ## Returns

  - `{:ok, :running}` - Task is still running
  - `{:ok, :completed}` - Task function returned (result may be ok or error)
  - `{:ok, :failed}` - Task process crashed (exception/exit)
  - `{:error, :not_found}` - Unknown task ID

  """
  defdelegate status(agent, task_id), to: AgentServer

  @doc """
  Gets the conversation history from an interactive agent process.

  The history is a list of messages in chronological order.
  """
  defdelegate get_history(agent), to: AgentServer

  @doc """
  Clears the conversation history.

  This starts a fresh conversation.
  Returns `{:error, {:agent_busy, task_ids}}` if an async run is active.
  """
  defdelegate clear_history(agent), to: AgentServer

  @doc """
  Forks an interactive agent process, creating a new one with the same
  history.

  This is useful for exploring different paths in a conversation.

  ## Example

      {:ok, forked} = Clementine.fork(agent, MyAgent)
      # forked has the same history as agent

  """
  defdelegate fork(agent, new_agent_module, opts \\ []), to: AgentServer

  @doc """
  Executes a tool directly without the LLM loop.

  This is useful for testing tools or running them manually.

  ## Example

      {:ok, %Clementine.ToolResult{content: content, is_error: false}} =
        Clementine.tool_run(MyApp.Tools.ReadFile, %{path: "README.md"})

  """
  def tool_run(tool_module, args, context \\ %{}) do
    tool_module.execute(args, context)
  end
end
