defmodule Clementine.Loop.RunnerTest do
  use ExUnit.Case, async: true

  alias Clementine.{Error, InterruptReason, Result}
  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.Loop.{Codec, Envelope, Input, Runner}
  alias Clementine.Loop.Protocol, as: LoopProtocol
  alias Clementine.Test.MemoryLoopHost, as: Host
  alias Clementine.Test.ScriptedLoop

  defmodule PoisonEvidenceLoop do
    @moduledoc "Raises on poison payloads AND on the synthesized evidence — the recursion guard's worst case."
    use Clementine.Loop

    def init(_args), do: {:ok, %{"seen" => []}, []}
    def handle({:message, %{"boom" => true}}, _state), do: raise("poison payload")
    def handle({:input_failed, _ref, _error}, _state), do: raise("poison evidence poisons too")

    def handle({:message, payload}, state) do
      {:ok, Map.update!(state, "seen", &(&1 ++ [payload["id"]])), []}
    end
  end

  defmodule InitActionsLoop do
    @moduledoc "Init emits cargo — the synthetic `:init` causal ref's coverage."
    use Clementine.Loop, vocabulary: [:boot]

    def init(%{"target" => target}) do
      {:ok, %{}, [{:send, target, %{"hello" => true}}, {:timer, :boot, 60_000}]}
    end

    def handle(_input, state), do: {:ok, state, []}
  end

  defmodule DeciderLoop do
    @moduledoc "The thread-agent shape for L12: an interrupted child is an ordinary completion the parent decides on."
    use Clementine.Loop, vocabulary: [:work, :retry]

    def init(_args), do: {:ok, %{"decisions" => []}, []}

    def handle({:message, %{"spawn" => id}}, state) do
      {:ok, state, [{:run, {:work, id}, %{"id" => id}}]}
    end

    def handle({:completed, {:work, id}, %Result.Interrupted{}}, state) do
      state = Map.update!(state, "decisions", &(&1 ++ ["retry:#{id}"]))
      {:ok, state, [{:run, {:retry, id}, %{"id" => id}}]}
    end

    def handle({:completed, tag, _result}, state) do
      {:ok, Map.update!(state, "decisions", &(&1 ++ ["done:#{inspect(tag)}"])), []}
    end
  end

  defmodule FlagMidStep do
    @moduledoc """
    The strand interleaving: the cancel flag lands after the claim read
    it (nil) and before the commit — injected at the post-claim pending
    read, exactly where a concurrent `cancel/3` against a running row
    leaves only the flag (its wake no-ops on `running`).
    """

    alias Clementine.Test.MemoryLoopHost

    defdelegate load(ref, ctx), to: MemoryLoopHost
    defdelegate bump_attempts(refs, ctx), to: MemoryLoopHost
    defdelegate apply_step(commit, ctx), to: MemoryLoopHost
    defdelegate enqueue_step(ref, ctx), to: MemoryLoopHost

    def pending(loop_ref, limit, scope, store) do
      Agent.update(store, fn state ->
        put_in(
          state.runs[loop_ref].cancel,
          %{reason: :late_flag, requested_at: DateTime.utc_now()}
        )
      end)

      MemoryLoopHost.pending(loop_ref, limit, scope, store)
    end
  end

  defmodule RequeueMidStep do
    @moduledoc "A reaper requeue superseding the execution mid-step — the zombie-fence case."

    alias Clementine.Lifecycle.Protocol, as: LifecycleProtocol
    alias Clementine.Test.MemoryLoopHost

    defdelegate load(ref, ctx), to: MemoryLoopHost
    defdelegate bump_attempts(refs, ctx), to: MemoryLoopHost
    defdelegate apply_step(commit, ctx), to: MemoryLoopHost
    defdelegate enqueue_step(ref, ctx), to: MemoryLoopHost

    def pending(loop_ref, limit, scope, store) do
      {:ok, facts} = MemoryLoopHost.fetch(loop_ref, store)
      {:ok, _} = LifecycleProtocol.requeue(MemoryLoopHost, facts, :lease_expired, store)
      MemoryLoopHost.pending(loop_ref, limit, scope, store)
    end
  end

  defmodule FlagAfterLoad do
    @moduledoc """
    The incompatible park's racing-cancel window: the flag lands after
    the post-claim load read it as nil, before the park commits — where a
    concurrent `cancel/3` against a running row leaves only the flag. The
    fuse fires after the second load (the post-claim one) so the claim
    still reads a clean flag.
    """

    alias Clementine.Test.MemoryLoopHost

    defdelegate pending(ref, limit, scope, ctx), to: MemoryLoopHost
    defdelegate bump_attempts(refs, ctx), to: MemoryLoopHost
    defdelegate apply_step(commit, ctx), to: MemoryLoopHost
    defdelegate enqueue_step(ref, ctx), to: MemoryLoopHost

    def arm, do: Process.put({__MODULE__, :fuse}, 2)

    def load(loop_ref, store) do
      result = MemoryLoopHost.load(loop_ref, store)

      case Process.get({__MODULE__, :fuse}) do
        1 ->
          Process.delete({__MODULE__, :fuse})

          Agent.update(store, fn state ->
            put_in(
              state.runs[loop_ref].cancel,
              %{reason: :mid_park, requested_at: DateTime.utc_now()}
            )
          end)

        n when is_integer(n) ->
          Process.put({__MODULE__, :fuse}, n - 1)

        nil ->
          :ok
      end

      result
    end
  end

  setup do
    {:ok, store: Host.start_store()}
  end

  defp create!(store, module, opts \\ []) do
    scope = Keyword.get(opts, :scope, "loop:#{System.unique_integer([:positive])}")

    {:ok, %Facts{ref: ref}} =
      LoopProtocol.create(
        Host,
        %{
          module: module,
          scope: scope,
          args: Keyword.get(opts, :args, %{}),
          policy: Keyword.get(opts, :policy, %{})
        },
        ctx: store
      )

    ref
  end

  defp step!(store, ref, host \\ Host) do
    Runner.step(ref, host: host, lifecycle: Host, executor_id: "test-runner", ctx: store)
  end

  defp append!(store, ref, payload, opts \\ []) do
    {:ok, :appended} = Host.append(ref, Input.message(payload), opts[:dedup_key], store)
    :ok
  end

  defp envelope!(store, ref) do
    {:ok, %{envelope: data}} = Host.load(ref, store)
    {:ok, envelope} = Envelope.decode(data)
    envelope
  end

  # Envelope state persists codec-encoded; the string-only test states
  # need no vocabulary to decode.
  defp state!(store, ref) do
    case envelope!(store, ref).state do
      nil -> nil
      state -> Codec.decode(state, vocabulary: [])
    end
  end

  defp pending_rows(store, ref) do
    store |> Host.inbox!(ref) |> Enum.filter(&is_nil(&1.dead_reason))
  end

  describe "creation and the first step" do
    test "create is insert-or-get on the scope key; init runs in the first step, not at create",
         %{
           store: store
         } do
      spec = %{module: ScriptedLoop, scope: "conversation:42", args: %{}, policy: %{}}

      {:ok, %Facts{ref: ref, kind: :loop, status: :queued}} =
        LoopProtocol.create(Host, spec, ctx: store)

      {:ok, :already_exists, %Facts{ref: ^ref}} = LoopProtocol.create(Host, spec, ctx: store)

      # No envelope exists until the first step commits init's fold.
      {:ok, %{envelope: nil}} = Host.load(ref, store)

      assert {:parked, %Facts{status: :waiting}} = step!(store, ref)
      assert state!(store, ref) == %{"log" => ["init"]}
    end

    test "init's actions dispatch as first-commit cargo under the synthetic :init causal ref", %{
      store: store
    } do
      target = create!(store, ScriptedLoop)
      ref = create!(store, InitActionsLoop, args: %{"target" => target})

      assert {:parked, _} = step!(store, ref)

      # The send landed in the target's inbox with the replay-stable
      # causally-derived key — causal segment "init", action index 1... 0.
      assert [%{input: %Input{kind: :message, payload: %{"hello" => true}}, dedup_key: dedup}] =
               pending_rows(store, target)

      assert dedup =~ ~r/^send:.*:init:0$/

      # The timer is armed in the same commit: envelope entry + job.
      assert map_size(envelope!(store, ref).timers) == 1
      assert Enum.any?(Host.jobs!(store), &(&1.kind == "timer" and &1.run_ref == ref))
    end

    test "a queued backlog continues (job re-enqueued in-unit) until drained, then parks", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop, policy: %{"batch_cap" => 1})
      append!(store, ref, %{"id" => "a"})
      append!(store, ref, %{"id" => "b"})

      assert {:continued, %Facts{status: :queued}} = step!(store, ref)
      assert {:parked, %Facts{status: :waiting}} = step!(store, ref)
      assert state!(store, ref) == %{"log" => ["init", "message:a", "message:b"]}
      assert pending_rows(store, ref) == []
    end
  end

  describe "the outcome union's discards" do
    test "a lost claim race, a vanished row, and a rollout-kind ref all discard", %{store: store} do
      ref = create!(store, ScriptedLoop)
      {:ok, _lease} = Protocol.claim(Host, ref, executor: "rival", ctx: store)
      assert {:discard, {:not_claimable, :running}} = step!(store, ref)

      assert {:discard, :not_found} = step!(store, 999_999)

      rollout_ref = Host.seed(store, kind: :rollout)
      assert {:discard, :rollout_run} = step!(store, rollout_ref)
    end
  end

  describe "matrix row L1" do
    test "matrix row L1: step crashes before commit — identical replay, no duplicate children, sends, or timers",
         %{store: store} do
      target = create!(store, ScriptedLoop)
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      append!(store, ref, %{
        "id" => "x",
        "actions" => [
          {:run, {:reply, 1}, %{"id" => 1}},
          {:send, target, %{"note" => true}},
          {:timer, {:retry, 1}, 60_000}
        ]
      })

      # The crash lands after the drain, before the commit: nothing
      # durable exists except the head's attempts bump.
      Host.inject_fault(store, :raise, 1)
      assert {:error, %Error{}} = step!(store, ref)

      # Never terminal `finish(failed)` — the loop analog of two-tier
      # failure: requeued, step job re-enqueued, bump committed.
      facts = Host.facts!(store, ref)
      assert facts.status == :queued
      refute Facts.terminal?(facts)
      assert [%{attempts: 1}] = pending_rows(store, ref)

      # The replay drains the identical input to one identical commit.
      assert {:parked, _} = step!(store, ref)

      children = envelope!(store, ref).children
      assert map_size(children) == 1
      assert [_one_child_job] = Enum.filter(Host.jobs!(store), &(&1.kind == "child"))
      assert [%{dedup_key: dedup}] = pending_rows(store, target)

      assert [_one_timer_job] =
               Enum.filter(Host.jobs!(store), &(&1.kind == "timer" and &1.run_ref == ref))

      assert dedup =~ ~r/^send:/
      assert state!(store, ref)["log"] == ["init", "message:x"]
    end
  end

  describe "matrix row L2" do
    test "matrix row L2: deploy during a weeks-long park — :incompatible_state parks visibly, never a crash, and never dead-letters",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      append!(store, ref, %{"id" => "before"})
      assert {:parked, _} = step!(store, ref)

      # The deploy: the same spec now names a loop declaring state_version 2.
      Host.rewrite_module!(store, ref, "Clementine.Test.VersionedLoop")
      append!(store, ref, %{"id" => "after"})

      assert {:parked, %Facts{} = facts} = step!(store, ref)

      assert facts.suspension.reason ==
               {:external, {:incompatible_state, %{state_version: 1, declared: 2}}}

      # Inputs are innocent of deploys: pending, un-bumped, un-marked —
      # the version check runs before the attempts bump.
      assert [%{attempts: 0, dead_reason: nil}] = pending_rows(store, ref)

      # The upgrade deploy: compatible code returns; a fresh append wakes
      # the loop and the park was never a grave.
      Host.rewrite_module!(store, ref, "Clementine.Test.ScriptedLoop")
      append!(store, ref, %{"id" => "healed"})
      assert {:parked, %Facts{suspension: %{reason: {:external, :loop}}}} = step!(store, ref)

      assert state!(store, ref)["log"] == [
               "init",
               "message:before",
               "message:after",
               "message:healed"
             ]
    end

    test "matrix row L2 (spec half): a renamed loop_module parks as :incompatible_spec until the name returns",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      Host.rewrite_module!(store, ref, "Meli.Gone.Agent")
      append!(store, ref, %{"id" => "orphaned"})

      assert {:parked, %Facts{} = facts} = step!(store, ref)
      assert {:external, {:incompatible_spec, %{reason: :not_a_loop}}} = facts.suspension.reason
      assert [%{attempts: 0}] = pending_rows(store, ref)

      Host.rewrite_module!(store, ref, "Clementine.Test.ScriptedLoop")
      append!(store, ref, %{"id" => "restored"})
      assert {:parked, _} = step!(store, ref)
      assert state!(store, ref)["log"] == ["init", "message:orphaned", "message:restored"]
    end
  end

  describe "matrix row L7" do
    test "matrix row L7: poison input — bump counted through the crash, batch-1 degrade, dead-letter at K, {:input_failed} informs the loop, innocents never dead-letter",
         %{store: store} do
      ref = create!(store, ScriptedLoop, policy: %{"dead_letter_after" => 2})
      assert {:parked, _} = step!(store, ref)

      # ScriptedLoop raises on this payload via its halt_failed? No — use
      # the raise the runner rescues: an undecodable row is the same
      # deterministic in-step failure with the same attempts path.
      append!(store, ref, %{"id" => "poison"})
      append!(store, ref, %{"id" => "innocent"})
      [poison_row, _innocent_row] = pending_rows(store, ref)

      Host.inject_decode_error(store, poison_row.ref, %Error{
        code: :undecodable,
        message: "vocabulary shrank"
      })

      # Step 1: full batch planned, head bumped, failure counted anyway.
      assert {:error, %Error{}} = step!(store, ref)
      assert [%{attempts: 1}, %{attempts: 0}] = pending_rows(store, ref)

      # Step 2: degraded to batch-1 (a bumped, unconsumed head is the
      # evidence of a failed step) — the innocent accumulates nothing.
      assert {:error, %Error{}} = step!(store, ref)
      assert [%{attempts: 2}, %{attempts: 0}] = pending_rows(store, ref)

      # Step 3: head at K — dead-lettered as :poison with the synthesized
      # {:input_failed} appended in the same commit; backlog continues.
      assert {:continued, _} = step!(store, ref)

      assert [%{dead_reason: :poison}] =
               store |> Host.inbox!(ref) |> Enum.filter(&(&1.ref == poison_row.ref))

      # Step 4: the decision layer is informed and the innocent drains —
      # the mailbox never jammed.
      assert {:parked, _} = step!(store, ref)
      log = state!(store, ref)["log"]
      assert "input_failed:input_dead_lettered" in log
      assert "message:innocent" in log
      assert pending_rows(store, ref) == []
    end

    test "matrix row L7 (recursion guard): poison {:input_failed} evidence dead-letters without re-synthesizing",
         %{store: store} do
      ref = create!(store, PoisonEvidenceLoop, policy: %{"dead_letter_after" => 1})
      assert {:parked, _} = step!(store, ref)

      append!(store, ref, %{"boom" => true})

      # One raise burns the threshold; the poison dead-letters and the
      # evidence is synthesized once.
      assert {:error, %Error{}} = step!(store, ref)
      assert {:continued, _} = step!(store, ref)

      assert [%{input: %Input{kind: :input_failed}, attempts: 0}] = pending_rows(store, ref)

      # The evidence itself poisons this loop's handle — it walks the
      # same threshold and dead-letters WITHOUT recursing into more
      # evidence: the mailbox drains to silence, the loop survives.
      assert {:error, %Error{}} = step!(store, ref)
      assert {:parked, _} = step!(store, ref)

      assert pending_rows(store, ref) == []

      dead = store |> Host.inbox!(ref) |> Enum.map(& &1.dead_reason)
      assert dead == [:poison, :poison]
      refute Facts.terminal?(Host.facts!(store, ref))
    end
  end

  describe "matrix row L8" do
    test "matrix row L8: loop cancelled with children in flight — children terminal first, loop terminal last, sweep leaves nothing behind",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      append!(store, ref, %{"id" => "work", "actions" => [{:run, {:reply, 7}, %{"id" => 7}}]})
      assert {:parked, _} = step!(store, ref)
      [child_ref] = Map.values(envelope!(store, ref).children)
      assert %Facts{status: :queued} = Host.facts!(store, child_ref)

      # The operator says stop; a straggler message is already queued
      # behind the cancel — it must never reach handle/2.
      append!(store, ref, %{"id" => "straggler"})
      assert {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :operator_stop, ctx: store)

      # The flag woke the parked loop: queued, job enqueued, flag durable.
      facts = Host.facts!(store, ref)
      assert facts.status == :queued
      assert facts.cancel.reason == :operator_stop

      # Cascade step: the machinery — not handle/2 — cancels the queued
      # child as cargo; its terminal projection appends the completion in
      # the same unit, and the park re-check sees it: continue, not park.
      assert {:continued, _} = step!(store, ref)
      assert %Facts{status: :cancelled} = Host.facts!(store, child_ref)
      refute Facts.terminal?(Host.facts!(store, ref))

      # Final step: the completion folds (no handle/2), children empties,
      # the loop finishes cancelled with the terminal sweep in-unit.
      assert {:finished, %Facts{status: :cancelled, cancel: nil}} = step!(store, ref)

      # Children terminal first, loop terminal last — projection order.
      assert [
               {^child_ref, %Result.Cancelled{reason: {:loop_cascade, ^ref}}},
               {^ref, %Result.Cancelled{reason: :operator_stop}}
             ] =
               Host.projections(store)

      # The straggler was swept, never handled, never silently retained.
      straggler = store |> Host.inbox!(ref) |> Enum.find(&(&1.input.payload["id"] == "straggler"))
      assert straggler.dead_reason == :terminal_sweep
      refute "message:straggler" in (state!(store, ref)["log"] || [])
      assert pending_rows(store, ref) == []
    end

    test "matrix row L8 (running child): the cascade parks on a cooperative child and stays parked — the flag does not spin a cascade park",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)
      append!(store, ref, %{"id" => "w", "actions" => [{:run, {:reply, 9}, %{}}]})
      assert {:parked, _} = step!(store, ref)

      [child_ref] = Map.values(envelope!(store, ref).children)
      {:ok, child_lease} = Protocol.claim(Host, child_ref, executor: "child-worker", ctx: store)

      assert {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :stop, ctx: store)

      # The cascade flags the running child cooperatively and parks
      # awaiting its completion; the set cancel flag must NOT downgrade a
      # cascade park (the cascade IS the flag's handler).
      assert {:parked, %Facts{status: :waiting, cancel: %{reason: :stop}}} = step!(store, ref)

      assert %Facts{status: :running, cancel: %{reason: {:loop_cascade, ^ref}}} =
               Host.facts!(store, child_ref)

      # The child honors its flag and finishes; its terminal projection
      # delivers the completion and wakes the parent (exactly-once at
      # source), and the cascade completes.
      {:ok, _} = Protocol.finish(child_lease, Result.cancelled({:loop_cascade, ref}))
      assert %Facts{status: :queued} = Host.facts!(store, ref)
      assert {:finished, %Facts{status: :cancelled}} = step!(store, ref)
    end
  end

  describe "matrix row L9" do
    test "matrix row L9: halt with children in flight and inputs behind the halt — drained to terminals, leftovers dead-lettered with reasons",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)
      append!(store, ref, %{"id" => "w", "actions" => [{:run, {:reply, 3}, %{}}]})
      assert {:parked, _} = step!(store, ref)

      # The halt arrives with a child live and a message queued behind it.
      append!(store, ref, %{"halt" => "all done"})
      append!(store, ref, %{"id" => "too-late"})

      # The halt enters the cascade: child cancelled as cargo, completion
      # arrives in-unit, pending result held in the envelope.
      assert {:continued, _} = step!(store, ref)

      assert %{pending_halt: %{result: %Result.Completed{output: "all done"}}} =
               envelope!(store, ref)

      # The cascade finishes with the HALT's result — not cancelled — and
      # the terminal sweep dead-letters the leftover, never silently.
      assert {:finished, %Facts{status: :completed}} = step!(store, ref)

      assert {^ref, %Result.Completed{output: "all done", messages: [], input_message: nil}} =
               store |> Host.projections() |> List.last()

      late = store |> Host.inbox!(ref) |> Enum.find(&(&1.input.payload["id"] == "too-late"))
      assert late.dead_reason == :terminal_sweep
    end

    test "first cause wins: a cancel landing mid-halt-cascade does not replace the halt's result",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)
      append!(store, ref, %{"id" => "w", "actions" => [{:run, {:reply, 5}, %{}}]})
      assert {:parked, _} = step!(store, ref)

      [child_ref] = Map.values(envelope!(store, ref).children)
      {:ok, child_lease} = Protocol.claim(Host, child_ref, executor: "child-worker", ctx: store)

      # Halt while the child runs: cascade parks holding the halt result.
      append!(store, ref, %{"halt" => "shipped"})
      assert {:parked, _} = step!(store, ref)

      # The cancel arrives mid-cascade; the flag wakes the loop but the
      # halt stays the pending result — first cause wins.
      assert {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :too_late, ctx: store)
      assert {:parked, _} = step!(store, ref)

      {:ok, _} = Protocol.finish(child_lease, Result.cancelled({:loop_cascade, ref}))
      assert {:finished, %Facts{status: :completed}} = step!(store, ref)

      assert {^ref, %Result.Completed{output: "shipped"}} =
               store |> Host.projections() |> List.last()
    end
  end

  describe "matrix row L12" do
    test "matrix row L12: child interrupted by pod death — the completion arrives exactly once and the parent decides",
         %{store: store} do
      ref = create!(store, DeciderLoop)
      assert {:parked, _} = step!(store, ref)
      append!(store, ref, %{"spawn" => 1})
      assert {:parked, _} = step!(store, ref)

      [child_ref] = Map.values(envelope!(store, ref).children)

      # The pod dies mid-child-run; the reaper interrupts on stale
      # evidence. The interrupt is a terminal transition with a
      # projection — the identical delivery path as a finish.
      {:ok, _lease} = Protocol.claim(Host, child_ref, executor: "doomed-pod", ctx: store)
      child_facts = Host.facts!(store, child_ref)

      {:ok, _} =
        Protocol.interrupt(
          Host,
          child_facts,
          InterruptReason.new(:lease_expired, "pod died"),
          store
        )

      # Exactly-once at source: the dead-end terminal cannot fire again.
      assert {:error, :already_terminal} =
               Protocol.interrupt(
                 Host,
                 Host.facts!(store, child_ref),
                 InterruptReason.new(:lease_expired),
                 store
               )

      completions =
        store |> Host.inbox!(ref) |> Enum.filter(&(&1.input.kind == :completed))

      assert [%{dedup_key: "completed:" <> _}] = completions

      # The parent was woken and DECIDES: an interrupted turn gets a
      # retry child — `handle/2` saw an ordinary completion input.
      assert %Facts{status: :queued} = Host.facts!(store, ref)
      assert {:parked, _} = step!(store, ref)

      assert state!(store, ref)["decisions"] == ["retry:1"]
      assert map_size(envelope!(store, ref).children) == 1
    end
  end

  describe "matrix row L16" do
    test "matrix row L16: a 1000-step loop crashes once — requeued with no epoch cap; longevity is not a death sentence",
         %{store: store} do
      veteran_envelope =
        Envelope.encode(%Envelope{
          state_version: 1,
          state: Codec.encode(%{"log" => ["init"]}),
          usage: %Clementine.Usage{}
        })

      ref =
        Host.seed(
          store,
          [epoch: 1000],
          %{module: "Clementine.Test.ScriptedLoop", envelope: veteran_envelope}
        )

      append!(store, ref, %{"id" => "steady"})

      Host.inject_fault(store, :raise, 1)
      assert {:error, %Error{}} = step!(store, ref)

      # A rollout at epoch 1000 would be long dead of max_claims; the
      # loop's epoch is execution identity, not an attempt budget.
      facts = Host.facts!(store, ref)
      assert facts.status == :queued
      assert facts.epoch == 1001
      refute Facts.terminal?(facts)

      assert {:parked, %Facts{epoch: 1002}} = step!(store, ref)
      assert state!(store, ref)["log"] == ["init", "message:steady"]
    end
  end

  describe "the send verb (Loop.Protocol.send/4)" do
    test "sugar over append: the payload arrives as {:message, payload}, the caller's key dedups, the wake rides the unit",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      assert {:ok, :appended} =
               LoopProtocol.send(Host, ref, %{"id" => "hi"}, dedup_key: "wh:1", ctx: store)

      assert Host.facts!(store, ref).status == :queued

      assert {:ok, :duplicate} =
               LoopProtocol.send(Host, ref, %{"id" => "hi"}, dedup_key: "wh:1", ctx: store)

      # No key, no dedup — the default for callers without an idempotency
      # source of their own.
      assert {:ok, :appended} = LoopProtocol.send(Host, ref, %{"id" => "hi"}, ctx: store)

      assert {:parked, _} = step!(store, ref)
      assert state!(store, ref)["log"] == ["init", "message:hi", "message:hi"]
    end

    test "terminal targets answer :dead_lettered; miswired and unknown refs are refused", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop)
      append!(store, ref, %{"halt" => "done"})
      assert {:finished, _} = step!(store, ref)

      # The sender is TOLD — retained evidence it can react to (L10), and
      # a transport's retry is a duplicate of that evidence.
      assert {:ok, :dead_lettered} =
               LoopProtocol.send(Host, ref, %{"id" => "late"}, dedup_key: "l:1", ctx: store)

      assert {:ok, :duplicate} =
               LoopProtocol.send(Host, ref, %{"id" => "late"}, dedup_key: "l:1", ctx: store)

      rollout_ref = Host.seed(store, kind: :rollout)
      assert {:error, :rollout_run} = LoopProtocol.send(Host, rollout_ref, %{}, ctx: store)
      assert {:error, :not_found} = LoopProtocol.send(Host, 424_242, %{}, ctx: store)
    end
  end

  describe "cancellation races and short-circuits" do
    test "a cancel flag landing mid-step downgrades the park in-unit — the cancellation is never stranded",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)
      append!(store, ref, %{"id" => "w"})

      # The step read cancel: nil at claim, drained normally, intended to
      # park — but the in-unit re-check saw the flag: continue, job, and
      # the next claim enters the cascade.
      assert {:continued, %Facts{status: :queued}} = step!(store, ref, FlagMidStep)
      assert {:finished, %Facts{status: :cancelled}} = step!(store, ref)

      assert {_, %Result.Cancelled{reason: :late_flag}} =
               store |> Host.projections() |> List.last()
    end

    test "cancelling a loop that never stepped short-circuits its queued inputs", %{store: store} do
      ref = create!(store, ScriptedLoop)
      append!(store, ref, %{"id" => "a"})
      append!(store, ref, %{"id" => "b"})
      append!(store, ref, %{"id" => "c"})

      assert {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :never_mind, ctx: store)
      assert {:finished, %Facts{status: :cancelled}} = step!(store, ref)

      # handle/2 never ran — no envelope state, three sweeps, evidence retained.
      assert envelope!(store, ref).state == nil

      assert store |> Host.inbox!(ref) |> Enum.map(& &1.dead_reason) ==
               [:terminal_sweep, :terminal_sweep, :terminal_sweep]
    end

    test "cancel is idempotent and first-cause-wins; terminal and rollout-kind refs are refused",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :first, ctx: store)
      assert {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :second, ctx: store)
      assert Host.facts!(store, ref).cancel.reason == :first

      assert {:finished, _} = step!(store, ref)
      assert {:error, :already_terminal} = LoopProtocol.cancel(Host, ref, :again, ctx: store)

      rollout_ref = Host.seed(store, kind: :rollout)
      assert {:error, :rollout_run} = LoopProtocol.cancel(Host, rollout_ref, :nope, ctx: store)
      assert {:error, :not_found} = LoopProtocol.cancel(Host, 424_242, :ghost, ctx: store)
    end

    test "a cascade absorbs completions parked behind a backlog longer than the batch window",
         %{store: store} do
      ref = create!(store, ScriptedLoop, policy: %{"batch_cap" => 2})
      assert {:parked, _} = step!(store, ref)
      append!(store, ref, %{"id" => "w", "actions" => [{:run, {:reply, 1}, %{}}]})
      assert {:parked, _} = step!(store, ref)

      # A backlog longer than the window queues ahead of where the
      # child's completion will land.
      for i <- 1..4, do: append!(store, ref, %{"id" => "backlog-#{i}"})

      assert {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :stop, ctx: store)

      # Cascade step: the queued child terminalizes in-unit, its
      # completion appending BEHIND the backlog; the re-check sees it.
      assert {:continued, _} = step!(store, ref)

      # The completions-scoped read surfaces it past the skipped backlog:
      # this step finishes — it must not park-and-rewake forever.
      assert {:finished, %Facts{status: :cancelled}} = step!(store, ref)
      assert Enum.all?(Host.inbox!(store, ref), &(&1.dead_reason == :terminal_sweep))
    end

    test "a cancel racing an :incompatible_state park wakes it into the cascade — never stranded",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      append!(store, ref, %{"id" => "w"})
      assert {:parked, _} = step!(store, ref)

      Host.rewrite_module!(store, ref, "Clementine.Test.VersionedLoop")
      append!(store, ref, %{"id" => "stuck"})

      # The flag lands after the post-claim load read it as nil and
      # before the incompatible park commits — its wake no-oped against
      # the running row, and this park bypasses the host's re-check.
      FlagAfterLoad.arm()
      assert {:continued, %Facts{status: :queued}} = step!(store, ref, FlagAfterLoad)

      # The woken step cascades (never loads state) and finishes.
      assert {:finished, %Facts{status: :cancelled}} = step!(store, ref)
      assert store |> Host.inbox!(ref) |> Enum.all?(&(&1.dead_reason == :terminal_sweep))
    end

    test "a cancel racing an :incompatible_spec park stays parked — waking a loop the cascade cannot run would spin",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      Host.rewrite_module!(store, ref, "Meli.Gone.Agent")
      append!(store, ref, %{"id" => "x"})

      FlagAfterLoad.arm()
      assert {:parked, %Facts{cancel: %{reason: :mid_park}}} = step!(store, ref, FlagAfterLoad)

      # Durable flag, no spin — and the documented remedy works: after
      # the healing deploy, a re-cancel wakes the loop and the cascade
      # finishes under the first cause.
      Host.rewrite_module!(store, ref, "Clementine.Test.ScriptedLoop")
      assert {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :again, ctx: store)
      assert {:finished, %Facts{status: :cancelled}} = step!(store, ref)

      assert {_, %Result.Cancelled{reason: :mid_park}} =
               store |> Host.projections() |> List.last()
    end

    test "an :incompatible_state loop is still cancellable — the cascade never loads state", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop)
      append!(store, ref, %{"id" => "w"})
      assert {:parked, _} = step!(store, ref)

      Host.rewrite_module!(store, ref, "Clementine.Test.VersionedLoop")
      append!(store, ref, %{"id" => "stuck"})

      assert {:parked, %Facts{suspension: %{reason: {:external, {:incompatible_state, _}}}}} =
               step!(store, ref)

      assert {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :give_up, ctx: store)
      assert {:finished, %Facts{status: :cancelled}} = step!(store, ref)

      assert store |> Host.inbox!(ref) |> Enum.map(& &1.dead_reason) == [:terminal_sweep]
    end
  end

  describe "commit failure postures" do
    test "transient apply_step errors retry inside the step; a committed park needs one commit",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      Host.inject_fault(store, :error, 2)
      assert {:parked, _} = step!(store, ref)
    end

    test "exhausted apply_step retries leave the run running — the reaper's story (A3a), not a terminal",
         %{store: store} do
      ref = create!(store, ScriptedLoop)

      # One per in-step attempt: the bounded retry exhausts, no more.
      Host.inject_fault(store, :error, 3)

      assert {:error, :storage_down} = step!(store, ref)

      facts = Host.facts!(store, ref)
      assert facts.status == :running
      refute Facts.terminal?(facts)

      # The reaper requeues loop-kind stale running unconditionally; the
      # replayed step commits identically once storage heals.
      {:ok, _} = Protocol.requeue(Host, facts, :lease_expired, store)
      assert {:parked, _} = step!(store, ref)
    end

    test "a reaper requeue racing the commit fences it: stale apply_step discards as lost lease",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:discard, :lost_lease} = step!(store, ref, RequeueMidStep)
      assert Host.facts!(store, ref).status == :queued
    end
  end

  describe "post-commit telemetry" do
    test "step and step_failed events fire post-commit with committed-facts outcomes", %{
      store: store
    } do
      handler = :"runner-telemetry-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach_many(
        handler,
        [[:clementine, :loop, :step], [:clementine, :loop, :step_failed]],
        fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      assert_receive {[:clementine, :loop, :step], %{duration: duration},
                      %{outcome: :parked, mode: :normal, batch: 0, loop_ref: ^ref, epoch: 1}}

      assert duration >= 0

      append!(store, ref, %{"id" => "x"})
      Host.inject_fault(store, :raise, 1)
      assert {:error, _} = step!(store, ref)

      assert_receive {[:clementine, :loop, :step_failed], %{},
                      %{loop_ref: ^ref, epoch: 2, requeued: true, error: %Error{}}}

      # The failed step's commit never happened: no :step event for epoch 2.
      refute_receive {[:clementine, :loop, :step], _, %{loop_ref: ^ref, epoch: 2}}, 10
    end
  end
end
