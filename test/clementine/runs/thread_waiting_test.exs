defmodule Clementine.Runs.ThreadWaitingTest do
  @moduledoc """
  `Clementine.Thread.waiting/1`: the messages a thread holds but has not
  started a turn for, in answer order, read through the library's own
  envelope decoding.
  """

  use Clementine.RunsCase

  alias Clementine.Runs.StepWorker
  alias Clementine.{Result, Thread}

  defmodule Other do
    @moduledoc false
    # A loop that is not a thread.
    use Clementine.Loop, key: "test_other"

    def init(_args), do: {:ok, %{}, []}
    def handle(_input, state), do: {:ok, state, []}
  end

  @moduletag runtime: false

  setup do
    Process.register(self(), :clementine_runs_test)

    start_supervised!(
      {Clementine,
       repo: TestRepo, agents: [Chat, Echo, Thread, Other], host: Clementine.RunsCase.Host}
    )

    :ok
  end

  test "the queue behind the running turn, then the undrained inbox, in answer order; never the running turn's message" do
    {:ok, loop} =
      Runs.start_loop(Thread, %{"agent" => "test_chat"}, subject: {"conversation", "w-1"})

    # Nothing sent, nothing stepped.
    assert {:ok, []} = Thread.waiting(loop.id)

    # Sent but not stepped: all still in the inbox, in order.
    for id <- ~w(m1 m2 m3) do
      {:ok, :appended} = Runs.send(loop.id, %{"prompt" => id, "id" => id})
    end

    assert {:ok, ["m1", "m2", "m3"]} = Thread.waiting(loop.id)

    # The first step starts m1's turn and holds m2 and m3 in the thread's
    # queue; the inbox is drained, so pending/2 alone would show nothing.
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    {:ok, turn} = Runs.child(loop.id, {:turn, "m1"})
    assert Runs.pending(loop.id) == []
    assert {:ok, ["m2", "m3"]} = Thread.waiting(loop.id)

    # Sent after the step, not yet drained: after the queue. One sent
    # without an id is listed under the counter id the thread will give it.
    {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "four", "id" => "m4"})
    {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "five"})
    assert {:ok, ["m2", "m3", "m4", 1]} = Thread.waiting(loop.id)

    # The running turn cancelled: its completion is not a message, and the
    # thread has not moved yet.
    assert {:ok, :finished} = Runs.cancel(turn.id)
    assert {:ok, ["m2", "m3", "m4", 1]} = Thread.waiting(loop.id)

    # The next step answers m2 next and drains the inbox into the queue,
    # the counted message under the id it was listed with.
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    assert {:ok, %AgentRun{}} = Runs.child(loop.id, {:turn, "m2"})
    assert {:ok, ["m3", "m4", 1]} = Thread.waiting(loop.id)
  end

  test "an empty thread, a thread that is ending or has ended, a run that is not a thread, and no such run" do
    {:ok, loop} =
      Runs.start_loop(Thread, %{"agent" => "test_chat"}, subject: {"conversation", "w-2"})

    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    assert {:ok, []} = Thread.waiting(loop.id)

    {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "x", "id" => "m1"})
    {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "y", "id" => "m2"})
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    assert {:ok, ["m2"]} = Thread.waiting(loop.id)

    # Cancelled: the thread answers nothing more, so it holds nothing,
    # while its cascade runs and once it has ended.
    assert {:ok, :flagged} = Runs.cancel(loop.id)
    assert {:ok, []} = Thread.waiting(loop.id)
    settle!(loop)
    assert %AgentRun{status: "cancelled"} = Runs.get(loop.id)
    assert {:ok, []} = Thread.waiting(loop.id)

    {:ok, run} = Runs.start(Echo, "Hi")
    assert {:error, :not_a_thread} = Thread.waiting(run.id)

    {:ok, other} = Runs.start_loop(Other, %{}, subject: {"conversation", "w-3"})
    assert {:error, :not_a_thread} = Thread.waiting(other.id)

    assert {:error, :not_found} = Thread.waiting(Ecto.UUID.generate())
    assert {:error, :not_found} = Thread.waiting("nope")
  end

  test "a failed turn waiting out its retry delay is the current turn, not a waiting message" do
    {:ok, state, []} = Thread.init(%{"agent" => "test_chat", "on_failure" => "retry"})
    {:ok, state, [_spawn]} = Thread.handle({:message, %{"prompt" => "a", "id" => "m1"}}, state)
    {:ok, state, []} = Thread.handle({:message, %{"prompt" => "b", "id" => "m2"}}, state)

    {:ok, state, [{:timer, {:retry, "m1"}, _ms}]} =
      Thread.handle({:completed, {:turn, "m1"}, Result.failed(:boom)}, state)

    assert state["turn"]["phase"] == "retry_wait"
    assert Thread.queued_ids(state) == ["m2"]
  end

  # Drives a flagged loop's steps until it ends.
  defp settle!(%AgentRun{id: id}) do
    case Runs.get(id) do
      %AgentRun{status: "queued"} ->
        assert :ok = perform_job(StepWorker, %{"run_id" => id})
        settle!(%AgentRun{id: id})

      %AgentRun{status: status} = run when status in ~w(completed failed cancelled interrupted) ->
        run

      %AgentRun{status: status} ->
        flunk("loop #{id} settled in #{status}")
    end
  end
end
