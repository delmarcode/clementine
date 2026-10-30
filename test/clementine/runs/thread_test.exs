defmodule Clementine.Runs.ThreadTest do
  @moduledoc """
  `Clementine.Thread` on the durable runtime, and the step `send/3` runs
  inline: a thread end to end on Postgres (two messages, two turns in
  order, the first cancelled mid-run, the second answered; the same with
  an interrupt), then the inline step against its backstop job, the send
  inside a caller's transaction, a task that dies mid-step, and Oban's
  `:manual` mode, where nothing steps inline.
  """

  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]

  alias Clementine.LLM.ProviderStream
  alias Clementine.LoopCase.Battery.Passthrough
  alias Clementine.Loop.Codec
  alias Clementine.Runs.{Config, Reaper, StepSupervisor, StepWorker}
  alias Clementine.{Result, Thread}

  defmodule Blocking do
    @moduledoc false
    # A controller whose step blocks until the test lets it go: the one
    # way to catch a step task mid-step and kill it.
    use Clementine.Loop, key: "test_blocking"

    def init(_args), do: {:ok, %{"log" => []}, []}

    def handle({:message, %{"block" => true} = payload}, state) do
      send(:clementine_runs_test, {:blocking, self()})

      receive do
        :go -> {:ok, Map.update!(state, "log", &(&1 ++ ["message:#{payload["id"]}"])), []}
      end
    end

    def handle(_input, state), do: {:ok, state, []}
  end

  @agents [Clementine.RunsCase.Chat, Clementine.RunsCase.Echo, Thread, Blocking]

  setup do
    Process.register(self(), :clementine_runs_test)
    :ok
  end

  describe "a thread on the runtime" do
    @describetag runtime: false

    setup do
      start_supervised!(
        {Clementine, repo: TestRepo, agents: @agents, host: Clementine.RunsCase.Host}
      )

      :ok
    end

    test "two messages are two turns in order; the first cancelled mid-run, the second still answers" do
      {:ok, loop} =
        Runs.start_loop(Thread, %{"agent" => "test_chat"},
          subject: {"conversation", 1},
          actor: {"user", "u-1"}
        )

      assert {:ok, :appended} =
               Runs.send(loop.id, %{"prompt" => "one", "id" => "m1"}, dedup_key: "m1")

      assert {:ok, :appended} =
               Runs.send(loop.id, %{"prompt" => "two", "id" => "m2"}, dedup_key: "m2")

      assert {:ok, :duplicate} =
               Runs.send(loop.id, %{"prompt" => "two", "id" => "m2"}, dedup_key: "m2")

      # The first step runs init and drains both: one turn starts, the
      # other waits in the thread's state.
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})

      assert {:ok, %AgentRun{turn: true, agent_key: "test_chat"} = first} =
               Runs.child(loop.id, {:turn, "m1"})

      assert first.subject_id == "1"
      assert first.actor_id == "u-1"
      assert first.tag_kind == "turn" and first.tag_id == "m1"
      assert {:error, :no_child} = Runs.child(loop.id, {:turn, "m2"})
      assert state(loop)["queue"] |> Enum.map(& &1["id"]) == ["m2"]

      # The first turn streams a long answer; the user stops it.
      long_answer(words: 50, every: 100)
      worker = Task.async(fn -> perform_job(Worker, %{"run_id" => first.id}) end)
      assert_receive {:model_answering, _request}, 5_000
      assert {:ok, :flagged} = Runs.cancel(first.id)
      assert :ok = Task.await(worker)
      assert %AgentRun{status: "cancelled"} = Runs.get(first.id)

      # Its completion woke the thread, which starts the second turn.
      assert %AgentRun{status: "queued"} = Runs.get(loop.id)
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert {:ok, %AgentRun{} = second} = Runs.child(loop.id, {:turn, "m2"})
      assert state(loop)["queue"] == []

      expect_turn(text_events("Two."))
      assert :ok = perform_job(Worker, %{"run_id" => second.id})
      assert %AgentRun{status: "completed", result: %{"output" => "Two."}} = Runs.get(second.id)

      assert_received {:history, %AgentRun{id: id, input: %{"prompt" => "two"}}}
                      when id == second.id

      # The thread folds the completion and parks idle.
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert %AgentRun{status: "waiting"} = Runs.get(loop.id)
      assert state(loop)["turn"] == nil

      assert Runs.turns(loop.id) |> Enum.map(&{&1.tag_id, &1.status}) ==
               [{"m2", "completed"}, {"m1", "cancelled"}]

      assert Runs.active({"conversation", 1}) == nil
      assert Runs.active({"conversation", 1}, kind: :loop).id == loop.id
    end

    test "interrupt: a message during a running turn cancels it, and its own turn starts on the completion" do
      {:ok, loop} =
        Runs.start_loop(Thread, %{"agent" => "test_chat", "busy" => "interrupt"},
          subject: {"conversation", 2}
        )

      {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "one", "id" => "m1"})
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      {:ok, first} = Runs.child(loop.id, {:turn, "m1"})

      long_answer(words: 50, every: 100)
      worker = Task.async(fn -> perform_job(Worker, %{"run_id" => first.id}) end)
      assert_receive {:model_answering, _request}, 5_000

      # The second message: the thread flags the running turn, the relay
      # pushes the flag to its runner, and the turn ends cancelled.
      {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "two", "id" => "m2"})
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert state(loop)["turn"]["phase"] == "interrupting"

      assert_receive {:run_committed, %AgentRun{id: id, status: "cancelled"},
                      %Result.Cancelled{reason: %{"code" => "loop_cancel"}}, _in_transaction?}
                     when id == first.id,
                     2_000

      assert :ok = Task.await(worker)

      # The Cancelled completion starts the second turn.
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert {:ok, %AgentRun{status: "queued"} = second} = Runs.child(loop.id, {:turn, "m2"})
      assert state(loop)["turn"]["phase"] == "running"

      expect_turn(text_events("Two."))
      assert :ok = perform_job(Worker, %{"run_id" => second.id})
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert state(loop)["turn"] == nil

      assert Runs.turns(loop.id) |> Enum.map(&{&1.tag_id, &1.status}) ==
               [{"m2", "completed"}, {"m1", "cancelled"}]
    end

    test "bad args end the thread failed in its first step, with the reason on the row" do
      {:ok, loop} =
        Runs.start_loop(Thread, %{"agent" => "test_chat", "busy" => "drop"},
          subject: {"conversation", 3}
        )

      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})

      assert %AgentRun{status: "failed", error: %{"code" => "invalid_args", "message" => message}} =
               Runs.get(loop.id)

      assert message =~ ~s("busy" must be one of)

      assert_received {:run_finished, %AgentRun{id: id}, %Result.Failed{}} when id == loop.id
    end

    test "under Oban's :manual testing mode nothing steps inline" do
      refute Config.fetch!().inline_steps

      {:ok, loop} =
        Runs.start_loop(Thread, %{"agent" => "test_chat"}, subject: {"conversation", 4})

      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      assert %AgentRun{status: "waiting"} = Runs.get(loop.id)

      assert {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "one", "id" => "m1"})
      assert Task.Supervisor.children(StepSupervisor) == []
      Process.sleep(50)
      assert %AgentRun{status: "queued"} = Runs.get(loop.id)
      assert {:error, :no_child} = Runs.child(loop.id, {:turn, "m1"})
    end
  end

  describe "the inline step" do
    # Oban's testing mode disabled, as in production: the runtime steps
    # inline (and would sweep). With no queues configured, the jobs the
    # runtime inserts stay available, so each is this test's to perform.
    @describetag runtime: false
    @describetag oban: [testing: :disabled]

    setup do
      start_supervised!(
        {Clementine, repo: TestRepo, agents: @agents, host: Clementine.RunsCase.Host}
      )

      assert Config.fetch!().inline_steps
      :ok
    end

    test "send/3 steps the loop at once; the backstop job then discards on the lost claim" do
      loop = parked_thread(5)

      assert {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "one", "id" => "m1"})

      # The task claimed, drained, and committed the turn's start; send/3
      # had already returned.
      assert {:ok, %AgentRun{status: "queued"} = first} = await_child(loop, {:turn, "m1"})
      assert first.parent_id == loop.id
      assert await_settled(loop) == "waiting"

      # The host heard the task's claim (the first :claimed in the mailbox
      # is the init step's, performed by hand above).
      loop_id = loop.id

      assert_received {:run_transition,
                       %AgentRun{id: ^loop_id, kind: "loop", executor_id: "inline:" <> _},
                       :claimed, false}

      # The wake enqueued the step job as the backstop; its claim finds a
      # parked loop and the job cancels itself.
      assert %Oban.Job{} = job = newest_step_job(loop)

      assert {:cancel, reason} =
               perform(job)

      assert reason =~ "not_claimable"
      assert {:ok, %AgentRun{id: id}} = Runs.child(loop.id, {:turn, "m1"})
      assert id == first.id
    end

    test "inside the caller's transaction nothing steps inline; the job steps the loop at the commit" do
      loop = parked_thread(6)

      {:ok, {:ok, :appended}} =
        TestRepo.transaction(fn ->
          {:ok, :appended} = result = Runs.send(loop.id, %{"prompt" => "one", "id" => "m1"})
          assert Task.Supervisor.children(StepSupervisor) == []
          result
        end)

      # Committed: the input and the step job, and no claim from a task.
      assert Task.Supervisor.children(StepSupervisor) == []
      Process.sleep(100)
      assert %AgentRun{status: "queued", executor_id: nil} = Runs.get(loop.id)
      assert {:error, :no_child} = Runs.child(loop.id, {:turn, "m1"})
      assert [%{input: %{kind: :message}}] = Runs.pending(loop.id)
      refute_received {:run_transition, %AgentRun{id: _}, :resumed, _}

      # The job is what steps it.
      assert :ok = perform(newest_step_job(loop))
      assert {:ok, %AgentRun{status: "queued"}} = Runs.child(loop.id, {:turn, "m1"})
      assert %AgentRun{status: "waiting"} = Runs.get(loop.id)
    end

    test "a task that dies mid-step leaves the loop running under a stale claim, which the loop sweep requeues" do
      {:ok, loop} = Runs.start_loop(Blocking, %{}, subject: {"blocking", 7})
      assert :ok = perform(newest_step_job(loop))
      assert %AgentRun{status: "waiting"} = Runs.get(loop.id)

      {:ok, :appended} = Runs.send(loop.id, %{"id" => "b1", "block" => true})
      assert_receive {:blocking, task}, 2_000
      assert [^task] = Task.Supervisor.children(StepSupervisor)
      assert %AgentRun{status: "running"} = Runs.get(loop.id)

      # The node dies under the step: the claim goes stale.
      ref = Process.monitor(task)
      Process.exit(task, :kill)
      assert_receive {:DOWN, ^ref, :process, ^task, :killed}
      assert %AgentRun{status: "running"} = Runs.get(loop.id)
      assert [%{input: %{kind: :message}}] = Runs.pending(loop.id)

      long_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

      TestRepo.update_all(from(r in AgentRun, where: r.id == ^loop.id),
        set: [heartbeat_at: long_ago]
      )

      assert %{requeue: 1} = Reaper.loop_sweep()
      assert %AgentRun{status: "queued"} = Runs.get(loop.id)

      # The replayed step drains the same input: this time it is let go.
      send(self(), :go)
      assert :ok = perform(newest_step_job(loop))
      assert %AgentRun{status: "waiting"} = Runs.get(loop.id)
      assert Runs.pending(loop.id) == []
      assert state(loop, [])["log"] == ["message:b1"]
    end
  end

  ## Helpers

  # A thread started and parked by hand: with no Oban queues running, the
  # first step's job is this test's to perform.
  defp parked_thread(n) do
    {:ok, loop} = Runs.start_loop(Thread, %{"agent" => "test_chat"}, subject: {"conversation", n})
    assert :ok = perform(newest_step_job(loop))
    assert %AgentRun{status: "waiting"} = Runs.get(loop.id)
    loop
  end

  defp await_child(loop, tag, tries \\ 100) do
    case Runs.child(loop.id, tag) do
      {:ok, child} ->
        {:ok, child}

      {:error, :no_child} when tries > 0 ->
        Process.sleep(20)
        await_child(loop, tag, tries - 1)

      error ->
        error
    end
  end

  # The inline task's status after it has returned: no child of the step
  # supervisor left, and the loop out of :running.
  defp await_settled(loop, tries \\ 100) do
    case {Task.Supervisor.children(StepSupervisor), Runs.get(loop.id).status} do
      {[], status} when status != "running" ->
        status

      _busy when tries > 0 ->
        Process.sleep(20)
        await_settled(loop, tries - 1)

      {_tasks, status} ->
        status
    end
  end

  defp newest_step_job(%AgentRun{id: id}) do
    TestRepo.one!(
      from(j in Oban.Job,
        where: j.worker == "Clementine.Runs.StepWorker",
        where: fragment("?->>'run_id' = ?", j.args, ^id),
        order_by: [desc: j.id],
        limit: 1
      )
    )
  end

  # A job read back from the table, performed as Oban would: attempted
  # now, on its first attempt.
  defp perform(%Oban.Job{} = job) do
    Oban.Testing.perform_job(%{job | attempt: 1, attempted_at: DateTime.utc_now()},
      repo: TestRepo
    )
  end

  # The thread's committed state.
  defp state(%AgentRun{id: id}, vocabulary \\ Thread.__loop__(:vocabulary)) do
    %AgentRun{envelope: %{"state" => stored}} = Runs.get(id)
    Codec.decode(stored, vocabulary: vocabulary)
  end

  # A model turn that streams `words` words, one every `every` ms, from a
  # request process of its own; the test hears {:model_answering, pid}.
  defp long_answer(words: words, every: every) do
    test = self()

    Mox.expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
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
end
