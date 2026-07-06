defmodule Clementine.AgentServer do
  @moduledoc """
  An interactive agent process: a GenServer that holds conversation history
  and runs each turn through the same machinery production uses — a
  `Clementine.Rollout` built from its state, a `Clementine.Run`, the
  `Clementine.Runner`, and the ephemeral in-memory lifecycle. A porch, not
  the house: convenience for interactive local use, never the ontology.

  Each turn builds a rollout with `messages: history`; a `Completed` result
  folds back as `history ++ [input_message] ++ messages`. Results follow
  `Clementine.run/3`'s contract — `{:ok, %Clementine.Result.Completed{}}`
  or `{:error, result}` with the other terminal `Clementine.Result`
  variants, every one carrying usage.

  ## Example

      defmodule MyApp.CodingAgent do
        use Clementine.AgentServer,
          name: "coding_agent",
          model: :claude_sonnet,
          tools: [
            MyApp.Tools.ReadFile,
            MyApp.Tools.WriteFile,
            MyApp.Tools.RunCommand
          ],
          system: \"\"\"
          You are a coding assistant. You have access to the filesystem
          and can run commands. Always verify your changes by running tests.
          \"\"\"
      end

      # Start the agent
      {:ok, agent} = MyApp.CodingAgent.start_link()

      # Run a task
      {:ok, %Clementine.Result.Completed{} = result} =
        Clementine.AgentServer.run(agent, "Add a fibonacci function to lib/math.ex")

      result.output

  ## Configuration

  The following options can be set at compile time via `use Clementine.AgentServer`:

  - `:name` - Required. The agent's name for identification.
  - `:model` - The LLM model to use (default: from config)
  - `:tools` - List of tool modules (default: [])
  - `:system` - System prompt (default: "")
  - `:max_iterations` - Maximum loop iterations (default: from config)

  Runtime options can override compile-time options when calling `start_link/1`.

  """

  @type agent :: GenServer.server()

  defmodule State do
    @moduledoc false
    defstruct [
      :name,
      :model,
      :system,
      :tools,
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
  - `:model` - LLM model reference (default: from config)
  - `:tools` - List of tool modules
  - `:system` - System prompt
  - `:max_iterations` - Maximum loop iterations
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use GenServer

      @agent_name Keyword.fetch!(opts, :name)
      @agent_model Keyword.get(opts, :model)
      @agent_tools Keyword.get(opts, :tools, [])
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
        `Clementine.AgentServer.fork/3` to seed the new agent with the source's history.
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

        state = %Clementine.AgentServer.State{
          name: @agent_name,
          model: Keyword.get(opts, :model, @agent_model || default_model),
          system: Keyword.get(opts, :system, @agent_system),
          tools: @agent_tools,
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
      def handle_call({:run, prompt}, _from, state) do
        case running_task_ids(state) do
          [] ->
            # Run synchronously, in this process — the ephemeral lifecycle
            # is single-writer by construction.
            case execute_turn(turn_rollout(state, prompt)) do
              {:ok, %Clementine.Result.Completed{} = result} ->
                {:reply, {:ok, result}, apply_history(state, result)}

              {:error, _result} = error ->
                {:reply, error, state}
            end

          task_ids ->
            {:reply, {:error, {:agent_busy, task_ids}}, state}
        end
      end

      @impl true
      def handle_call({:run_async, prompt}, _from, state) do
        case running_task_ids(state) do
          [] ->
            task_id = generate_task_id()
            rollout = turn_rollout(state, prompt)

            # async_nolink so a crash in the turn doesn't take down the agent
            task =
              Task.Supervisor.async_nolink(Clementine.TaskSupervisor, fn ->
                execute_turn(rollout)
              end)

            entry = %{task: task, status: :running, waiters: []}
            tasks = Map.put(state.tasks, task_id, entry)
            {:reply, {:ok, task_id}, %{state | tasks: tasks}}

          task_ids ->
            {:reply, {:error, {:agent_busy, task_ids}}, state}
        end
      end

      @impl true
      def handle_call({:run_stream, prompt, consumer, tag}, _from, state)
          when is_pid(consumer) and is_reference(tag) do
        case running_task_ids(state) do
          [] ->
            task_id = generate_task_id()
            rollout = turn_rollout(state, prompt)
            consumer_monitor_ref = Process.monitor(consumer)

            # Stamped events flow straight from the turn's execution to the
            # consumer via the forwarder; only the terminal result routes
            # back through this server (for the history fold).
            task =
              Task.Supervisor.async_nolink(Clementine.TaskSupervisor, fn ->
                execute_turn(rollout, [forward_to: {consumer, tag}], Clementine.Events.Forwarder)
              end)

            entry = %{
              task: task,
              status: :running,
              waiters: [],
              stream_consumer: consumer,
              consumer_monitor_ref: consumer_monitor_ref,
              tag: tag
            }

            tasks = Map.put(state.tasks, task_id, entry)
            {:reply, {:ok, task_id, self(), task.pid}, %{state | tasks: tasks}}

          task_ids ->
            {:reply, {:error, {:agent_busy, task_ids}}, state}
        end
      end

      @impl true
      def handle_call({:cancel_stream, task_id}, _from, state) do
        case Map.get(state.tasks, task_id) do
          %{status: :running, stream_consumer: _consumer, task: task} ->
            demonitor_stream_consumer(Map.get(state.tasks, task_id))
            Task.shutdown(task, :brutal_kill)
            {:reply, :ok, %{state | tasks: Map.delete(state.tasks, task_id)}}

          _ ->
            {:reply, :ok, state}
        end
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
            {:reply, result, %{state | tasks: tasks}}
        end
      end

      @impl true
      def handle_call(:get_history, _from, state) do
        {:reply, state.history, state}
      end

      @impl true
      def handle_call(:clear_history, _from, state) do
        case running_task_ids(state) do
          [] -> {:reply, :ok, %{state | history: []}}
          task_ids -> {:reply, {:error, {:agent_busy, task_ids}}, state}
        end
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
            demonitor_stream_consumer(task_info)
            state = maybe_apply_task_history(state, task_info, result)
            maybe_notify_stream_consumer(task_info, result)
            tasks = finish_task(state.tasks, task_id, task_info, :completed, result)
            {:noreply, %{state | tasks: tasks}}

          nil ->
            {:noreply, state}
        end
      end

      @impl true
      def handle_info({:DOWN, ref, :process, _pid, :normal}, state) do
        case find_stream_by_consumer_monitor_ref(state.tasks, ref) do
          {task_id, task_info} ->
            Task.shutdown(task_info.task, :brutal_kill)
            {:noreply, %{state | tasks: Map.delete(state.tasks, task_id)}}

          nil ->
            # Normal task exits follow a successful {ref, result} which already
            # handled the task. Process.demonitor(:flush) usually eats these,
            # but they can arrive if the demonitor races. Safe to ignore.
            {:noreply, state}
        end
      end

      @impl true
      def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
        cond do
          stream = find_stream_by_consumer_monitor_ref(state.tasks, ref) ->
            {task_id, task_info} = stream
            Task.shutdown(task_info.task, :brutal_kill)
            {:noreply, %{state | tasks: Map.delete(state.tasks, task_id)}}

          task = find_task_by_ref(state.tasks, ref) ->
            # Abnormal exit or :shutdown — task crashed or was terminated
            {task_id, %{status: :running} = task_info} = task
            result = {:error, {:task_crashed, reason}}
            demonitor_stream_consumer(task_info)
            notify_stream_consumer(task_info, result)
            tasks = finish_task(state.tasks, task_id, task_info, :failed, result)
            {:noreply, %{state | tasks: tasks}}

          true ->
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

      # One turn = one ephemeral run of the rollout, through the same
      # Agent/Rollout/Run/Runner path `Clementine.run/3` uses. Returns that
      # facade's contract: {:ok, Completed} | {:error, other_terminal}.
      defp execute_turn(rollout, create_opts \\ [], sink \\ Clementine.Events.Null) do
        {ref, ctx} = Clementine.Lifecycle.Ephemeral.create(create_opts)
        run = Clementine.Run.new(ref: ref, rollout: rollout)

        try do
          case Clementine.execute_ephemeral(run, ctx, sink) do
            %Clementine.Result.Completed{} = completed -> {:ok, completed}
            other -> {:error, other}
          end
        after
          Clementine.Lifecycle.Ephemeral.delete(ctx)
        end
      end

      defp turn_rollout(state, prompt) do
        agent =
          Clementine.Agent.new(
            model: state.model,
            instructions: state.system,
            tools: state.tools,
            defaults: [max_iterations: state.max_iterations]
          )

        Clementine.Rollout.new(
          agent: agent,
          input: prompt,
          messages: state.history,
          context: state.context
        )
      end

      # The history fold: history ++ [input_message] ++ generated messages —
      # stated this way so the fold cannot silently drop user input.
      defp apply_history(state, %Clementine.Result.Completed{} = result) do
        %{state | history: state.history ++ [result.input_message | result.messages]}
      end

      defp validate_history!(history) when is_list(history) do
        Enum.each(history, fn
          %Clementine.LLM.Message.UserMessage{} ->
            :ok

          %Clementine.LLM.Message.AssistantMessage{} ->
            :ok

          %Clementine.LLM.Message.ToolResultMessage{} ->
            :ok

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

      defp generate_task_id do
        :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      end

      defp find_task_by_ref(tasks, ref) do
        Enum.find_value(tasks, fn
          {task_id, %{task: %Task{ref: ^ref}} = info} -> {task_id, info}
          _ -> nil
        end)
      end

      defp find_stream_by_consumer_monitor_ref(tasks, ref) do
        Enum.find_value(tasks, fn
          {task_id, %{consumer_monitor_ref: ^ref} = info} -> {task_id, info}
          _ -> nil
        end)
      end

      defp running_task_ids(%{tasks: tasks}) do
        tasks
        |> Enum.flat_map(fn
          {task_id, %{status: :running}} -> [task_id]
          _ -> []
        end)
        |> Enum.sort()
      end

      defp notify_stream_consumer(%{stream_consumer: consumer, tag: tag}, result) do
        send(consumer, {:clementine_stream_done, tag, result})
      end

      defp notify_stream_consumer(_task_info, _result), do: :ok

      defp maybe_notify_stream_consumer(%{stream_consumer: consumer} = task_info, result) do
        if Process.alive?(consumer) do
          notify_stream_consumer(task_info, result)
        else
          :ok
        end
      end

      defp maybe_notify_stream_consumer(task_info, result) do
        notify_stream_consumer(task_info, result)
      end

      defp maybe_apply_task_history(
             state,
             %{stream_consumer: consumer},
             {:ok, %Clementine.Result.Completed{} = result}
           ) do
        if Process.alive?(consumer), do: apply_history(state, result), else: state
      end

      defp maybe_apply_task_history(
             state,
             _task_info,
             {:ok, %Clementine.Result.Completed{} = result}
           ) do
        apply_history(state, result)
      end

      defp maybe_apply_task_history(state, _task_info, _result), do: state

      defp demonitor_stream_consumer(%{consumer_monitor_ref: ref}) do
        Process.demonitor(ref, [:flush])
      end

      defp demonitor_stream_consumer(_task_info), do: :ok

      # Transition a task to a terminal state, replying to any blocked waiters.
      # If waiters exist, the task entry is removed (waiters got the result).
      # If no waiters, the entry is kept so a later await/3 can retrieve it.
      defp finish_task(tasks, task_id, task_info, status, result) do
        waiters = Map.get(task_info, :waiters, [])

        for {from, timer_ref} <- waiters do
          if timer_ref, do: Process.cancel_timer(timer_ref)
          GenServer.reply(from, result)
        end

        cond do
          Map.has_key?(task_info, :stream_consumer) ->
            Map.delete(tasks, task_id)

          waiters == [] ->
            Map.put(tasks, task_id, %{
              status: status,
              result: result,
              completed_at: System.monotonic_time(:millisecond)
            })

          true ->
            Map.delete(tasks, task_id)
        end
      end
    end
  end

  # Public API functions that work with any agent process

  @doc """
  Runs a prompt synchronously on an agent.

  Returns `{:ok, %Clementine.Result.Completed{}}` — final output, generated
  messages, and usage — or `{:error, result}` carrying the other terminal
  `Clementine.Result` variants (`Failed`, `Cancelled`, `Interrupted`).
  Returns `{:error, {:agent_busy, task_ids}}` if an async run is already
  active for this conversational agent.
  """
  def run(agent, prompt) when is_binary(prompt) do
    GenServer.call(agent, {:run, prompt}, :infinity)
  end

  @doc """
  Runs a prompt asynchronously on an agent.

  Returns `{:ok, task_id}` immediately. Use `await/3` to get the result.
  Returns `{:error, {:agent_busy, task_ids}}` if another run is active.
  """
  def run_async(agent, prompt) when is_binary(prompt) do
    GenServer.call(agent, {:run_async, prompt})
  end

  @doc """
  Streams a prompt execution on an agent.

  Returns a lazy enumerable of stamped `Clementine.Event` structs in
  `(epoch, seq)` order, ending with `{:result, result}` carrying the
  terminal `Clementine.Result` (any variant). When the run cannot start or
  its process dies, the final element is `{:error, reason}` instead —
  `{:agent_busy, task_ids}`, `{:agent_down, reason}`, or
  `{:task_crashed, reason}`.

  A run that completes updates the agent's conversation history exactly as
  `run/2` does. Abandoning the stream cancels the run.

  ## Example

      Clementine.AgentServer.stream(agent, "Explain this code")
      |> Enum.each(fn
        %Clementine.Event{type: :text_delta, payload: %{content: text}} -> IO.write(text)
        {:result, %Clementine.Result.Completed{}} -> IO.puts("\\n[done]")
        _ -> :ok
      end)
  """
  def stream(agent, prompt) when is_binary(prompt) do
    Stream.resource(
      fn ->
        tag = make_ref()

        case start_stream(agent, prompt, tag) do
          {:ok, task_id, agent_pid, task_pid} ->
            agent_monitor_ref = Process.monitor(agent_pid)
            {:running, agent, tag, task_id, agent_monitor_ref, task_pid}

          {:error, reason} ->
            {:emit, [{:error, reason}]}
        end
      end,
      &next_stream_event/1,
      &cleanup_stream/1
    )
  end

  defp start_stream(agent, prompt, tag) do
    GenServer.call(agent, {:run_stream, prompt, self(), tag}, :infinity)
  catch
    :exit, reason -> {:error, {:agent_down, reason}}
  end

  defp next_stream_event({:emit, []}) do
    {:halt, :done}
  end

  defp next_stream_event({:emit, [item | rest]}) do
    {[item], {:emit, rest}}
  end

  defp next_stream_event(:done) do
    {:halt, :done}
  end

  defp next_stream_event({:running, _agent, tag, _task_id, agent_monitor_ref, task_pid} = state) do
    receive do
      {:clementine_stream_event, ^tag, %Clementine.Event{} = event} ->
        {[event], state}

      {:clementine_stream_done, ^tag, result} ->
        demonitor_agent(agent_monitor_ref)
        drain_stream_messages(tag)
        {[done_element(result)], :done}

      {:DOWN, ^agent_monitor_ref, :process, _pid, reason} ->
        terminate_stream_task(task_pid)
        drain_stream_messages(tag)
        {[{:error, {:agent_down, reason}}], :done}
    end
  end

  # The terminal element: any Result variant rides in {:result, _} — the
  # result is truth, whichever way the run ended; a bare {:error, reason}
  # is reserved for runs that never produced one (crashed task).
  defp done_element({:ok, %Clementine.Result.Completed{} = result}), do: {:result, result}

  defp done_element({:error, %struct{} = result})
       when struct in [
              Clementine.Result.Failed,
              Clementine.Result.Cancelled,
              Clementine.Result.Interrupted
            ],
       do: {:result, result}

  defp done_element({:error, reason}), do: {:error, reason}

  defp cleanup_stream({:running, agent, tag, task_id, agent_monitor_ref, task_pid}) do
    demonitor_agent(agent_monitor_ref)

    case cancel_stream(agent, task_id) do
      :ok -> :ok
      {:error, _reason} -> terminate_stream_task(task_pid)
    end

    drain_stream_messages(tag)
  end

  defp cleanup_stream(_state), do: :ok

  defp cancel_stream(agent, task_id) do
    GenServer.call(agent, {:cancel_stream, task_id}, 5_000)
  catch
    :exit, reason -> {:error, reason}
  end

  defp demonitor_agent(ref) do
    Process.demonitor(ref, [:flush])
  end

  defp drain_stream_messages(tag) do
    receive do
      {:clementine_stream_event, ^tag, _event} -> drain_stream_messages(tag)
      {:clementine_stream_done, ^tag, _result} -> drain_stream_messages(tag)
    after
      0 -> :ok
    end
  end

  defp terminate_stream_task(task_pid) when is_pid(task_pid) do
    task_ref = Process.monitor(task_pid)
    Process.exit(task_pid, :kill)

    receive do
      {:DOWN, ^task_ref, :process, ^task_pid, _reason} -> :ok
    after
      500 -> Process.demonitor(task_ref, [:flush])
    end

    :ok
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

  - `{:ok, %Clementine.Result.Completed{}}` — the turn completed
  - `{:error, result}` — the other terminal `Clementine.Result` variants
  - `{:error, {:task_crashed, reason}}` — the task process crashed
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

  Returns `{:error, {:agent_busy, task_ids}}` if an async run is active.
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
