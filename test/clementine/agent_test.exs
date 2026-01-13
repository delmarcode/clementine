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
        # Add a small delay
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
