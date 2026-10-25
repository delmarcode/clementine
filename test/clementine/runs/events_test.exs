defmodule Clementine.Runs.EventsTest do
  use Clementine.RunsCase

  import ExUnit.CaptureLog

  alias Clementine.{Event, Result}

  setup do
    Process.register(self(), :clementine_runs_test)
    :ok
  end

  # What the host heard, in the order it arrived: each event's type, each
  # transition, and each end's status.
  defp reports do
    receive do
      {:run_event, _run, %Event{type: type}, _in_transaction?, _pid} ->
        [{:event, type} | reports()]

      {:run_transition, _run, transition, _in_transaction?} ->
        [transition | reports()]

      {:run_committed, _run, result, _in_transaction?} ->
        [Result.status(result) | reports()]

      {:run_finished, _run, _result} ->
        reports()
    after
      0 -> []
    end
  end

  test "a run streams its events to the host between its claim and its end" do
    {:ok, run} = Runs.start(Echo, "Say hello")

    expect_turn(text_events("Hello."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert reports() == [
             :claimed,
             {:event, :iteration_start},
             {:event, :text_delta},
             {:event, :usage_delta},
             :completed
           ]
  end

  test "the host gets each event with the run, in a process of its own, outside any transaction" do
    {:ok, run} = Runs.start(Echo, "Say hello")
    id = run.id

    expect_turn(text_events("Hello."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert_received {:run_event, %AgentRun{id: ^id, status: "running", subject: nil},
                     %Event{run_ref: ^id, type: :text_delta, payload: %{content: "Hello."}},
                     false = _in_transaction?, courier}

    assert courier != self()
  end

  test "a suspension is heard before the approval it asks for" do
    {:ok, run} = Runs.start(Approval, "Tell the team")

    expect_turn(tool_events("toolu_1", "send_note", %{text: "hello"}))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert [:claimed | rest] = reports()
    assert [:suspended, {:event, :approval_requested}] = Enum.take(rest, -2)
  end

  test "every event reaches the host before the change that follows it, however slow the host" do
    {:ok, run} = Runs.start(Echo, "Say hello", metadata: %{"event_probe" => "hold"})
    id = run.id

    expect_turn(text_events("Hello."))
    worker = Task.async(fn -> perform_job(Worker, %{"run_id" => id}) end)

    # The host holds its first event; the run finishes its turn, then waits
    # for the host before it writes its end.
    assert_receive {:run_event_held, ^id, courier}
    refute_receive {:run_committed, _run, _result, _in_transaction?}, 100
    assert %AgentRun{status: "running"} = Runs.get(id)

    send(courier, {:release, id})
    assert :ok = Task.await(worker)

    assert [:claimed, {:event, :iteration_start} | rest] = reports()
    assert List.last(rest) == :completed
  end

  test "a host that raises on events is logged, and the run completes" do
    {:ok, run} = Runs.start(Echo, "Say hello", metadata: %{"event_probe" => "raise"})

    expect_turn(text_events("Hello."))
    log = capture_log(fn -> assert :ok = perform_job(Worker, %{"run_id" => run.id}) end)

    assert log =~ "Clementine.RunsCase.Host.run_event/2 raised: event probe"
    assert %AgentRun{status: "completed"} = Runs.get(run.id)
  end

  @tag runtime: false
  test "a host without run_event/2 hears no events, and its runs complete" do
    start_supervised!({Clementine, repo: TestRepo, agents: [Echo]})
    {:ok, run} = Runs.start(Echo, "Say hello")

    expect_turn(text_events("Hello."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert %AgentRun{status: "completed", result: %{"output" => "Hello."}} = Runs.get(run.id)
    assert reports() == []
  end
end
