defmodule Clementine.TelemetryTest do
  # Telemetry handlers are global; this battery must never observe another
  # module's runs.
  use ExUnit.Case, async: false

  import Mox

  alias Clementine.{
    ApprovalRequest,
    Error,
    InterruptReason,
    Pending,
    Result,
    ResumeToken,
    Rollout,
    Run,
    Runner,
    Suspension,
    Usage
  }

  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.LLM.Message.UserMessage
  alias Clementine.Test.MemoryLifecycle

  setup :verify_on_exit!

  @rollout_events [
    [:clementine, :rollout, :start],
    [:clementine, :rollout, :stop],
    [:clementine, :rollout, :exception]
  ]

  @llm_events [
    [:clementine, :llm, :start],
    [:clementine, :llm, :stop],
    [:clementine, :llm, :exception]
  ]

  @run_events [
    [:clementine, :run, :claimed],
    [:clementine, :run, :heartbeat],
    [:clementine, :run, :suspended],
    [:clementine, :run, :resumed],
    [:clementine, :run, :finished],
    [:clementine, :run, :requeued],
    [:clementine, :run, :lease_lost],
    [:clementine, :run, :reaped]
  ]

  setup do
    {:ok, store: MemoryLifecycle.start_store(), ref: make_ref()}
  end

  @doc false
  def echo_event(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  defp attach(events) do
    handler_id = "telemetry-test-#{inspect(make_ref())}"
    :telemetry.attach_many(handler_id, events, &__MODULE__.echo_event/4, %{pid: self()})
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp drain_events(acc \\ []) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain_events([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp agent(opts) do
    Clementine.Agent.new(
      Keyword.merge(
        [id: "telemetry_test", model: :claude_sonnet, instructions: "test agent", tools: []],
        opts
      )
    )
  end

  defp build_run(ref, agent_opts \\ [], rollout_opts \\ []) do
    rollout =
      Rollout.new(Keyword.merge([agent: agent(agent_opts), input: "go"], rollout_opts))

    Run.new(ref: ref, rollout: rollout)
  end

  defp execute(run, store, opts \\ []) do
    Runner.execute(
      run,
      Keyword.merge(
        [
          lifecycle: MemoryLifecycle,
          ctx: store,
          executor_id: "test:runner",
          heartbeat: false
        ],
        opts
      )
    )
  end

  defp claim!(store, ref) do
    MemoryLifecycle.seed_queued(store, ref)

    {:ok, lease} =
      Protocol.claim(MemoryLifecycle, ref, executor: "test:proto", ctx: store)

    lease
  end

  defp expect_stream(events) do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      events
    end)
  end

  defp text_events(text) do
    [
      {:text_delta, text},
      {:message_delta, %{"stop_reason" => "end_turn"},
       %{"input_tokens" => 7, "output_tokens" => 3}}
    ]
  end

  defp tool_events(id, name, input) do
    [
      {:tool_use_start, id, name},
      {:input_json_delta, id, Jason.encode!(input)},
      {:content_block_stop, 0},
      {:message_delta, %{"stop_reason" => "tool_use"},
       %{"input_tokens" => 5, "output_tokens" => 2}}
    ]
  end

  defp suspension_request do
    %Suspension.Request{
      reason:
        {:approval,
         %ApprovalRequest{tool_use_id: "tu_1", tool_name: "deploy", args: %{"env" => "prod"}}},
      pending: %Pending.ToolApproval{
        tool_use_id: "tu_1",
        tool_name: "deploy",
        args: %{"env" => "prod"}
      },
      messages: [UserMessage.new("go")],
      iteration: 2,
      usage: %Usage{input_tokens: 9, output_tokens: 4}
    }
  end

  describe "rollout events" do
    test "a completed rollout emits start and stop in the renamed vocabulary",
         %{store: store, ref: ref} do
      attach(@rollout_events)
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(text_events("done"))

      assert {:finished, %Facts{status: :completed}} = execute(build_run(ref), store)

      assert_received {:telemetry, [:clementine, :rollout, :start], %{system_time: system_time},
                       %{
                         agent_key: "telemetry_test",
                         provider: :anthropic,
                         model: "claude-sonnet-5",
                         alias: :claude_sonnet,
                         max_iterations: 10,
                         tool_count: 0
                       }}

      assert is_integer(system_time)

      assert_received {:telemetry, [:clementine, :rollout, :stop],
                       %{duration: duration, iterations: 1},
                       %{agent_key: "telemetry_test", model: "claude-sonnet-5", status: :success}}

      assert is_integer(duration) and duration >= 0
      refute_received {:telemetry, [:clementine, :rollout, :exception], _, _}
    end

    test "a returned error emits exception with the normalized error",
         %{store: store, ref: ref} do
      attach(@rollout_events)
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(tool_events("tu_1", "echo", %{"message" => "hi"}))

      run =
        build_run(ref, [tools: [Clementine.Test.Tools.Echo]], limits: [max_iterations: 1])

      assert {:finished, %Facts{status: :failed}} = execute(run, store)

      assert_received {:telemetry, [:clementine, :rollout, :exception],
                       %{duration: _, iterations: 1},
                       %{
                         agent_key: "telemetry_test",
                         provider: :anthropic,
                         kind: :error,
                         reason: %Error{} = error
                       }}

      assert error.code == :max_iterations
      refute_received {:telemetry, [:clementine, :rollout, :stop], _, _}
    end

    test "a provider raise is hardened into the returned-error flavor",
         %{store: store, ref: ref} do
      attach(@rollout_events ++ @llm_events)
      MemoryLifecycle.seed_queued(store, ref)
      # LLM.stream converts enumeration raises into {:error, ...} events by
      # contract, so the engine sees an error return, never the raise.
      expect_stream(Stream.map([1], fn _ -> raise "provider exploded" end))

      assert {:finished, %Facts{status: :failed}} = execute(build_run(ref), store)

      assert_received {:telemetry, [:clementine, :llm, :exception], %{duration: _},
                       %{kind: :error, reason: {:llm_exception, _}}}

      assert_received {:telemetry, [:clementine, :rollout, :exception],
                       %{duration: _, iterations: 1},
                       %{kind: :error, reason: %Error{code: :exception}}}
    end

    test "a raise escaping the engine emits exception without an iteration count and re-raises" do
      attach(@rollout_events)

      rollout = Rollout.new(agent: agent([]), input: "go")

      assert_raise RuntimeError, "cancel probe blew up", fn ->
        Rollout.execute(rollout, cancel?: fn -> raise "cancel probe blew up" end)
      end

      assert_received {:telemetry, [:clementine, :rollout, :exception], measurements,
                       %{kind: :error, reason: %RuntimeError{message: "cancel probe blew up"}}}

      refute Map.has_key?(measurements, :iterations)
      assert Map.has_key?(measurements, :duration)
    end

    test "a runner signal concludes the rollout as a stop, not an exception",
         %{store: store, ref: ref} do
      attach(@rollout_events)
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream([{:text_delta, "par"}, {:signal, {:clementine, :cancel, :user_stop}}])

      assert {:finished, %Facts{status: :cancelled}} = execute(build_run(ref), store)

      assert_received {:telemetry, [:clementine, :rollout, :stop], %{iterations: 1},
                       %{status: :cancelled}}
    end
  end

  describe "llm events" do
    test "each gather emits start and stop with token counts", %{store: store, ref: ref} do
      attach(@llm_events)
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(text_events("done"))

      assert {:finished, _facts} = execute(build_run(ref), store)

      assert_received {:telemetry, [:clementine, :llm, :start], %{system_time: _},
                       %{
                         agent_key: "telemetry_test",
                         provider: :anthropic,
                         model: "claude-sonnet-5",
                         alias: :claude_sonnet,
                         iteration: 1,
                         message_count: 1,
                         tool_count: 0,
                         streaming: true
                       }}

      assert_received {:telemetry, [:clementine, :llm, :stop],
                       %{duration: _, input_tokens: 7, output_tokens: 3},
                       %{iteration: 1, stop_reason: "end_turn", streaming: true}}
    end

    test "stop carries the cache counts as measurements", %{store: store, ref: ref} do
      attach(@llm_events)
      MemoryLifecycle.seed_queued(store, ref)

      expect_stream([
        {:text_delta, "done"},
        {:message_delta, %{"stop_reason" => "end_turn"},
         %{
           "input_tokens" => 900,
           "output_tokens" => 3,
           "cache_read_tokens" => 800,
           "cache_write_tokens" => 60
         }}
      ])

      assert {:finished, %Facts{status: :completed}} = execute(build_run(ref), store)

      assert_received {:telemetry, [:clementine, :llm, :stop],
                       %{
                         input_tokens: 900,
                         output_tokens: 3,
                         cache_read_tokens: 800,
                         cache_write_tokens: 60
                       }, %{stop_reason: "end_turn"}}
    end

    test "stop carries a priced call's cost; an unpriced call leaves it out, never zero",
         %{store: store, ref: ref} do
      previous = Application.get_env(:clementine, :models)
      on_exit(fn -> Application.put_env(:clementine, :models, previous) end)

      # Illustrative rates: 3.00 in, 15.00 out, 0.30 read, 3.75 write per
      # million tokens.
      Application.put_env(
        :clementine,
        :models,
        Keyword.put(previous, :claude_sonnet,
          provider: :anthropic,
          id: "claude-sonnet-5",
          pricing: [currency: "USD", input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75]
        )
      )

      attach(@llm_events)
      MemoryLifecycle.seed_queued(store, ref)

      usage = %{
        "input_tokens" => 900,
        "output_tokens" => 3,
        "cache_read_tokens" => 800,
        "cache_write_tokens" => 60
      }

      expect_stream([
        {:text_delta, "done"},
        {:message_delta, %{"stop_reason" => "end_turn"}, usage}
      ])

      assert {:finished, %Facts{status: :completed}} = execute(build_run(ref), store)

      # 40 × 3.00 + 800 × 0.30 + 60 × 3.75 + 3 × 15.00 = 630 micro-dollars.
      assert_received {:telemetry, [:clementine, :llm, :stop],
                       %{input_tokens: 900, cost_micros: 630},
                       %{alias: :claude_sonnet, provider: :anthropic, currency: "USD"}}

      Application.put_env(:clementine, :models, previous)
      unpriced = make_ref()
      MemoryLifecycle.seed_queued(store, unpriced)

      expect_stream([
        {:text_delta, "done"},
        {:message_delta, %{"stop_reason" => "end_turn"}, usage}
      ])

      assert {:finished, %Facts{status: :completed}} = execute(build_run(unpriced), store)

      assert_received {:telemetry, [:clementine, :llm, :stop], measurements, %{currency: nil}}

      refute Map.has_key?(measurements, :cost_micros)
    end

    test "a provider error after the stream's start carries what it burned, priced",
         %{store: store, ref: ref} do
      previous = Application.get_env(:clementine, :models)
      on_exit(fn -> Application.put_env(:clementine, :models, previous) end)

      Application.put_env(
        :clementine,
        :models,
        Keyword.put(previous, :claude_sonnet,
          provider: :anthropic,
          id: "claude-sonnet-5",
          pricing: [currency: "USD", input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75]
        )
      )

      attach(@llm_events)
      MemoryLifecycle.seed_queued(store, ref)

      expect_stream([
        {:message_start, %{"usage" => %{"input_tokens" => 1_000, "output_tokens" => 1}}},
        {:error, :overloaded}
      ])

      assert {:finished, %Facts{status: :failed}} = execute(build_run(ref), store)

      # 1,000 × 3.00 + 1 × 15.00 = 3,015 micro-dollars.
      assert_received {:telemetry, [:clementine, :llm, :exception],
                       %{input_tokens: 1_000, output_tokens: 1, cost_micros: 3_015},
                       %{kind: :error, reason: :overloaded, currency: "USD"}}
    end

    test "a provider error in the stream emits exception", %{store: store, ref: ref} do
      attach(@llm_events)
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream([{:error, :overloaded}])

      assert {:finished, %Facts{status: :failed}} = execute(build_run(ref), store)

      assert_received {:telemetry, [:clementine, :llm, :exception], %{duration: _},
                       %{kind: :error, reason: :overloaded, streaming: true}}

      refute_received {:telemetry, [:clementine, :llm, :stop], _, _}
    end

    test "a signal-aborted stream stops with nil stop_reason and the partial usage",
         %{store: store, ref: ref} do
      attach(@llm_events)
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream([{:text_delta, "par"}, {:signal, {:clementine, :cancel, :user_stop}}])

      assert {:finished, %Facts{status: :cancelled}} = execute(build_run(ref), store)

      assert_received {:telemetry, [:clementine, :llm, :stop],
                       %{duration: _, input_tokens: 0, output_tokens: 0},
                       %{stop_reason: nil, streaming: true}}
    end
  end

  describe "run events" do
    test "claim emits :claimed with the minted epoch", %{store: store, ref: ref} do
      attach(@run_events)
      lease = claim!(store, ref)

      assert lease.epoch == 1

      assert_received {:telemetry, [:clementine, :run, :claimed], %{epoch: 1},
                       %{run_ref: ^ref, executor_id: "test:proto"}}
    end

    test "every successful heartbeat emits :heartbeat", %{store: store, ref: ref} do
      attach(@run_events)
      lease = claim!(store, ref)

      assert :ok = Protocol.heartbeat(lease)
      assert :ok = Protocol.heartbeat(lease, usage: %Usage{input_tokens: 5})

      assert_received {:telemetry, [:clementine, :run, :heartbeat], %{},
                       %{run_ref: ^ref, epoch: 1}}

      assert_received {:telemetry, [:clementine, :run, :heartbeat], %{},
                       %{run_ref: ^ref, epoch: 1}}
    end

    test "suspend and resume emit :suspended and :resumed", %{store: store, ref: ref} do
      attach(@run_events)
      lease = claim!(store, ref)

      assert {:ok, %ResumeToken{} = token} = Protocol.suspend(lease, suspension_request())

      assert_received {:telemetry, [:clementine, :run, :suspended], %{},
                       %{run_ref: ^ref, epoch: 1, reason_type: :approval}}

      assert {:ok, %Facts{status: :queued}} =
               Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "me"}}, store)

      assert_received {:telemetry, [:clementine, :run, :resumed], %{}, %{run_ref: ^ref, epoch: 1}}
    end

    test "finish emits :finished with terminal, usage, and the execution's duration",
         %{store: store, ref: ref} do
      attach(@run_events)
      lease = claim!(store, ref)
      usage = %Usage{input_tokens: 7, output_tokens: 3}

      assert {:ok, %Facts{status: :completed}} =
               Protocol.finish(lease, Result.completed(output: "ok", usage: usage))

      assert_received {:telemetry, [:clementine, :run, :finished], %{duration: duration},
                       %{run_ref: ^ref, epoch: 1, terminal: :completed, usage: ^usage}}

      assert is_integer(duration) and duration >= 0
    end

    test "a drain requeue and a reaper requeue both emit :requeued",
         %{store: store, ref: ref} do
      attach(@run_events)
      lease = claim!(store, ref)

      assert {:ok, %Facts{status: :queued}} = Protocol.requeue(lease, :drain)

      assert_received {:telemetry, [:clementine, :run, :requeued], %{},
                       %{run_ref: ^ref, epoch: 1, reason: :drain}}

      other = make_ref()
      MemoryLifecycle.seed(store, %Facts{ref: other, status: :running, epoch: 2})
      facts = MemoryLifecycle.facts!(store, other)

      assert {:ok, %Facts{status: :queued}} =
               Protocol.requeue(MemoryLifecycle, facts, :lease_expired, store)

      assert_received {:telemetry, [:clementine, :run, :requeued], %{},
                       %{run_ref: ^other, epoch: 2, reason: :lease_expired}}
    end

    test "a reaper interrupt emits :reaped with the taxonomy code",
         %{store: store, ref: ref} do
      attach(@run_events)

      MemoryLifecycle.seed(store, %Facts{
        ref: ref,
        status: :running,
        epoch: 3,
        usage: %Usage{input_tokens: 2}
      })

      facts = MemoryLifecycle.facts!(store, ref)

      assert {:ok, %Facts{status: :interrupted}} =
               Protocol.interrupt(
                 MemoryLifecycle,
                 facts,
                 InterruptReason.new(:lease_expired),
                 store
               )

      assert_received {:telemetry, [:clementine, :run, :reaped], %{},
                       %{run_ref: ^ref, epoch: 3, code: :lease_expired}}

      refute_received {:telemetry, [:clementine, :run, :finished], _, _}
    end

    test "a direct cancel of an unowned run emits :finished with zero duration",
         %{store: store, ref: ref} do
      attach(@run_events)
      MemoryLifecycle.seed_queued(store, ref)

      assert {:ok, :finished} =
               Protocol.request_cancel(MemoryLifecycle, ref, :user_stop, store)

      assert_received {:telemetry, [:clementine, :run, :finished], %{duration: 0},
                       %{run_ref: ^ref, epoch: 0, terminal: :cancelled, usage: %Usage{}}}
    end

    test "a cooperative cancel flag alone emits nothing until the terminal lands",
         %{store: store, ref: ref} do
      attach(@run_events)
      lease = claim!(store, ref)

      assert {:ok, :flagged} =
               Protocol.request_cancel(MemoryLifecycle, ref, :user_stop, store)

      refute_received {:telemetry, [:clementine, :run, :finished], _, _}

      assert {:ok, %Facts{status: :cancelled}} =
               Protocol.finish(lease, Result.cancelled(:user_stop))

      assert_received {:telemetry, [:clementine, :run, :finished], _,
                       %{run_ref: ^ref, terminal: :cancelled}}
    end

    test "cancel racing suspend emits :suspended then :finished, flag-first order",
         %{store: store, ref: ref} do
      attach(@run_events)
      lease = claim!(store, ref)

      assert {:ok, :flagged} =
               Protocol.request_cancel(MemoryLifecycle, ref, :changed_mind, store)

      assert {:cancelled, %Facts{status: :cancelled}} =
               Protocol.suspend(lease, suspension_request())

      assert [
               {[:clementine, :run, :claimed], _, _},
               {[:clementine, :run, :suspended], _, %{reason_type: :approval}},
               {[:clementine, :run, :finished], %{duration: duration},
                %{terminal: :cancelled, usage: %Usage{input_tokens: 9, output_tokens: 4}}}
             ] = drain_events()

      assert duration >= 0
    end

    test "every lease-loss discovery point emits :lease_lost", %{store: store, ref: ref} do
      attach(@run_events)
      lease = claim!(store, ref)

      # A successor execution owns the run now; every write and poll from
      # the old lease must discover the loss.
      MemoryLifecycle.seed(store, %Facts{ref: ref, status: :running, epoch: 2})

      assert {:error, :lost_lease} = Protocol.heartbeat(lease)
      assert {:error, :lost_lease} = Protocol.cancellation(lease)
      assert {:error, :lost_lease} = Protocol.mark_effects(lease)
      assert {:error, :lost_lease} = Protocol.suspend(lease, suspension_request())
      assert {:error, :lost_lease} = Protocol.finish(lease, Result.completed(output: "late"))
      assert {:error, :lost_lease} = Protocol.requeue(lease, :drain)

      for _ <- 1..6 do
        assert_received {:telemetry, [:clementine, :run, :lease_lost], %{},
                         %{run_ref: ^ref, epoch: 1}}
      end

      refute_received {:telemetry, [:clementine, :run, :lease_lost], _, _}
    end

    test "the runner path is observable end to end, in emission order",
         %{store: store, ref: ref} do
      attach(@run_events ++ @rollout_events ++ @llm_events)
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(text_events("done"))

      assert {:finished, %Facts{status: :completed}} =
               execute(build_run(ref), store, executor_id: "test:e2e")

      events = drain_events()

      assert Enum.map(events, fn {event, _, _} -> event end) == [
               [:clementine, :run, :claimed],
               [:clementine, :rollout, :start],
               [:clementine, :llm, :start],
               [:clementine, :llm, :stop],
               [:clementine, :rollout, :stop],
               [:clementine, :run, :finished]
             ]

      assert {_, %{duration: _}, %{terminal: :completed, usage: %Usage{input_tokens: 7}}} =
               List.last(events)
    end
  end

  describe "agent_key on run events" do
    test "an execution's writes name its agent; a direct cancel and a resume do not",
         %{store: store, ref: ref} do
      attach(@run_events)
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(text_events("done"))

      assert {:finished, _facts} = execute(build_run(ref), store)

      assert_received {:telemetry, [:clementine, :run, :claimed], _,
                       %{agent_key: "telemetry_test"}}

      assert_received {:telemetry, [:clementine, :run, :finished], _,
                       %{agent_key: "telemetry_test", terminal: :completed}}

      # A rollout run on the runtime names the row's key, which wins over
      # the agent's id.
      runtime = make_ref()
      MemoryLifecycle.seed_queued(store, runtime)
      expect_stream(text_events("done"))
      run = build_run(runtime, [], context: %{agent_key: "row_key"})
      assert {:finished, _facts} = execute(run, store)

      assert_received {:telemetry, [:clementine, :run, :finished], _, %{agent_key: "row_key"}}

      unowned = make_ref()
      MemoryLifecycle.seed_queued(store, unowned)
      assert {:ok, :finished} = Protocol.request_cancel(MemoryLifecycle, unowned, :stop, store)

      assert_received {:telemetry, [:clementine, :run, :finished], _,
                       %{run_ref: ^unowned, agent_key: nil}}
    end

    test "the reaper names the agent it read", %{store: store, ref: ref} do
      attach(@run_events)
      lease = claim!(store, ref)
      {:ok, facts} = MemoryLifecycle.fetch(lease.run_ref, store)

      assert {:ok, _} =
               Protocol.interrupt(
                 MemoryLifecycle,
                 facts,
                 InterruptReason.new(:lease_expired),
                 store,
                 agent_key: "reaped_agent"
               )

      assert_received {:telemetry, [:clementine, :run, :reaped], _,
                       %{agent_key: "reaped_agent", code: :lease_expired}}
    end
  end
end
