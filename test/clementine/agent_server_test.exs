defmodule Clementine.AgentServerTest do
  # Need sync for Mox global mode
  use ExUnit.Case, async: false
  import Mox
  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Response

  setup :set_mox_global
  setup :verify_on_exit!

  # Define a test agent
  defmodule TestAgent do
    use Clementine.AgentServer,
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
         %Response{
           content: [Content.text("Hello from agent!")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      assert {:ok, "Hello from agent!"} = Clementine.AgentServer.run(agent, "Hi")

      GenServer.stop(agent)
    end

    test "updates history after successful run" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Response 1")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, _} = Clementine.AgentServer.run(agent, "First message")
      history = Clementine.AgentServer.get_history(agent)

      # user + assistant
      assert length(history) == 2
      assert Enum.at(history, 0).role == :user
      assert Enum.at(history, 1).role == :assistant

      GenServer.stop(agent)
    end
  end

  describe "stream/2" do
    test "emits real streaming events and updates history" do
      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:content_block_start, 0, :text},
          {:text_delta, "Hello "},
          {:text_delta, "stream!"},
          {:content_block_stop, 0},
          {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
          {:message_stop}
        ]
      end)

      {:ok, agent} = TestAgent.start_link()

      events = Clementine.AgentServer.stream(agent, "Hi") |> Enum.to_list()

      assert {:text_delta, "Hello "} in events
      assert {:text_delta, "stream!"} in events
      assert List.last(events) == {:done, :success}

      history = Clementine.AgentServer.get_history(agent)
      assert length(history) == 2
      assert Enum.at(history, 0).role == :user
      assert Enum.at(history, 1).role == :assistant

      GenServer.stop(agent)
    end

    test "emits streaming errors once before done" do
      error = %{"type" => "stream_parse_error", "message" => "bad stream"}

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:text_delta, "partial"},
          {:error, error}
        ]
      end)

      {:ok, agent} = TestAgent.start_link()

      events = Clementine.AgentServer.stream(agent, "Hi") |> Enum.to_list()

      assert events == [
               {:loop_event, {:loop_start, "Hi"}},
               {:loop_event, {:iteration_start, 1}},
               {:loop_event, :llm_call_start},
               {:text_delta, "partial"},
               {:error, error},
               {:loop_event, {:llm_call_end, {:error, error}}},
               {:loop_event, {:loop_end, {:error, error}}},
               {:done, :error}
             ]

      assert Clementine.AgentServer.get_history(agent) == []

      GenServer.stop(agent)
    end

    test "returns busy error when another task is active" do
      Clementine.LLM.MockClient
      |> stub(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(100)

        {:ok,
         %Response{
           content: [Content.text("Async response")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Async task")

      assert [
               {:error, {:agent_busy, [^task_id]}},
               {:done, :error}
             ] = Clementine.AgentServer.stream(agent, "Hi") |> Enum.to_list()

      assert {:ok, "Async response"} = Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "emits an error and terminates when the agent exits before stream completion" do
      test_pid = self()

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        send(test_pid, :stream_started)
        Process.sleep(:infinity)
      end)

      {:ok, agent} = TestAgent.start_link()

      consumer =
        Task.async(fn ->
          Clementine.AgentServer.stream(agent, "Hi") |> Enum.to_list()
        end)

      assert_receive :stream_started
      GenServer.stop(agent)

      events = Task.await(consumer, 1_000)

      assert {:error, {:agent_down, :normal}} in events
      assert List.last(events) == {:done, :error}
    end

    test "drains queued stream messages when consumer stops early" do
      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:content_block_start, 0, :text}
          | Enum.map(1..100, &{:text_delta, Integer.to_string(&1)})
        ] ++
          [
            {:content_block_stop, 0},
            {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
            {:message_stop}
          ]
      end)

      {:ok, agent} = TestAgent.start_link()

      assert [_loop_start, _iteration_start, _llm_call_start, _message_start] =
               Clementine.AgentServer.stream(agent, "Hi") |> Enum.take(4)

      Process.sleep(50)
      assert_no_stream_mailbox_messages()

      GenServer.stop(agent)
    end

    test "cancels stream task when consumer exits before cleanup" do
      test_pid = self()

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        send(test_pid, :stream_started)
        Process.sleep(200)

        [
          {:message_start, %{"id" => "msg_1"}},
          {:text_delta, "late"},
          {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
          {:message_stop}
        ]
      end)

      {:ok, agent} = TestAgent.start_link()

      consumer =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert {:ok, task_id} = GenServer.call(agent, {:run_stream, "Hi", consumer}, :infinity)
      assert_receive :stream_started

      send(consumer, :stop)

      assert_eventually(fn ->
        assert {:error, :not_found} = Clementine.AgentServer.status(agent, task_id)
      end)

      Process.sleep(250)
      assert Clementine.AgentServer.get_history(agent) == []

      GenServer.stop(agent)
    end
  end

  describe "get_history/1" do
    test "returns empty history initially" do
      {:ok, agent} = TestAgent.start_link()

      assert [] = Clementine.AgentServer.get_history(agent)

      GenServer.stop(agent)
    end
  end

  describe "clear_history/1" do
    test "clears the conversation history" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Response")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, _} = Clementine.AgentServer.run(agent, "Message")
      assert length(Clementine.AgentServer.get_history(agent)) > 0

      :ok = Clementine.AgentServer.clear_history(agent)
      assert [] = Clementine.AgentServer.get_history(agent)

      GenServer.stop(agent)
    end

    test "rejects clearing history while an async run is active" do
      Clementine.LLM.MockClient
      |> stub(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(100)

        {:ok,
         %Response{
           content: [Content.text("Async response")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Async task")

      assert {:error, {:agent_busy, [^task_id]}} = Clementine.AgentServer.clear_history(agent)
      assert {:ok, "Async response"} = Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end
  end

  describe "run_async/2" do
    test "returns task_id immediately" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(10)

        {:ok,
         %Response{
           content: [Content.text("Async response")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Async message")

      assert is_binary(task_id)
      assert byte_size(task_id) > 0

      # Wait a bit for the task to complete
      Process.sleep(50)

      assert {:ok, :completed} = Clementine.AgentServer.status(agent, task_id)

      GenServer.stop(agent)
    end

    test "agent normalizes async LLM client exceptions" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        raise "simulated LLM failure"
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "This will fail")

      # Wait for the task to complete with a normalized error
      Process.sleep(100)

      # Agent should still be alive
      assert Process.alive?(agent)

      assert {:ok, :completed} = Clementine.AgentServer.status(agent, task_id)

      assert {:error, {:llm_exception, %{message: "simulated LLM failure"}}} =
               Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "status returns :running for in-progress task" do
      # Use stub — we don't need to assert the mock was called; we only care
      # that the task is still :running when we check status. expect/2 fails
      # because GenServer.stop kills the agent before the 500ms sleep expires,
      # and the task (async_nolink, under TaskSupervisor) may never reach the mock.
      Clementine.LLM.MockClient
      |> stub(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(500)

        {:ok,
         %Response{
           content: [Content.text("Delayed response")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Slow task")

      assert {:ok, :running} = Clementine.AgentServer.status(agent, task_id)

      GenServer.stop(agent)
    end

    test "rejects a second async run while one is already running" do
      Clementine.LLM.MockClient
      |> stub(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(100)

        {:ok,
         %Response{
           content: [Content.text("First response")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "First async task")

      assert {:error, {:agent_busy, [^task_id]}} =
               Clementine.AgentServer.run_async(agent, "Second async task")

      assert {:ok, "First response"} = Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "rejects a synchronous run while an async run is already running" do
      Clementine.LLM.MockClient
      |> stub(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(100)

        {:ok,
         %Response{
           content: [Content.text("Async response")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Async task")

      assert {:error, {:agent_busy, [^task_id]}} =
               Clementine.AgentServer.run(agent, "Sync task")

      assert {:ok, "Async response"} = Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end
  end

  describe "await/3" do
    test "blocks until async task completes and returns result" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(30)

        {:ok,
         %Response{
           content: [Content.text("Awaited response")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Async message")

      # await blocks until the result is ready
      assert {:ok, "Awaited response"} = Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "returns result immediately when task already completed" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Fast response")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Quick task")

      # Let it finish
      Process.sleep(50)
      assert {:ok, :completed} = Clementine.AgentServer.status(agent, task_id)

      # await returns the result and cleans up
      assert {:ok, "Fast response"} = Clementine.AgentServer.await(agent, task_id)

      # Task entry is consumed — status and await both return :not_found
      assert {:error, :not_found} = Clementine.AgentServer.status(agent, task_id)
      assert {:error, :not_found} = Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "returns normalized error when async LLM client raises" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        raise "boom"
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Fail task")

      assert {:error, {:llm_exception, %{message: "boom"}}} =
               Clementine.AgentServer.await(agent, task_id)

      # Agent still alive
      assert Process.alive?(agent)

      GenServer.stop(agent)
    end

    test "returns {:error, :timeout} when task takes too long" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(5_000)

        {:ok,
         %Response{
           content: [Content.text("Too slow")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Slow task")

      assert {:error, :timeout} = Clementine.AgentServer.await(agent, task_id, 50)

      # Task is still running (timeout doesn't cancel it)
      assert {:ok, :running} = Clementine.AgentServer.status(agent, task_id)

      GenServer.stop(agent)
    end

    test "returns {:error, :not_found} for unknown task_id" do
      {:ok, agent} = TestAgent.start_link()

      assert {:error, :not_found} = Clementine.AgentServer.await(agent, "nonexistent")

      GenServer.stop(agent)
    end

    test "await with :infinity timeout blocks until completion" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(50)

        {:ok,
         %Response{
           content: [Content.text("Infinite patience")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Wait forever")

      assert {:ok, "Infinite patience"} = Clementine.AgentServer.await(agent, task_id, :infinity)

      GenServer.stop(agent)
    end

    test "completed status reflects Rollout.run error results" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:error, :max_iterations_exceeded}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Will error")

      # Rollout.run returned {:error, ...} but the function completed normally
      assert {:error, :max_iterations_exceeded} = Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end
  end

  describe "task cleanup" do
    test "sweeps unawaited terminal tasks after TTL expires" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Forgotten result")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Fire and forget")

      # Let the task complete
      Process.sleep(50)
      assert {:ok, :completed} = Clementine.AgentServer.status(agent, task_id)

      # Backdate the completed_at timestamp so the sweep will evict it
      state = GenServer.call(agent, :get_state)
      old_entry = Map.get(state.tasks, task_id)

      backdated = %{
        old_entry
        | completed_at: System.monotonic_time(:millisecond) - :timer.minutes(60)
      }

      new_tasks = Map.put(state.tasks, task_id, backdated)
      # We can't set state directly, so trigger cleanup by sending the message
      # after updating via :sys.replace_state
      :sys.replace_state(agent, fn s -> %{s | tasks: new_tasks} end)

      # Trigger sweep
      send(agent, :task_cleanup)
      Process.sleep(10)

      # Task should be gone
      assert {:error, :not_found} = Clementine.AgentServer.status(agent, task_id)

      GenServer.stop(agent)
    end

    test "does not sweep tasks within TTL" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Recent result")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Recent task")

      Process.sleep(50)
      assert {:ok, :completed} = Clementine.AgentServer.status(agent, task_id)

      # Trigger sweep — task is fresh, should survive
      send(agent, :task_cleanup)
      Process.sleep(10)

      assert {:ok, :completed} = Clementine.AgentServer.status(agent, task_id)

      GenServer.stop(agent)
    end
  end

  # A second agent module used as the fork target
  defmodule ForkTargetAgent do
    use Clementine.AgentServer,
      name: "fork_target",
      model: :claude_sonnet,
      tools: [],
      system: "You are a fork target."
  end

  describe "fork/3" do
    test "forked agent preserves conversation history from source" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Source response")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, source} = TestAgent.start_link()
      {:ok, _} = Clementine.AgentServer.run(source, "Hello source")

      source_history = Clementine.AgentServer.get_history(source)
      assert length(source_history) == 2

      {:ok, forked} = Clementine.AgentServer.fork(source, ForkTargetAgent)

      forked_history = Clementine.AgentServer.get_history(forked)
      assert forked_history == source_history

      GenServer.stop(forked)
      GenServer.stop(source)
    end

    test "forked agent copies context, model, and system from source" do
      {:ok, source} = TestAgent.start_link(model: :claude_opus, context: %{custom: "data"})

      {:ok, forked} = Clementine.AgentServer.fork(source, ForkTargetAgent)

      forked_state = GenServer.call(forked, :get_state)
      assert forked_state.model == :claude_opus
      assert forked_state.system == "You are a test assistant."
      assert forked_state.context.custom == "data"

      GenServer.stop(forked)
      GenServer.stop(source)
    end

    test "forked agent can continue conversation using copied history" do
      Clementine.LLM.MockClient
      |> expect(:call, 2, fn _model, _system, messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Response #{length(messages)}")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      {:ok, source} = TestAgent.start_link()
      {:ok, _} = Clementine.AgentServer.run(source, "First message")

      {:ok, forked} = Clementine.AgentServer.fork(source, ForkTargetAgent)
      {:ok, result} = Clementine.AgentServer.run(forked, "Second message")

      # The forked agent received 2 prior messages (from source) + 1 new user message = 3
      assert result == "Response 3"

      forked_history = Clementine.AgentServer.get_history(forked)
      # 2 from source + 2 from the new run = 4
      assert length(forked_history) == 4

      GenServer.stop(forked)
      GenServer.stop(source)
    end

    test "user-supplied opts override source agent settings" do
      {:ok, source} = TestAgent.start_link()

      {:ok, forked} =
        Clementine.AgentServer.fork(source, ForkTargetAgent,
          model: :claude_haiku,
          context: %{overridden: true}
        )

      forked_state = GenServer.call(forked, :get_state)
      assert forked_state.model == :claude_haiku
      assert forked_state.context.overridden == true

      GenServer.stop(forked)
      GenServer.stop(source)
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

  describe "history validation" do
    alias Clementine.LLM.Message.{AssistantMessage, Content, UserMessage}

    test "accepts valid message structs in :history" do
      history = [
        UserMessage.new("hello"),
        AssistantMessage.new([Content.text("hi")])
      ]

      {:ok, agent} = TestAgent.start_link(history: history)
      assert Clementine.AgentServer.get_history(agent) == history
      GenServer.stop(agent)
    end

    test "rejects plain maps in :history" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _}} =
               TestAgent.start_link(history: [%{role: :user, content: "hi"}])

      assert msg =~ "must be message structs"
    end

    test "rejects non-list :history" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _}} =
               TestAgent.start_link(history: "not a list")

      assert msg =~ "must be a list of messages"
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 1 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
  end

  defp assert_eventually(fun, 1), do: fun.()

  defp assert_no_stream_mailbox_messages do
    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {:clementine_stream_event, _task_id, _event} -> true
             {:clementine_stream_done, _task_id, _result} -> true
             _message -> false
           end)
  end
end
