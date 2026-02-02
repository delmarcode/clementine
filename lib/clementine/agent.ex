defmodule Clementine.Agent do
  @moduledoc """
  Behaviour and macro for defining agents.

  An agent is a GenServer that runs the agentic loop with a set of tools.
  It maintains conversation history and can be supervised like any OTP process.

  ## Example

      defmodule MyApp.CodingAgent do
        use Clementine.Agent,
          name: "coding_agent",
          model: :claude_sonnet,
          tools: [
            MyApp.Tools.ReadFile,
            MyApp.Tools.WriteFile,
            MyApp.Tools.RunCommand
          ],
          verifiers: [
            MyApp.Verifiers.TestsPassing
          ],
          system: \"\"\"
          You are a coding assistant. You have access to the filesystem
          and can run commands. Always verify your changes by running tests.
          \"\"\"
      end

      # Start the agent
      {:ok, agent} = MyApp.CodingAgent.start_link()

      # Run a task
      {:ok, result} = Clementine.run(agent, "Add a fibonacci function to lib/math.ex")

  ## Configuration

  The following options can be set at compile time via `use Clementine.Agent`:

  - `:name` - Required. The agent's name for identification.
  - `:model` - The LLM model to use (default: from config)
  - `:tools` - List of tool modules (default: [])
  - `:verifiers` - List of verifier modules (default: [])
  - `:system` - System prompt (default: "")
  - `:max_iterations` - Maximum loop iterations (default: from config)

  Runtime options can override compile-time options when calling `start_link/1`.

  """

  alias Clementine.Loop

  @type agent :: GenServer.server()

  defmodule State do
    @moduledoc false
    defstruct [
      :name,
      :model,
      :system,
      :tools,
      :verifiers,
      :max_iterations,
      :context,
      history: [],
      tasks: %{}
    ]
  end

  @doc """
  Invoked when using the agent module.

  ## Options

  - `:name` - Required. The agent's name.
  - `:model` - LLM model atom (default: from config)
  - `:tools` - List of tool modules
  - `:verifiers` - List of verifier modules
  - `:system` - System prompt
  - `:max_iterations` - Maximum loop iterations
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use GenServer

      @agent_name Keyword.fetch!(opts, :name)
      @agent_model Keyword.get(opts, :model)
      @agent_tools Keyword.get(opts, :tools, [])
      @agent_verifiers Keyword.get(opts, :verifiers, [])
      @agent_system Keyword.get(opts, :system, "")
      @agent_max_iterations Keyword.get(opts, :max_iterations)

      @task_ttl_ms :timer.minutes(30)
      @task_cleanup_interval_ms :timer.minutes(5)

      @doc """
      Starts the agent with optional runtime configuration.

      ## Options

      - `:name` - Process name for registration
      - `:model` - Override the default model
      - `:system` - Override the system prompt
      - `:max_iterations` - Override max iterations
      - `:context` - Initial context map
      - `:working_dir` - Working directory for tools
      - `:history` - Initial conversation history (list of messages). Used by
        `Clementine.Agent.fork/3` to seed the new agent with the source's history.
      """
      def start_link(opts \\ []) do
        {gen_opts, agent_opts} = Keyword.split(opts, [:name])
        GenServer.start_link(__MODULE__, agent_opts, gen_opts)
      end

      @doc """
      Returns the agent's compile-time configuration.
      """
      def __config__ do
        %{
          name: @agent_name,
          model: @agent_model,
          tools: @agent_tools,
          verifiers: @agent_verifiers,
          system: @agent_system,
          max_iterations: @agent_max_iterations
        }
      end

      # GenServer callbacks

      @impl true
      def init(opts) do
        default_model = Application.get_env(:clementine, :default_model, :claude_sonnet)
        default_max_iterations = Application.get_env(:clementine, :max_iterations, 10)

        context =
          Keyword.get(opts, :context, %{})
          |> Map.put_new(:working_dir, Keyword.get(opts, :working_dir, File.cwd!()))

        history = Keyword.get(opts, :history, [])
        validate_history!(history)

        state = %Clementine.Agent.State{
          name: @agent_name,
          model: Keyword.get(opts, :model, @agent_model || default_model),
          system: Keyword.get(opts, :system, @agent_system),
          tools: @agent_tools,
          verifiers: @agent_verifiers,
          max_iterations:
            Keyword.get(opts, :max_iterations, @agent_max_iterations || default_max_iterations),
          context: context,
          history: history,
          tasks: %{}
        }

        schedule_task_cleanup()
        {:ok, state}
      end

      @impl true
      def handle_call({:run, prompt}, from, state) do
        # Run synchronously
        config = build_loop_config(state)

        case Loop.run(config, prompt) do
          {:ok, result, messages} ->
            {:reply, {:ok, result}, %{state | history: messages}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end

      @impl true
      def handle_call({:run_async, prompt}, {from_pid, _ref}, state) do
        task_id = generate_task_id()
        config = build_loop_config(state)

        # Use async_nolink so a crash in Loop.run/2 doesn't take down the agent
        task =
          Task.Supervisor.async_nolink(Clementine.TaskSupervisor, fn ->
            Loop.run(config, prompt)
          end)

        entry = %{task: task, from: from_pid, status: :running, waiters: []}
        tasks = Map.put(state.tasks, task_id, entry)
        {:reply, {:ok, task_id}, %{state | tasks: tasks}}
      end

      @impl true
      def handle_call({:status, task_id}, _from, state) do
        case Map.get(state.tasks, task_id) do
          nil ->
            {:reply, {:error, :not_found}, state}

          %{status: status} ->
            {:reply, {:ok, status}, state}
        end
      end

      @impl true
      def handle_call({:await, task_id, timeout}, from, state) do
        case Map.get(state.tasks, task_id) do
          nil ->
            {:reply, {:error, :not_found}, state}

          %{status: :running} = entry ->
            # Task still running — defer reply until it completes or timeout fires
            timer_ref =
              if timeout == :infinity,
                do: nil,
                else: Process.send_after(self(), {:await_timeout, task_id, from}, timeout)

            waiters = [{from, timer_ref} | entry.waiters]
            tasks = Map.put(state.tasks, task_id, %{entry | waiters: waiters})
            {:noreply, %{state | tasks: tasks}}

          %{result: result} ->
            # Task already finished — return result and clean up
            tasks = Map.delete(state.tasks, task_id)
            {:reply, normalize_result(result), %{state | tasks: tasks}}
        end
      end

      @impl true
      def handle_call(:get_history, _from, state) do
        {:reply, state.history, state}
      end

      @impl true
      def handle_call(:clear_history, _from, state) do
        {:reply, :ok, %{state | history: []}}
      end

      @impl true
      def handle_call(:get_state, _from, state) do
        {:reply, state, state}
      end

      @impl true
      def handle_info({ref, result}, state) when is_reference(ref) do
        # Successful task completion from Task.Supervisor.async_nolink
        Process.demonitor(ref, [:flush])

        case find_task_by_ref(state.tasks, ref) do
          {task_id, task_info} ->
            state =
              case result do
                {:ok, _text, messages} -> %{state | history: messages}
                _ -> state
              end

            tasks = finish_task(state.tasks, task_id, task_info, :completed, result)
            {:noreply, %{state | tasks: tasks}}

          nil ->
            {:noreply, state}
        end
      end

      @impl true
      def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
        # Normal exit follows a successful {ref, result} which already
        # handled the task. Process.demonitor(:flush) usually eats this,
        # but it can arrive if the demonitor races. Safe to ignore.
        {:noreply, state}
      end

      @impl true
      def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
        # Abnormal exit or :shutdown — task crashed or was terminated
        case find_task_by_ref(state.tasks, ref) do
          {task_id, %{status: :running} = task_info} ->
            result = {:error, {:task_crashed, reason}}
            tasks = finish_task(state.tasks, task_id, task_info, :failed, result)
            {:noreply, %{state | tasks: tasks}}

          _ ->
            # Task already terminal or unknown — ignore
            {:noreply, state}
        end
      end

      @impl true
      def handle_info({:await_timeout, task_id, from}, state) do
        case Map.get(state.tasks, task_id) do
          %{waiters: waiters} = entry when is_list(waiters) ->
            case List.keytake(waiters, from, 0) do
              {{^from, _timer_ref}, remaining} ->
                GenServer.reply(from, {:error, :timeout})
                tasks = Map.put(state.tasks, task_id, %{entry | waiters: remaining})
                {:noreply, %{state | tasks: tasks}}

              nil ->
                # Waiter already replied to (task completed before timeout fired)
                {:noreply, state}
            end

          _ ->
            # Task already cleaned up
            {:noreply, state}
        end
      end

      @impl true
      def handle_info(:task_cleanup, state) do
        now = System.monotonic_time(:millisecond)

        tasks =
          Map.reject(state.tasks, fn {_id, entry} ->
            match?(%{completed_at: t} when now - t > @task_ttl_ms, entry)
          end)

        schedule_task_cleanup()
        {:noreply, %{state | tasks: tasks}}
      end

      # Private helpers

      defp validate_history!(history) when is_list(history) do
        Enum.each(history, fn
          %Clementine.LLM.Message.UserMessage{} -> :ok
          %Clementine.LLM.Message.AssistantMessage{} -> :ok
          %Clementine.LLM.Message.ToolResultMessage{} -> :ok
          other ->
            raise ArgumentError,
              ":history elements must be message structs " <>
              "(UserMessage, AssistantMessage, or ToolResultMessage), got: #{inspect(other)}"
        end)
      end

      defp validate_history!(other) do
        raise ArgumentError, ":history must be a list of messages, got: #{inspect(other)}"
      end

      defp schedule_task_cleanup do
        Process.send_after(self(), :task_cleanup, @task_cleanup_interval_ms)
      end

      defp build_loop_config(state) do
        [
          model: state.model,
          system: state.system,
          tools: state.tools,
          verifiers: state.verifiers,
          context: state.context,
          max_iterations: state.max_iterations,
          messages: state.history
        ]
      end

      defp generate_task_id do
        :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      end

      defp find_task_by_ref(tasks, ref) do
        Enum.find_value(tasks, fn
          {task_id, %{task: %Task{ref: ^ref}} = info} -> {task_id, info}
          _ -> nil
        end)
      end

      # Transition a task to a terminal state, replying to any blocked waiters.
      # If waiters exist, the task entry is removed (waiters got the result).
      # If no waiters, the entry is kept so a later await/3 can retrieve it.
      defp finish_task(tasks, task_id, task_info, status, result) do
        waiters = Map.get(task_info, :waiters, [])
        normalized = normalize_result(result)

        for {from, timer_ref} <- waiters do
          if timer_ref, do: Process.cancel_timer(timer_ref)
          GenServer.reply(from, normalized)
        end

        if waiters == [] do
          Map.put(tasks, task_id, %{status: status, result: result, completed_at: System.monotonic_time(:millisecond)})
        else
          Map.delete(tasks, task_id)
        end
      end

      # Convert internal Loop.run/2 results to the public await/3 contract,
      # which matches run/2: {:ok, text} | {:error, reason}
      defp normalize_result({:ok, text, _messages}), do: {:ok, text}
      defp normalize_result({:error, _reason} = error), do: error
    end
  end

  # Public API functions that work with any agent process

  @doc """
  Runs a prompt synchronously on an agent.
  """
  def run(agent, prompt) when is_binary(prompt) do
    GenServer.call(agent, {:run, prompt}, :infinity)
  end

  @doc """
  Runs a prompt asynchronously on an agent.

  Returns `{:ok, task_id}` immediately. Use `await/3` to get the result.
  """
  def run_async(agent, prompt) when is_binary(prompt) do
    GenServer.call(agent, {:run_async, prompt})
  end

  @doc """
  Awaits the result of an async task.

  Blocks until the task completes or the timeout expires. Returns the same
  contract as `run/2`. The task entry is removed from state after the result
  is retrieved; subsequent calls return `{:error, :not_found}`.

  ## Options

  - `timeout` — milliseconds to wait (default: `5000`). Use `:infinity` to
    wait indefinitely.

  ## Returns

  - `{:ok, text}` — task completed successfully
  - `{:error, reason}` — task failed (LLM error, crash, etc.)
  - `{:error, :timeout}` — task did not complete within the timeout
  - `{:error, :not_found}` — unknown or already-consumed task_id
  """
  def await(agent, task_id, timeout \\ 5000)

  def await(agent, task_id, :infinity) do
    GenServer.call(agent, {:await, task_id, :infinity}, :infinity)
  end

  def await(agent, task_id, timeout) when is_integer(timeout) and timeout >= 0 do
    GenServer.call(agent, {:await, task_id, timeout}, timeout + 5000)
  end

  @doc """
  Gets the status of an async task.

  This is a non-blocking, read-only check. Use `await/3` to retrieve results.

  Returns:
  - `{:ok, :running}` — task is still in progress
  - `{:ok, :completed}` — task function returned (result may be ok or error)
  - `{:ok, :failed}` — task process crashed (exception/exit)
  - `{:error, :not_found}` — unknown or already-consumed task_id
  """
  def status(agent, task_id) do
    GenServer.call(agent, {:status, task_id})
  end

  @doc """
  Gets the conversation history from an agent.
  """
  def get_history(agent) do
    GenServer.call(agent, :get_history)
  end

  @doc """
  Clears the conversation history.
  """
  def clear_history(agent) do
    GenServer.call(agent, :clear_history)
  end

  @doc """
  Forks an agent, creating a new agent with the same history.

  The new agent is started with the same configuration as the original,
  but as a separate process with its own copy of the history.
  """
  def fork(agent, new_agent_module, opts \\ []) do
    history = get_history(agent)
    state = GenServer.call(agent, :get_state)

    fork_opts =
      Keyword.merge(
        [
          context: state.context,
          model: state.model,
          system: state.system,
          history: history
        ],
        opts
      )

    new_agent_module.start_link(fork_opts)
  end
end
