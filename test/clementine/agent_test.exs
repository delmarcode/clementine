defmodule Clementine.AgentTest do
  use ExUnit.Case, async: false  # Need sync for Mox global mode
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  # Define a test agent
  defmodule TestAgent do
    use Clementine.Agent,
      name: "test_agent",
      model: :claude_sonnet,
      tools: [],
      system: "You are a test assistant."
  end

  setup do
    # The TaskSupervisor is started by the application
    :ok
  end

  describe "start_link/1" do
    test "starts the agent process" do
      assert {:ok, pid} = TestAgent.start_link()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts name option for registration" do
      assert {:ok, pid} = TestAgent.start_link(name: :test_agent)
      assert Process.whereis(:test_agent) == pid
      GenServer.stop(pid)
    end
  end

  describe "__config__/0" do
    test "returns compile-time configuration" do
      config = TestAgent.__config__()

      assert config.name == "test_agent"
      assert config.model == :claude_sonnet
      assert config.tools == []
      assert config.system == "You are a test assistant."
    end
  end

  describe "run/2" do
    test "executes prompt and returns result" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %{
           content: [%{type: :text, text: "Hello from agent!"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      assert {:ok, "Hello from agent!"} = Clementine.Agent.run(agent, "Hi")

      GenServer.stop(agent)
    end

    test "updates history after successful run" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %{
           content: [%{type: :text, text: "Response 1"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, _} = Clementine.Agent.run(agent, "First message")
      history = Clementine.Agent.get_history(agent)

      assert length(history) == 2  # user + assistant
      assert Enum.at(history, 0).role == :user
      assert Enum.at(history, 1).role == :assistant

      GenServer.stop(agent)
    end
  end

  describe "get_history/1" do
    test "returns empty history initially" do
      {:ok, agent} = TestAgent.start_link()

      assert [] = Clementine.Agent.get_history(agent)

      GenServer.stop(agent)
    end
  end

  describe "clear_history/1" do
    test "clears the conversation history" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %{
           content: [%{type: :text, text: "Response"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, _} = Clementine.Agent.run(agent, "Message")
      assert length(Clementine.Agent.get_history(agent)) > 0

      :ok = Clementine.Agent.clear_history(agent)
      assert [] = Clementine.Agent.get_history(agent)

      GenServer.stop(agent)
    end
  end

  describe "run_async/2" do
    test "returns task_id immediately" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(10)

        {:ok,
         %{
           content: [%{type: :text, text: "Async response"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.Agent.run_async(agent, "Async message")

      assert is_binary(task_id)
      assert byte_size(task_id) > 0

      # Wait a bit for the task to complete
      Process.sleep(50)

      assert {:ok, :completed} = Clementine.Agent.status(agent, task_id)

      GenServer.stop(agent)
    end

    test "agent survives when async task crashes" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        raise "simulated LLM failure"
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.Agent.run_async(agent, "This will crash")

      # Wait for the task to crash and the :DOWN message to be processed
      Process.sleep(100)

      # Agent should still be alive
      assert Process.alive?(agent)

      # Task should be marked as failed
      assert {:ok, :failed} = Clementine.Agent.status(agent, task_id)

      GenServer.stop(agent)
    end

    test "status returns :running for in-progress task" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(500)

        {:ok,
         %{
           content: [%{type: :text, text: "Delayed response"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.Agent.run_async(agent, "Slow task")

      assert {:ok, :running} = Clementine.Agent.status(agent, task_id)

      GenServer.stop(agent)
    end
  end

  describe "await/3" do
    test "blocks until async task completes and returns result" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(30)

        {:ok,
         %{
           content: [%{type: :text, text: "Awaited response"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.Agent.run_async(agent, "Async message")

      # await blocks until the result is ready
      assert {:ok, "Awaited response"} = Clementine.Agent.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "returns result immediately when task already completed" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %{
           content: [%{type: :text, text: "Fast response"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.Agent.run_async(agent, "Quick task")

      # Let it finish
      Process.sleep(50)
      assert {:ok, :completed} = Clementine.Agent.status(agent, task_id)

      # await returns the result and cleans up
      assert {:ok, "Fast response"} = Clementine.Agent.await(agent, task_id)

      # Task entry is consumed — status and await both return :not_found
      assert {:error, :not_found} = Clementine.Agent.status(agent, task_id)
      assert {:error, :not_found} = Clementine.Agent.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "returns error when async task crashes" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        raise "boom"
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.Agent.run_async(agent, "Crash task")

      assert {:error, {:task_crashed, _reason}} = Clementine.Agent.await(agent, task_id)

      # Agent still alive
      assert Process.alive?(agent)

      GenServer.stop(agent)
    end

    test "returns {:error, :timeout} when task takes too long" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(5_000)

        {:ok,
         %{
           content: [%{type: :text, text: "Too slow"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.Agent.run_async(agent, "Slow task")

      assert {:error, :timeout} = Clementine.Agent.await(agent, task_id, 50)

      # Task is still running (timeout doesn't cancel it)
      assert {:ok, :running} = Clementine.Agent.status(agent, task_id)

      GenServer.stop(agent)
    end

    test "returns {:error, :not_found} for unknown task_id" do
      {:ok, agent} = TestAgent.start_link()

      assert {:error, :not_found} = Clementine.Agent.await(agent, "nonexistent")

      GenServer.stop(agent)
    end

    test "await with :infinity timeout blocks until completion" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(50)

        {:ok,
         %{
           content: [%{type: :text, text: "Infinite patience"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.Agent.run_async(agent, "Wait forever")

      assert {:ok, "Infinite patience"} = Clementine.Agent.await(agent, task_id, :infinity)

      GenServer.stop(agent)
    end

    test "completed status reflects Loop.run error results" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:error, :max_iterations_exceeded}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.Agent.run_async(agent, "Will error")

      # Loop.run returned {:error, ...} but the function completed normally
      assert {:error, :max_iterations_exceeded} = Clementine.Agent.await(agent, task_id)

      GenServer.stop(agent)
    end
  end

  describe "task cleanup" do
    test "sweeps unawaited terminal tasks after TTL expires" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %{
           content: [%{type: :text, text: "Forgotten result"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.Agent.run_async(agent, "Fire and forget")

      # Let the task complete
      Process.sleep(50)
      assert {:ok, :completed} = Clementine.Agent.status(agent, task_id)

      # Backdate the completed_at timestamp so the sweep will evict it
      state = GenServer.call(agent, :get_state)
      old_entry = Map.get(state.tasks, task_id)
      backdated = %{old_entry | completed_at: System.monotonic_time(:millisecond) - :timer.minutes(60)}
      new_tasks = Map.put(state.tasks, task_id, backdated)
      # We can't set state directly, so trigger cleanup by sending the message
      # after updating via :sys.replace_state
      :sys.replace_state(agent, fn s -> %{s | tasks: new_tasks} end)

      # Trigger sweep
      send(agent, :task_cleanup)
      Process.sleep(10)

      # Task should be gone
      assert {:error, :not_found} = Clementine.Agent.status(agent, task_id)

      GenServer.stop(agent)
    end

    test "does not sweep tasks within TTL" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %{
           content: [%{type: :text, text: "Recent result"}],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.Agent.run_async(agent, "Recent task")

      Process.sleep(50)
      assert {:ok, :completed} = Clementine.Agent.status(agent, task_id)

      # Trigger sweep — task is fresh, should survive
      send(agent, :task_cleanup)
      Process.sleep(10)

      assert {:ok, :completed} = Clementine.Agent.status(agent, task_id)

      GenServer.stop(agent)
    end
  end

  describe "runtime configuration" do
    test "allows overriding model at runtime" do
      {:ok, agent} = TestAgent.start_link(model: :claude_opus)

      state = GenServer.call(agent, :get_state)
      assert state.model == :claude_opus

      GenServer.stop(agent)
    end

    test "allows setting working_dir" do
      {:ok, agent} = TestAgent.start_link(working_dir: "/tmp")

      state = GenServer.call(agent, :get_state)
      assert state.context.working_dir == "/tmp"

      GenServer.stop(agent)
    end
  end
end
