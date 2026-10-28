defmodule Clementine.Runs.PurgeTest do
  @moduledoc """
  `Runs.purge/1`: a subject's runs erased, descendants of its loops
  included whatever their own subject, refused while any of them is
  active, inside the caller's transaction, with an audit event.
  """

  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]

  alias Clementine.Runs.StepWorker
  alias Clementine.Thread

  defmodule Elsewhere do
    @moduledoc false
    # A controller whose one child runs on another subject than its own.
    use Clementine.Loop, key: "test_elsewhere", vocabulary: [:job]

    def init(_args) do
      child = %{"agent" => "test_echo", "prompt" => "go", "subject" => ["other", "o-1"]}
      {:ok, %{}, [{:run, {:job, 1}, child}]}
    end

    def handle(_input, state), do: {:ok, state, []}
  end

  @moduletag runtime: false
  @subject {"conversation", "c-1"}

  setup do
    Process.register(self(), :clementine_runs_test)

    start_supervised!(
      {Clementine,
       repo: TestRepo, agents: [Chat, Echo, Thread, Elsewhere], host: Clementine.RunsCase.Host}
    )

    :ok
  end

  test "a direct run on the subject is erased, and nothing on another subject" do
    {:ok, run} = Runs.start(Echo, "Hi", subject: @subject)
    {:ok, other} = Runs.start(Echo, "Hi", subject: {"conversation", "c-2"})
    assert {:ok, :finished} = Runs.cancel(run.id)
    assert {:ok, :finished} = Runs.cancel(other.id)

    assert {:ok, 1} = Runs.purge(@subject)
    assert Runs.get(run.id) == nil
    assert %AgentRun{} = Runs.get(other.id)
    assert {:ok, 0} = Runs.purge(@subject)
  end

  test "a thread's loop and its turns go together, inbox rows included, once every one of them has ended" do
    {:ok, loop} = Runs.start_loop(Thread, %{"agent" => "test_chat"}, subject: @subject)
    {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "hi", "id" => "m1"})
    {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "again", "id" => "m2"})
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    {:ok, turn} = Runs.child(loop.id, {:turn, "m1"})

    # The loop and its queued turn are active: refused, nothing deleted.
    assert {:error, :active} = Runs.purge(@subject)
    assert %AgentRun{status: "waiting"} = Runs.get(loop.id)

    # The turn ended, the loop still live: still refused.
    assert {:ok, :finished} = Runs.cancel(turn.id)
    assert {:error, :active} = Runs.purge(@subject)

    # The app's path: cancel the loop, purge once it has ended. A message
    # sent to the ended loop is a retained dead letter, which the purge
    # takes with the inbox.
    assert {:ok, :flagged} = Runs.cancel(loop.id)
    settle!(loop)
    assert %AgentRun{status: "cancelled"} = Runs.get(loop.id)
    assert [%AgentRun{id: turn_id}] = Runs.list(parent: loop.id)
    assert turn_id == turn.id
    assert {:ok, :dead_lettered} = Runs.send(loop.id, %{"prompt" => "late", "id" => "m3"})
    assert inbox_rows(loop) == 1

    assert {:ok, 2} = Runs.purge(@subject)
    assert Runs.get(loop.id) == nil
    assert Runs.get(turn.id) == nil
    assert inbox_rows(loop) == 0
  end

  test "a loop's child on another subject goes with the loop" do
    {:ok, loop} = Runs.start_loop(Elsewhere, %{}, subject: {"conversation", "c-3"})
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    {:ok, child} = Runs.child(loop.id, {:job, 1})
    assert %AgentRun{subject_type: "other", subject_id: "o-1"} = child

    assert {:ok, :finished} = Runs.cancel(child.id)
    assert {:ok, :flagged} = Runs.cancel(loop.id)
    settle!(loop)

    # Found by walking parent_id, not by its subject; deleted before its
    # parent, which parent_id restricts.
    assert {:ok, 2} = Runs.purge({"conversation", "c-3"})
    assert Runs.get(loop.id) == nil
    assert Runs.get(child.id) == nil
  end

  test "it works inside the caller's transaction, and a refusal there is a return, not a rollback" do
    {:ok, run} = Runs.start(Echo, "Hi", subject: @subject)

    assert {:ok, :kept} =
             TestRepo.transaction(fn ->
               assert {:error, :active} = Runs.purge(@subject)
               :kept
             end)

    assert %AgentRun{status: "queued"} = Runs.get(run.id)
    assert {:ok, :finished} = Runs.cancel(run.id)

    assert {:ok, {:ok, 1}} =
             TestRepo.transaction(fn ->
               outcome = Runs.purge(@subject)
               assert Runs.get(run.id) == nil
               outcome
             end)

    assert Runs.get(run.id) == nil
  end

  test "the audit event carries the count and the subject; a refusal emits nothing" do
    test = self()
    handler = "purge-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:clementine, :runs, :purge],
      fn _event, measurements, metadata, _config ->
        send(test, {:purged, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, run} = Runs.start(Echo, "Hi", subject: @subject)
    assert {:ok, :finished} = Runs.cancel(run.id)
    assert {:ok, 1} = Runs.purge(@subject)
    assert_received {:purged, %{count: 1}, %{subject_type: "conversation", subject_id: "c-1"}}

    {:ok, _active} = Runs.start(Echo, "Hi", subject: @subject)
    assert {:error, :active} = Runs.purge(@subject)
    refute_received {:purged, _measurements, _metadata}
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

  defp inbox_rows(%AgentRun{id: id}) do
    TestRepo.one(
      from(i in "agent_run_inbox", where: i.run_id == type(^id, Ecto.UUID), select: count(i.id))
    )
  end
end
