defmodule Clementine.Runs.CostTest do
  @moduledoc """
  Cost on the durable runtime: each trace `model_call` freezes its call's
  cost at the prices of the moment, `Runs.cost/2` sums a run's (and, with
  `children: true`, those of every run below it), and
  `Runs.subject_cost/1` a subject's. A host that sets no prices gets
  `nil`, never zero. The rates are illustrative, not anyone's current
  prices.
  """

  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]

  alias Clementine.{Cost, InterruptReason, Thread, Usage}
  alias Clementine.Lifecycle.Protocol
  alias Clementine.Runs.{Lifecycle, Reaper, StepWorker}

  defmodule Middle do
    @moduledoc false
    use Clementine.Agent,
      key: "test_cost_middle",
      model: :claude_sonnet,
      instructions: "Ask the echo.",
      delegates: [Clementine.RunsCase.Echo]
  end

  defmodule Outer do
    @moduledoc false
    use Clementine.Agent,
      key: "test_cost_outer",
      model: :claude_sonnet,
      instructions: "Ask the middle.",
      delegates: [Middle]
  end

  defmodule Terse do
    @moduledoc false
    use Clementine.Agent,
      key: "test_cost_terse",
      model: :claude_sonnet,
      instructions: "Answer.",
      trace: :facts
  end

  defmodule Ledger do
    @moduledoc false
    # A host that keeps spend past a purge: it copies the run's cost from
    # inside the transaction that ends the run.
    @behaviour Clementine.Host

    @impl true
    def run_finished(run, _result) do
      if pid = Process.whereis(:clementine_runs_test),
        do: send(pid, {:ledger, run.id, Clementine.Runs.cost(run.id)})

      :ok
    end
  end

  # Per million tokens: 3.00 in, 15.00 out, 0.30 read, 3.75 written.
  @pricing [currency: "USD", input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75]

  setup do
    Process.register(self(), :clementine_runs_test)
    previous = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, previous) end)
    {:ok, catalog: previous}
  end

  defp price_sonnet!(catalog, pricing \\ @pricing) do
    Application.put_env(
      :clementine,
      :models,
      Keyword.put(catalog, :claude_sonnet,
        provider: :anthropic,
        id: "claude-sonnet-5",
        pricing: pricing
      )
    )
  end

  # A turn that reads most of its prompt from the cache and writes the rest.
  # 100 × 3.00 + 1,500 × 0.30 + 400 × 3.75 + 50 × 15.00 = 3,000 micro-dollars.
  @cached %{
    "input_tokens" => 2_000,
    "cache_read_tokens" => 1_500,
    "cache_write_tokens" => 400,
    "output_tokens" => 50
  }
  @cached_micros 3_000

  defp answer(text, usage \\ @cached) do
    [{:text_delta, text}, {:message_delta, %{"stop_reason" => "end_turn"}, usage}]
  end

  defp call(id, name, input, usage \\ @cached) do
    [
      {:tool_use_start, id, name},
      {:input_json_delta, id, Jason.encode!(input)},
      {:content_block_stop, 0},
      {:message_delta, %{"stop_reason" => "tool_use"}, usage}
    ]
  end

  defp model_calls(run_id), do: for(%{kind: :model_call} = e <- Runs.trace(run_id), do: e)

  defp usd(micros), do: %Cost{currency: "USD", micros: micros}

  describe "a run's cost" do
    test "is the sum of the costs frozen on its model calls", %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Lookup, "Find the forecast", subject: {"ticket", "t-1"})
      expect_turn(call("tu_1", "lookup", %{"query" => "forecast"}))
      # 1,000 × 3.00 + 100 × 15.00 = 4,500.
      expect_turn(answer("Sunny.", %{"input_tokens" => 1_000, "output_tokens" => 100}))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert [first, second] = model_calls(run.id)

      assert %{
               "alias" => "claude_sonnet",
               "cost" => %{"currency" => "USD", "micros" => @cached_micros}
             } = first.payload

      assert %{"cost" => %{"currency" => "USD", "micros" => 4_500}} = second.payload
      assert Runs.cost(run.id) == usd(@cached_micros + 4_500)
    end

    test "is frozen: a price changed afterwards reprices nothing; Cost.of reprices on request",
         %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Echo, "Hi")
      expect_turn(answer("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      assert Runs.cost(run.id) == usd(@cached_micros)

      price_sonnet!(catalog, Keyword.put(@pricing, :output, 30.0))
      assert Runs.cost(run.id) == usd(@cached_micros)

      # Today's prices, from what the trace kept: 50 × 15.00 more.
      [%{payload: payload}] = model_calls(run.id)

      assert Cost.of(Usage.from_map(payload["usage"]), payload["alias"]) ==
               usd(@cached_micros + 750)
    end

    test "is nil, not zero, for a host that sets no prices", %{catalog: catalog} do
      Application.put_env(:clementine, :models, catalog)
      {:ok, run} = Runs.start(Echo, "Hi", subject: {"ticket", "t-unpriced"})
      expect_turn(answer("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert [%{payload: %{"alias" => "claude_sonnet", "cost" => nil}}] = model_calls(run.id)
      assert Runs.cost(run.id) == nil
      assert Runs.subject_cost({"ticket", "t-unpriced"}) == nil

      # Nothing priced at all: even a run that called no model has no cost.
      {:ok, idle} = Runs.start(Echo, "Hi")
      assert Runs.cost(idle.id) == nil
    end

    test "is nil when one of its calls ran unpriced: never an undercount", %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Approval, "Tell the team")
      expect_turn(call("tu_1", "send_note", %{"text" => "hi"}))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      assert %AgentRun{status: "waiting"} = Runs.get(run.id)
      assert Runs.cost(run.id) == usd(@cached_micros)

      # The host drops the price while the run waits; its next call is unpriced.
      Application.put_env(:clementine, :models, catalog)
      assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
      expect_turn(answer("Sent."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert [%{payload: %{"cost" => %{}}}, %{payload: %{"cost" => nil}}] = model_calls(run.id)
      assert Runs.cost(run.id) == nil
    end

    test "is zero for a run that called no model, where the catalog has prices",
         %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Echo, "Hi")
      assert {:ok, _} = Runs.cancel(run.id)

      assert %AgentRun{status: "cancelled"} = Runs.get(run.id)
      assert Runs.cost(run.id) == usd(0)
    end

    test "is nil for a run that does not exist" do
      assert Runs.cost(Ecto.UUID.generate()) == nil
      assert Runs.cost("not-a-uuid") == nil
    end
  end

  describe "a parent that asked other agents" do
    defp ask(id, agent, prompt) do
      [
        {:tool_use_start, id, "delegate"},
        {:input_json_delta, id, Jason.encode!(%{"agent" => agent, "prompt" => prompt})},
        {:content_block_stop, 0},
        {:message_delta, %{"stop_reason" => "tool_use"}, @cached}
      ]
    end

    test "is charged for its own calls; children: true adds every run below it",
         %{catalog: catalog} do
      price_sonnet!(catalog)
      subject = {"ticket", "t-delegates"}
      {:ok, parent} = Runs.start(Planner, "Plan the launch", subject: subject)
      expect_turn(ask("tu_1", "test_echo", "Say the plan."))
      assert :ok = perform_job(Worker, %{"run_id" => parent.id})

      [child] = Runs.list(parent: parent.id)
      # 1,000 × 3.00 + 200 × 15.00 = 6,000.
      expect_turn(answer("The plan.", %{"input_tokens" => 1_000, "output_tokens" => 200}))
      assert :ok = perform_job(Worker, %{"run_id" => child.id})

      expect_turn(answer("Planned."))
      assert :ok = perform_job(Worker, %{"run_id" => parent.id})
      assert %AgentRun{status: "completed"} = Runs.get(parent.id)

      # The parent's two calls, then the child's one.
      assert Runs.cost(parent.id) == usd(2 * @cached_micros)
      assert Runs.cost(child.id) == usd(6_000)
      assert Runs.cost(parent.id, children: true) == usd(2 * @cached_micros + 6_000)

      # The child runs on its parent's subject, so the subject counts it once.
      assert Runs.subject_cost(subject) == usd(2 * @cached_micros + 6_000)
      # A subject with no runs, a purged one included, has no cost to state.
      assert Runs.subject_cost({"ticket", "elsewhere"}) == nil
    end
  end

  describe "a thread" do
    @describetag runtime: false

    setup do
      start_supervised!(
        {Clementine, repo: TestRepo, agents: [Chat, Echo, Thread], host: Clementine.RunsCase.Host}
      )

      :ok
    end

    test "costs nothing itself; its turns are its children and its subject's runs",
         %{catalog: catalog} do
      price_sonnet!(catalog)
      subject = {"conversation", "c-cost"}
      {:ok, loop} = Runs.start_loop(Thread, %{"agent" => "test_chat"}, subject: subject)

      for {id, prompt} <- [{"m1", "one"}, {"m2", "two"}] do
        assert {:ok, :appended} = Runs.send(loop.id, %{"prompt" => prompt, "id" => id})
        assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
        assert {:ok, turn} = Runs.child(loop.id, {:turn, id})
        expect_turn(answer("Answer #{id}."))
        assert :ok = perform_job(Worker, %{"run_id" => turn.id})
        assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      end

      assert length(Runs.turns(loop.id)) == 2
      assert Runs.cost(loop.id) == usd(0)
      assert Runs.cost(loop.id, children: true) == usd(2 * @cached_micros)
      assert Runs.subject_cost(subject) == usd(2 * @cached_micros)
    end
  end

  describe "a run whose trace is behind its usage" do
    # A node that died mid-run: running, its heartbeat two hours old (with
    # the usage it last counted), its job gone with it.
    defp dead_executor!(run, usage) do
      long_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

      {1, _} =
        TestRepo.update_all(from(r in AgentRun, where: r.id == ^run.id),
          set: [
            status: "running",
            lease_epoch: 1,
            executor_id: "oban:1:dead@node",
            heartbeat_at: long_ago,
            usage: usage
          ]
        )

      {1, _} =
        TestRepo.update_all(from(j in Oban.Job, where: j.id == ^run.oban_job_id),
          set: [state: "executing", attempted_at: long_ago]
        )

      :ok
    end

    # The heartbeat's sample, and then the reaper, while the model answers.
    defp reaped_mid_call!(run_id, heartbeat_usage) do
      {1, _} =
        TestRepo.update_all(from(r in AgentRun, where: r.id == ^run_id),
          set: [usage: heartbeat_usage]
        )

      {:ok, facts} = Lifecycle.fetch(run_id, nil)
      {:ok, _} = Protocol.interrupt(Lifecycle, facts, InterruptReason.new(:lease_expired))
      :ok
    end

    test "is nil when the node died in its first call, which only the heartbeat counted",
         %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Echo, "Hi", subject: {"ticket", "t-dead"})
      dead_executor!(run, %{"input_tokens" => 200_000, "output_tokens" => 4_000})

      assert %{interrupted: 1} = Reaper.sweep()
      assert %AgentRun{status: "interrupted"} = Runs.get(run.id)
      assert model_calls(run.id) == []

      # Not a confident zero: 200,000 × 3.00 + 4,000 × 15.00 burned.
      assert Runs.cost(run.id) == nil
      assert Runs.subject_cost({"ticket", "t-dead"}) == nil
    end

    test "is nil when the node died in a later call; a live run is nil while it lags",
         %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Lookup, "Find it", subject: {"ticket", "t-later"})
      expect_turn(call("tu_1", "lookup", %{"query" => "it"}))
      test = self()

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        # Live, at the boundary: the first call is in the trace.
        send(test, {:live, Runs.cost(run.id)})
        # The second call ends, the heartbeat counts it, and the node dies
        # before the boundary that would write it.
        reaped_mid_call!(run.id, %{"input_tokens" => 4_000, "output_tokens" => 100})
        send(test, {:lagging, Runs.cost(run.id)})
        answer("Too late.")
      end)

      # The executor finds the run already ended when it reaches its write.
      assert {:cancel, ":already_terminal"} = perform_job(Worker, %{"run_id" => run.id})
      assert_received {:live, live}
      assert live == usd(@cached_micros)
      assert_received {:lagging, nil}

      assert %AgentRun{status: "interrupted"} = Runs.get(run.id)
      assert [_first] = model_calls(run.id)
      assert Runs.cost(run.id) == nil
    end

    test "is nil when a resumed run's node died, though earlier executions trace more",
         %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Approval, "Tell the team")
      expect_turn(call("tu_1", "send_note", %{"text" => "hi"}))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})

      # The heartbeat counts one execution: this one's 300 tokens, less
      # than the first execution's 2,050 in the trace.
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        reaped_mid_call!(run.id, %{"input_tokens" => 250, "output_tokens" => 50})
        answer("Sent.")
      end)

      assert {:cancel, ":already_terminal"} = perform_job(Worker, %{"run_id" => run.id})
      assert %AgentRun{status: "interrupted"} = Runs.get(run.id)
      assert Runs.cost(run.id) == nil
    end
  end

  describe "a run whose trace is whole is priced" do
    test "across a drain's requeue: both executions' calls", %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Lookup, "Look it up")
      worker = self()

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        send(worker, {:clementine, :drain})
        call("tu_1", "lookup", %{"query" => "it"})
      end)

      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      assert %AgentRun{status: "queued"} = Runs.get(run.id)

      expect_turn(call("tu_1", "lookup", %{"query" => "it"}))
      expect_turn(answer("Found."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert %AgentRun{status: "completed"} = Runs.get(run.id)
      assert length(model_calls(run.id)) == 3
      assert Runs.cost(run.id) == usd(3 * @cached_micros)
    end

    test "across a paused turn and its continuation", %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Echo, "Think it through")

      expect_turn([
        {:text_delta, "Let me look."},
        {:message_delta, %{"stop_reason" => "pause_turn"}, @cached}
      ])

      expect_turn(answer("Done."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert %AgentRun{status: "completed"} = Runs.get(run.id)
      assert Runs.cost(run.id) == usd(2 * @cached_micros)
    end

    test "across a park and its resume", %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Approval, "Tell the team")
      expect_turn(call("tu_1", "send_note", %{"text" => "hi"}))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      assert Runs.cost(run.id) == usd(@cached_micros)

      assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
      expect_turn(answer("Sent."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert %AgentRun{status: "completed"} = Runs.get(run.id)
      assert Runs.cost(run.id) == usd(2 * @cached_micros)
    end

    test "with a call a cancel cut off, at what its stream reported", %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Echo, "Tell me a long story")
      id = run.id

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        assert {:ok, :flagged} = Runs.cancel(id)

        [
          {:message_start, %{"usage" => %{"input_tokens" => 1_000, "output_tokens" => 1}}},
          {:text_delta, "Once upon"},
          {:signal, {:clementine, :cancel, %{"code" => "cancelled"}}}
        ]
      end)

      assert :ok = perform_job(Worker, %{"run_id" => id})
      assert %AgentRun{status: "cancelled"} = Runs.get(id)

      # 1,000 × 3.00 + 1 × 15.00.
      assert [%{payload: %{"stop_reason" => nil, "cost" => %{"micros" => 3_015}}}] =
               model_calls(id)

      assert Runs.cost(id) == usd(3_015)
    end

    test "with a call a provider error ended, at what its stream reported", %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Echo, "Hi")

      expect_turn([
        {:message_start, %{"usage" => %{"input_tokens" => 1_000, "output_tokens" => 1}}},
        {:error, :overloaded}
      ])

      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      assert %AgentRun{status: "failed"} = Runs.get(run.id)
      assert [%{payload: %{"cost" => %{"micros" => 3_015}}}] = model_calls(run.id)
      assert Runs.cost(run.id) == usd(3_015)
    end
  end

  describe "on a runtime of its own" do
    @describetag runtime: false

    setup do
      start_supervised!(
        {Clementine, repo: TestRepo, agents: [Echo, Outer, Middle, Terse], host: Ledger}
      )

      :ok
    end

    test "children: true counts grandchildren; each level's own cost is its own",
         %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, outer} = Runs.start(Outer, "Plan", subject: {"ticket", "t-tree"})
      expect_turn(ask("tu_1", "test_cost_middle", "Ask the echo."))
      assert :ok = perform_job(Worker, %{"run_id" => outer.id})

      [middle] = Runs.list(parent: outer.id)
      expect_turn(ask("tu_2", "test_echo", "Say it."))
      assert :ok = perform_job(Worker, %{"run_id" => middle.id})

      [echo] = Runs.list(parent: middle.id)
      expect_turn(answer("It."))
      assert :ok = perform_job(Worker, %{"run_id" => echo.id})

      expect_turn(answer("The echo said it."))
      assert :ok = perform_job(Worker, %{"run_id" => middle.id})
      expect_turn(answer("Planned."))
      assert :ok = perform_job(Worker, %{"run_id" => outer.id})
      assert %AgentRun{status: "completed"} = Runs.get(outer.id)

      assert Runs.cost(outer.id) == usd(2 * @cached_micros)
      assert Runs.cost(middle.id, children: true) == usd(3 * @cached_micros)
      assert Runs.cost(outer.id, children: true) == usd(5 * @cached_micros)
      assert Runs.subject_cost({"ticket", "t-tree"}) == usd(5 * @cached_micros)
    end

    test "a facts-only trace keeps the cost", %{catalog: catalog} do
      price_sonnet!(catalog)
      {:ok, run} = Runs.start(Terse, "Hi")
      expect_turn(answer("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert [%{payload: payload}] = model_calls(run.id)
      refute Map.has_key?(payload, "content")
      assert %{"alias" => "claude_sonnet", "cost" => %{"micros" => @cached_micros}} = payload
      assert Runs.cost(run.id) == usd(@cached_micros)
    end

    test "costs in two currencies have no total", %{catalog: catalog} do
      subject = {"ticket", "t-currencies"}
      price_sonnet!(catalog)
      {:ok, first} = Runs.start(Echo, "Hi", subject: subject)
      expect_turn(answer("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => first.id})

      price_sonnet!(catalog, Keyword.put(@pricing, :currency, "EUR"))
      {:ok, second} = Runs.start(Echo, "Again", subject: subject)
      expect_turn(answer("Hello again."))
      assert :ok = perform_job(Worker, %{"run_id" => second.id})

      assert Runs.cost(first.id) == usd(@cached_micros)
      assert Runs.cost(second.id) == %Cost{currency: "EUR", micros: @cached_micros}
      assert Runs.subject_cost(subject) == nil
    end

    test "a purge takes the cost with the trace; a host's ledger keeps it",
         %{catalog: catalog} do
      price_sonnet!(catalog)
      subject = {"ticket", "t-purged"}
      {:ok, run} = Runs.start(Echo, "Hi", subject: subject)
      expect_turn(answer("Hello."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      # run_finished/2 read the whole trace inside the end's transaction.
      run_id = run.id
      assert_received {:ledger, ^run_id, ledger}
      assert ledger == usd(@cached_micros)

      assert {:ok, 1} = Runs.purge(subject)
      assert Runs.cost(run.id) == nil
      assert Runs.subject_cost(subject) == nil
    end
  end

  test "an unknown option raises rather than undercounting" do
    {:ok, run} = Runs.start(Echo, "Hi")

    assert_raise ArgumentError, ~r/unknown keys \[:child\]/, fn ->
      Runs.cost(run.id, child: true)
    end
  end
end
