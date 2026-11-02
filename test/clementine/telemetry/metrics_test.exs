defmodule Clementine.Telemetry.MetricsTest do
  @moduledoc """
  `Clementine.Telemetry.metrics/0` as an app exports it: every metric
  read the way a Prometheus reporter reads it (the measurement, the tags
  from `tag_values`, and nothing exported for an event missing either),
  against real runs on the runtime and in process. Every metric in the
  list exports, every label is bounded (an atom, a string, or a number;
  `""` where the writer had no value), and the engine's series name the
  agent, the provider (the model's vendor), the platform, and the model,
  and no alias. The same runs, scraped through
  PromEx's two stores (TelemetryMetricsPrometheus.Core and Peep), export
  the same series.
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

  defmodule Plugin do
    @moduledoc false
    # The guide's plugin, as an app writes it.
    use PromEx.Plugin

    @impl true
    def event_metrics(_opts) do
      [Event.build(:clementine_event_metrics, Clementine.Telemetry.metrics())]
    end
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
    platform: :anthropic,
    model: "claude-sonnet-5"
  }

  setup do
    previous = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, previous) end)

    # Illustrative rates, so calls carry a cost.
    Application.put_env(
      :clementine,
      :models,
      Map.put(previous || %{}, "claude-sonnet-5",
        prices: [currency: "USD", input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75]
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

  # Every event the list reads, from real runs where a test can make one:
  # on the runtime and in process, through a tool call, a park and its
  # resume, a provider error, a tool that exits, a repaired call, an
  # iteration limit, direct cancels, a drain requeue and its lost lease,
  # the reaper, a thread through cascade and purge, and a stale loop.
  defp exercise! do
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

    # A final turn the provider refused, scripted through the Anthropic
    # fake with the usage it reports, cache tokens included: an error,
    # never a success, and its tokens and cost count as a real stream's.
    {:ok, refused} = Runs.start(Echo, "Something it will not do")

    expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
      Clementine.LLM.Anthropic.Fake.stream(model, system, messages, tools, opts, [],
        stop_reason: "refusal",
        usage: [
          input_tokens: 40,
          output_tokens: 7,
          cache_read_input_tokens: 900,
          cache_creation_input_tokens: 300
        ]
      )
    end)

    assert :ok = perform_job(Worker, %{"run_id" => refused.id})

    # A queued run cancelled directly: its end names the row's key.
    {:ok, cancelled} = Runs.start(Echo, "Never mind")
    assert {:ok, :finished} = Runs.cancel(cancelled.id)

    # In process: a tool that exits, a garbled call the engine repairs,
    # and an execution that runs out of iterations. The caller names the
    # agent in the context; its id (an app's own, per workspace say)
    # never labels anything.
    agent =
      Clementine.Agent.new(
        id: "workspace-42",
        model: "claude-sonnet-5",
        tools: [Exits, Verdict]
      )

    in_process = [context: %{agent_key: "in_process"}]

    expect_turn(tool_events("tu_x", "exits", %{}))
    expect_turn(text_events("Exited."))
    assert {:ok, _} = Clementine.run(agent, "Crash", in_process)

    # A history whose turn was produced after another conversation: on a
    # model that binds its thinking, the call sends it without it.
    binding_agent = Clementine.Agent.new(model: "claude-sonnet-5-5")

    stale = [
      Clementine.LLM.Message.UserMessage.new("Earlier."),
      %Clementine.LLM.Message.AssistantMessage{
        content: [
          Clementine.LLM.Message.Content.thinking("", "sig"),
          Clementine.LLM.Message.Content.text("Hello.")
        ],
        binding: "another-conversation"
      }
    ]

    expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
      Clementine.LLM.Anthropic.Fake.stream(model, system, messages, tools, opts, [{:text, "Hi."}],
        strict: false
      )
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, _} = Clementine.run(binding_agent, "Hi", [messages: stale] ++ in_process)
    end)

    garbled = %{"summary" => "Chest pain.</summary>\n<parameter name=\"tier\">urgent"}
    expect_turn(tool_events("tu_g", "record_verdict", garbled))

    assert {:error, _} =
             Clementine.run(agent, "Triage", [limits: [max_iterations: 1]] ++ in_process)

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
      %{provider: :openai, platform: :openai, model: "gpt-5"}
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

    :ok
  end

  test "every metric exports from a real event, with bounded labels" do
    exercise!()
    exports = exported()
    names = exports |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    for metric <- Clementine.Telemetry.metrics() do
      name = Enum.join(metric.name, "_")
      assert name in names, "#{name} exported nothing"
    end

    for {name, labels, _value} <- exports, {label, value} <- labels do
      assert value != nil and (is_atom(value) or is_binary(value) or is_number(value)),
             "#{name} labels #{label} with #{inspect(value)}"
    end

    # The engine's series name the agent, the vendor, the platform, and
    # the model, and no alias; every metered call counts once, by how it
    # ended.
    lookup = @identity
    stopped = Map.put(lookup, :outcome, :stop)

    assert {stopped, 20} in sum_by(series(exports, "clementine_llm_input_tokens_total"))
    assert {stopped, 10} in sum_by(series(exports, "clementine_llm_output_tokens_total"))
    assert {stopped, 0} in sum_by(series(exports, "clementine_llm_cache_read_tokens_total"))
    assert {stopped, 0} in sum_by(series(exports, "clementine_llm_cache_write_tokens_total"))

    assert {Map.put(stopped, :currency, "USD"), 210} in sum_by(
             series(exports, "clementine_llm_cost_micros_total")
           )

    assert {Map.put(stopped, :stop_reason, "tool_use"), 1} in sum_by(
             series(exports, "clementine_llm_calls_total")
           )

    assert {Map.put(stopped, :stop_reason, "end_turn"), 1} in sum_by(
             series(exports, "clementine_llm_calls_total")
           )

    assert {Map.merge(lookup, %{tool: "lookup", result: :ok}), 1} in sum_by(
             series(exports, "clementine_tool_calls_total")
           )

    assert {Map.put(lookup, :status, :success), 1} in sum_by(
             series(exports, "clementine_rollout_stops_total")
           )

    # A call a provider error ended: in the same series, as an error,
    # and counted again by its error code.
    errored = %{lookup | agent_key: "test_echo"} |> Map.put(:outcome, :error)

    assert {errored, 40} in sum_by(series(exports, "clementine_llm_input_tokens_total"))

    assert {Map.put(errored, :currency, "USD"), 135} in sum_by(
             series(exports, "clementine_llm_cost_micros_total")
           )

    assert {Map.put(errored, :stop_reason, ""), 1} in sum_by(
             series(exports, "clementine_llm_calls_total")
           )

    assert {%{lookup | agent_key: "test_echo"} |> Map.put(:error_code, :unknown), 1} in sum_by(
             series(exports, "clementine_llm_exceptions_total")
           )

    in_process = %{lookup | agent_key: "in_process"}

    assert {Map.put(in_process, :tool, "exits"), 1} in sum_by(
             series(exports, "clementine_tool_exceptions_total")
           )

    assert {Map.put(in_process, :tool, "record_verdict"), 1} in sum_by(
             series(exports, "clementine_tool_input_repaired_total")
           )

    assert {Map.merge(in_process, %{
              kind: :error,
              error_kind: :rollout,
              error_code: :max_iterations
            }), 1} in sum_by(series(exports, "clementine_rollout_exceptions_total"))

    # The refused run: an error by its code, with the fake's cache tokens
    # and their cost in the call series.
    echo = %{lookup | agent_key: "test_echo"}
    echo_stopped = Map.put(echo, :outcome, :stop)

    assert {Map.merge(echo, %{kind: :error, error_kind: :rollout, error_code: :refused}), 1} in sum_by(
             series(exports, "clementine_rollout_exceptions_total")
           )

    refute Enum.any?(
             series(exports, "clementine_rollout_stops_total"),
             fn {labels, _value} -> labels.agent_key == "test_echo" end
           )

    assert {Map.put(echo_stopped, :stop_reason, "refusal"), 1} in sum_by(
             series(exports, "clementine_llm_calls_total")
           )

    assert {echo_stopped, 1240} in sum_by(series(exports, "clementine_llm_input_tokens_total"))

    assert {echo_stopped, 900} in sum_by(
             series(exports, "clementine_llm_cache_read_tokens_total")
           )

    assert {echo_stopped, 300} in sum_by(
             series(exports, "clementine_llm_cache_write_tokens_total")
           )

    # 40 × 3.0 + 900 × 0.3 + 300 × 3.75 + 7 × 15.0, per million tokens.
    assert {Map.put(echo_stopped, :currency, "USD"), 1620} in sum_by(
             series(exports, "clementine_llm_cost_micros_total")
           )

    # A history replayed from another conversation is the history's drop,
    # labeled by its bounded cause.
    assert {Map.put(%{in_process | model: "claude-sonnet-5-5"}, :cause, :history), 1} in sum_by(
             series(exports, "clementine_llm_thinking_dropped_total")
           )

    # A usage report that undercounts names the wire whose convention
    # differs, and the vendor.
    assert {%{provider: :openai, platform: :openai}, 1} in sum_by(
             series(exports, "clementine_llm_usage_clamped_total")
           )

    # The agent's id labels nothing.
    refute Enum.any?(exports, fn {_name, labels, _value} ->
             "workspace-42" in Map.values(labels)
           end)

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

    # A loop's step names its controller's key.
    assert [{%{agent_key: "thread"}, _} | _] =
             Enum.filter(
               sum_by(series(exports, "clementine_run_claims_total")),
               &match?({%{agent_key: "thread"}, _}, &1)
             )

    # A resume and a cancel name the row's agent: a direct cancel, and
    # the turn the thread's cascade cancelled.
    assert {%{agent_key: "test_approval"}, 1} in sum_by(
             series(exports, "clementine_run_resumed_total")
           )

    assert {%{agent_key: "test_echo", terminal: :cancelled}, 1} in sum_by(
             series(exports, "clementine_run_finished_total")
           )

    assert {%{agent_key: "test_chat", terminal: :cancelled}, 1} in sum_by(
             series(exports, "clementine_run_finished_total")
           )
  end

  test "PromEx's Core and Peep stores export the same series from the same runs" do
    core = store(PromEx.Storage.Core, :clementine_metrics_core)
    peep = store(PromEx.Storage.Peep, :clementine_metrics_peep)

    exercise!()

    core = scrape(core)
    peep = scrape(peep)

    for {store, scrape} <- [core: core, peep: peep] do
      refute scrape.text =~ ~s(="nil"), "#{store} exported a nil label"

      for metric <- Clementine.Telemetry.metrics() do
        name = Enum.join(metric.name, "_")
        assert Map.has_key?(scrape.types, name), "#{store} exported nothing for #{name}"
      end
    end

    assert core.types == peep.types
    assert core.samples == peep.samples
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

  test "a stop reason outside the providers' known ones is labeled other" do
    calls =
      Enum.find(
        Clementine.Telemetry.metrics(),
        &(Enum.join(&1.name, "_") == "clementine_llm_calls_total")
      )

    label = &calls.tag_values.(%{outcome: :stop, stop_reason: &1}).stop_reason

    assert label.("end_turn") == "end_turn"
    assert label.("max_tokens") == "max_tokens"
    assert label.(nil) == "other"
    assert label.("some_server_finish_reason_#{System.unique_integer()}") == "other"

    # A call that did not stop has no stop reason.
    assert calls.tag_values.(%{outcome: :aborted, stop_reason: nil}).stop_reason == ""
    assert calls.tag_values.(%{outcome: :error, stop_reason: "end_turn"}).stop_reason == ""
  end

  test "a label nothing filled exports as an empty string, never nil, on every metric" do
    # An id no sheet holds resolves to no provider and no platform,
    # keeping its id; and a direct tool batch names nothing.
    unknown = Clementine.Trace.resolve_model("not-a-model")

    unknown = %{
      agent_key: nil,
      provider: unknown.provider,
      platform: unknown.platform,
      model: unknown.id
    }

    nothing = %{agent_key: nil, provider: nil, platform: nil, model: nil}

    for metadata <- [unknown, nothing],
        metric <- Clementine.Telemetry.metrics(),
        metric.tags != [] do
      labels = metric.tag_values.(metadata)
      assert Map.keys(labels) |> Enum.sort() == Enum.sort(metric.tags)
      refute Enum.any?(Map.values(labels), &is_nil/1), "#{inspect(metric.name)} kept a nil"
    end

    tokens =
      Enum.find(
        Clementine.Telemetry.metrics(),
        &(Enum.join(&1.name, "_") == "clementine_llm_input_tokens_total")
      )

    assert %{agent_key: "", provider: "", platform: "", model: "not-a-model", outcome: ""} =
             tokens.tag_values.(unknown)

    assert %{agent_key: "", provider: "", platform: "", model: "", outcome: ""} =
             tokens.tag_values.(nothing)

    # No series is labeled alias, and every engine series is labeled
    # platform.
    for metric <- Clementine.Telemetry.metrics() do
      refute :alias in metric.tags, "#{inspect(metric.name)} is labeled alias"

      if :model in metric.tags,
        do: assert(:platform in metric.tags, "#{inspect(metric.name)} lacks platform")
    end
  end

  test "the error labels are closed: every provider error's code, else other" do
    by_name = Map.new(Clementine.Telemetry.metrics(), &{Enum.join(&1.name, "_"), &1})
    code = &by_name["clementine_llm_exceptions_total"].tag_values.(%{error_code: &1}).error_code

    kind =
      &by_name["clementine_rollout_exceptions_total"].tag_values.(%{error_kind: &1}).error_kind

    provider_errors =
      [
        {:api_error, 401, %{}},
        {:api_error, 404, %{}},
        {:api_error, 408, %{}},
        {:api_error, 429, %{}},
        {:api_error, 529, %{}},
        {:api_error, 400, %{}},
        {:api_error, 503, %{}},
        {:api_error, 302, %{}},
        {:request_failed, :econnrefused},
        {:llm_exception, %{message: "boom"}},
        %{"type" => "overloaded_error"}
      ]

    for reason <- provider_errors do
      error = Clementine.Error.normalize(reason)
      assert code.(error.code) == error.code, "#{inspect(reason)} is labeled other"
      assert kind.(error.kind) == error.kind
    end

    assert code.(:exception) == :exception

    # The engine's own rollout errors, a final turn refused or cut off
    # among them, label the rollout series by code.
    rollout_code =
      &by_name["clementine_rollout_exceptions_total"].tag_values.(%{error_code: &1}).error_code

    for reason <- [
          "refusal",
          "content_filter",
          "max_tokens",
          "model_context_window_exceeded",
          "incomplete"
        ] do
      %Clementine.Error{code: error_code} = Clementine.Error.stopped(reason)
      assert rollout_code.(error_code) == error_code
    end

    assert rollout_code.(Clementine.Error.empty("end_turn").code) == :empty

    for engine_code <- [:max_iterations, :deadline_exceeded, :invalid_output] do
      assert rollout_code.(engine_code) == engine_code
    end

    assert rollout_code.(:an_apps_own_code) == :other
    assert code.(:an_apps_own_code) == :other
    assert kind.(:an_apps_own_kind) == :other
    assert code.(nil) == ""
  end

  test "the reaped counter collapses an app's own codes to a bounded label" do
    reaped =
      Enum.find(Clementine.Telemetry.metrics(), &(&1.event_name == [:clementine, :run, :reaped]))

    assert %{code: :app, agent_key: ""} = reaped.tag_values.(%{code: {:app, {:custom, "why"}}})
    assert %{code: :lease_expired} = reaped.tag_values.(%{code: :lease_expired, agent_key: "a"})
  end

  defp store(store, name) do
    previous = Application.get_env(:prom_ex, :storage_adapter)
    Application.put_env(:prom_ex, :storage_adapter, store)

    # Event.build/2 reads the store: for Peep it makes a bucket module of
    # each distribution's buckets.
    [%PromEx.MetricTypes.Event{metrics: metrics}] = Plugin.event_metrics([])

    if previous,
      do: Application.put_env(:prom_ex, :storage_adapter, previous),
      else: Application.delete_env(:prom_ex, :storage_adapter)

    start_supervised!(Supervisor.child_spec(store.child_spec(name, metrics), id: name))
    {store, name}
  end

  # A scrape as the series it holds: each metric's type, and each
  # sample's value by name and labels. A histogram compares by its count:
  # Peep writes only the buckets it filled, its bounds as floats
  # (le="250.0"), and its sum in whole units.
  defp scrape({store, name}) do
    text = store.scrape(name)
    lines = String.split(text, "\n", trim: true)

    types =
      for "# TYPE " <> rest <- lines, into: %{} do
        [name, type] = String.split(rest, " ")
        {name, type}
      end

    histograms = for {name, "histogram"} <- types, do: name

    samples =
      for line <- lines,
          not String.starts_with?(line, "#"),
          [_, name, labels, value] = Regex.run(~r/^(\w+)(?:\{(.*)\})? (\S+)$/, line),
          not Enum.any?(histograms, &(name in [&1 <> "_bucket", &1 <> "_sum"])),
          into: %{} do
        labels = Regex.scan(~r/(\w+)="((?:[^"\\]|\\.)*)"/, labels, capture: :all_but_first)
        {{name, Map.new(labels, &List.to_tuple/1)}, number(value)}
      end

    %{text: text, types: types, samples: samples}
  end

  defp number(value) do
    case Float.parse(value) do
      {float, ""} -> float
    end
  end

  # Each label set's total.
  defp sum_by(series) do
    series
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {labels, values} -> {labels, Enum.sum(values)} end)
  end
end
