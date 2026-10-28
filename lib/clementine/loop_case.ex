if Code.ensure_loaded?(Oban.Testing) and Code.ensure_loaded?(Mox) do
  defmodule Clementine.LoopCase do
    @moduledoc false
    # The loop battery against the durable runtime: `Clementine.Runs`,
    # `Clementine.Runs.Loops`, and the two workers, on a real Postgres,
    # as `mix test` runs it:
    #
    #     defmodule Clementine.Runs.LoopConformanceTest do
    #       use Clementine.LoopCase, repo: Clementine.TestRepo, moduletag: :postgres
    #     end
    #
    # It starts Oban in `:manual` testing mode and `{Clementine, ...}` with
    # the conformance controller and agents (`Clementine.LoopCase.
    # ConformanceLoop`, `Task`, `Turn`) and host, on a shared SQL sandbox,
    # and scripts the model on the configured `:llm_client`, a Mox mock.
    # The library's own suite runs it; an app proves its loops at its own
    # altitude, in its own tests.
    #
    # The battery's first two tests are the two the loop RFC's cold read
    # said must lead: the park-vs-append interleaving (matrix row L4) and
    # the crash-replay early-completion (row L5). Then creation, appends,
    # the wrong-state calls, the step commit (L1, L11), poison isolation
    # (L7), children through the start path (L12), the `{:cancel, tag}`
    # action, cancels and halts (L8, L9), timers (L6), the loop sweep's
    # five verdicts (L13, L15, L16, L4's backstop, the deadline belt),
    # the step-job enqueues, and the lane matrix with children. Mid-step
    # interleavings (crash windows, zombie commits, the park race) are
    # manufactured with the pure step core (`Clementine.Loop.Step`),
    # exactly the states a step occupies between its claim and its commit.
    #
    # Options: `:repo` (required), the repo `agent_runs` lives in;
    # `:moduletag`, an atom or list of atoms applied to the generated
    # tests. Racing-writer tests carry `racing_writers: true`.

    defmacro __using__(opts) do
      repo = Keyword.fetch!(opts, :repo)
      moduletags = opts |> Keyword.get(:moduletag) |> List.wrap()

      quote do
        use ExUnit.Case, async: false
        use Oban.Testing, repo: unquote(repo)

        import Mox

        unquote_splicing(
          for tag <- moduletags do
            quote do: @moduletag(unquote(tag))
          end
        )

        alias Clementine.LoopCase.Battery

        setup :set_mox_global
        setup :verify_on_exit!

        setup do
          pid = Ecto.Adapters.SQL.Sandbox.start_owner!(unquote(repo), shared: true)
          on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

          start_supervised!({Oban, repo: unquote(repo), testing: :manual})

          start_supervised!(
            {Clementine,
             repo: unquote(repo),
             agents: [
               Clementine.LoopCase.ConformanceLoop,
               Clementine.LoopCase.Task,
               Clementine.LoopCase.Turn
             ],
             host: Clementine.LoopCase.Host}
          )

          Process.register(self(), :clementine_loop_case)
          :ok
        end

        describe "loop conformance: the two lead interleavings" do
          test "matrix row L4: the park-vs-append interleaving — an append landing between drain and park never strands" do
            Battery.park_vs_append_interleaving()
          end

          test "matrix row L5: the crash-replay early-completion — the replayed step delivers the fast child's completion exactly once" do
            Battery.crash_replay_early_completion()
          end
        end

        describe "loop conformance: start_loop" do
          test "a loop is a run: kind loop, the controller's key, the args as input; init runs in the first step, exactly once" do
            Battery.start_loop_is_a_run()
          end

          test "start_loop is insert-or-get on the lane: the same controller and subject returns the standing loop" do
            Battery.start_loop_insert_or_get()
          end

          test "start_loop refuses an agent, an unlisted module, and a loop without a subject" do
            Battery.start_loop_refusals()
          end
        end

        describe "loop conformance: send and append" do
          test "appends round-trip the codec in FIFO commit-visibility order; the wake rides the unit" do
            Battery.append_round_trip()
          end

          test "duplicate sends by dedup_key return :duplicate and change nothing; keys are per-loop" do
            Battery.dedup_key_duplicates()
          end

          test "matrix row L10: a send racing or trailing the finish returns :dead_lettered — the sender observes the outcome" do
            Battery.append_to_terminal_observability()
          end

          test "inside the caller's transaction the input and the step job commit with it" do
            Battery.send_inside_a_transaction()
          end

          @tag racing_writers: true
          test "matrix row L3: sends race each other and the wake — one step drains all, none lost, none doubled" do
            Battery.concurrent_appends()
          end

          @tag racing_writers: true
          test "matrix rows L3/L4 (load): sends racing steps never strand a parked loop with pending inputs" do
            Battery.appends_racing_steps_never_strand()
          end
        end

        describe "loop conformance: send if_idle" do
          test "if_idle refuses :busy under a live child, a non-empty inbox, and a pending cancel; the refused message never reaches the loop" do
            Battery.send_if_idle_refusals()
          end

          test "if_idle and a step serialize on the loop row lock: a send racing a park is refused whole or appended whole" do
            Battery.send_if_idle_racing_a_step()
          end

          @tag racing_writers: true
          test "if_idle sends racing each other: exactly one lands" do
            Battery.send_if_idle_concurrent()
          end

          test "a :busy inside the caller's transaction is a return, not a rollback" do
            Battery.send_if_idle_inside_a_transaction()
          end
        end

        describe "loop conformance: wrong-state calls" do
          test "every loop verb refuses a run that is not a loop; a parked rollout's suspension survives a miswired wake" do
            Battery.kind_guards()
          end

          test "cancel is idempotent and first-cause-wins; terminal loops answer :already_terminal" do
            Battery.cancel_wrong_states()
          end

          test "the step runner discards lost claim races and terminal loops without writing" do
            Battery.step_discards_wrong_states()
          end

          test "send, inspect, cancel, child, and the step report an unknown loop" do
            Battery.not_found()
          end

          test "resume refuses a loop, which waits for its inbox rather than a decision" do
            Battery.resume_refuses_a_loop()
          end
        end

        describe "loop conformance: the step commit" do
          test "matrix row L1: a step crashing before its commit replays identically — the bump counted, no duplicate children or sends" do
            Battery.crash_replay_no_duplicates()
          end

          test "matrix row L11: a zombie step's commit is fenced :stale on both guard halves and writes nothing" do
            Battery.zombie_step_fenced()
          end

          test "matrix rows L1/L11 (send half): a re-dispatched send — crash replay or zombie — lands :duplicate at the target" do
            Battery.send_redispatch_dedup()
          end

          test "a cancel flag landing between drain and park downgrades the park in its own commit — never stranded" do
            Battery.cancel_flag_racing_park()
          end

          test "the step worker maps the runner's outcomes: parked, continued, and finished ack; a discard cancels the job" do
            Battery.step_worker_outcomes()
          end
        end

        describe "loop conformance: poison isolation" do
          # The poison path logs each failed step at error level by design.
          @tag capture_log: true
          test "matrix row L7: head blame, batch-1 degrade, dead-letter at the threshold, the controller informed, innocents untouched" do
            Battery.poison_isolation()
          end

          test "matrix row L7 (VM death): the drain-time attempts bump commits outside both units and survives the crash" do
            Battery.vm_death_attempts_counted()
          end
        end

        describe "loop conformance: children through the start path" do
          test "a step commit inserts the child with its parent, tag, turn, subject, actor, and Oban job in one transaction" do
            Battery.child_inserted_through_the_start_path()
          end

          test "the child builds at its claim like any run: history/1 sees run.subject resolved, both resolvers run, tools see parent_id and tag" do
            Battery.child_builds_at_claim()
          end

          test "matrix row L12: the child's terminal appends {:completed, tag, result} to the parent's inbox and the parent wakes" do
            Battery.child_completion_wakes_parent()
          end

          test "a child the runtime cannot build is cancelled as unstartable, and its loop hears the Cancelled completion" do
            Battery.unstartable_child_completes_cancelled()
          end

          test "a child's events fold like any run's, and its end closes the view" do
            Battery.child_events_fold()
          end

          test "the loop's children are list(parent:) and turns/1; child/2 is the live child under a tag, re-armed once it ends" do
            Battery.children_queries()
          end

          test "a child description the runtime refuses fails the step naming the tag, requeues the loop, and inserts nothing" do
            Battery.child_spec_refused()
          end

          test "a send to a missing run or a rollout fails the step; the target's inbox stays untouched" do
            Battery.send_target_refused()
          end
        end

        describe "loop conformance: {:cancel, tag}" do
          test "{:cancel, tag} flags the running child, the cancel relay pushes it, and its Cancelled completion arrives" do
            Battery.cancel_action_stops_running_child()
          end

          test "a cancel and its child's completion in one drain: the cancel retires, and a successor under the re-armed tag lives" do
            Battery.cancel_retired_by_completion_in_one_batch()
          end

          test "{:cancel, tag} ends a queued child at once; a tag with no live child is a no-op" do
            Battery.cancel_action_queued_child_and_no_op()
          end
        end

        describe "loop conformance: cancel/1" do
          test "matrix row L8: cancel/1 on a loop flags, wakes, cascades to its children, dead-letters leftovers, and finishes the loop last" do
            Battery.cascade_orders_queued_child()
          end

          test "matrix row L8 (running child): the cascade flags cooperatively and its park never spins on the cancel flag" do
            Battery.cascade_running_child_cooperative()
          end

          test "cancel/1 on a child behaves as on any rollout; the loop hears the completion and goes on" do
            Battery.cancel_child_like_a_rollout()
          end

          test "matrix row L9: halt with children in flight and inputs behind the halt — the halt's result wins, leftovers dead-letter" do
            Battery.halt_with_children_in_flight()
          end

          test "matrix row L9 (same step): a halt in the step that spawned a child cascades to the child it just inserted" do
            Battery.halt_in_the_spawning_step()
          end

          test "the cascade's :completions window reads past a backlog longer than the batch cap — never a livelock" do
            Battery.cascade_completion_behind_long_backlog()
          end

          test "cancelling a loop that never stepped short-circuits its queued inputs into the sweep" do
            Battery.cancel_never_stepped_short_circuits()
          end
        end

        describe "loop conformance: timers" do
          test "matrix row L6: a timer schedules a job in the step's commit; its fire delivers {:elapsed, tag} once per schedule and the tag re-arms" do
            Battery.timer_fire_delivers_and_rearms()
          end

          test "matrix row L6: a fire racing its cancel is consumed as a dead letter — never seen by handle/2, never silently dropped" do
            Battery.timer_fire_racing_cancel_dead_letters()
          end

          test "matrix row L6 (terminal): a fire against a terminal loop answers :dead_lettered — distinguishable noise" do
            Battery.timer_fire_against_terminal()
          end

          test "matrix row L6 (crash window): a schedule is cargo — it cannot outlive its never-committed envelope entry" do
            Battery.timer_schedule_is_cargo()
          end
        end

        describe "loop conformance: the loop sweep's verdicts" do
          test "matrix row L16: a crashed step requeues with its job, whatever its epoch" do
            Battery.sweep_requeues_crashed_step()
          end

          test "matrix row L15: a lost step job never kills the loop — :reenqueue re-inserts it" do
            Battery.sweep_reenqueues_lost_job()
          end

          test "matrix row L13: a lost completion self-heals — :reconcile_children synthesizes the append under the canonical dedup key, and collapses to :duplicate against a real delivery" do
            Battery.sweep_reconciles_children()
          end

          test "matrix row L4 (backstop): the :wake_pending verdict wakes a park stranded over pending inputs" do
            Battery.sweep_wakes_pending()
          end

          test "a live-wedged step past its deadline is the one verdict that ends a loop" do
            Battery.sweep_interrupts_wedged_step()
          end
        end

        describe "loop conformance: step-job enqueues" do
          test "start_loop, the send wake, the park downgrade, and cancel each enqueue the step job inside their units" do
            Battery.step_job_enqueues()
          end
        end

        describe "loop conformance: the lane matrix" do
          test "a turn child and a direct turn on one thread collide: the direct start is refused, and as a step commit the step fails and the poison path records it" do
            Battery.lane_turn_child_vs_direct_turn()
          end

          test "a turn child and a task child on one subject both run" do
            Battery.lane_turn_child_vs_task_child()
          end

          test "two loops of one controller on one subject are one loop; a loop and its own turn never collide" do
            Battery.lane_loop_vs_loop_and_own_turn()
          end

          test "two children of one task agent on one subject collide: the second is refused" do
            Battery.lane_two_task_children()
          end

          test "interrupt is two steps: cancel, then spawn on the cancelled child's completion; cancel-and-spawn in one step fails" do
            Battery.lane_interrupt_two_phase()
          end
        end
      end
    end
  end
end
