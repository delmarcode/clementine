defmodule Clementine.RunsTest do
  use Clementine.RunsCase

  alias Clementine.Result
  alias Clementine.Runs.Reaper

  setup do
    Process.register(self(), :clementine_runs_test)
    :ok
  end

  describe "start/3" do
    test "a started run executes on the agents queue, stores its output, and reports it" do
      {:ok, run} = Runs.start(Echo, "Say hello")

      assert %AgentRun{agent: "test_echo", status: "queued", input: %{"prompt" => "Say hello"}} =
               run

      assert_enqueued(worker: Worker, args: %{"run_id" => run.id}, queue: :agents)

      expect_turn(text_events("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert %AgentRun{status: "completed", result: %{"output" => "Hello."}} = Runs.get(run.id)

      assert_received {:run_finished, %AgentRun{result: %{"output" => "Hello."}},
                       %Result.Completed{output: "Hello."}}
    end

    test "a subject has at most one active run" do
      assert {:ok, _run} = Runs.start(Echo, "First", subject: {"ticket", 1})
      assert {:error, :active_run_exists} = Runs.start(Echo, "Second", subject: {"ticket", 1})
      assert {:ok, _run} = Runs.start(Echo, "Elsewhere", subject: {:ticket, 2})
    end

    test "a subject with no id stores NULL, so such runs never block each other" do
      assert {:ok, first} = Runs.start(Echo, "One", subject: {"ticket", nil})
      assert {:ok, _second} = Runs.start(Echo, "Two", subject: {"ticket", nil})
      assert %AgentRun{subject_type: "ticket", subject_id: nil} = Runs.get(first.id)
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
