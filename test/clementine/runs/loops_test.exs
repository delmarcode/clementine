defmodule Clementine.Runs.LoopsTest do
  @moduledoc """
  The loop surface of `Clementine.Runs` beyond the battery
  (`Clementine.LoopCase`): the child spec's controllers, the optional
  `after_execution/2` agent callback, the doctor, the inbox gauge, and
  the reaper process's loop cadence.
  """

  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Clementine.Loop.Report
  alias Clementine.Runs.{Config, Loops, Reaper, StepWorker, TimerWorker}

  defmodule Thread do
    @moduledoc false
    use Clementine.Loop, key: "test_thread", vocabulary: [:turn]

    def init(args), do: {:ok, %{"agent" => args["agent"], "log" => []}, []}

    def handle({:message, %{"prompt" => prompt}}, state) do
      child = %{"agent" => state["agent"], "prompt" => prompt}
      {:ok, state, [{:run, {:turn, prompt}, child}]}
    end

    def handle({:completed, {:turn, prompt}, _result}, state) do
      {:ok, Map.update!(state, "log", &(&1 ++ [prompt])), []}
    end

    def handle(_input, state), do: {:ok, state, []}
  end

  defmodule Keyless do
    @moduledoc false
    use Clementine.Loop

    def init(_args), do: {:ok, %{}, []}
    def handle(_input, state), do: {:ok, state, []}
  end

  defmodule Tidy do
    @moduledoc "An agent that holds a resource per execution and releases it after."
    use Clementine.Agent, key: "test_tidy", model: :claude_sonnet, instructions: "Tidy."

    @impl true
    def after_execution(run, context) do
      if pid = Process.whereis(:clementine_runs_test) do
        send(pid, {:after_execution, run, context, self()})
      end

      if run.metadata["after_execution_probe"] == "raise", do: raise("cleanup probe")
      :ok
    end
  end

  setup do
    Process.register(self(), :clementine_runs_test)
    :ok
  end

  describe "the child spec" do
    @describetag runtime: false

    test "lists loop controllers beside agents, in one key namespace" do
      config = Config.new!(repo: TestRepo, agents: [Echo, Thread])
      assert config.agents == %{"test_echo" => Echo, "test_thread" => Thread}
      assert Config.controller?(Thread)
      refute Config.controller?(Echo)
      assert Config.agent?(Echo)
      refute Config.agent?(Thread)
    end

    test "refuses a loop without a key, and two modules sharing a key" do
      assert_raise ArgumentError,
                   ~r/not a Clementine.Agent or a Clementine.Loop with a key/,
                   fn ->
                     Config.new!(repo: TestRepo, agents: [Keyless])
                   end

      defmodule SameKey do
        use Clementine.Loop, key: "test_echo"
        def init(_args), do: {:ok, %{}, []}
        def handle(_input, state), do: {:ok, state, []}
      end

      assert_raise ArgumentError, ~r/share the agent key "test_echo"/, fn ->
        Config.new!(repo: TestRepo, agents: [Echo, SameKey])
      end
    end
  end

  describe "the loop workers before the runtime is up" do
    @describetag runtime: false

    test "a step or timer job that arrives first snoozes rather than fail" do
      :persistent_term.erase({Clementine.Runs.Config, :config})
      assert {:snooze, 1} = perform_job(StepWorker, %{"run_id" => Ecto.UUID.generate()})

      assert {:snooze, 1} =
               perform_job(TimerWorker, %{"run_id" => Ecto.UUID.generate(), "tag_key" => "t"})
    end
  end

  describe "a controller in the child spec" do
    @describetag runtime: false

    setup do
      start_supervised!(
        {Clementine,
         repo: TestRepo, agents: [Echo, Thread, Tidy], host: Clementine.RunsCase.Host},
        id: :loops_runtime
      )

      :ok
    end

    test "start/3 refuses a controller, and start_loop/3 refuses an agent" do
      assert {:error, :unknown_agent} = Runs.start(Thread, "Hello", subject: {"ticket", 1})
      assert {:error, :unknown_controller} = Runs.start_loop(Echo, %{}, subject: {"ticket", 1})
    end

    test "a thread: send a message, the loop starts a turn of its agent, the turn answers, the loop hears it" do
      {:ok, loop} = Runs.start_loop(Thread, %{"agent" => "test_echo"}, subject: {"ticket", 7})
      assert {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "Hi there"})

      # The first step runs init and spawns the turn in one commit.
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})

      assert {:ok, %AgentRun{agent_key: "test_echo", input: %{"prompt" => "Hi there"}} = turn} =
               Runs.child(loop.id, {:turn, "Hi there"})

      assert turn.parent_id == loop.id
      assert turn.subject_id == "7"

      # The reads filter by the controller as they do by an agent.
      loop_id = loop.id
      assert Runs.active?(Thread, {"ticket", 7}, kind: :loop)
      assert %AgentRun{id: ^loop_id} = Runs.latest({"ticket", 7}, kind: :loop, agent: Thread)
      assert [%AgentRun{id: ^loop_id}] = Runs.list(kind: :loop, agent: Thread)
      assert Runs.list(kind: :loop, agent: Echo) == []
      assert_received {:run_transition, %AgentRun{id: loop_id, kind: "loop"}, :claimed, false}
      assert loop_id == loop.id

      expect_turn(text_events("Hello!"))
      assert :ok = perform_job(Worker, %{"run_id" => turn.id})
      assert %AgentRun{status: "completed"} = Runs.get(turn.id)

      # The completion woke the loop; its step folds it.
      assert %AgentRun{status: "queued"} = Runs.get(loop.id)
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert %AgentRun{status: "waiting", envelope: %{"state" => stored}} = Runs.get(loop.id)
      assert Clementine.Loop.Codec.decode(stored, vocabulary: [:turn])["log"] == ["Hi there"]

      # The doctor sees it all.
      assert {:ok, %Report{} = report} = Runs.inspect(loop.id)
      assert report.module == {:ok, Thread}
      assert report.args == %{"agent" => "test_echo"}
      assert report.children == []
      assert report.pending == []
      assert report.strands == []
      assert report |> Report.render() |> String.contains?(inspect(Thread))
    end

    test "after_execution/2 runs in the worker's process once the execution ends, with the tools' context" do
      {:ok, run} = Runs.start(Tidy, "Tidy up", subject: {"ticket", 3})
      expect_turn(text_events("Tidied."))

      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert_received {:after_execution, %AgentRun{id: id}, context, worker}
      assert id == run.id
      assert worker == self()

      assert %{run_id: ^id, agent_key: "test_tidy", subject_id: "3", parent_id: nil, tag: nil} =
               context

      assert %AgentRun{status: "completed"} = Runs.get(run.id)
    end

    test "a raising after_execution/2 is logged, and the outcome stands" do
      {:ok, run} = Runs.start(Tidy, "Tidy up", metadata: %{"after_execution_probe" => "raise"})
      expect_turn(text_events("Tidied."))

      log = capture_log(fn -> assert :ok = perform_job(Worker, %{"run_id" => run.id}) end)

      assert log =~ "Tidy.after_execution/2 raised: cleanup probe"
      assert %AgentRun{status: "completed"} = Runs.get(run.id)
    end

    test "the inbox gauge names every loop with pending inputs" do
      {:ok, loop} = Runs.start_loop(Thread, %{"agent" => "test_echo"}, subject: {"ticket", 9})
      assert Runs.inbox_depths() == []

      assert {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "one"})
      assert {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "two"})

      assert [%{loop_id: id, depth: 2, oldest_age_ms: age}] = Runs.inbox_depths()
      assert id == loop.id
      assert is_integer(age) and age >= 0

      :telemetry.attach(
        "inbox-gauge-#{inspect(self())}",
        [:clementine, :loop, :inbox],
        fn _event, measurements, metadata, _config ->
          send(:clementine_runs_test, {:inbox_gauge, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("inbox-gauge-#{inspect(self())}") end)

      assert :ok = Runs.emit_inbox_depths()
      assert_received {:inbox_gauge, %{depth: 2}, %{loop_ref: ^id}}
    end

    test "the reaper process runs the loop sweep at its own cadence" do
      {:ok, loop} = Runs.start_loop(Thread, %{"agent" => "test_echo"}, subject: {"ticket", 11})

      # A crashed step: running, heartbeat long gone.
      {:ok, _lease} =
        Clementine.Lifecycle.Protocol.claim(Clementine.Runs.Lifecycle, loop.id, executor: "dead")

      long_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

      TestRepo.update_all(from(r in AgentRun, where: r.id == ^loop.id),
        set: [heartbeat_at: long_ago]
      )

      pid = start_supervised!({Reaper, name: :loops_reaper_test})
      # The first sweeps are the first messages the reaper handles.
      :sys.get_state(pid)

      assert %AgentRun{status: "queued"} = Runs.get(loop.id)
      assert_enqueued(worker: StepWorker, args: %{"run_id" => loop.id})
    end

    test "a child's tag reaches its agent as {kind, id}; a kind no loaded code declares stays text" do
      {:ok, loop} = Runs.start_loop(Thread, %{"agent" => "test_echo"}, subject: {"ticket", 15})
      kind = "kind_no_code_declares_#{System.unique_integer([:positive])}"

      child =
        insert_queued_run!(%{
          agent_key: "test_tidy",
          input: %{"prompt" => "Tidy up"},
          subject_type: "ticket",
          subject_id: "15",
          parent_id: loop.id,
          tag_kind: kind,
          tag_id: "1"
        })

      expect_turn(text_events("Tidied."))
      assert :ok = perform_job(Worker, %{"run_id" => child.id})

      assert_received {:after_execution, %AgentRun{id: id}, %{parent_id: parent_id, tag: tag}, _}
      assert id == child.id
      assert parent_id == loop.id
      assert tag == {kind, "1"}
      assert %AgentRun{status: "completed"} = Runs.get(child.id)

      # Its completion still reached the loop's inbox, under the row's tag.
      assert [%{input: %{kind: :completed}}] = Runs.pending(loop.id)
    end

    test "a timer job for a deleted loop or a rollout cancels itself" do
      assert {:cancel, "loop row deleted"} =
               perform_job(TimerWorker, %{"run_id" => Ecto.UUID.generate(), "tag_key" => "t"})

      {:ok, run} = Runs.start(Echo, "Hello")

      assert {:cancel, "not a loop"} =
               perform_job(TimerWorker, %{"run_id" => run.id, "tag_key" => "t"})
    end

    test "Loops.evidence/1 reads a parked loop's children and oldest input" do
      {:ok, loop} = Runs.start_loop(Thread, %{"agent" => "test_echo"}, subject: {"ticket", 13})
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})

      assert %Clementine.Reconciler.LoopEvidence{children: [], oldest_pending_at: nil} =
               Loops.evidence(Runs.get(loop.id))

      {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "later"})
      assert %{oldest_pending_at: %DateTime{}} = Loops.evidence(Runs.get(loop.id))
    end
  end
end
