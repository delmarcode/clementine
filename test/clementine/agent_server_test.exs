defmodule Clementine.AgentServerTest do
  # Need sync for Mox global mode
  use ExUnit.Case, async: false
  import Mox

  alias Clementine.{Error, Event, Result}
  alias Clementine.LLM.Message.{AssistantMessage, UserMessage}

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

  defp text_events(text) do
    [
      {:text_delta, text},
      {:message_delta, %{"stop_reason" => "end_turn"},
       %{"input_tokens" => 7, "output_tokens" => 3}}
    ]
  end

  defp expect_stream(events, count \\ 1) do
    expect(Clementine.LLM.MockClient, :stream, count, fn _model,
                                                         _system,
                                                         _messages,
                                                         _tools,
                                                         _opts ->
      events
    end)
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
    test "executes prompt and returns a completed result" do
      expect_stream(text_events("Hello from agent!"))

      {:ok, agent} = TestAgent.start_link()

      assert {:ok, %Result.Completed{output: "Hello from agent!"}} =
               Clementine.AgentServer.run(agent, "Hi")

      GenServer.stop(agent)
    end

    test "updates history after successful run" do
      expect_stream(text_events("Response 1"))

      {:ok, agent} = TestAgent.start_link()

      {:ok, _} = Clementine.AgentServer.run(agent, "First message")
      history = Clementine.AgentServer.get_history(agent)

      # user + assistant
      assert length(history) == 2
      assert %UserMessage{} = Enum.at(history, 0)
      assert %AssistantMessage{} = Enum.at(history, 1)

      GenServer.stop(agent)
    end

    test "a failed turn returns the terminal result and leaves history alone" do
      expect_stream([{:error, {:api_error, 500, "boom"}}])

      {:ok, agent} = TestAgent.start_link()

      assert {:error, %Result.Failed{error: %Error{code: :provider_unavailable}}} =
               Clementine.AgentServer.run(agent, "Hi")

      assert Clementine.AgentServer.get_history(agent) == []

      GenServer.stop(agent)
    end
  end

  describe "stream/2" do
    test "emits stamped events ending with the result, and updates history" do
      expect_stream([
        {:message_start, %{"id" => "msg_1"}},
        {:content_block_start, 0, :text},
        {:text_delta, "Hello "},
        {:text_delta, "stream!"},
        {:content_block_stop, 0},
        {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
        {:message_stop}
      ])

      {:ok, agent} = TestAgent.start_link()

      output = Clementine.AgentServer.stream(agent, "Hi") |> Enum.to_list()

      assert {:result, %Result.Completed{output: "Hello stream!"}} = List.last(output)

      events = Enum.drop(output, -1)
      assert Enum.all?(events, &match?(%Event{epoch: 1}, &1))
      assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))

      text =
        events
        |> Enum.filter(&(&1.type == :text_delta))
        |> Enum.map_join(& &1.payload.content)

      assert text == "Hello stream!"

      # The done element arrives after the server applied the fold.
      history = Clementine.AgentServer.get_history(agent)
      assert length(history) == 2
      assert %UserMessage{} = Enum.at(history, 0)
      assert %AssistantMessage{} = Enum.at(history, 1)

      GenServer.stop(agent)
    end

    test "a streaming error ends with a failed result and no history change" do
      expect_stream([
        {:message_start, %{"id" => "msg_1"}},
        {:text_delta, "partial"},
        {:error, {:api_error, 529, "overloaded"}}
      ])

      {:ok, agent} = TestAgent.start_link()

      output = Clementine.AgentServer.stream(agent, "Hi") |> Enum.to_list()

      assert {:result, %Result.Failed{error: %Error{} = error}} = List.last(output)
      assert error.retryable?

      # The advisory error event precedes the terminal result.
      types = output |> Enum.drop(-1) |> Enum.map(& &1.type)
      assert types == [:iteration_start, :text_delta, :error]

      assert Clementine.AgentServer.get_history(agent) == []

      GenServer.stop(agent)
    end

    test "returns busy error when another task is active" do
      stub(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(100)
        text_events("Async response")
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Async task")

      assert [{:error, {:agent_busy, [^task_id]}}] =
               Clementine.AgentServer.stream(agent, "Hi") |> Enum.to_list()

      assert {:ok, %Result.Completed{output: "Async response"}} =
               Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "emits an error and terminates when the agent exits before stream completion" do
      test_pid = self()

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
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

      assert List.last(events) == {:error, {:agent_down, :normal}}
    end

    test "drains queued stream messages when consumer stops early" do
      expect_stream(
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
      )

      {:ok, agent} = TestAgent.start_link()

      assert [%Event{type: :iteration_start} | _] =
               Clementine.AgentServer.stream(agent, "Hi") |> Enum.take(4)

      Process.sleep(50)
      assert_no_stream_mailbox_messages()

      GenServer.stop(agent)
    end

    test "cancels stream task when consumer exits before cleanup" do
      test_pid = self()

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        send(test_pid, :stream_started)
        Process.sleep(200)
        text_events("late")
      end)

      {:ok, agent} = TestAgent.start_link()

      consumer =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert {:ok, task_id, _agent_pid, _task_pid} =
               GenServer.call(agent, {:run_stream, "Hi", consumer, make_ref()}, :infinity)

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
      expect_stream(text_events("Response"))

      {:ok, agent} = TestAgent.start_link()

      {:ok, _} = Clementine.AgentServer.run(agent, "Message")
      assert length(Clementine.AgentServer.get_history(agent)) > 0

      :ok = Clementine.AgentServer.clear_history(agent)
      assert [] = Clementine.AgentServer.get_history(agent)

      GenServer.stop(agent)
    end

    test "rejects clearing history while an async run is active" do
      stub(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(100)
        text_events("Async response")
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Async task")

      assert {:error, {:agent_busy, [^task_id]}} = Clementine.AgentServer.clear_history(agent)

      assert {:ok, %Result.Completed{output: "Async response"}} =
               Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end
  end

  describe "run_async/2" do
    test "returns task_id immediately" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(10)
        text_events("Async response")
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

    test "an LLM client exception is rescued into a failed result, not a crash" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        raise "simulated LLM failure"
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "This will fail")

      # The exception is normalized into a Failed result, so the task
      # completed — it did not crash.
      Process.sleep(100)
      assert Process.alive?(agent)
      assert {:ok, :completed} = Clementine.AgentServer.status(agent, task_id)

      assert {:error, %Result.Failed{error: %Error{code: :exception} = error}} =
               Clementine.AgentServer.await(agent, task_id)

      assert error.message =~ "simulated LLM failure"

      GenServer.stop(agent)
    end

    test "status returns :running for in-progress task" do
      # Use stub — we don't need to assert the mock was called; we only care
      # that the task is still :running when we check status. expect/2 fails
      # because GenServer.stop kills the agent before the 500ms sleep expires,
      # and the task (async_nolink, under TaskSupervisor) may never reach the mock.
      stub(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(500)
        text_events("Delayed response")
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Slow task")

      assert {:ok, :running} = Clementine.AgentServer.status(agent, task_id)

      GenServer.stop(agent)
    end

    test "rejects a second async run while one is already running" do
      stub(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(100)
        text_events("First response")
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "First async task")

      assert {:error, {:agent_busy, [^task_id]}} =
               Clementine.AgentServer.run_async(agent, "Second async task")

      assert {:ok, %Result.Completed{output: "First response"}} =
               Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "rejects a synchronous run while an async run is already running" do
      stub(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(100)
        text_events("Async response")
      end)

      {:ok, agent} = TestAgent.start_link()

      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Async task")

      assert {:error, {:agent_busy, [^task_id]}} =
               Clementine.AgentServer.run(agent, "Sync task")

      assert {:ok, %Result.Completed{output: "Async response"}} =
               Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end
  end

  describe "await/3" do
    test "blocks until async task completes and returns result" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(30)
        text_events("Awaited response")
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Async message")

      # await blocks until the result is ready
      assert {:ok, %Result.Completed{output: "Awaited response"}} =
               Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "returns result immediately when task already completed" do
      expect_stream(text_events("Fast response"))

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Quick task")

      # Let it finish
      Process.sleep(50)
      assert {:ok, :completed} = Clementine.AgentServer.status(agent, task_id)

      # await returns the result and cleans up
      assert {:ok, %Result.Completed{output: "Fast response"}} =
               Clementine.AgentServer.await(agent, task_id)

      # Task entry is consumed — status and await both return :not_found
      assert {:error, :not_found} = Clementine.AgentServer.status(agent, task_id)
      assert {:error, :not_found} = Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end

    test "returns a failed result when the async LLM client raises" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        raise "boom"
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Fail task")

      assert {:error, %Result.Failed{error: %Error{code: :exception} = error}} =
               Clementine.AgentServer.await(agent, task_id)

      assert error.message =~ "boom"

      # Agent still alive
      assert Process.alive?(agent)

      GenServer.stop(agent)
    end

    test "returns {:error, :timeout} when task takes too long" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(5_000)
        text_events("Too slow")
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
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(50)
        text_events("Infinite patience")
      end)

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Wait forever")

      assert {:ok, %Result.Completed{output: "Infinite patience"}} =
               Clementine.AgentServer.await(agent, task_id, :infinity)

      GenServer.stop(agent)
    end

    test "completed status covers turns whose result is a non-completed terminal" do
      expect_stream([{:error, {:api_error, 500, "boom"}}])

      {:ok, agent} = TestAgent.start_link()
      {:ok, task_id} = Clementine.AgentServer.run_async(agent, "Will error")

      # The turn produced {:error, %Failed{}} but the task function
      # returned normally.
      assert {:error, %Result.Failed{error: %Error{code: :provider_unavailable}}} =
               Clementine.AgentServer.await(agent, task_id)

      GenServer.stop(agent)
    end
  end

  describe "task cleanup" do
    test "sweeps unawaited terminal tasks after TTL expires" do
      expect_stream(text_events("Forgotten result"))

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
      expect_stream(text_events("Recent result"))

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
      expect_stream(text_events("Source response"))

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
      expect(Clementine.LLM.MockClient, :stream, 2, fn _model, _system, messages, _tools, _opts ->
        text_events("Response #{length(messages)}")
      end)

      {:ok, source} = TestAgent.start_link()
      {:ok, _} = Clementine.AgentServer.run(source, "First message")

      {:ok, forked} = Clementine.AgentServer.fork(source, ForkTargetAgent)
      {:ok, result} = Clementine.AgentServer.run(forked, "Second message")

      # The forked agent received 2 prior messages (from source) + 1 new user message = 3
      assert result.output == "Response 3"

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
    alias Clementine.LLM.Message.Content

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
             {:clementine_stream_event, _tag, _event} -> true
             {:clementine_stream_done, _tag, _result} -> true
             _message -> false
           end)
  end
end
