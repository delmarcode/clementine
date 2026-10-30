defmodule Clementine.TraceTest do
  @moduledoc """
  The run's trace through the real runner and engine, on the in-memory
  lifecycle: what each entry holds, when it is written (each iteration
  boundary, then the rest with the end or the park), what a superseded or
  reaped executor leaves, a resume that continues the trace, the agent's
  fidelity, and the usage a cut-off model call keeps (C13).
  """

  use ExUnit.Case, async: true

  import Mox

  alias Clementine.{Result, Rollout, Run, Runner, Trace}
  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.Test.{FlakyLifecycle, MemoryLifecycle}
  alias Clementine.Test.Tools.{GatedDeploy, SafeEcho}
  alias Clementine.Trace.Entry

  setup :verify_on_exit!

  setup do
    {:ok, store: MemoryLifecycle.start_store(), ref: make_ref()}
  end

  defmodule Requeuer do
    @moduledoc false
    # Takes its own run away mid-batch: the reaper requeues it, and
    # another executor claims it, as a node that came back after a
    # partition would find.
    use Clementine.Tool,
      name: "requeuer",
      description: "Hands the run to another executor",
      retry: :safe,
      parameters: []

    @impl true
    def run(_args, %{run_ref: ref, store: store}) do
      {:ok, facts} = MemoryLifecycle.fetch(ref, store)
      {:ok, _} = Protocol.requeue(MemoryLifecycle, facts, :lease_expired, store)
      {:ok, _lease} = Protocol.claim(MemoryLifecycle, ref, executor: "elsewhere", ctx: store)
      {:ok, "handed over"}
    end
  end

  defp agent(opts) do
    Clementine.Agent.new(
      Keyword.merge([model: :claude_sonnet, instructions: "Trace me.", tools: []], opts)
    )
  end

  defp build_run(ref, agent_opts \\ [], rollout_opts \\ []) do
    rollout = Rollout.new(Keyword.merge([agent: agent(agent_opts), input: "go"], rollout_opts))
    Run.new(ref: ref, rollout: rollout)
  end

  defp execute(run, store, opts \\ []) do
    Runner.execute(
      run,
      Keyword.merge(
        [lifecycle: MemoryLifecycle, ctx: store, executor_id: "test:trace", heartbeat: false],
        opts
      )
    )
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

  defp kinds(entries), do: Enum.map(entries, &{&1.epoch, &1.seq, &1.kind})

  describe "a run that completes" do
    test "has its whole trace: written at each boundary, the rest with its end",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      test = self()
      expect_stream(tool_events("tu_1", "safe_echo", %{"message" => "hi"}))

      # The second model call sees what the boundary before it wrote.
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        send(test, {:written_before_gather_2, MemoryLifecycle.trace(store, ref)})
        text_events("Done.")
      end)

      assert {:finished, %Facts{status: :completed}} =
               execute(build_run(ref, tools: [SafeEcho]), store)

      assert_received {:written_before_gather_2, written}

      assert kinds(written) == [{1, 1, :execution}, {1, 2, :model_call}, {1, 3, :tool_call}]

      assert [execution, first_call, tool_call, last_call] = MemoryLifecycle.trace(store, ref)
      assert last_call.seq == 4 and last_call.kind == :model_call
      assert Enum.all?([execution, first_call, tool_call, last_call], &(&1.run_id == ref))

      assert %{
               "model" => "claude-sonnet-5",
               "agent_fingerprint" => fingerprint,
               "instructions" => "Trace me.",
               "tools" => ["safe_echo"],
               "resumed" => false
             } = execution.payload

      assert fingerprint == Trace.fingerprint(:claude_sonnet, "Trace me.", [SafeEcho])
      assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/

      assert %{
               "iteration" => 1,
               "stop_reason" => "tool_use",
               "usage" => %{"input_tokens" => 5, "output_tokens" => 2},
               "content" => [
                 %{
                   "type" => "tool_use",
                   "id" => "tu_1",
                   "name" => "safe_echo",
                   "input" => %{"message" => "hi"}
                 }
               ],
               "duration_ms" => duration
             } = first_call.payload

      assert is_integer(duration) and duration >= 0

      assert %{
               "iteration" => 1,
               "tool_use_id" => "tu_1",
               "name" => "safe_echo",
               "args" => %{"message" => "hi"},
               "result" => "Echo: hi",
               "is_error" => false,
               "approval" => nil,
               "duration_ms" => tool_ms
             } = tool_call.payload

      assert is_integer(tool_ms) and tool_ms >= 0

      assert %{
               "iteration" => 2,
               "stop_reason" => "end_turn",
               "content" => [%{"type" => "text", "text" => "Done."}]
             } = last_call.payload
    end

    test "a boundary write that fails for a moment leaves its entries for the end",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      # The claim passes; the first boundary's trace write blips.
      faults = FlakyLifecycle.start_faults([:pass, {:fail, :db_blip}])
      expect_stream(text_events("Done."))

      assert {:finished, %Facts{status: :completed}} =
               execute(build_run(ref), store,
                 lifecycle: FlakyLifecycle,
                 ctx: %{store: store, faults: faults}
               )

      assert kinds(MemoryLifecycle.trace(store, ref)) ==
               [{1, 1, :execution}, {1, 2, :model_call}]
    end
  end

  describe "a run that ends otherwise" do
    test "a failed run has its whole trace, the failing call included",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_stream([
        {:message_start, %{"usage" => %{"input_tokens" => 11, "output_tokens" => 1}}},
        {:error, %{"type" => "overloaded_error", "message" => "Overloaded"}}
      ])

      assert {:finished, %Facts{status: :failed, usage: usage}} =
               execute(build_run(ref), store)

      assert usage == %Clementine.Usage{input_tokens: 11, output_tokens: 1}

      assert [%Entry{kind: :execution}, %Entry{kind: :model_call, payload: call}] =
               MemoryLifecycle.trace(store, ref)

      assert %{
               "stop_reason" => nil,
               "usage" => %{"input_tokens" => 11, "output_tokens" => 1},
               "content" => nil
             } = call
    end

    test "a rollout that raises still ends with what it recorded", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      raising = fn _rollout, opts ->
        Clementine.Trace.Recorder.record(opts[:trace], :execution, %{"model" => "m"})
        raise "boom"
      end

      assert {:finished, %Facts{status: :failed}} =
               execute(build_run(ref), store, rollout_execute: raising)

      assert [%Entry{epoch: 1, seq: 1, kind: :execution, payload: %{"model" => "m"}}] =
               MemoryLifecycle.trace(store, ref)
    end

    test "a run that hits its iteration cap has its whole trace", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(tool_events("tu_1", "safe_echo", %{"message" => "again"}))

      run = build_run(ref, tools: [SafeEcho], defaults: [max_iterations: 1])

      assert {:finished, %Facts{status: :failed}} = execute(run, store)

      assert kinds(MemoryLifecycle.trace(store, ref)) ==
               [{1, 1, :execution}, {1, 2, :model_call}, {1, 3, :tool_call}]
    end

    test "a run cancelled mid-response keeps the usage its stream reported (C13)",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      # The start event carries the input count, then text streams, then
      # the cancel push lands.
      expect_stream([
        {:message_start, %{"usage" => %{"input_tokens" => 42, "output_tokens" => 1}}},
        {:text_delta, "Once upon"},
        {:signal, {:clementine, :cancel, :user_stop}}
      ])

      assert {:finished, %Facts{status: :cancelled, usage: usage}} =
               execute(build_run(ref), store)

      assert usage == %Clementine.Usage{input_tokens: 42, output_tokens: 1}

      assert [{^ref, %Result.Cancelled{reason: :user_stop, usage: ^usage}}] =
               MemoryLifecycle.projections(store)

      assert [%Entry{kind: :execution}, %Entry{kind: :model_call, payload: call}] =
               MemoryLifecycle.trace(store, ref)

      assert %{
               "stop_reason" => nil,
               "usage" => %{"input_tokens" => 42, "output_tokens" => 1},
               "content" => [%{"type" => "text", "text" => "Once upon"}]
             } = call
    end

    test "a drained run writes its trace before it is requeued", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_stream([
        {:message_start, %{"usage" => %{"input_tokens" => 9, "output_tokens" => 1}}},
        {:signal, {:clementine, :drain}}
      ])

      assert {:finished, %Facts{status: :queued}} = execute(build_run(ref), store)

      assert kinds(MemoryLifecycle.trace(store, ref)) ==
               [{1, 1, :execution}, {1, 2, :model_call}]
    end
  end

  describe "an executor that loses its run" do
    test "writes no entries once superseded", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(tool_events("tu_1", "requeuer", %{}))

      run = build_run(ref, [tools: [Requeuer]], context: %{run_ref: ref, store: store})

      # The boundary after the batch finds the run gone and the executor
      # unwinds: what it recorded since its last write goes nowhere.
      assert {:discard, :lost_lease} = execute(run, store)
      assert %Facts{status: :running, epoch: 2} = MemoryLifecycle.facts!(store, ref)

      assert kinds(MemoryLifecycle.trace(store, ref)) == [{1, 1, :execution}]
    end

    test "reaped between iterations, has its trace up to its last boundary",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(tool_events("tu_1", "safe_echo", %{"message" => "hi"}))

      # The node stalls in the second call long enough for the reaper.
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        {:ok, facts} = MemoryLifecycle.fetch(ref, store)

        {:ok, _} =
          Protocol.interrupt(
            MemoryLifecycle,
            facts,
            Clementine.InterruptReason.new(:lease_expired),
            store
          )

        text_events("Too late.")
      end)

      assert {:discard, :already_terminal} =
               execute(build_run(ref, tools: [SafeEcho]), store)

      assert %Facts{status: :interrupted} = MemoryLifecycle.facts!(store, ref)

      assert kinds(MemoryLifecycle.trace(store, ref)) ==
               [{1, 1, :execution}, {1, 2, :model_call}, {1, 3, :tool_call}]
    end
  end

  describe "a run that parks for an approval" do
    test "commits its trace with the park, and the resume continues it",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_stream([
        {:tool_use_start, "tu_1", "gated_deploy"},
        {:input_json_delta, "tu_1", Jason.encode!(%{"env" => "prod"})},
        {:content_block_stop, 0},
        {:tool_use_start, "tu_2", "safe_echo"},
        {:input_json_delta, "tu_2", Jason.encode!(%{"message" => "staged"})},
        {:content_block_stop, 1},
        {:message_delta, %{"stop_reason" => "tool_use"},
         %{"input_tokens" => 5, "output_tokens" => 2}}
      ])

      run = build_run(ref, [tools: [GatedDeploy, SafeEcho]], context: %{notify: self()})
      assert {:suspended, token} = execute(run, store)

      # The model call and the ungated sibling commit with the park; the
      # gated call has not run.
      assert [_execution, _call, %Entry{kind: :tool_call, payload: sibling}] =
               parked = MemoryLifecycle.trace(store, ref)

      assert kinds(parked) == [{1, 1, :execution}, {1, 2, :model_call}, {1, 3, :tool_call}]
      assert %{"tool_use_id" => "tu_2", "approval" => nil} = sibling

      {:ok, _facts} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "u1"}}, store)
      expect_stream(text_events("Shipped."))

      assert {:finished, %Facts{status: :completed, epoch: 2}} = execute(run, store)

      assert [_, _, _, resumed, approved, final] = MemoryLifecycle.trace(store, ref)

      assert kinds([resumed, approved, final]) ==
               [{2, 1, :execution}, {2, 2, :tool_call}, {2, 3, :model_call}]

      assert %{"resumed" => true, "tools" => ["gated_deploy", "safe_echo"]} = resumed.payload

      assert %{
               "iteration" => 1,
               "tool_use_id" => "tu_1",
               "name" => "gated_deploy",
               "args" => %{"env" => "prod"},
               "result" => "deployed prod",
               "is_error" => false,
               "approval" => %{"verdict" => "approved", "by" => "u1"}
             } = approved.payload

      assert %{"iteration" => 2, "stop_reason" => "end_turn"} = final.payload
    end

    test "a denial is a tool call that never ran, with the approver's message",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(tool_events("tu_1", "gated_deploy", %{"env" => "prod"}))
      run = build_run(ref, [tools: [GatedDeploy]], context: %{notify: self()})

      assert {:suspended, token} = execute(run, store)

      {:ok, _facts} =
        Protocol.resume(
          MemoryLifecycle,
          token,
          {:denied, %{"by" => "u2", message: "not in prod"}},
          store
        )

      expect_stream(text_events("Understood."))
      assert {:finished, %Facts{status: :completed}} = execute(run, store)
      refute_received {:deployed, _args}

      assert %Entry{epoch: 2, seq: 2, kind: :tool_call, payload: denial} =
               Enum.at(MemoryLifecycle.trace(store, ref), 3)

      assert %{
               "tool_use_id" => "tu_1",
               "result" => "not in prod",
               "is_error" => true,
               "duration_ms" => 0,
               "approval" => %{"verdict" => "denied", "by" => "u2"}
             } = denial
    end
  end

  describe "fidelity" do
    test ":facts stores no content, and the fingerprint is the same under either",
         %{store: store, ref: ref} do
      facts_ref = make_ref()

      for {run_ref, fidelity} <- [{ref, :content}, {facts_ref, :facts}] do
        MemoryLifecycle.seed_queued(store, run_ref)
        expect_stream(tool_events("tu_1", "safe_echo", %{"message" => "secret"}))
        expect_stream(text_events("The secret is out."))

        assert {:finished, %Facts{status: :completed}} =
                 execute(build_run(run_ref, tools: [SafeEcho], trace: fidelity), store)
      end

      content = MemoryLifecycle.trace(store, ref)
      facts = MemoryLifecycle.trace(store, facts_ref)

      assert kinds(content) == kinds(facts)

      assert [execution, first_call, tool_call, last_call] = facts
      refute Map.has_key?(execution.payload, "instructions")
      refute Map.has_key?(first_call.payload, "content")
      refute Map.has_key?(last_call.payload, "content")
      refute Map.has_key?(tool_call.payload, "result")

      # What the model and the tools said is nowhere in it; what was
      # called, with what, and what it cost, is.
      refute inspect(facts) =~ "Trace me."
      refute inspect(facts) =~ "Echo: secret"
      refute inspect(facts) =~ "The secret is out."
      assert %{"args" => %{"message" => "secret"}, "is_error" => false} = tool_call.payload
      assert %{"usage" => %{"input_tokens" => 7}} = last_call.payload

      assert execution.payload["agent_fingerprint"] ==
               hd(content).payload["agent_fingerprint"]

      # Everything else matches the content run's, key for key, timings
      # aside.
      for {kept, full} <- Enum.zip(facts, content) do
        kept = Map.delete(kept.payload, "duration_ms")
        assert kept == Map.take(full.payload, Map.keys(kept))
      end
    end

    test "an agent takes only :content or :facts" do
      assert %Clementine.Agent{trace: :content} = agent([])

      assert_raise ArgumentError, ~r/trace: takes :content or :facts/, fn ->
        agent(trace: :everything)
      end
    end
  end

  describe "the trace write" do
    test "is fenced on the epoch: a superseded lease writes nothing", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      {:ok, old} = Protocol.claim(MemoryLifecycle, ref, executor: "old", ctx: store)
      entry = %Entry{run_id: ref, epoch: 1, seq: 1, kind: :execution, payload: %{}}

      assert :ok = Protocol.record_trace(old, [entry], usage: %Clementine.Usage{input_tokens: 3})

      assert %Facts{usage: %Clementine.Usage{input_tokens: 3}} =
               MemoryLifecycle.facts!(store, ref)

      {:ok, _} =
        Protocol.requeue(
          MemoryLifecycle,
          MemoryLifecycle.facts!(store, ref),
          :lease_expired,
          store
        )

      {:ok, _new} = Protocol.claim(MemoryLifecycle, ref, executor: "new", ctx: store)

      late = %Entry{entry | seq: 2, kind: :model_call}
      assert {:error, :lost_lease} = Protocol.record_trace(old, [late])
      assert MemoryLifecycle.trace(store, ref) == [entry]
    end
  end

  describe "the recorder" do
    test "numbers entries per execution, keeps them through a blip, and drops them only once written" do
      test = self()
      replies = :counters.new(1, [])

      flush = fn entries ->
        send(test, {:flushed, Enum.map(entries, & &1.seq)})

        case :counters.get(replies, 1) do
          0 -> {:error, :db_blip}
          1 -> :ok
          _ -> {:error, :lost_lease}
        end
      end

      recorder = Clementine.Trace.Recorder.new("run-1", 3, flush)
      :ok = Clementine.Trace.Recorder.record(recorder, :execution, %{})
      :ok = Clementine.Trace.Recorder.record(recorder, :model_call, %{})

      # A blip keeps the entries for the next write.
      assert :ok = Clementine.Trace.Recorder.flush(recorder)
      assert_received {:flushed, [1, 2]}

      assert [%Entry{run_id: "run-1", epoch: 3, seq: 1}, %Entry{seq: 2}] =
               Clementine.Trace.Recorder.pending(recorder)

      :counters.add(replies, 1, 1)
      assert :ok = Clementine.Trace.Recorder.flush(recorder)
      assert_received {:flushed, [1, 2]}
      assert Clementine.Trace.Recorder.pending(recorder) == []

      # Nothing pending writes nothing.
      assert :ok = Clementine.Trace.Recorder.flush(recorder)
      refute_received {:flushed, _}

      :counters.add(replies, 1, 1)
      :ok = Clementine.Trace.Recorder.record(recorder, :tool_call, %{})
      assert :lost_lease = Clementine.Trace.Recorder.flush(recorder)
      assert [%Entry{seq: 3, kind: :tool_call}] = Clementine.Trace.Recorder.pending(recorder)

      assert :ok = Clementine.Trace.Recorder.close(recorder)
    end
  end

  describe "entry kinds" do
    test "a stored kind reads back as its atom, and one a later version wrote stays text" do
      assert Entry.kinds() == [:execution, :model_call, :tool_call]
      assert Entry.decode_kind("tool_call") == :tool_call
      assert Entry.decode_kind("skill_load") == "skill_load"
    end
  end

  describe "the fingerprint" do
    test "moves with the instructions, the tool schemas, and the model, and nothing else" do
      base = Trace.fingerprint(:claude_sonnet, "Trace me.", [SafeEcho])

      assert base == Trace.fingerprint(:claude_sonnet, "Trace me.", [SafeEcho])
      refute base == Trace.fingerprint(:claude_sonnet, "Trace you.", [SafeEcho])
      refute base == Trace.fingerprint(:claude_sonnet, "Trace me.", [SafeEcho, GatedDeploy])
      refute base == Trace.fingerprint({:openai, "gpt-5"}, "Trace me.", [SafeEcho])
    end
  end

  describe "payloads" do
    test "store what a jsonb round trip gives back, whatever a tool or an approver handed over" do
      payload =
        Trace.payload(
          :tool_call,
          Trace.tool_call(%{
            iteration: 1,
            tool_use_id: "tu_1",
            name: "echo",
            args: %{"nested" => %{"atom" => :value}},
            result: "nul" <> <<0>> <> "byte",
            is_error: false,
            duration_ms: 3,
            approval: {:approved, %{by: {:user, 7}}}
          }),
          :content
        )

      assert payload == payload |> Jason.encode!() |> Jason.decode!()
      assert payload["args"] == %{"nested" => %{"atom" => "value"}}
      assert payload["result"] == "nul�byte"
      assert payload["approval"] == %{"verdict" => "approved", "by" => "{:user, 7}"}
    end
  end
end
