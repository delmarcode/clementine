defmodule Clementine.Telemetry.MetricsTest do
  @moduledoc """
  `Clementine.Telemetry.metrics/0` as an app exports it: every metric
  read the way a Prometheus reporter reads it (the measurement, the tags
  from `tag_values`, and nothing exported for an event missing either),
  against real runs on the runtime and in process. Every metric in the
  list exports, every label is bounded (an atom, a string, a number, or
  nil), and the engine's series name the agent, provider, model, and
  alias.
  """

  use Clementine.RunsCase

  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.Runs.{Lifecycle, Reaper, StepWorker}
  alias Clementine.Thread

  defmodule Verdict do
    @moduledoc false
    use Clementine.Tool,
      name: "record_verdict",
      description: "Records a verdict.",
      parameters: [
        tier: [type: :string, required: true],
        summary: [type: :string, required: true]
      ]

    @impl true
    def run(_args, _context), do: {:ok, "recorded"}
  end

  defmodule Exits do
    @moduledoc false
    use Clementine.Tool, name: "exits", description: "Exits.", parameters: []

    # The tool macro rescues a raise into an error result; an exit
    # reaches the runner as a tool exception.
    @impl true
    def run(_args, _context), do: exit(:gone)
  end

  @moduletag runtime: false
  @subject {"conversation", "metrics-1"}
  @identity %{
    agent_key: "test_lookup",
    provider: :anthropic,
    model: "claude-sonnet-5",
    alias: :claude_sonnet
  }

  setup do
    previous = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, previous) end)

    # Illustrative rates, so calls carry a cost.
    Application.put_env(
      :clementine,
      :models,
      Keyword.put(previous, :claude_sonnet,
        provider: :anthropic,
        id: "claude-sonnet-5",
        pricing: [currency: "USD", input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75]
      )
    )

    start_supervised!(
      {Clementine, repo: TestRepo, agents: [Echo, Lookup, Approval, Chat, Thread]}
    )

    report(Clementine.Telemetry.metrics())
    :ok
  end

  @doc false
  def export(_event, measurements, metadata, {test, metric}) do
    labels = metric.tag_values.(metadata)

    send(test, {
      :exported,
      Enum.join(metric.name, "_"),
      Map.take(labels, metric.tags),
      measure(metric, measurements, metadata),
      Enum.reject(metric.tags, &Map.has_key?(labels, &1))
    })
  end

  # One handler per metric, as a reporter attaches them.
  defp report(metrics) do
    for metric <- metrics do
      id = {__MODULE__, metric.name, make_ref()}
      :telemetry.attach(id, metric.event_name, &__MODULE__.export/4, {self(), metric})
      on_exit(fn -> :telemetry.detach(id) end)
    end
  end

  defp measure(%Telemetry.Metrics.Counter{}, _measurements, _metadata), do: 1
  defp measure(%{measurement: key}, measurements, _meta) when is_atom(key), do: measurements[key]

  defp measure(%{measurement: fun}, measurements, _meta) when is_function(fun, 1),
    do: fun.(measurements)

  defp measure(%{measurement: fun}, measurements, meta), do: fun.(measurements, meta)

  # Every export since the last call; an event missing a tag fails here,
  # since a reporter would drop it without a word.
  defp exported(acc \\ []) do
    receive do
      {:exported, name, labels, value, []} ->
        exported([{name, labels, value} | acc])

      {:exported, name, _labels, _value, missing} ->
        flunk("#{name} lost an event: its metadata has no #{inspect(missing)}")
    after
      0 -> acc |> Enum.reverse() |> Enum.reject(fn {_name, _labels, value} -> is_nil(value) end)
    end
  end

  defp series(exports, name), do: for({^name, labels, value} <- exports, do: {labels, value})

  test "every metric exports from a real event, with bounded labels" do
    # A task with a tool call, then the answer, priced.
    {:ok, run} = Runs.start(Lookup, "Find the forecast", subject: {"ticket", "t-1"})
    expect_turn(tool_events("tu_1", "lookup", %{"query" => "forecast"}))
    expect_turn(text_events("Sunny."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    # A park for approval, its resume, and the rest of the run.
    {:ok, approval} = Runs.start(Approval, "Tell the team")
    expect_turn(tool_events("tu_1", "send_note", %{"text" => "hi"}))
    assert :ok = perform_job(Worker, %{"run_id" => approval.id})
    assert :ok = Runs.resume(approval.id, {:approved, %{by: "alice"}})
    expect_turn(text_events("Sent."))
    assert :ok = perform_job(Worker, %{"run_id" => approval.id})

    # A provider error after the stream's start: it burned, and costs.
    {:ok, failed} = Runs.start(Echo, "Hello")

    expect_turn([
      {:message_start, %{"usage" => %{"input_tokens" => 40, "output_tokens" => 1}}},
      {:error, :overloaded}
    ])

    assert :ok = perform_job(Worker, %{"run_id" => failed.id})

    # In process: a tool that exits, a garbled call the engine repairs,
    # and an execution that runs out of iterations.
    agent =
      Clementine.Agent.new(
        id: "in_process",
        model: :claude_sonnet,
        tools: [Exits, Verdict]
      )

    expect_turn(tool_events("tu_x", "exits", %{}))
    expect_turn(text_events("Exited."))
    assert {:ok, _} = Clementine.run(agent, "Crash")

    garbled = %{"summary" => "Chest pain.</summary>\n<parameter name=\"tier\">urgent"}
    expect_turn(tool_events("tu_g", "record_verdict", garbled))
    assert {:error, _} = Clementine.run(agent, "Triage", limits: [max_iterations: 1])

    # A drain's requeue, the lease it leaves behind, and the reaper.
    {:ok, drained} = Runs.start(Echo, "Wait")

    {:ok, lease} =
      Protocol.claim(Lifecycle, drained.id, executor: "test", agent_key: "test_echo")

    assert :ok = Protocol.heartbeat(lease)
    assert {:ok, _} = Protocol.requeue(lease, :drain)
    assert {:error, :lost_lease} = Protocol.heartbeat(lease)
    assert {:ok, _} = Protocol.claim(Lifecycle, drained.id, executor: "test")

    TestRepo.query!(
      "UPDATE agent_runs SET heartbeat_at = now() - interval '1 hour' WHERE id = $1",
      [Ecto.UUID.dump!(drained.id)]
    )

    assert %{interrupted: interrupted} = Reaper.sweep()
    assert interrupted >= 1

    # A thread: an input, its inbox polled, a step that spawns a turn, the
    # loop cancelled while the turn runs, a message to the ended loop, and
    # the subject purged.
    {:ok, loop} = Runs.start_loop(Thread, %{"agent" => "test_chat"}, subject: @subject)
    {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "hi", "id" => "m1"})
    assert :ok = Runs.emit_inbox_depths()
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    {:ok, turn} = Runs.child(loop.id, {:turn, "m1"})
    assert {:ok, _} = Runs.cancel(loop.id)
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    _ = Runs.cancel(turn.id)
    _ = perform_job(StepWorker, %{"run_id" => loop.id})
    _ = Runs.send(loop.id, %{"prompt" => "late", "id" => "m2"})
    _ = Runs.purge(@subject)

    # A provider whose usage report undercounts its cache parts, and a
    # loop judged stale.
    Clementine.LLM.ProviderUsage.openai(
      %{"input_tokens" => 1, "input_tokens_details" => %{"cached_tokens" => 5}},
      %{provider: :openai, model: "gpt-5"}
    )

    stale = %Facts{
      ref: Ecto.UUID.generate(),
      kind: :loop,
      status: :running,
      epoch: 1,
      heartbeat_at: DateTime.add(DateTime.utc_now(), -3_600, :second)
    }

    assert {:requeue, _} = Clementine.Reconciler.judge(stale, DateTime.utc_now())

    # Emitted as the step runner emits them, after commits these tests'
    # loops never make: a step that raised, and a state upgrade
    # (test/clementine/loop/ pins their metadata).
    :telemetry.execute([:clementine, :loop, :step_failed], %{}, %{
      loop_ref: loop.id,
      epoch: 1,
      error: %Clementine.Error{message: "boom"},
      requeued: true
    })

    :telemetry.execute([:clementine, :loop, :upgraded], %{}, %{
      loop_ref: loop.id,
      epoch: 1,
      from: 1,
      to: 2
    })

    exports = exported()
    names = exports |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    for metric <- Clementine.Telemetry.metrics() do
      name = Enum.join(metric.name, "_")
      assert name in names, "#{name} exported nothing"
    end

    for {name, labels, _value} <- exports, {label, value} <- labels do
      assert is_nil(value) or is_atom(value) or is_binary(value) or is_number(value),
             "#{name} labels #{label} with #{inspect(value)}"
    end

    # The engine's series name the agent, the provider, the model, and
    # the alias.
    lookup = @identity

    assert {lookup, 20} in sum_by(series(exports, "clementine_llm_input_tokens_total"))
    assert {lookup, 10} in sum_by(series(exports, "clementine_llm_output_tokens_total"))
    assert {lookup, 0} in sum_by(series(exports, "clementine_llm_cache_read_tokens_total"))
    assert {lookup, 0} in sum_by(series(exports, "clementine_llm_cache_write_tokens_total"))

    assert {Map.put(lookup, :currency, "USD"), 210} in sum_by(
             series(exports, "clementine_llm_cost_micros_total")
           )

    assert {Map.put(lookup, :stop_reason, "tool_use"), 1} in sum_by(
             series(exports, "clementine_llm_calls_total")
           )

    assert {Map.merge(lookup, %{tool: "lookup", result: :ok}), 1} in sum_by(
             series(exports, "clementine_tool_calls_total")
           )

    assert {Map.put(lookup, :status, :success), 1} in sum_by(
             series(exports, "clementine_rollout_stops_total")
           )

    echo = %{lookup | agent_key: "test_echo"}

    assert {echo, 40} in sum_by(series(exports, "clementine_llm_exception_input_tokens_total"))

    assert {Map.put(echo, :currency, "USD"), 135} in sum_by(
             series(exports, "clementine_llm_exception_cost_micros_total")
           )

    in_process = %{lookup | agent_key: "in_process"}

    assert {Map.put(in_process, :tool, "exits"), 1} in sum_by(
             series(exports, "clementine_tool_exceptions_total")
           )

    assert {Map.put(in_process, :tool, "record_verdict"), 1} in sum_by(
             series(exports, "clementine_tool_input_repaired_total")
           )

    assert {Map.put(in_process, :kind, :error), 1} in sum_by(
             series(exports, "clementine_rollout_exceptions_total")
           )

    # The run metrics name the agent where the writer knew it.
    assert {%{agent_key: "test_lookup", terminal: :completed}, 1} in sum_by(
             series(exports, "clementine_run_finished_total")
           )

    assert {%{agent_key: "test_approval", reason_type: :approval}, 1} in sum_by(
             series(exports, "clementine_run_suspended_total")
           )

    assert {%{agent_key: "test_echo"}, 1} in sum_by(
             series(exports, "clementine_run_heartbeats_total")
           )

    assert {%{agent_key: "test_echo"}, 1} in sum_by(
             series(exports, "clementine_run_requeued_total")
           )

    assert {%{agent_key: "test_echo"}, 1} in sum_by(
             series(exports, "clementine_run_lease_lost_total")
           )

    assert {%{agent_key: "test_echo", code: :lease_expired}, 1} in sum_by(
             series(exports, "clementine_run_reaped_total")
           )

    # A resume has no execution to name its agent.
    assert {%{agent_key: nil}, 1} in sum_by(series(exports, "clementine_run_resumed_total"))
  end

  test "the list holds no summaries, and every name is unique, as a Prometheus registry needs" do
    metrics = Clementine.Telemetry.metrics()
    names = Enum.map(metrics, &Enum.join(&1.name, "_"))

    assert Enum.uniq(names) == names

    for metric <- metrics do
      assert metric.__struct__ in [
               Telemetry.Metrics.Counter,
               Telemetry.Metrics.Sum,
               Telemetry.Metrics.Distribution
             ]

      assert hd(metric.name) == :clementine

      if match?(%Telemetry.Metrics.Distribution{}, metric) do
        assert [_ | _] = metric.reporter_options[:buckets]
      end
    end
  end

  test "the series Meli's and yakky's plugins export keep their names and labels" do
    labels = Map.new(Clementine.Telemetry.metrics(), &{Enum.join(&1.name, "_"), &1.tags})

    for {name, tags} <- [
          {"clementine_llm_calls_total", [:model, :stop_reason]},
          {"clementine_llm_input_tokens_total", [:model]},
          {"clementine_llm_output_tokens_total", [:model]},
          {"clementine_llm_duration_milliseconds", [:model]},
          {"clementine_llm_exceptions_total", [:model]},
          {"clementine_tool_calls_total", [:tool, :result]},
          {"clementine_tool_duration_milliseconds", [:tool]},
          {"clementine_tool_exceptions_total", [:tool]},
          {"clementine_tool_input_repaired_total", [:tool]},
          {"clementine_rollout_stops_total", [:status]},
          {"clementine_rollout_duration_milliseconds", [:status]},
          {"clementine_rollout_iterations", [:status]},
          {"clementine_rollout_exceptions_total", [:kind]},
          {"clementine_run_claims_total", []},
          {"clementine_run_heartbeats_total", []},
          {"clementine_run_suspended_total", [:reason_type]},
          {"clementine_run_resumed_total", []},
          {"clementine_run_finished_total", [:terminal]},
          {"clementine_run_duration_milliseconds", [:terminal]},
          {"clementine_run_requeued_total", []},
          {"clementine_run_lease_lost_total", []},
          {"clementine_run_reaped_total", [:code]},
          {"clementine_loop_verdicts_total", [:verdict]},
          {"clementine_loop_step_duration_milliseconds", [:outcome, :mode]},
          {"clementine_loop_step_inputs_total", []},
          {"clementine_loop_step_failures_total", [:requeued]},
          {"clementine_loop_inputs_total", [:kind, :outcome]},
          {"clementine_loop_dead_letters_total", [:reason]},
          {"clementine_loop_spawned_total", []},
          {"clementine_loop_cascades_total", [:trigger]},
          {"clementine_loop_upgrades_total", []}
        ] do
      assert Map.has_key?(labels, name), "#{name} is gone"
      assert tags -- labels[name] == [], "#{name} lost a label: #{inspect(tags)}"
    end
  end

  test "the reaped counter collapses an app's own codes to a bounded label" do
    reaped =
      Enum.find(Clementine.Telemetry.metrics(), &(&1.event_name == [:clementine, :run, :reaped]))

    assert %{code: :app, agent_key: nil} = reaped.tag_values.(%{code: {:app, {:custom, "why"}}})
    assert %{code: :lease_expired} = reaped.tag_values.(%{code: :lease_expired, agent_key: "a"})
  end

  # Each label set's total.
  defp sum_by(series) do
    series
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {labels, values} -> {labels, Enum.sum(values)} end)
  end
end
