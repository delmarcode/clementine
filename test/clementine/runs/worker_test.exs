defmodule Clementine.Runs.WorkerTest do
  use Clementine.RunsCase

  test "a drained run that has not touched the world is requeued for the next node" do
    {:ok, run} = Runs.start(Lookup, "Look it up")
    worker = self()

    # The node starts shutting down while the model's turn streams in.
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      send(worker, {:clementine, :drain})
      tool_events("toolu_1", "lookup", %{query: "the weather"})
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    requeued = Runs.get(run.id)
    assert %AgentRun{status: "queued"} = requeued
    assert requeued.oban_job_id != run.oban_job_id
    assert_enqueued(worker: Worker, args: %{"run_id" => run.id}, queue: :agents)
  end

  test "a job that arrives before the runtime is up waits for it" do
    {:ok, run} = Runs.start(Echo, "Early")
    :persistent_term.erase({Clementine.Runs.Config, :config})

    assert {:snooze, 1} = perform_job(Worker, %{"run_id" => run.id})

    Clementine.Runs.Config.put(
      Clementine.Runs.Config.new!(repo: TestRepo, agents: [Echo], host: Clementine.RunsCase.Host)
    )

    expect_turn(text_events("Hello."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "completed"} = Runs.get(run.id)
  end

  test "a run that already finished is not executed again" do
    {:ok, run} = Runs.start(Echo, "Once")
    expect_turn(text_events("Done."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert {:cancel, reason} = perform_job(Worker, %{"run_id" => run.id})
    assert reason =~ "not_claimable"
    assert %AgentRun{status: "completed"} = Runs.get(run.id)
  end

  test "a job whose run is gone is cancelled" do
    run = insert_queued_run!()
    TestRepo.delete!(run)

    assert {:cancel, reason} = perform_job(Worker, %{"run_id" => run.id})
    assert reason =~ "run_not_found"
  end

  test "a run whose agent is gone is cancelled as unstartable, and the host hears why" do
    Process.register(self(), :clementine_runs_test)
    run = insert_queued_run!(%{agent: "retired_agent"})

    assert {:cancel, reason} = perform_job(Worker, %{"run_id" => run.id})
    assert reason =~ "unknown_agent"
    assert %AgentRun{status: "cancelled"} = Runs.get(run.id)

    assert_received {:run_finished, _run,
                     %Clementine.Result.Cancelled{
                       reason: %{"code" => "unstartable", "detail" => ":unknown_agent"}
                     }}
  end

  test "a run with a blank prompt is cancelled as unstartable" do
    run = insert_queued_run!(%{input: %{}})

    assert {:cancel, reason} = perform_job(Worker, %{"run_id" => run.id})
    assert reason =~ "blank_prompt"
    assert %AgentRun{status: "cancelled"} = Runs.get(run.id)
  end

  test "a failed model call finishes the run failed" do
    {:ok, run} = Runs.start(Echo, "Fail")

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      [{:error, %{"type" => "invalid_request_error", "message" => "bad request"}}]
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "failed", error: %{}} = Runs.get(run.id)
  end
end
