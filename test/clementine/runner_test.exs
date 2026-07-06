defmodule Clementine.RunnerTest do
  use ExUnit.Case, async: true

  import Mox

  alias Clementine.{
    ApprovalRequest,
    Checkpoint,
    Error,
    Event,
    InterruptReason,
    Lease,
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
  alias Clementine.LLM.Message.{Content, ToolResultMessage, UserMessage}
  alias Clementine.Test.{CollectingSink, FlakyLifecycle, MemoryLifecycle}
  alias Clementine.Test.Tools.{Crash, Echo, SafePush, Slow, UnsafeSlow}

  setup :verify_on_exit!

  setup do
    {:ok, store: MemoryLifecycle.start_store(), ref: make_ref()}
  end

  defmodule CancelTool do
    @moduledoc false
    use Clementine.Tool,
      name: "cancel_run",
      description: "Flags cooperative cancellation on the executing run",
      parameters: []

    @impl true
    def run(_args, context) do
      {:ok, :flagged} =
        Clementine.Lifecycle.Protocol.request_cancel(
          Clementine.Test.MemoryLifecycle,
          context.run_ref,
          :user_stop,
          context.store
        )

      {:ok, "flagged"}
    end
  end

  defmodule PushLifecycle do
    @moduledoc false
    # MemoryLifecycle storage plus the optional push channel; delivering a
    # pending cancel at subscription time is the deterministic stand-in
    # for a broadcast landing mid-run (subscribe_cancel runs in the runner
    # process, so self() is the right mailbox).
    @behaviour Clementine.Lifecycle

    @impl true
    defdelegate fetch(run_ref, ctx), to: MemoryLifecycle

    @impl true
    defdelegate apply(transition, ctx), to: MemoryLifecycle

    @impl true
    def subscribe_cancel(_lease) do
      send(self(), {:clementine, :cancel, :pushed_stop})
      :ok
    end
  end

  defmodule RaisingPushLifecycle do
    @moduledoc false
    @behaviour Clementine.Lifecycle

    @impl true
    defdelegate fetch(run_ref, ctx), to: MemoryLifecycle

    @impl true
    defdelegate apply(transition, ctx), to: MemoryLifecycle

    @impl true
    def subscribe_cancel(_lease), do: raise("pubsub down")
  end

  defp agent(opts) do
    Clementine.Agent.new(
      Keyword.merge([model: :claude_sonnet, instructions: "test agent", tools: []], opts)
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

  describe "claim" do
    test "a run that is not queued is discarded, not raced", %{store: store, ref: ref} do
      MemoryLifecycle.seed(store, %Facts{ref: ref, status: :running, epoch: 1})

      assert {:discard, {:not_claimable, :running}} = execute(build_run(ref), store)
    end

    test "a missing run is discarded", %{store: store, ref: ref} do
      assert {:discard, :not_found} = execute(build_run(ref), store)
    end
  end

  describe "completed rollouts" do
    test "finishes with the projection firing and exact usage", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(text_events("Final!"))

      assert {:finished, %Facts{status: :completed} = facts} = execute(build_run(ref), store)
      assert facts.epoch == 1
      assert facts.usage == %Usage{input_tokens: 7, output_tokens: 3}
      assert %DateTime{} = facts.finished_at

      assert [{^ref, %Result.Completed{} = result}] = MemoryLifecycle.projections(store)
      assert result.output == "Final!"
      assert %UserMessage{} = result.input_message
      assert [%{content: _}] = result.messages
    end

    test "a tool batch raises the effect fence before executing", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(tool_events("tu_1", "echo", %{"message" => "hi"}))
      expect_stream(text_events("Done"))

      assert {:finished, %Facts{status: :completed, effects?: true}} =
               execute(build_run(ref, tools: [Echo]), store)

      assert [{^ref, %Result.Completed{messages: messages}}] =
               MemoryLifecycle.projections(store)

      # assistant tool_use, tool results, assistant final — generated only
      assert length(messages) == 3
    end
  end

  describe "failure matrix row 3" do
    test "matrix row 3: reaper races a live finish — exactly one terminal writer",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      reaper_wins = fn _rollout, _opts ->
        {:ok, facts} = MemoryLifecycle.fetch(ref, store)

        {:ok, _} =
          Protocol.interrupt(MemoryLifecycle, facts, InterruptReason.new(:lease_expired), store)

        {:ok, Result.completed(output: "too late")}
      end

      assert {:discard, :already_terminal} =
               execute(build_run(ref), store, rollout_execute: reaper_wins)

      facts = MemoryLifecycle.facts!(store, ref)
      assert facts.status == :interrupted
      assert facts.interrupt.code == :lease_expired

      assert [{^ref, %Result.Interrupted{}}] = MemoryLifecycle.projections(store)
    end

    test "matrix row 3: a stale-observed reaper interrupt loses cleanly to a committed finish",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      test = self()

      observe_then_complete = fn _rollout, _opts ->
        {:ok, running_facts} = MemoryLifecycle.fetch(ref, store)
        send(test, {:observed, running_facts})
        {:ok, Result.completed(output: "committed")}
      end

      assert {:finished, %Facts{status: :completed}} =
               execute(build_run(ref), store, rollout_execute: observe_then_complete)

      assert_received {:observed, %Facts{status: :running} = observed}

      assert {:error, :stale} =
               Protocol.interrupt(
                 MemoryLifecycle,
                 observed,
                 InterruptReason.new(:lease_expired),
                 store
               )

      assert MemoryLifecycle.facts!(store, ref).status == :completed
      assert [{^ref, %Result.Completed{}}] = MemoryLifecycle.projections(store)
    end
  end

  describe "failure matrix row 4 (poll flavor)" do
    test "matrix row 4: a cancel flagged mid-run is honored at the next poll",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      # One provider call only: the boundary poll after the tool batch must
      # stop the loop before a second gather.
      expect_stream(tool_events("tu_1", "cancel_run", %{}))

      run =
        build_run(ref, [tools: [CancelTool]], context: %{run_ref: ref, store: store})

      assert {:finished, %Facts{status: :cancelled}} = execute(run, store)

      assert [{^ref, %Result.Cancelled{reason: :user_stop, usage: usage}}] =
               MemoryLifecycle.projections(store)

      # The stamper's accumulated approximation rides on runner-built results.
      assert usage == %Usage{input_tokens: 5, output_tokens: 2}
    end
  end

  describe "failure matrix row 4 (push flavor)" do
    test "matrix row 4: a pushed cancel aborts without waiting for the poll",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      # Zero stream expectations: the push lands before the first gather
      # and Mox verifies no provider call ever happened — the latency is
      # the signal's, not an iteration's.
      assert {:finished, %Facts{status: :cancelled}} =
               execute(build_run(ref), store, lifecycle: PushLifecycle)

      assert [{^ref, %Result.Cancelled{reason: :pushed_stop}}] =
               MemoryLifecycle.projections(store)
    end

    @tag capture_log: true
    test "a failing subscription costs latency, never the run",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(text_events("Fine"))

      assert {:finished, %Facts{status: :completed}} =
               execute(build_run(ref), store, lifecycle: RaisingPushLifecycle)
    end
  end

  describe "failure matrix row 5" do
    test "matrix row 5: cancel during an unsafe tool — safe siblings killed, unsafe runs out, finish(cancelled)",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_stream([
        {:tool_use_start, "tu_1", "safe_push"},
        {:input_json_delta, "tu_1", "{}"},
        {:content_block_stop, 0},
        {:tool_use_start, "tu_2", "unsafe_slow"},
        {:input_json_delta, "tu_2", Jason.encode!(%{"delay_ms" => 80})},
        {:content_block_stop, 1},
        {:message_delta, %{"stop_reason" => "tool_use"},
         %{"input_tokens" => 5, "output_tokens" => 2}}
      ])

      run =
        build_run(ref, [tools: [SafePush, UnsafeSlow]],
          context: %{push_to: self(), notify: self()}
        )

      started = System.monotonic_time(:millisecond)

      assert {:finished, %Facts{status: :cancelled}} = execute(run, store)

      # The unsafe tool's external effect settled before the terminal wrote.
      assert_received {:unsafe_done, 80}
      # SafePush sleeps forever: finishing at all proves the kill; finishing
      # fast proves nobody waited for a timeout.
      assert System.monotonic_time(:millisecond) - started < 2_000

      assert [{^ref, %Result.Cancelled{reason: :mid_batch_stop}}] =
               MemoryLifecycle.projections(store)
    end
  end

  defp seed_waiting_and_resume(store, ref, checkpoint) do
    token = %ResumeToken{run_ref: ref, epoch: 1, reason_type: :approval}

    suspension = %Suspension{
      reason: {:approval, %ApprovalRequest{tool_use_id: "tu_1", tool_name: "deploy"}},
      checkpoint: checkpoint,
      token: token
    }

    MemoryLifecycle.seed(
      store,
      %Facts{ref: ref, status: :waiting, epoch: 1, suspension: suspension}
    )

    {:ok, _facts} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "u1"}}, store)
    :ok
  end

  describe "failure matrix row 8" do
    test "matrix row 8: a checkpoint version from another deploy fails cleanly, never crashes",
         %{store: store, ref: ref} do
      seed_waiting_and_resume(store, ref, %Checkpoint{version: 999, rollout_id: "r1"})

      assert {:finished, %Facts{status: :failed} = facts} = execute(build_run(ref), store)
      assert %Error{code: :incompatible_checkpoint, retryable?: false} = facts.error

      assert [{^ref, %Result.Failed{error: %Error{code: :incompatible_checkpoint}}}] =
               MemoryLifecycle.projections(store)
    end

    test "matrix row 8: an undecodable stored checkpoint takes the same path",
         %{store: store, ref: ref} do
      seed_waiting_and_resume(store, ref, %{"version" => 42, "rollout_id" => "r1"})

      assert {:finished, %Facts{status: :failed} = facts} = execute(build_run(ref), store)
      assert %Error{code: :incompatible_checkpoint} = facts.error
    end

    test "matrix row 8: a pending operation this engine cannot resolve is not understood",
         %{store: store, ref: ref} do
      # Pending resolution arrives with gated tools (SKUNK-134); until then a
      # pending checkpoint is exactly "content no longer understood".
      checkpoint = %Checkpoint{
        rollout_id: "r1",
        iteration: 1,
        pending: %Pending.ToolApproval{tool_use_id: "tu_1", tool_name: "deploy"}
      }

      seed_waiting_and_resume(store, ref, checkpoint)

      assert {:finished, %Facts{status: :failed} = facts} = execute(build_run(ref), store)
      assert %Error{code: :incompatible_checkpoint} = facts.error
    end
  end

  describe "failure matrix row 9" do
    test "matrix row 9: the deadline fails an agreeable run despite a healthy heartbeat",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(tool_events("tu_1", "slow", %{"delay_ms" => 250}))

      run =
        build_run(ref, [tools: [Slow]], limits: [max_duration: 100, max_iterations: 10])

      # Heartbeat on: the run must fail by deadline judgment, not by reaping.
      assert {:finished, %Facts{status: :failed} = facts} =
               execute(run, store, heartbeat: [interval: 25])

      assert %Error{code: :deadline_exceeded, retryable?: false} = facts.error
      assert [{^ref, %Result.Failed{}}] = MemoryLifecycle.projections(store)
    end
  end

  describe "failure matrix row 11" do
    test "matrix row 11: a tool crash becomes an error tool result the model reacts to",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(tool_events("tu_1", "crash", %{}))
      expect_stream(text_events("Recovered"))

      assert {:finished, %Facts{status: :completed}} =
               execute(build_run(ref, tools: [Crash]), store)

      assert [{^ref, %Result.Completed{messages: messages, output: "Recovered"}}] =
               MemoryLifecycle.projections(store)

      assert [_tool_use, %ToolResultMessage{content: [result]}, _final] = messages
      assert %Content.ToolResult{is_error: true} = result
      assert result.content =~ "Intentional crash"
    end

    test "matrix row 11: an exception escaping the rollout is rescued into finish(failed)",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      # A provider client bug: a malformed stream event raises inside the
      # engine. The runner's rescue tier, not the reaper, must answer.
      expect_stream([{:text_delta, :not_a_binary}])

      assert {:finished, %Facts{status: :failed} = facts} = execute(build_run(ref), store)
      assert %Error{kind: :runtime, code: :exception} = facts.error
      assert [{^ref, %Result.Failed{}}] = MemoryLifecycle.projections(store)
    end
  end

  describe "failure matrix row 13" do
    test "matrix row 13: drain with the fence unset requeues, and the run survives",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      send(self(), {:clementine, :drain})

      assert {:finished, %Facts{status: :queued} = facts} = execute(build_run(ref), store)
      assert facts.epoch == 1
      assert facts.executor_id == nil
      assert facts.deadline == nil
      assert facts.heartbeat_at == nil
      assert %DateTime{} = facts.queued_at
      assert MemoryLifecycle.projections(store) == []

      # The worker's re-enqueue: the same run claims again at the next epoch
      # and completes as if the deploy never happened.
      expect_stream(text_events("Survived"))

      assert {:finished, %Facts{status: :completed, epoch: 2}} =
               execute(build_run(ref), store)
    end

    test "matrix row 13: drain with the fence set interrupts immediately and labeled",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref, effects?: true)
      send(self(), {:clementine, :drain})

      assert {:finished, %Facts{status: :interrupted} = facts} = execute(build_run(ref), store)
      assert facts.interrupt.code == :drain

      assert [{^ref, %Result.Interrupted{reason: %InterruptReason{code: :drain}}}] =
               MemoryLifecycle.projections(store)
    end

    test "matrix row 13: a drain signal aborts an in-flight tool batch",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_stream(tool_events("tu_1", "slow", %{"delay_ms" => 2_000}))

      runner = self()

      spawn(fn ->
        Process.sleep(50)
        send(runner, {:clementine, :drain})
      end)

      started = System.monotonic_time(:millisecond)

      # The batch already raised the fence, so an aborted drain resolves as
      # the labeled interrupt, well before the tool's own duration.
      assert {:finished, %Facts{status: :interrupted} = facts} =
               execute(build_run(ref, tools: [Slow]), store)

      assert facts.interrupt.code == :drain
      assert System.monotonic_time(:millisecond) - started < 1_500
    end
  end

  describe "failure matrix row 16" do
    test "matrix row 16: transient storage failures at the terminal write are retried to success",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      # Fault script by apply order: claim passes, the first two finish
      # attempts blip, the third (empty queue) commits.
      faults = FlakyLifecycle.start_faults([:pass, {:fail, :db_blip}, {:fail, :db_blip}])
      expect_stream(text_events("Persisted"))

      assert {:finished, %Facts{status: :completed}} =
               execute(build_run(ref), store,
                 lifecycle: FlakyLifecycle,
                 ctx: %{store: store, faults: faults}
               )

      assert [{^ref, %Result.Completed{output: "Persisted"}}] =
               MemoryLifecycle.projections(store)
    end

    test "matrix row 16: exhausted retries leave the run running for the reaper",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      faults =
        FlakyLifecycle.start_faults([
          :pass,
          {:fail, :db_blip},
          {:fail, :db_blip},
          {:fail, :db_blip}
        ])

      expect_stream(text_events("Lost"))

      assert {:error, :db_blip} =
               execute(build_run(ref), store,
                 lifecycle: FlakyLifecycle,
                 ctx: %{store: store, faults: faults}
               )

      # Nothing terminal wrote; the generated messages are the acknowledged
      # residual and the reaper finishes the story.
      assert MemoryLifecycle.facts!(store, ref).status == :running
      assert MemoryLifecycle.projections(store) == []
    end
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

  describe "suspend" do
    test "a suspend parks the run, no finish, approval event only after commit",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      request = suspension_request()
      suspender = fn _rollout, _opts -> {:suspend, request} end

      assert {:suspended, %ResumeToken{run_ref: ^ref, epoch: 1, reason_type: :approval}} =
               execute(build_run(ref), store,
                 rollout_execute: suspender,
                 events: CollectingSink
               )

      facts = MemoryLifecycle.facts!(store, ref)
      assert facts.status == :waiting
      assert facts.executor_id == nil
      assert facts.deadline == nil
      assert facts.heartbeat_at == nil
      assert facts.suspension.checkpoint.iteration == 2
      # The runner completed the cursor from its stamper (nothing emitted
      # before the suspend, so seq 0).
      assert facts.suspension.checkpoint.cursor == {1, 0}
      assert MemoryLifecycle.projections(store) == []

      assert_received {:clementine_event, %Event{type: :approval_requested} = event}
      assert event.payload == %{tool_use_id: "tu_1", name: "deploy", args: %{"env" => "prod"}}
      refute Map.has_key?(event.payload, :token)
    end

    test "a cancel that raced the suspend converges to cancelled, not a stranded waiting run",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      request = suspension_request()

      flag_then_suspend = fn _rollout, _opts ->
        {:ok, :flagged} = Protocol.request_cancel(MemoryLifecycle, ref, :changed_mind, store)
        {:suspend, request}
      end

      assert {:finished, %Facts{status: :cancelled}} =
               execute(build_run(ref), store,
                 rollout_execute: flag_then_suspend,
                 events: CollectingSink
               )

      assert [{^ref, %Result.Cancelled{reason: :changed_mind}}] =
               MemoryLifecycle.projections(store)

      refute_received {:clementine_event, %Event{type: :approval_requested}}
    end

    test "a suspend from a lost lease is a discard", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      requeue_then_suspend = fn _rollout, _opts ->
        {:ok, running} = MemoryLifecycle.fetch(ref, store)
        {:ok, _} = Protocol.requeue(MemoryLifecycle, running, :test_fence, store)
        {:suspend, suspension_request()}
      end

      assert {:discard, :lost_lease} =
               execute(build_run(ref), store, rollout_execute: requeue_then_suspend)
    end
  end

  describe "lost lease" do
    test "a rollout that discovered lease loss discards without writing",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      lost = fn _rollout, _opts -> :lost_lease end

      assert {:discard, :lost_lease} = execute(build_run(ref), store, rollout_execute: lost)
      assert MemoryLifecycle.facts!(store, ref).status == :running
      assert MemoryLifecycle.projections(store) == []
    end

    test "a finish that discovers lease loss is the same discard shape",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      requeue_then_complete = fn _rollout, _opts ->
        {:ok, running} = MemoryLifecycle.fetch(ref, store)
        {:ok, _} = Protocol.requeue(MemoryLifecycle, running, :test_fence, store)
        {:ok, Result.completed(output: "zombie work")}
      end

      assert {:discard, :lost_lease} =
               execute(build_run(ref), store, rollout_execute: requeue_then_complete)

      assert MemoryLifecycle.projections(store) == []
    end
  end

  describe "contract violations" do
    test "a rollout return outside the closed set becomes finish(failed), never a crash",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      buggy = fn _rollout, _opts -> :bogus end

      assert {:finished, %Facts{status: :failed} = facts} =
               execute(build_run(ref), store, rollout_execute: buggy)

      assert %Error{code: :invalid_rollout_return} = facts.error
    end

    test "a bare-atom error tuple is a contract violation too", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      buggy = fn _rollout, _opts -> {:error, :bare_atom} end

      assert {:finished, %Facts{status: :failed} = facts} =
               execute(build_run(ref), store, rollout_execute: buggy)

      assert %Error{code: :invalid_rollout_return} = facts.error
    end
  end

  describe "heartbeat wiring" do
    test "the heartbeat discovers lease loss and signals the busy rollout",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      test = self()

      blocked_rollout = fn _rollout, _opts ->
        # Zombie simulation: a successor execution bumps the epoch while
        # this one blocks exactly like a provider-stream receive would.
        Agent.update(store, fn state ->
          update_in(state.runs[ref].epoch, &(&1 + 1))
        end)

        receive do
          {:clementine, :lease_lost, %Lease{}} ->
            send(test, :lease_lost_signal_received)
            :lost_lease
        after
          2_000 ->
            send(test, :no_signal)
            :lost_lease
        end
      end

      assert {:discard, :lost_lease} =
               execute(build_run(ref), store,
                 rollout_execute: blocked_rollout,
                 heartbeat: [interval: 25]
               )

      assert_received :lease_lost_signal_received
    end

    test "the heartbeat piggybacks stamper usage while the rollout runs",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      test = self()

      emitting_rollout = fn _rollout, opts ->
        stamper = Keyword.fetch!(opts, :emit)

        Clementine.Events.Stamper.emit(stamper, :usage_delta, %{
          input_tokens: 11,
          output_tokens: 6
        })

        # Wait (bounded) for a beat to sample the counter into the facts.
        wait_until = fn
          _wait_until, 0 ->
            :ok

          wait_until, attempts ->
            case MemoryLifecycle.facts!(store, ref).usage do
              %Usage{input_tokens: 11, output_tokens: 6} ->
                send(test, :piggybacked)

              _ ->
                Process.sleep(10)
                wait_until.(wait_until, attempts - 1)
            end
        end

        wait_until.(wait_until, 100)
        {:cancelled, :done_observing}
      end

      assert {:finished, %Facts{status: :cancelled}} =
               execute(build_run(ref), store,
                 rollout_execute: emitting_rollout,
                 heartbeat: [interval: 20]
               )

      assert_received :piggybacked
    end
  end
end
