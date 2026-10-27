defmodule Clementine.RunsTest do
  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Clementine.Result
  alias Clementine.Runs.Reaper
  alias Clementine.RunsCase.Host

  setup do
    Process.register(self(), :clementine_runs_test)
    :ok
  end

  describe "start/3" do
    test "a started run executes on the agents queue, stores its output, and reports it" do
      {:ok, run} = Runs.start(Echo, "Say hello")

      assert %AgentRun{
               agent_key: "test_echo",
               status: "queued",
               input: %{"prompt" => "Say hello"}
             } =
               run

      assert_enqueued(worker: Worker, args: %{"run_id" => run.id}, queue: :agents)

      expect_turn(text_events("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert %AgentRun{status: "completed", result: %{"output" => "Hello."}} = Runs.get(run.id)

      assert_received {:run_finished, %AgentRun{result: %{"output" => "Hello."}},
                       %Result.Completed{output: "Hello."}}
    end

    test "copies the agent's turn to the row" do
      assert {:ok, %AgentRun{turn: true}} = Runs.start(Chat, "Hi", subject: {"conversation", 1})
      assert {:ok, %AgentRun{turn: false}} = Runs.start(Echo, "Hi", subject: {"conversation", 1})
    end

    test "a turn needs a subject" do
      assert {:error, :subject_required} = Runs.start(Chat, "Hi")
      assert {:error, :subject_required} = Runs.start(Chat, "Hi", subject: {"conversation", nil})
      assert {:ok, _run} = Runs.start(Chat, "Hi", subject: {"conversation", 1})
    end
  end

  describe "lanes" do
    test "a task's lane is its agent and subject: each agent has at most one active run per subject" do
      assert {:ok, _run} = Runs.start(Echo, "First", subject: {"ticket", 1})
      assert {:error, :active_run_exists} = Runs.start(Echo, "Second", subject: {"ticket", 1})
      assert {:ok, _run} = Runs.start(Echo, "Elsewhere", subject: {:ticket, 2})
    end

    test "tasks of two agents on one subject don't collide" do
      assert {:ok, echo} = Runs.start(Echo, "Answer", subject: {"ticket", 1})
      assert {:ok, lookup} = Runs.start(Lookup, "Look it up", subject: {"ticket", 1})
      assert {:error, :active_run_exists} = Runs.start(Lookup, "Again", subject: {"ticket", 1})

      expect_turn(text_events("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => echo.id})

      expect_turn(text_events("Found it."))
      assert :ok = perform_job(Worker, %{"run_id" => lookup.id})

      assert %AgentRun{agent_key: "test_echo", status: "completed"} = Runs.get(echo.id)
      assert %AgentRun{agent_key: "test_lookup", status: "completed"} = Runs.get(lookup.id)
    end

    test "a turn's lane is its thread: turns of two agents on one thread collide" do
      assert {:ok, chat} = Runs.start(Chat, "Hi", subject: {"conversation", 1})

      assert {:error, :active_run_exists} =
               Runs.start(Chat, "Again", subject: {"conversation", 1})

      assert {:error, :active_run_exists} =
               Runs.start(Handoff, "Take over", subject: {"conversation", 1})

      assert {:ok, _elsewhere} = Runs.start(Handoff, "Take over", subject: {"conversation", 2})

      # The thread frees up when its turn ends.
      expect_turn(text_events("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => chat.id})
      assert {:ok, _handoff} = Runs.start(Handoff, "Take over", subject: {"conversation", 1})
    end

    test "a turn parked for approval still holds its thread" do
      {:ok, chat} = Runs.start(Chat, "Tell the team", subject: {"conversation", 1})

      expect_turn(tool_events("toolu_1", "send_note", %{text: "hello"}))
      assert :ok = perform_job(Worker, %{"run_id" => chat.id})
      assert %AgentRun{status: "waiting"} = Runs.get(chat.id)

      assert {:error, :active_run_exists} =
               Runs.start(Handoff, "Take over", subject: {"conversation", 1})
    end

    test "a turn and a task on one subject don't collide" do
      assert {:ok, _turn} = Runs.start(Chat, "Hi", subject: {"conversation", 1})
      assert {:ok, _task} = Runs.start(Echo, "Screen it", subject: {"conversation", 1})
      assert {:ok, _other_task} = Runs.start(Lookup, "Look it up", subject: {"conversation", 1})
    end

    test "subject-less runs have no lane and never block" do
      assert {:ok, first} = Runs.start(Echo, "One", subject: {"ticket", nil})
      assert {:ok, _second} = Runs.start(Echo, "Two", subject: {"ticket", nil})
      assert {:ok, _third} = Runs.start(Echo, "Three")
      assert {:ok, _fourth} = Runs.start(Echo, "Four")
      assert %AgentRun{subject_type: "ticket", subject_id: nil} = Runs.get(first.id)
    end

    test "ids that contain colons don't alias" do
      # Joined into one string, Chat's turn on ("test_echo", "x:y") and
      # Echo's task on ("x", "y") would share the lane "test_echo:x:y".
      assert {:ok, _turn} = Runs.start(Chat, "Hi", subject: {"test_echo", "x:y"})
      assert {:ok, _task} = Runs.start(Echo, "Hi", subject: {"x", "y"})

      assert {:ok, _one} = Runs.start(Echo, "Hi", subject: {"ticket", "1:2"})
      assert {:ok, _two} = Runs.start(Echo, "Hi", subject: {"ticket:1", "2"})
    end

    test "concurrent starts on one thread admit exactly one turn" do
      results =
        1..8
        |> Task.async_stream(
          fn n -> Runs.start(Handoff, "Go #{n}", subject: {"conversation", "race"}) end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _run}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :active_run_exists})) == 7
    end
  end

  describe "queries" do
    test "active?/2 is a task's lane: whether the agent has an active run on the subject" do
      refute Runs.active?(Echo, {"ticket", 1})

      {:ok, run} = Runs.start(Echo, "Hi", subject: {"ticket", 1})
      assert Runs.active?(Echo, {"ticket", 1})
      assert Runs.active?(Echo, {:ticket, "1"})
      refute Runs.active?(Lookup, {"ticket", 1})
      refute Runs.active?(Echo, {"ticket", 2})
      refute Runs.active?(Echo, {"ticket", nil})

      expect_turn(text_events("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      refute Runs.active?(Echo, {"ticket", 1})

      assert_raise ArgumentError, ~r/String is not an agent the child spec lists/, fn ->
        Runs.active?(String, {"ticket", 1})
      end
    end

    test "active/1 is the thread's active turn, of whichever agent" do
      assert Runs.active({"conversation", 1}) == nil

      {:ok, _task} = Runs.start(Echo, "Screen it", subject: {"conversation", 1})
      assert Runs.active({"conversation", 1}) == nil

      {:ok, turn} = Runs.start(Handoff, "Take over", subject: {"conversation", 1})
      assert %AgentRun{id: turn_id, turn: true} = Runs.active({"conversation", 1})
      assert turn_id == turn.id
      assert Runs.active({"conversation", nil}) == nil

      assert {:ok, :finished} = Runs.cancel(turn.id)
      assert Runs.active({"conversation", 1}) == nil
    end

    test "latest/2 is the newest run on the subject, active or ended, under the list filters" do
      assert Runs.latest({"conversation", 1}) == nil

      {:ok, first} = Runs.start(Chat, "One", subject: {"conversation", 1})
      expect_turn(text_events("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => first.id})

      {:ok, task} = Runs.start(Echo, "Screen it", subject: {"conversation", 1})
      {:ok, second} = Runs.start(Chat, "Two", subject: {"conversation", 1})

      assert %AgentRun{id: id} = Runs.latest({"conversation", 1})
      assert id == second.id
      assert %AgentRun{id: id} = Runs.latest({"conversation", 1}, turn: false)
      assert id == task.id
      assert %AgentRun{id: id} = Runs.latest({"conversation", 1}, agent: Echo)
      assert id == task.id
      assert Runs.latest({"conversation", 1}, agent: Lookup) == nil
    end

    test "list/1 filters by subject, agent, turn, and actor, newest first, with a limit" do
      {:ok, turn} = Runs.start(Chat, "One", subject: {"conversation", 1}, actor: {"user", "ada"})
      {:ok, task} = Runs.start(Echo, "Two", subject: {"conversation", 1})
      {:ok, elsewhere} = Runs.start(Echo, "Three", subject: {"conversation", 2})
      {:ok, nowhere} = Runs.start(Echo, "Four", subject: {"conversation", nil})

      ids = fn runs -> Enum.map(runs, & &1.id) end

      assert ids.(Runs.list()) == [nowhere.id, elsewhere.id, task.id, turn.id]
      assert ids.(Runs.list(limit: 2)) == [nowhere.id, elsewhere.id]
      assert ids.(Runs.list(subject: {"conversation", 1})) == [task.id, turn.id]
      assert ids.(Runs.list(subject: {"conversation", 1}, turn: true)) == [turn.id]
      assert ids.(Runs.list(subject: {"conversation", nil})) == [nowhere.id]
      assert ids.(Runs.list(agent: Echo)) == [nowhere.id, elsewhere.id, task.id]
      assert ids.(Runs.list(actor: {"user", "ada"})) == [turn.id]
      assert ids.(Runs.list(turn: false, actor: {"user", "ada"})) == []

      assert_raise ArgumentError, ~r/unknown filter \{:status, "queued"\}/, fn ->
        Runs.list(status: "queued")
      end
    end

    test "the queries take rollouts unless told kind: :loop" do
      {:ok, task} = Runs.start(Echo, "Screen it", subject: {"conversation", 1})

      loop =
        insert_queued_run!(%{subject_type: "conversation", subject_id: "1", agent_key: "thread"})

      {1, _} =
        TestRepo.update_all(from(r in AgentRun, where: r.id == ^loop.id), set: [kind: "loop"])

      assert [%AgentRun{id: id}] = Runs.list(subject: {"conversation", 1})
      assert id == task.id
      assert [%AgentRun{id: id}] = Runs.list(subject: {"conversation", 1}, kind: :loop)
      assert id == loop.id
      assert %AgentRun{id: id} = Runs.latest({"conversation", 1})
      assert id == task.id
      assert %AgentRun{id: id} = Runs.latest({"conversation", 1}, kind: :loop)
      assert id == loop.id
    end

    test "AgentRun.active?/1 and terminal?/1 read the status" do
      {:ok, run} = Runs.start(Echo, "Hi")
      assert AgentRun.active?(run)
      refute AgentRun.terminal?(run)

      assert {:ok, :finished} = Runs.cancel(run.id)
      ended = Runs.get(run.id)
      refute AgentRun.active?(ended)
      assert AgentRun.terminal?(ended)
    end

    test "stores metadata as given" do
      assert {:ok, run} = Runs.start(Echo, "Hi", metadata: %{"source" => "test"})
      assert %AgentRun{metadata: %{"source" => "test"}} = Runs.get(run.id)
    end

    test "an agent the child spec does not list and a blank prompt are refused" do
      assert {:error, :unknown_agent} = Runs.start(String, "Hello")
      assert {:error, :blank_prompt} = Runs.start(Echo, "  ")
    end

    @tag runtime: false
    test "says how to start the runtime when it is not running" do
      :persistent_term.erase({Clementine.Runs.Config, :config})

      assert_raise RuntimeError, ~r/add \{Clementine, repo: MyApp.Repo/, fn ->
        Runs.start(Echo, "Hello")
      end
    end
  end

  describe "subjects" do
    test "the host resolves the subject for the agent and its tools" do
      {:ok, run} = Runs.start(Lookup, "Look it up", subject: {"ticket", 42})

      expect(Clementine.LLM.MockClient, :stream, fn _model, system, _messages, _tools, _opts ->
        assert system =~ ~s(%{ticket: "42"})
        tool_events("toolu_1", "lookup", %{query: "the weather"})
      end)

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
        assert inspect(messages) =~ ~s(Found the weather about %{ticket: \\"42\\"})
        text_events("Done.")
      end)

      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      assert %AgentRun{status: "completed"} = Runs.get(run.id)
    end

    test "a run whose subject no longer resolves is cancelled as unstartable" do
      {:ok, run} = Runs.start(Lookup, "Look it up", subject: {"gone", 1})

      assert {:cancel, reason} = perform_job(Worker, %{"run_id" => run.id})
      assert reason =~ "subject_gone"
      assert %AgentRun{status: "cancelled"} = Runs.get(run.id)
    end
  end

  describe "get/1" do
    test "is nil for an unknown or malformed id" do
      assert Runs.get(Ecto.UUID.generate()) == nil
      assert Runs.get("not-a-uuid") == nil
    end
  end

  describe "cancel/1" do
    test "cancelling a queued run finishes it, and the host hears of it" do
      {:ok, run} = Runs.start(Echo, "Never mind")

      assert {:ok, :finished} = Runs.cancel(run.id)
      assert %AgentRun{status: "cancelled"} = Runs.get(run.id)
      assert_received {:run_finished, _run, %Result.Cancelled{}}

      assert {:error, :already_terminal} = Runs.cancel(run.id)
    end

    test "an unknown or malformed id is not found" do
      assert {:error, :not_found} = Runs.cancel(Ecto.UUID.generate())
      assert {:error, :not_found} = Runs.cancel("not-a-uuid")
    end
  end

  describe "resume/2" do
    test "a tool that needs approval parks the run until a decision resumes it" do
      run = park!()

      assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
      assert_enqueued(worker: Worker, args: %{"run_id" => run.id})
      assert %AgentRun{status: "queued"} = resumed = Runs.get(run.id)
      assert resumed.oban_job_id != run.oban_job_id

      expect_turn(text_events("Sent."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert %AgentRun{status: "completed", result: %{"output" => "Sent."}} = Runs.get(run.id)
    end

    test "a denial reaches the model with its message" do
      run = park!()

      assert :ok = Runs.resume(run.id, {:denied, %{by: "alice", message: "Not today."}})

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
        assert inspect(messages) =~ "Not today."
        text_events("Understood.")
      end)

      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      assert %AgentRun{status: "completed"} = Runs.get(run.id)
    end

    test "the host decides who may resume" do
      run = park!()

      assert {:error, :forbidden} = Runs.resume(run.id, {:approved, %{by: "mallory"}})
      assert %AgentRun{status: "waiting", oban_job_id: job_id} = Runs.get(run.id)
      assert job_id == run.oban_job_id
      assert [_parked_job] = all_enqueued(worker: Worker, args: %{"run_id" => run.id})
    end

    test "a sweep racing a resume never interrupts the approved run" do
      run = park!()

      # Oban's pruner has removed the job that completed when the run parked.
      TestRepo.delete_all(Oban.Job)

      # Sweep from another process at the worst moment: after the resume
      # wrote `queued`, while its new job is being inserted. Were the two
      # writes not one transaction, the sweep would find a queued run with
      # no job and interrupt it, losing the approval.
      sweep_while_inserting_a_job()

      assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
      assert %{interrupted: 0} = sweep_result()
      assert %AgentRun{status: "queued"} = Runs.get(run.id)

      expect_turn(text_events("Sent."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      assert %AgentRun{status: "completed"} = Runs.get(run.id)
    end

    test "a run that is not waiting cannot be resumed" do
      {:ok, run} = Runs.start(Echo, "Not parked")

      assert {:error, :not_waiting} = Runs.resume(run.id, {:approved, %{}})
      assert {:error, :not_found} = Runs.resume(Ecto.UUID.generate(), {:approved, %{}})
      assert %AgentRun{status: "queued"} = Runs.get(run.id)
    end
  end

  describe "the host's finish hooks" do
    test "run_finished/2 commits with the run's end, and run_committed/2 hears of it once, after" do
      {:ok, run} = Runs.start(Echo, "Say hello")

      expect_turn(text_events("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert %AgentRun{status: "completed"} = Runs.get(run.id)
      assert Host.host_writes(run.id) == ["run_finished"]
      assert_received {:run_finished, _run, %Result.Completed{}}

      assert_received {:run_committed,
                       %AgentRun{status: "completed", result: %{"output" => "Hello."}},
                       %Result.Completed{output: "Hello."}, false = _in_transaction?}

      refute_received {:run_committed, _run, _result, _in_transaction?}
    end

    test "an end that rolls back takes run_finished/2's writes with it, and run_committed/2 never hears of it" do
      {:ok, run} = Runs.start(Echo, "Never mind", metadata: %{"conformance_probe" => "raise"})

      # run_finished/2 writes its row, then raises: the end rolls back.
      assert_raise RuntimeError, "conformance probe", fn -> Runs.cancel(run.id) end

      assert %AgentRun{status: "queued"} = Runs.get(run.id)
      assert Host.host_writes(run.id) == []
      refute_received {:run_committed, _run, _result, _in_transaction?}

      # The next end commits, and run_committed/2 hears of that one alone.
      {1, _} =
        TestRepo.update_all(from(r in AgentRun, where: r.id == ^run.id), set: [metadata: %{}])

      assert {:ok, :finished} = Runs.cancel(run.id)

      assert Host.host_writes(run.id) == ["run_finished"]
      assert_received {:run_committed, %AgentRun{status: "cancelled"}, %Result.Cancelled{}, false}
      refute_received {:run_committed, _run, _result, _in_transaction?}
    end

    test "the reaper's interrupt reaches both hooks" do
      run = insert_queued_run!()

      assert %{interrupted: 1} = Reaper.sweep()

      assert Host.host_writes(run.id) == ["run_finished"]

      assert_received {:run_committed, %AgentRun{status: "interrupted"}, %Result.Interrupted{},
                       false}
    end

    test "a raising run_committed/2 is logged, and the end stands" do
      {:ok, run} = Runs.start(Echo, "Never mind", metadata: %{"committed_probe" => "raise"})

      log = capture_log(fn -> assert {:ok, :finished} = Runs.cancel(run.id) end)

      assert log =~ "Clementine.RunsCase.Host.run_committed/2 raised: committed probe"
      assert %AgentRun{status: "cancelled"} = Runs.get(run.id)
      assert Host.host_writes(run.id) == ["run_finished"]
    end

    test "cancel/1 refuses to run inside the caller's transaction" do
      {:ok, run} = Runs.start(Echo, "Never mind")

      # Were it allowed, run_committed/2 would hear of an end the caller's
      # transaction then rolls back.
      assert_raise RuntimeError, ~r/inside a transaction/, fn ->
        TestRepo.transaction(fn ->
          Runs.cancel(run.id)
          TestRepo.rollback(:changed_my_mind)
        end)
      end

      assert %AgentRun{status: "queued"} = Runs.get(run.id)
      refute_received {:run_committed, _run, _result, _in_transaction?}
    end
  end

  defp park! do
    {:ok, run} = Runs.start(Approval, "Tell the team")

    expect_turn(tool_events("toolu_1", "send_note", %{text: "hello"}))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "waiting"} = Runs.get(run.id)

    run
  end

  # On the next job insert, starts a sweep in another process and gives it
  # 200ms to finish before the insert goes on.
  defp sweep_while_inserting_a_job do
    test = self()
    handler = "runs-test-sweep-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:oban, :engine, :insert_job, :start],
      fn _event, _measurements, _metadata, _config ->
        :telemetry.detach(handler)
        sweep = Task.async(fn -> Reaper.sweep() end)
        send(test, {:sweep, Task.yield(sweep, 200) || sweep})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp sweep_result do
    receive do
      {:sweep, {:ok, result}} -> result
      {:sweep, %Task{} = sweep} -> Task.await(sweep)
    after
      1_000 -> flunk("the resume inserted no job")
    end
  end
end
