defmodule Clementine.Runs.CancelTest do
  use Clementine.RunsCase

  import ExUnit.CaptureLog

  alias Clementine.{Event, Lease, Result}
  alias Clementine.Lifecycle.Protocol
  alias Clementine.LLM.ProviderStream
  alias Clementine.Runs.{CancelRelay, Lifecycle}
  alias Clementine.RunsCase.Host

  # Events pass through as the model streams them.
  defmodule Passthrough do
    @moduledoc false
    def new, do: nil
    def parse(state, event), do: {[event], state}
  end

  # The lifecycle another node's runtime writes through, as far as this
  # node can tell: the same table, and no push to this node's runners.
  defmodule Elsewhere do
    @moduledoc false
    use Clementine.Lifecycle.Ecto, repo: Clementine.TestRepo, schema: Clementine.Runs.AgentRun
  end

  setup do
    Process.register(self(), :clementine_runs_test)
    :ok
  end

  describe "a cancel on the node running the run" do
    test "stops it mid-response within a second, and ends it cancelled" do
      {:ok, run} = Runs.start(Echo, "Tell me a long story")
      id = run.id

      # Five seconds of text, through the stream every HTTP provider uses.
      long_answer(words: 50, every: 100)
      worker = Task.async(fn -> perform_job(Worker, %{"run_id" => id}) end)

      assert_receive {:model_answering, request}, 5_000

      assert_receive {:run_event, _run, %Event{type: :text_delta}, _in_transaction?, _courier},
                     1_000

      request_ref = Process.monitor(request)

      started = System.monotonic_time(:millisecond)
      assert {:ok, :flagged} = Runs.cancel(id)

      assert_receive {:run_committed, %AgentRun{id: ^id, status: "cancelled"},
                      %Result.Cancelled{reason: %{"code" => "cancelled"}}, false},
                     1_000

      assert System.monotonic_time(:millisecond) - started < 1_000

      # The model call was aborted, not run out.
      assert_receive {:DOWN, ^request_ref, :process, ^request, _reason}, 1_000
      assert :ok = Task.await(worker)

      assert_received {:run_transition, %AgentRun{id: ^id, cancel: %{}}, :cancel_requested, false}

      # The end commits as cancelled, with nothing of the partial answer.
      assert_received {:run_finished, %AgentRun{id: ^id, status: "cancelled", result: nil},
                       %Result.Cancelled{}}

      assert Host.host_writes(id) == ["run_finished"]
      assert %AgentRun{status: "cancelled", result: nil, cancel: %{}} = Runs.get(id)
      refute_received {:run_committed, _run, _result, _in_transaction?}
    end

    test "after the end changes nothing" do
      {:ok, run} = Runs.start(Echo, "Say hello")
      id = run.id

      expect_turn(text_events("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => id})
      assert_received {:run_committed, _run, %Result.Completed{}, false}

      assert {:error, :already_terminal} = Runs.cancel(id)

      assert %AgentRun{status: "completed", result: %{"output" => "Hello."}, cancel: nil} =
               Runs.get(id)

      refute_received {:run_transition, _run, :cancel_requested, _in_transaction?}
      refute_received {:run_committed, _run, _result, _in_transaction?}
    end

    test "that lands as the answer completes lets it stand, and leaves nothing behind" do
      {:ok, run} = Runs.start(Echo, "Short answer")
      id = run.id

      # The flag lands, and its push reaches this process, the run's, while
      # the model call is in flight. The scripted answer is already whole,
      # as a provider's last chunk can be.
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        assert {:ok, :flagged} = Runs.cancel(id)
        text_events("Done anyway.")
      end)

      assert :ok = perform_job(Worker, %{"run_id" => id})

      assert %AgentRun{status: "completed"} = Runs.get(id)
      assert Registry.lookup(Clementine.Runs.Registry, {:cancel, id}) == []
      refute_received {:clementine, :cancel, _reason}
    end
  end

  describe "a cancel between nodes" do
    @describetag oban: [notifier: Oban.Notifiers.PG]

    test "is published to every node when no runner here holds the run" do
      {:ok, run} = Runs.start(Echo, "Elsewhere")
      id = run.id
      {:ok, _lease} = Protocol.claim(Lifecycle, id, executor: "oban:1:other@node")

      :ok = Oban.Notifier.listen(Oban, [:clementine_cancel])
      assert {:ok, :flagged} = Runs.cancel(id)

      assert_receive {:notification, :clementine_cancel, %{"run_id" => ^id}}, 1_000
    end

    test "published by another node stops the run here mid-response" do
      {:ok, run} = Runs.start(Echo, "Tell me a long story")
      id = run.id

      long_answer(words: 50, every: 100)
      worker = Task.async(fn -> perform_job(Worker, %{"run_id" => id}) end)
      assert_receive {:model_answering, _request}, 5_000

      assert_receive {:run_event, _run, %Event{type: :text_delta}, _in_transaction?, _courier},
                     1_000

      # The other node commits the flag, and its runtime finds no runner
      # there, so it notifies every node.
      started = System.monotonic_time(:millisecond)
      assert {:ok, :flagged} = Protocol.request_cancel(Elsewhere, id, %{"code" => "cancelled"})
      :ok = Oban.Notifier.notify(Oban, :clementine_cancel, %{"run_id" => id})

      assert_receive {:run_committed, %AgentRun{id: ^id, status: "cancelled"},
                      %Result.Cancelled{reason: %{"code" => "cancelled"}}, false},
                     1_000

      assert System.monotonic_time(:millisecond) - started < 1_000
      assert :ok = Task.await(worker)
    end

    test "stops only a run whose flag committed, on the execution that holds it" do
      unflagged = claimed_run!()
      stale = claimed_run!()
      current = claimed_run!()

      {:ok, :flagged} = Protocol.request_cancel(Elsewhere, stale, "stale")
      {:ok, :flagged} = Protocol.request_cancel(Elsewhere, current, "current")

      # This process plays the runners: one of a run with no flag, one that
      # holds an execution the flag is not on, and one the flag is on.
      :ok = Lifecycle.subscribe_cancel(lease(unflagged, 1))
      :ok = Lifecycle.subscribe_cancel(lease(stale, 2))
      :ok = Lifecycle.subscribe_cancel(lease(current, 1))

      # The relay takes notifications in order, so once the last arrives
      # the first two have been dealt with.
      for run_id <- [unflagged, stale, current],
          do: :ok = Oban.Notifier.notify(Oban, :clementine_cancel, %{"run_id" => run_id})

      assert_receive {:clementine, :cancel, "current"}, 1_000
      refute_received {:clementine, :cancel, _reason}

      for run_id <- [unflagged, stale, current], do: CancelRelay.unsubscribe(run_id)
    end

    @tag capture_log: true
    test "still arrives after the notifier restarts" do
      relay = Process.whereis(CancelRelay)
      notifier = Oban.Registry.whereis(Oban, Oban.Notifier)
      Process.exit(notifier, :kill)

      assert eventually(fn -> listening?(relay, notifier) end)

      run_id = claimed_run!()
      {:ok, :flagged} = Protocol.request_cancel(Elsewhere, run_id, "after the restart")
      :ok = Lifecycle.subscribe_cancel(lease(run_id, 1))
      :ok = Oban.Notifier.notify(Oban, :clementine_cancel, %{"run_id" => run_id})

      assert_receive {:clementine, :cancel, "after the restart"}, 1_000
      CancelRelay.unsubscribe(run_id)
    end
  end

  describe "the relay" do
    test "waits for a notifier that is not running" do
      relay = start_supervised!({CancelRelay, oban: :no_such_oban, name: :test_cancel_relay})

      assert %{notifier: nil} = :sys.get_state(relay)
      send(relay, :listen)
      assert %{notifier: nil} = :sys.get_state(relay)
    end

    test "logs a notification it cannot send, and the cancel stands" do
      {:ok, run} = Runs.start(Echo, "Elsewhere")
      {:ok, _lease} = Protocol.claim(Lifecycle, run.id, executor: "oban:1:other@node")
      stop_supervised!(Oban)

      log = capture_log(fn -> assert {:ok, :flagged} = Runs.cancel(run.id) end)

      assert log =~ "could not notify other nodes of a cancel"
      assert %AgentRun{status: "running", cancel: %{}} = Runs.get(run.id)
    end
  end

  # Scripts a model turn that streams `words` words, one every `every` ms,
  # from a request process of its own, as an HTTP provider does. The test
  # hears `{:model_answering, request}` when the answer starts.
  defp long_answer(words: words, every: every) do
    test = self()

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      ProviderStream.new(Passthrough, fn parent, ref ->
        send(test, {:model_answering, self()})

        for n <- 1..words do
          send(parent, {ref, {:data, {:text_delta, "word#{n} "}}})
          Process.sleep(every)
        end

        usage = %{"input_tokens" => 10, "output_tokens" => words}
        send(parent, {ref, {:data, {:message_delta, %{"stop_reason" => "end_turn"}, usage}}})
        send(parent, {ref, :done})
      end)
    end)
  end

  defp lease(run_id, epoch),
    do: %Lease{run_ref: run_id, epoch: epoch, executor_id: "test", lifecycle: Lifecycle}

  # A running run at epoch 1 whose runner is on another node.
  defp claimed_run! do
    {:ok, run} = Runs.start(Echo, "Elsewhere")
    {:ok, _lease} = Protocol.claim(Lifecycle, run.id, executor: "oban:1:other@node")
    run.id
  end

  defp listening?(relay, old_notifier) do
    case Oban.Registry.whereis(Oban, Oban.Notifier) do
      notifier when is_pid(notifier) and notifier != old_notifier ->
        Map.has_key?(:sys.get_state(notifier).listeners, relay)

      _restarting ->
        false
    end
  end

  defp eventually(check, tries \\ 60) do
    cond do
      check.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(check, tries - 1)
    end
  end
end
