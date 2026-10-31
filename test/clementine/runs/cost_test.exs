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

  alias Clementine.{Cost, Thread, Usage}
  alias Clementine.Runs.StepWorker

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
      assert Runs.subject_cost({"ticket", "elsewhere"}) == usd(0)
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
end
