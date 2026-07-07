defmodule Clementine.Loop.StepTest do
  use ExUnit.Case, async: true

  alias Clementine.Loop.{Codec, Envelope, Input, Step, StepCommit, StoredInput}
  alias Clementine.Test.{BadDumpLoop, DoorLoop, ScriptedLoop, VersionedLoop}
  alias Clementine.{Result, Suspension, Usage}

  @loop_ref "loop-1"
  @epoch 3
  @opts [loop_ref: @loop_ref, epoch: @epoch]

  defp vocab, do: ScriptedLoop.__loop__(:vocabulary)
  defp key(tag), do: Codec.key(tag, vocabulary: vocab())

  defp stored(ref, input, attempts \\ 0),
    do: %StoredInput{ref: ref, input: input, attempts: attempts}

  defp msg(ref, payload, attempts \\ 0), do: stored(ref, Input.message(payload), attempts)

  defp completed(ref, tag, result \\ Result.completed()),
    do: stored(ref, Input.completed(tag, result))

  defp elapsed(ref, tag), do: stored(ref, Input.elapsed(tag))

  defp scripted_envelope(attrs \\ []) do
    state = Codec.encode(%{"log" => []}, vocabulary: vocab())
    struct!(%Envelope{state_version: 1, state: state}, attrs)
  end

  defp drain!(module, envelope, plan, opts \\ @opts) do
    {:ok, commit} = Step.drain(module, envelope, plan, opts)
    commit
  end

  defp log(%StepCommit{set: %{envelope: envelope}}) do
    Codec.decode(envelope.state, vocabulary: vocab())["log"]
  end

  describe "plan/3" do
    test "empty window plans an empty step" do
      assert %Step.Plan{mode: :normal, bump: [], batch: [], rest: [], dead: [], synthesize: []} =
               Step.plan(nil, [])
    end

    test "a fresh head is bumped and drained with the full batch cap" do
      pending = for n <- 1..25, do: msg(n, %{"id" => n})
      plan = Step.plan(nil, pending, batch_cap: 20)

      assert plan.bump == [1]
      assert length(plan.batch) == 20
      assert length(plan.rest) == 5
    end

    test "matrix row L7 (degrade): attempts on the head mean a failed step — batch degrades to one" do
      pending = [msg(1, %{}, 1), msg(2, %{}), msg(3, %{})]
      plan = Step.plan(nil, pending)

      assert plan.bump == [1]
      assert [%StoredInput{ref: 1}] = plan.batch
      assert length(plan.rest) == 2
    end

    test "matrix row L7 (threshold): the head at K dead-letters with a synthesized {:input_failed}, unbumped and undrained" do
      pending = [msg(1, %{"id" => "poison"}, 3), msg(2, %{})]
      plan = Step.plan(nil, pending, dead_letter_after: 3)

      assert plan.bump == []
      assert plan.batch == []
      assert [%{ref: 1, reason: :poison, error: error}] = plan.dead
      assert error.code == :input_dead_lettered
      refute error.retryable?
      assert [%Input{kind: :input_failed, input_ref: 1, error: ^error}] = plan.synthesize
      assert [%StoredInput{ref: 2}] = plan.rest
    end

    test "matrix row L7 (non-recursive): a poison {:input_failed} dead-letters without synthesizing another" do
      poison_evidence = stored(9, Input.input_failed(1, %Clementine.Error{}), 3)
      plan = Step.plan(nil, [poison_evidence])

      assert [%{ref: 9, reason: :poison}] = plan.dead
      assert plan.synthesize == []
    end

    test "a cancel flag plans a cascade: no bump, completions fill the batch past any backlog" do
      pending = [msg(1, %{}, 5), completed(2, {:reply, 1})]
      plan = Step.plan(nil, pending, cancel: :user_request)

      assert %Step.Plan{mode: :cascade, cancel: :user_request, bump: []} = plan
      # Only completions are consumable mid-cascade, so only they occupy
      # batch slots; the message waits for the terminal sweep.
      assert [%StoredInput{ref: 2}] = plan.batch
      assert [%StoredInput{ref: 1}] = plan.rest
    end

    test "a pending halt in the envelope plans a cascade without any flag" do
      envelope = scripted_envelope(pending_halt: %{result: Result.completed(output: "x")})
      plan = Step.plan(envelope, [msg(1, %{})])

      assert plan.mode == :cascade
      assert plan.cancel == nil
    end
  end

  describe "first step (init)" do
    test "init runs inside the first step: state and actions land in the same commit as the drain" do
      args = %{"actions" => [{:timer, :poll, 1_000}]}
      batch = [msg(1, %{"id" => "m1"})]
      plan = Step.plan(nil, batch)

      commit = drain!(ScriptedLoop, nil, plan, @opts ++ [loop_args: args])

      assert log(commit) == ["init", "message:m1"]
      assert [%{tag: :poll, tag_key: _, fire: {:now_plus, 1_000}}] = commit.timers
      assert commit.set.envelope.timers == %{key(:poll) => %{}}
      assert commit.consumed == [1]
      assert commit.op == :park
    end

    test "init halting finishes through the terminal path, sweeping whatever the inbox already holds" do
      batch = [msg(1, %{"id" => "never-seen"})]
      plan = Step.plan(nil, batch)

      commit = drain!(ScriptedLoop, nil, plan, @opts ++ [loop_args: %{"halt" => "done"}])

      assert commit.op == :finish
      assert %Result.Completed{output: "done"} = commit.result
      assert commit.terminal_sweep
      assert commit.consumed == []
      assert commit.marks == []
    end

    test "init returning outside its contract raises toward the poison path" do
      defmodule BadInit do
        use Clementine.Loop
        def init(_args), do: :nope
        def handle(_input, state), do: {:ok, state, []}
      end

      assert_raise ArgumentError, ~r/init\/1 must return/, fn ->
        Step.drain(BadInit, nil, Step.plan(nil, []), @opts)
      end
    end
  end

  describe "drain — dedup and tag lifetime" do
    test "matrix row L5: replay re-drains spawn + completion — in-fold dedup delivers exactly once, drops never" do
      # The stored envelope has no record of the spawn (its commit never
      # landed); the replayed batch carries both the spawn-causing message
      # and the fast child's completion.
      batch = [
        msg(1, %{"id" => "m1", "actions" => [{:run, {:reply, 9}, %{"email" => "e9"}}]}),
        completed(2, {:reply, 9}, Result.completed(usage: %Usage{input_tokens: 5}))
      ]

      plan = Step.plan(nil, batch)
      commit = drain!(ScriptedLoop, nil, plan)

      # The replayed spawn re-records the tag before the completion is
      # judged: delivered once, to handle/2, never dead-lettered.
      assert Enum.count(log(commit), &(&1 == "completed:{:reply, 9}")) == 1
      assert commit.marks == []
      assert commit.consumed == [1, 2]

      # The completion proves the child already ran: its spawn cargo is
      # retired, and the tag is no longer live.
      assert commit.children == []
      assert commit.set.envelope.children == %{}

      # Usage aggregated as the completion folded.
      assert commit.set.envelope.usage == %Usage{input_tokens: 5, output_tokens: 0}

      # Crash replay converges: the identical drain computes the identical
      # commit.
      assert drain!(ScriptedLoop, nil, plan) == commit
    end

    test "matrix row L6 (dedup half): a fire racing its cancel dead-letters :stale_elapsed, never a ghost to handle/2" do
      tag = {:retry, 1}
      envelope = scripted_envelope(timers: %{key(tag) => %{}})

      batch = [
        msg(1, %{"id" => "c", "actions" => [{:cancel_timer, tag}]}),
        elapsed(2, tag)
      ]

      plan = Step.plan(envelope, batch)
      commit = drain!(ScriptedLoop, envelope, plan)

      assert commit.cancel_timers == [key(tag)]
      assert [%{ref: 2, reason: :stale_elapsed, error: nil}] = commit.marks
      assert commit.consumed == [1]
      assert commit.set.envelope.timers == %{}

      # The race stays observable in dead-letter marks, invisible to the app.
      refute Enum.any?(log(commit), &String.starts_with?(&1, "elapsed"))
    end

    test "matrix row L6 (dedup half): an elapse for a tag never armed dead-letters, never silently drops" do
      envelope = scripted_envelope()
      plan = Step.plan(envelope, [elapsed(1, {:retry, 404})])
      commit = drain!(ScriptedLoop, envelope, plan)

      assert [%{ref: 1, reason: :stale_elapsed}] = commit.marks
      assert commit.consumed == []
    end

    test "matrix row L17: a completion for an unknown tag dead-letters as evidence, never silently drops" do
      envelope = scripted_envelope(children: %{key({:reply, 1}) => 900})
      plan = Step.plan(envelope, [completed(1, {:reply, 404})])
      commit = drain!(ScriptedLoop, envelope, plan)

      assert [%{ref: 1, reason: :unknown_tag, error: nil}] = commit.marks
      assert commit.consumed == []
      refute Enum.any?(log(commit), &String.starts_with?(&1, "completed"))

      # The known child is untouched.
      assert commit.set.envelope.children == %{key({:reply, 1}) => 900}
    end

    test "the watcher: a fired timer tag is immediately re-armable (live-key lifetime)" do
      envelope = scripted_envelope(timers: %{key(:poll) => %{}})
      plan = Step.plan(envelope, [elapsed(1, :poll)])
      commit = drain!(ScriptedLoop, envelope, plan)

      assert log(commit) == ["elapsed::poll"]
      assert commit.set.envelope.timers == %{key(:poll) => %{}}
      assert [%{tag: :poll, fire: {:now_plus, 60_000}}] = commit.timers
      assert commit.cancel_timers == []
      assert commit.consumed == [1]
    end

    test "a timer armed and elapsed in the same drain delivers and retires its own schedule" do
      tag = {:retry, 7}

      batch = [
        msg(1, %{"id" => "arm", "actions" => [{:timer, tag, 500}]}),
        elapsed(2, tag)
      ]

      envelope = scripted_envelope()
      plan = Step.plan(envelope, batch)
      commit = drain!(ScriptedLoop, envelope, plan)

      assert Enum.count(log(commit), &(&1 == "elapsed:#{inspect(tag)}")) == 1
      assert commit.timers == []
      assert commit.cancel_timers == []
      assert commit.set.envelope.timers == %{}
      assert commit.consumed == [1, 2]
    end

    test "a completion frees its tag for a same-drain respawn, keeping only the new spawn's cargo" do
      tag = {:reply, 1}
      envelope = scripted_envelope(children: %{key(tag) => 900})

      batch = [
        completed(1, tag),
        msg(2, %{"id" => "respawn", "actions" => [{:run, tag, %{"try" => 2}}]})
      ]

      plan = Step.plan(envelope, batch)
      commit = drain!(ScriptedLoop, envelope, plan)

      assert [%{tag: ^tag, child_args: %{"try" => 2}}] = commit.children
      assert commit.set.envelope.children == %{key(tag) => nil}
      assert commit.consumed == [1, 2]
    end

    test "spawning a tag that is already a live child raises toward the poison path" do
      tag = {:reply, 1}
      envelope = scripted_envelope(children: %{key(tag) => 900})
      batch = [msg(1, %{"actions" => [{:run, tag, %{}}]})]

      assert_raise ArgumentError, ~r/already a live child/, fn ->
        Step.drain(ScriptedLoop, envelope, Step.plan(envelope, batch), @opts)
      end
    end

    test "arming a tag that is already a pending timer raises toward the poison path" do
      envelope = scripted_envelope(timers: %{key(:poll) => %{}})
      batch = [msg(1, %{"actions" => [{:timer, :poll, 100}]})]

      assert_raise ArgumentError, ~r/already a pending timer/, fn ->
        Step.drain(ScriptedLoop, envelope, Step.plan(envelope, batch), @opts)
      end
    end

    test "cancelling a timer that is not pending is a benign no-op" do
      envelope = scripted_envelope()
      batch = [msg(1, %{"id" => "c", "actions" => [{:cancel_timer, :poll}]})]
      commit = drain!(ScriptedLoop, envelope, Step.plan(envelope, batch))

      assert commit.cancel_timers == []
      assert commit.consumed == [1]
    end

    test "handle returning outside its contract raises toward the poison path" do
      defmodule BadHandle do
        use Clementine.Loop
        def init(_args), do: {:ok, %{}, []}
        def handle(_input, _state), do: :nope
      end

      plan = Step.plan(nil, [msg(1, %{})])

      assert_raise ArgumentError, ~r/handle\/2 must return/, fn ->
        Step.drain(BadHandle, nil, plan, @opts)
      end
    end
  end

  describe "sends" do
    test "send dedup keys are causally derived and replay-stable" do
      batch = [
        msg(41, %{
          "id" => "s",
          "actions" => [
            {:send, "loop-2", %{"note" => "one"}},
            {:run, {:reply, 1}, %{}},
            {:send, "loop-2", %{"note" => "two"}}
          ]
        })
      ]

      plan = Step.plan(nil, batch)
      commit = drain!(ScriptedLoop, nil, plan)

      assert [
               %{target: "loop-2", payload: %{"note" => "one"}, dedup_key: key_one},
               %{target: "loop-2", payload: %{"note" => "two"}, dedup_key: key_two}
             ] = commit.sends

      # sender ref, causal input ref, action index — stable across replay,
      # unique across genuine re-sends.
      assert key_one == "send:\"loop-1\":41:0"
      assert key_two == "send:\"loop-1\":41:2"
      assert drain!(ScriptedLoop, nil, plan).sends == commit.sends
    end

    test "init's actions get the synthetic causal ref" do
      args = %{"actions" => [{:send, "loop-2", %{"hello" => true}}]}
      commit = drain!(ScriptedLoop, nil, Step.plan(nil, []), @opts ++ [loop_args: args])

      assert [%{dedup_key: "send:\"loop-1\":init:0"}] = commit.sends
    end

    test "an un-encodable send payload raises toward the poison path" do
      batch = [msg(1, %{"actions" => [{:send, "loop-2", %{"pid" => self()}}]})]

      assert_raise ArgumentError, fn ->
        Step.drain(ScriptedLoop, nil, Step.plan(nil, batch), @opts)
      end
    end
  end

  describe "transitions" do
    test "park: waiting with a checkpoint-less external suspension, hygiene cleared, recheck :any" do
      commit = drain!(ScriptedLoop, nil, Step.plan(nil, [msg(1, %{"id" => "m"})]))

      assert commit.op == :park
      assert commit.park_recheck == :any
      assert commit.expect == %{status: :running, epoch: @epoch}

      assert %{
               status: :waiting,
               executor_id: nil,
               deadline: nil,
               heartbeat_at: nil,
               queued_at: :now,
               state_version: 1,
               suspension: %Suspension{reason: {:external, :loop}, checkpoint: nil, token: token}
             } = commit.set

      assert token.run_ref == @loop_ref
      assert token.epoch == @epoch
      assert token.reason_type == :external
    end

    test "continue when the window holds a backlog: queued, atomic re-enqueue intent" do
      pending = [msg(1, %{"id" => "a"}), msg(2, %{"id" => "b"})]
      plan = Step.plan(nil, pending, batch_cap: 1)
      commit = drain!(ScriptedLoop, nil, plan)

      assert commit.op == :continue
      assert commit.park_recheck == nil
      assert %{status: :queued, queued_at: :now, suspension: nil} = commit.set
      assert commit.consumed == [1]
    end

    test "continue when the step synthesized poison evidence, so the appended {:input_failed} drains next" do
      pending = [msg(1, %{"id" => "p"}, 3)]
      plan = Step.plan(nil, pending)
      commit = drain!(ScriptedLoop, nil, plan)

      assert commit.op == :continue
      assert [%{ref: 1, reason: :poison}] = commit.marks
      assert [%Input{kind: :input_failed, input_ref: 1}] = commit.appends
      assert commit.consumed == []
    end

    test "a poison {:input_failed} at threshold with an empty window parks — marked, never jammed" do
      poison = stored(9, Input.input_failed(1, %Clementine.Error{}), 3)
      plan = Step.plan(nil, [poison])
      commit = drain!(ScriptedLoop, nil, plan)

      assert commit.op == :park
      assert [%{ref: 9, reason: :poison}] = commit.marks
      assert commit.appends == []
    end

    test "a threshold step consults no app doors: init that always raises still dead-letters (review: mailbox never jams)" do
      defmodule RaisingInitLoop do
        use Clementine.Loop
        def init(_args), do: raise("init boom")
        def handle(_input, state), do: {:ok, state, []}
      end

      # Below the threshold the raising init is the failure being counted.
      below = Step.plan(nil, [msg(1, %{}, 2), msg(2, %{})])

      assert_raise RuntimeError, "init boom", fn ->
        Step.drain(RaisingInitLoop, nil, below, @opts)
      end

      # At the threshold the poison mark must land without touching init.
      at = Step.plan(nil, [msg(1, %{}, 3), msg(2, %{})])
      {:ok, commit} = Step.drain(RaisingInitLoop, nil, at, @opts)

      assert commit.op == :continue
      assert [%{ref: 1, reason: :poison}] = commit.marks
      assert [%Input{kind: :input_failed, input_ref: 1}] = commit.appends

      # The commit changes no app state: envelope, state_version, and
      # usage are absent — the stored values ride along untouched.
      refute Map.has_key?(commit.set, :envelope)
      refute Map.has_key?(commit.set, :state_version)
      refute Map.has_key?(commit.set, :usage)
    end

    test "a threshold step bypasses load and the version check: a deploy never blocks input hygiene" do
      defmodule RaisingLoadLoop do
        use Clementine.Loop
        def init(_args), do: {:ok, %{}, []}
        def handle(_input, state), do: {:ok, state, []}
        def load(_state), do: raise("load boom")
      end

      envelope = scripted_envelope()
      at = Step.plan(envelope, [msg(1, %{}, 3)])

      assert {:ok, %{op: :continue, marks: [%{ref: 1, reason: :poison}]}} =
               Step.drain(RaisingLoadLoop, envelope, at, @opts)

      # Same with a state_version the current code cannot load: the
      # normal drain refuses, the threshold commit still lands.
      stale = %Envelope{state_version: 1, state: %{}}

      assert {:error, {:incompatible_state, _detail}} =
               Step.drain(VersionedLoop, stale, Step.plan(stale, [msg(1, %{})]), @opts)

      assert {:ok, %{marks: [%{ref: 1, reason: :poison}]}} =
               Step.drain(VersionedLoop, stale, Step.plan(stale, [msg(1, %{}, 3)]), @opts)
    end

    test "the synthesized {:input_failed} reaches handle/2 as an ordinary input" do
      evidence = stored(9, Input.input_failed(1, %Clementine.Error{code: :input_dead_lettered}))
      envelope = scripted_envelope()
      commit = drain!(ScriptedLoop, envelope, Step.plan(envelope, [evidence]))

      assert log(commit) == ["input_failed:input_dead_lettered"]
      assert commit.consumed == [9]
    end
  end

  describe "halt" do
    test "matrix row L9 (no children): halt finishes with the terminal sweep; undrained inputs stay unconsumed for it" do
      batch = [
        msg(1, %{"id" => "a"}),
        msg(2, %{"halt" => "summary"}),
        msg(3, %{"id" => "behind-the-halt"})
      ]

      plan = Step.plan(nil, batch)
      commit = drain!(ScriptedLoop, nil, plan)

      assert commit.op == :finish
      assert commit.terminal_sweep
      assert commit.consumed == [1, 2]
      assert commit.marks == []

      # The loop's terminal Completed: the halt's summary, empty messages,
      # nil input_message, machinery-aggregated usage.
      assert %Result.Completed{output: "summary", messages: [], input_message: nil} =
               commit.result

      assert %{status: :completed, finished_at: :now, suspension: nil} = commit.set
    end

    test "halt normalizes a Completed carrying messages — history lives in the messages table" do
      defmodule MessyHaltLoop do
        use Clementine.Loop

        def init(_args) do
          {:halt,
           Clementine.Result.completed(
             output: "x",
             messages: [:not_history],
             input_message: :nope
           )}
        end

        def handle(_input, state), do: {:ok, state, []}
      end

      commit = drain!(MessyHaltLoop, nil, Step.plan(nil, []))
      assert %Result.Completed{messages: [], input_message: nil} = commit.result
    end

    test "a Failed halt carries its error into the terminal set" do
      batch = [msg(1, %{"halt_failed" => "gave up"})]
      commit = drain!(ScriptedLoop, nil, Step.plan(nil, batch))

      assert commit.op == :finish
      assert %Result.Failed{error: %{message: "gave up"}} = commit.result
      assert %{status: :failed, error: %{message: "gave up"}} = commit.set
    end

    test "matrix rows L8/L9 (children in flight): halt enters the cascade — machinery cancel cargo, pending result parked, recheck :completions" do
      spawn_and_halt = [
        msg(1, %{"id" => "s", "actions" => [{:run, {:reply, 1}, %{}}]}),
        msg(2, %{"halt" => "done"}),
        msg(3, %{"id" => "behind"})
      ]

      envelope = scripted_envelope(children: %{key({:reply, 0}) => 900})
      plan = Step.plan(envelope, spawn_and_halt)
      commit = drain!(ScriptedLoop, envelope, plan)

      assert commit.op == :park
      assert commit.park_recheck == :completions
      assert commit.result == nil
      refute commit.terminal_sweep

      # Every live child — stored and spawned this very drain — gets the
      # machinery's cancel, deterministically ordered.
      assert commit.cancel_children == Enum.sort([key({:reply, 0}), key({:reply, 1})])

      # The pending result rides the envelope until the cascade completes.
      assert %{result: %Result.Completed{output: "done"}} = commit.set.envelope.pending_halt

      # Input 3 stays unconsumed for the post-cascade sweep.
      assert commit.consumed == [1, 2]
      assert commit.marks == []
    end

    test "halt parks straight into continue when a live child's completion is already visible" do
      envelope = scripted_envelope(children: %{key({:reply, 0}) => 900})

      batch = [msg(1, %{"halt" => "done"})]
      rest = [completed(2, {:reply, 0})]
      plan = %{Step.plan(envelope, batch) | rest: rest}

      commit = drain!(ScriptedLoop, envelope, plan)
      assert commit.op == :continue
      assert commit.cancel_children == [key({:reply, 0})]
    end
  end

  describe "cascade mode" do
    test "matrix row L8 (entry): the cancel flag short-circuits queued inputs and cancels children, handle/2 never runs" do
      envelope =
        scripted_envelope(
          children: %{key({:reply, 1}) => 901, key({:reply, 2}) => 902},
          usage: %Usage{input_tokens: 10}
        )

      pending = [msg(1, %{"id" => "queued-behind-cancel"}), completed(2, {:reply, 1})]
      plan = Step.plan(envelope, pending, cancel: :user_request)
      commit = drain!(ScriptedLoop, envelope, plan)

      assert commit.op == :park
      assert commit.park_recheck == :completions

      # Entry cancels every still-live child.
      assert commit.cancel_children == [key({:reply, 2})]

      # The completion absorbed without handle/2 — state untouched,
      # usage aggregated, consumption committed.
      assert commit.consumed == [2]
      assert commit.set.envelope.state == envelope.state
      assert commit.set.envelope.usage == %Usage{input_tokens: 10}

      # The queued message stays unconsumed; the pending cancel result parks.
      assert %{result: %Result.Cancelled{reason: :user_request}} =
               commit.set.envelope.pending_halt
    end

    test "matrix row L8 (finish): the last completion folds, the loop finishes last, the sweep leaves nothing behind" do
      envelope =
        scripted_envelope(
          children: %{key({:reply, 1}) => 901},
          pending_halt: %{result: Result.cancelled(:user_request)},
          usage: %Usage{input_tokens: 10}
        )

      pending = [
        completed(1, {:reply, 1}, Result.cancelled(:parent, %Usage{output_tokens: 4})),
        msg(2, %{"id" => "swept"})
      ]

      plan = Step.plan(envelope, pending)
      commit = drain!(ScriptedLoop, envelope, plan)

      assert commit.op == :finish
      assert commit.terminal_sweep
      assert commit.cancel_children == []

      assert %Result.Cancelled{
               reason: :user_request,
               usage: %Usage{input_tokens: 10, output_tokens: 4}
             } = commit.result

      assert %{status: :cancelled} = commit.set
      assert commit.set.envelope.pending_halt == nil
      assert commit.consumed == [1]
    end

    test "a halt cascade absorbs completions and finishes with the halt's result, not a cancel" do
      envelope =
        scripted_envelope(
          children: %{key({:reply, 1}) => 901},
          pending_halt: %{result: Result.completed(output: "summary")}
        )

      plan = Step.plan(envelope, [completed(1, {:reply, 1})])
      commit = drain!(ScriptedLoop, envelope, plan)

      assert commit.op == :finish
      assert %Result.Completed{output: "summary"} = commit.result
    end

    test "first cause wins: a cancel flag arriving mid-halt-cascade neither replaces the result nor re-cancels" do
      envelope =
        scripted_envelope(
          children: %{key({:reply, 1}) => 901},
          pending_halt: %{result: Result.completed(output: "summary")}
        )

      plan = Step.plan(envelope, [], cancel: :late_cancel)
      commit = drain!(ScriptedLoop, envelope, plan)

      assert commit.op == :park
      assert commit.cancel_children == []
      assert %{result: %Result.Completed{output: "summary"}} = commit.set.envelope.pending_halt
    end

    test "unknown-tag completions dead-letter as evidence even mid-cascade" do
      envelope =
        scripted_envelope(
          children: %{key({:reply, 1}) => 901},
          pending_halt: %{result: Result.cancelled(:x)}
        )

      plan = Step.plan(envelope, [completed(1, {:reply, 404})])
      commit = drain!(ScriptedLoop, envelope, plan)

      assert [%{ref: 1, reason: :unknown_tag}] = commit.marks
      assert commit.consumed == []
    end

    test "a completion visible in the window continues instead of parking" do
      envelope =
        scripted_envelope(
          children: %{key({:reply, 1}) => 901, key({:reply, 2}) => 902},
          pending_halt: %{result: Result.cancelled(:x)}
        )

      plan = %{
        Step.plan(envelope, [completed(1, {:reply, 1})])
        | rest: [completed(2, {:reply, 2})]
      }

      commit = drain!(ScriptedLoop, envelope, plan)

      assert commit.op == :continue
    end

    test "cancel before the first step ever runs: init is skipped, the loop finishes cancelled" do
      plan = Step.plan(nil, [msg(1, %{"id" => "never"})], cancel: :gone)
      commit = drain!(ScriptedLoop, nil, plan)

      assert commit.op == :finish
      assert %Result.Cancelled{reason: :gone} = commit.result
      assert commit.terminal_sweep
      # init never ran: no state was ever created.
      assert commit.set.envelope.state == nil
      assert commit.consumed == []
    end

    test "a cascade folds a completion behind a backlog longer than the batch cap (review: no livelock)" do
      # Three queued messages sit ahead of the last child's completion,
      # with batch_cap 2. Positional batching would drain nothing forever;
      # completion-first batching folds it and finishes the cascade.
      envelope =
        scripted_envelope(
          children: %{key({:reply, 1}) => 901},
          pending_halt: %{result: Result.cancelled(:user_request)}
        )

      pending = [
        msg(1, %{"id" => "a"}),
        msg(2, %{"id" => "b"}),
        msg(3, %{"id" => "c"}),
        completed(4, {:reply, 1})
      ]

      plan = Step.plan(envelope, pending, batch_cap: 2)
      assert [%StoredInput{ref: 4}] = plan.batch

      commit = drain!(ScriptedLoop, envelope, plan)
      assert commit.op == :finish
      assert commit.terminal_sweep
      assert commit.consumed == [4]
      assert %Result.Cancelled{reason: :user_request} = commit.result
    end

    test "matrix row L2 (cancellability): an :incompatible_state loop still cascades — no load, no dump, no handle" do
      # Stored at version 1; VersionedLoop declares 2. A normal drain
      # refuses; the cascade proceeds.
      envelope = %Envelope{state_version: 1, state: %{"old" => true}, children: %{}}

      assert {:error, {:incompatible_state, %{state_version: 1, declared: 2}}} =
               Step.drain(VersionedLoop, envelope, Step.plan(envelope, []), @opts)

      plan = Step.plan(envelope, [], cancel: :operator)
      commit = drain!(VersionedLoop, envelope, plan)

      assert commit.op == :finish
      assert %Result.Cancelled{reason: :operator} = commit.result
      # The un-loadable state rides along untouched.
      assert commit.set.envelope.state == %{"old" => true}
      assert commit.set.state_version == 1
    end
  end

  describe "clean-failure paths" do
    test "matrix row L2 (state half): a stored state_version the code cannot load parks the step as :incompatible_state" do
      envelope = %Envelope{state_version: 2, state: %{}}

      assert {:error, {:incompatible_state, %{state_version: 2, declared: 1}}} =
               Step.drain(ScriptedLoop, envelope, Step.plan(envelope, []), @opts)
    end

    test "matrix row L2 (spec half): a module without the loop contract fails as :incompatible_spec" do
      assert {:error, {:incompatible_spec, %{reason: :not_a_loop}}} =
               Step.drain(String, nil, Step.plan(nil, []), @opts)
    end
  end

  describe "state doors" do
    test "dump/load doors round-trip non-JSON state through the envelope" do
      first = drain!(DoorLoop, nil, Step.plan(nil, [msg(1, %{"add" => "b"})]))
      assert first.set.envelope.state == %{"items" => ["l", ["b"]]}

      {:ok, envelope} = first.set.envelope |> Envelope.encode() |> Envelope.decode()
      plan = Step.plan(envelope, [msg(2, %{"add" => "a"})])
      second = drain!(DoorLoop, envelope, plan)

      assert second.set.envelope.state == %{"items" => ["l", ["a", "b"]]}
    end

    test "dump/1 returning a non-map raises toward the poison path" do
      assert_raise ArgumentError, ~r/dump\/1 must return a map/, fn ->
        Step.drain(BadDumpLoop, nil, Step.plan(nil, []), @opts)
      end
    end
  end
end
