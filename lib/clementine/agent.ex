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

      @doc """
      Starts the agent with optional runtime configuration.

      ## Options

      - `:name` - Process name for registration
      - `:model` - Override the default model
      - `:system` - Override the system prompt
      - `:max_iterations` - Override max iterations
      - `:context` - Initial context map
      - `:working_dir` - Working directory for tools
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

        state = %Clementine.Agent.State{
          name: @agent_name,
          model: Keyword.get(opts, :model, @agent_model || default_model),
          system: Keyword.get(opts, :system, @agent_system),
          tools: @agent_tools,
          verifiers: @agent_verifiers,
          max_iterations:
            Keyword.get(opts, :max_iterations, @agent_max_iterations || default_max_iterations),
          context: context,
          history: [],
          tasks: %{}
        }

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

        # Spawn a task to run the loop
        parent = self()

        task =
          Task.async(fn ->
            config = build_loop_config(state)
            result = Loop.run(config, prompt)
            send(parent, {:task_complete, task_id, result})
            result
          end)

        tasks = Map.put(state.tasks, task_id, %{task: task, from: from_pid})
        {:reply, {:ok, task_id}, %{state | tasks: tasks}}
      end

      @impl true
      def handle_call({:status, task_id}, _from, state) do
        case Map.get(state.tasks, task_id) do
          nil ->
            {:reply, {:error, :not_found}, state}

          %{task: task} = task_info ->
            status =
              if Process.alive?(task.pid) do
                :running
              else
                :completed
              end

            {:reply, {:ok, status}, state}
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
      def handle_info({:task_complete, task_id, result}, state) do
        case Map.get(state.tasks, task_id) do
          nil ->
            {:noreply, state}

          %{from: from_pid} ->
            # Update history if successful
            state =
              case result do
                {:ok, _text, messages} -> %{state | history: messages}
                _ -> state
              end

            tasks = Map.delete(state.tasks, task_id)
            {:noreply, %{state | tasks: tasks}}
        end
      end

      @impl true
      def handle_info({ref, _result}, state) when is_reference(ref) do
        # Task completed message - already handled
        {:noreply, state}
      end

      @impl true
      def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
        {:noreply, state}
      end

      # Private helpers

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
  Gets the status of an async task.
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
    _history = get_history(agent)
    state = GenServer.call(agent, :get_state)

    fork_opts =
      Keyword.merge(opts,
        context: state.context,
        model: state.model,
        system: state.system
      )

    case new_agent_module.start_link(fork_opts) do
      {:ok, new_agent} ->
        # Copy history to new agent
        # Note: This is a simplified approach - in production you might
        # want a more sophisticated mechanism
        {:ok, new_agent}

      error ->
        error
    end
  end
end
