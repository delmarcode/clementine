defmodule Clementine do
  @moduledoc """
  Clementine - A simple, process-oriented agent framework for Elixir.

  Clementine provides a straightforward way to build AI agents using Elixir's
  process model. Inspired by Claude Code's architecture, it implements the
  gather→act→verify loop pattern with tools and verification.

  ## Quick Start

      # Define an agent
      defmodule MyAgent do
        use Clementine.Agent,
          name: "my_agent",
          model: :claude_sonnet,
          tools: [MyApp.Tools.ReadFile, MyApp.Tools.WriteFile],
          system: "You are a helpful assistant."
      end

      # Start and use it
      {:ok, agent} = MyAgent.start_link()
      {:ok, result} = Clementine.run(agent, "Hello!")

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

  Verifiers check results after each action. Define them with `Clementine.Verifier`:

      defmodule MyApp.Verifiers.TestsPassing do
        use Clementine.Verifier

        @impl true
        def verify(_result, context) do
          case System.cmd("mix", ["test"], cd: context.working_dir) do
            {_, 0} -> :ok
            {output, _} -> {:retry, "Tests failed: \#{output}"}
          end
        end
      end

  ### Agents

  Agents are GenServers that run the agentic loop. Define them with `Clementine.Agent`:

      defmodule MyAgent do
        use Clementine.Agent,
          name: "my_agent",
          model: :claude_sonnet,
          tools: [MyApp.Tools.Echo],
          verifiers: [MyApp.Verifiers.TestsPassing],
          system: "You are helpful."
      end

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
        ],
        gpt_5: [
          provider: :openai,
          id: "gpt-5",
          defaults: [max_output_tokens: 4096]
        ]

  """

  alias Clementine.Agent

  @doc """
  Runs a prompt on an agent synchronously.

  ## Example

      {:ok, agent} = MyAgent.start_link()
      {:ok, result} = Clementine.run(agent, "Hello!")

  ## Returns

  - `{:ok, result}` - The agent's text response
  - `{:error, reason}` - If something went wrong

  """
  defdelegate run(agent, prompt), to: Agent

  @doc """
  Runs a prompt on an agent asynchronously.

  Returns immediately with a task ID. Use `await/3` to get the result.

  ## Example

      {:ok, task_id} = Clementine.run_async(agent, "Long running task")
      # ... do other things ...
      {:ok, result} = Clementine.await(agent, task_id)

  """
  defdelegate run_async(agent, prompt), to: Agent

  @doc """
  Awaits the result of an async task.

  Blocks until the task completes or the timeout expires (default: 5000ms).
  Returns the same `{:ok, text}` / `{:error, reason}` contract as `run/2`.
  The task is removed from state after retrieval.

  ## Example

      {:ok, task_id} = Clementine.run_async(agent, "Long running task")
      {:ok, result} = Clementine.await(agent, task_id)

      # With custom timeout
      {:ok, result} = Clementine.await(agent, task_id, 30_000)

  """
  defdelegate await(agent, task_id, timeout \\ 5000), to: Agent

  @doc """
  Gets the status of an async task.

  Non-blocking, read-only check. Use `await/3` to retrieve results.

  ## Returns

  - `{:ok, :running}` - Task is still running
  - `{:ok, :completed}` - Task function returned (result may be ok or error)
  - `{:ok, :failed}` - Task process crashed (exception/exit)
  - `{:error, :not_found}` - Unknown task ID

  """
  defdelegate status(agent, task_id), to: Agent

  @doc """
  Gets the conversation history from an agent.

  The history is a list of messages in chronological order.
  """
  defdelegate get_history(agent), to: Agent

  @doc """
  Clears the conversation history.

  This starts a fresh conversation.
  """
  defdelegate clear_history(agent), to: Agent

  @doc """
  Forks an agent, creating a new agent with the same history.

  This is useful for exploring different paths in a conversation.

  ## Example

      {:ok, forked} = Clementine.fork(agent, MyAgent)
      # forked has the same history as agent

  """
  defdelegate fork(agent, new_agent_module, opts \\ []), to: Agent

  @doc """
  Streams a prompt execution, returning events as they occur.

  ## Example

      Clementine.stream(agent, "Explain this code")
      |> Stream.each(fn
        {:text_delta, chunk} -> IO.write(chunk)
        {:tool_use_start, _id, name} -> IO.puts("\\n[Calling \#{name}...]")
        {:tool_result, _id, result} -> IO.puts("[Done]")
        _ -> :ok
      end)
      |> Stream.run()

  Note: This is a simplified streaming interface. For full streaming support
  with real-time LLM output, use the underlying `Clementine.LLM.stream/5` directly.
  """
  def stream(agent, prompt) do
    # For now, this wraps run/2 and emits events
    # A full implementation would stream from the LLM
    Stream.resource(
      fn ->
        task = Task.async(fn -> run(agent, prompt) end)
        task
      end,
      fn task ->
        case Task.yield(task, 100) do
          nil ->
            {[], task}

          {:ok, {:ok, result}} ->
            {[{:text, result}, {:done, :success}], :done}

          {:ok, {:error, reason}} ->
            {[{:error, reason}, {:done, :error}], :done}

          {:exit, reason} ->
            {[{:error, {:exit, reason}}, {:done, :error}], :done}
        end
      end,
      fn
        :done -> :ok
        task -> Task.shutdown(task, :brutal_kill)
      end
    )
  end

  @doc """
  Executes a tool directly without the LLM loop.

  This is useful for testing tools or running them manually.

  ## Example

      {:ok, content} = Clementine.Tool.run(MyApp.Tools.ReadFile, %{path: "README.md"})

  """
  def tool_run(tool_module, args, context \\ %{}) do
    tool_module.execute(args, context)
  end
end
