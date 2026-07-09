defmodule Clementine.Loop.ReportTest do
  use ExUnit.Case, async: true

  alias Clementine.Lifecycle.Facts
  alias Clementine.Loop
  alias Clementine.Loop.{Codec, Input, Report, Runner, StoredInput}
  alias Clementine.Loop.Protocol, as: LoopProtocol
  alias Clementine.Result
  alias Clementine.Test.MemoryLoopHost, as: Host
  alias Clementine.Test.ScriptedLoop

  setup do
    {:ok, store: Host.start_store()}
  end

  defp create!(store, module, opts \\ []) do
    scope = Keyword.get(opts, :scope, "loop:#{System.unique_integer([:positive])}")

    {:ok, %Facts{ref: ref}} =
      LoopProtocol.create(
        Host,
        %{module: module, scope: scope, args: %{}, policy: %{}},
        ctx: store
      )

    ref
  end

  defp step!(store, ref) do
    Runner.step(ref, host: Host, lifecycle: Host, executor_id: "test-runner", ctx: store)
  end

  defp inspect!(store, ref, opts \\ []) do
    {:ok, %Report{} = report} =
      Loop.inspect(Host, ref, Keyword.merge([lifecycle: Host, ctx: store], opts))

    report
  end

  # Strand shapes need states the honest verbs make unreachable (that
  # unreachability is the point), so tests forge them directly in the
  # store — exactly what a lost wake or lost glue write leaves behind.
  defp forge_row!(store, loop_ref, %Input{} = input, opts \\ []) do
    Agent.update(store, fn state ->
      row = %{
        ref: Keyword.get(opts, :ref, System.unique_integer([:positive]) + 10_000),
        input: input,
        dedup_key: Keyword.get(opts, :dedup_key),
        attempts: Keyword.get(opts, :attempts, 0),
        inserted_at: Keyword.get(opts, :inserted_at, DateTime.utc_now()),
        dead_at: nil,
        dead_reason: nil,
        decode_error: Keyword.get(opts, :decode_error)
      }

      update_in(state.inbox[loop_ref], &[row | &1 || []])
    end)
  end

  describe "the report" do
    test "gathers facts, spec, envelope, children with statuses, timers, and pending", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      {:ok, :appended} =
        Host.append(
          ref,
          Input.message(%{
            "id" => "work",
            "actions" => [{:run, {:reply, 7}, %{"n" => 7}}, {:timer, :poll, 60_000}]
          }),
          nil,
          store
        )

      assert {:parked, _} = step!(store, ref)

      report = inspect!(store, ref)

      assert %Facts{status: :waiting, epoch: 2} = report.facts
      assert {:ok, ScriptedLoop} = report.module
      assert report.state_version == %{stored: 1, declared: 1}
      assert [%{tag: {:ok, {:reply, 7}}, status: :queued, ref: child_ref}] = report.children
      assert child_ref != nil
      assert [%{tag: {:ok, :poll}, meta: %{"tag_key" => _}}] = report.timers
      assert report.pending == []
      assert report.dead_letters == []
      assert report.strands == []
    end

    test "children report :unknown without a :lifecycle, and stranding is not guessed", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      {:ok, :appended} =
        Host.append(
          ref,
          Input.message(%{"id" => "w", "actions" => [{:run, {:reply, 1}, %{}}]}),
          nil,
          store
        )

      assert {:parked, _} = step!(store, ref)

      report = inspect!(store, ref, lifecycle: nil)
      assert [%{status: :unknown}] = report.children
      assert report.strands == []
    end

    test "pending inputs carry ages; a terminal loop shows its swept dead letters", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop)

      {:ok, :appended} = Host.append(ref, Input.message(%{"id" => "a"}), nil, store)
      {:ok, :appended} = Host.append(ref, Input.message(%{"id" => "b"}), nil, store)
      {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :tester, ctx: store)

      assert {:finished, %Facts{status: :cancelled}} = step!(store, ref)

      report = inspect!(store, ref)
      assert report.pending == []

      assert [%StoredInput{dead_reason: :terminal_sweep, dead_at: %DateTime{}}, _second] =
               report.dead_letters

      assert report.strands == []
    end

    test "errors pass through from load", %{store: store} do
      assert {:error, :not_found} = Loop.inspect(Host, 999_999, ctx: store)

      rollout = Host.seed(store, kind: :rollout)
      assert {:error, :rollout_run} = Loop.inspect(Host, rollout, ctx: store)
    end
  end

  describe "strand classes (LOOP_RFC failure matrix)" do
    test "L2: a renamed loop_module diagnoses :incompatible_spec", %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      Host.rewrite_module!(store, ref, "Meli.Gone.Agent")

      report = inspect!(store, ref)
      assert {:error, {:incompatible_spec, _}} = report.module
      assert [%{class: :incompatible_spec, detail: %{reason: :not_a_loop}}] = report.strands
    end

    test "L2: a stored state_version the code no longer declares diagnoses :incompatible_state",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      Host.rewrite_module!(store, ref, "Clementine.Test.VersionedLoop")

      report = inspect!(store, ref)
      assert report.state_version == %{stored: 1, declared: 2}

      assert [%{class: :incompatible_state, detail: %{state_version: 1, declared: 2}}] =
               report.strands
    end

    test "L2: an undecodable envelope diagnoses :incompatible_state", %{store: store} do
      ref = Host.seed(store, [status: :waiting], %{envelope: %{"v" => 99}})

      report = inspect!(store, ref)
      assert {:error, {:incompatible_state, _}} = report.envelope
      assert Enum.any?(report.strands, &(&1.class == :incompatible_state))
    end

    test "L4: a waiting loop with a consumable pending input diagnoses :parked_with_pending", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      forge_row!(store, ref, Input.message(%{"id" => "lost-wake"}),
        inserted_at: DateTime.add(DateTime.utc_now(), -42, :second)
      )

      report = inspect!(store, ref)

      assert [%{class: :parked_with_pending, detail: %{pending: 1, oldest_age_ms: age}}] =
               report.strands

      assert age >= 42_000
    end

    test "L8: a waiting loop with the cancel flag and no cascade diagnoses :parked_with_cancel",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      Agent.update(store, fn state ->
        put_in(state.runs[ref].cancel, %{reason: :lost_wake, requested_at: DateTime.utc_now()})
      end)

      report = inspect!(store, ref)
      assert [%{class: :parked_with_cancel, detail: %{reason: :lost_wake}}] = report.strands
    end

    test "mid-cascade, non-completion backlog is legitimate; a pending completion strands", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      {:ok, :appended} =
        Host.append(
          ref,
          Input.message(%{"id" => "w", "actions" => [{:run, {:reply, 1}, %{}}]}),
          nil,
          store
        )

      assert {:parked, _} = step!(store, ref)
      {:ok, child} = LoopProtocol.child_ref(Host, ref, {:reply, 1}, ctx: store)

      # A running child only gets the cooperative flag, so the cascade
      # parks waiting for its completion.
      {:ok, _lease} = Clementine.Lifecycle.Protocol.claim(Host, child, executor: "w", ctx: store)
      {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :tester, ctx: store)
      assert {:parked, _} = step!(store, ref)

      forge_row!(store, ref, Input.message(%{"id" => "backlog"}))
      report = inspect!(store, ref)
      assert %{pending_halt: %{result: %Result.Cancelled{}}} = report.envelope
      assert report.strands == []

      forge_row!(store, ref, Input.completed({:reply, 99}, Result.completed(output: "lost")))
      report = inspect!(store, ref)
      assert [%{class: :parked_with_pending, detail: %{pending: 1}}] = report.strands
    end

    test "L13: a terminal child with no completion row diagnoses :stranded_completion", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      {:ok, :appended} =
        Host.append(
          ref,
          Input.message(%{"id" => "w", "actions" => [{:run, {:reply, 1}, %{}}]}),
          nil,
          store
        )

      assert {:parked, _} = step!(store, ref)
      {:ok, child} = LoopProtocol.child_ref(Host, ref, {:reply, 1}, ctx: store)

      # Terminalize the child row directly — the lost-glue simulation: no
      # projection ran, so no completion was appended.
      Agent.update(store, fn state ->
        update_in(state.runs[child], &%{&1 | status: :completed})
      end)

      report = inspect!(store, ref)

      assert [
               %{
                 class: :stranded_completion,
                 detail: %{child_ref: ^child, child_status: :completed}
               }
             ] =
               report.strands

      # The completion arriving (however late) clears the diagnosis.
      forge_row!(store, ref, Input.completed({:reply, 1}, Result.completed(output: "ok")))
      assert inspect!(store, ref).strands |> Enum.map(& &1.class) == [:parked_with_pending]
    end

    test "diagnosis reads the :completions window past a backlog longer than :limit", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      {:ok, :appended} =
        Host.append(
          ref,
          Input.message(%{"id" => "w", "actions" => [{:run, {:reply, 1}, %{}}]}),
          nil,
          store
        )

      assert {:parked, _} = step!(store, ref)
      {:ok, child} = LoopProtocol.child_ref(Host, ref, {:reply, 1}, ctx: store)

      {:ok, _lease} = Clementine.Lifecycle.Protocol.claim(Host, child, executor: "w", ctx: store)
      {:ok, :flagged} = LoopProtocol.cancel(Host, ref, :tester, ctx: store)
      assert {:parked, _} = step!(store, ref)

      # The child reached its terminal and its completion WAS delivered —
      # but two messages sit ahead of it in FIFO, so a limit-1 :any
      # window sees only backlog and only the :completions window reaches
      # the completion.
      Agent.update(store, fn state ->
        update_in(state.runs[child], &%{&1 | status: :cancelled})
      end)

      forge_row!(store, ref, Input.message(%{"id" => "noise-1"}), ref: 20_001)
      forge_row!(store, ref, Input.message(%{"id" => "noise-2"}), ref: 20_002)

      forge_row!(store, ref, Input.completed({:reply, 1}, Result.completed(output: "ok")),
        ref: 20_003
      )

      report = inspect!(store, ref, limit: 1)
      assert [%StoredInput{input: %Input{kind: :message}}] = report.pending

      # The delivered completion strands the cascade park (it is
      # consumable and unconsumed) — and its terminal child must NOT read
      # as :stranded_completion, because the completion exists.
      assert [%{class: :parked_with_pending, detail: %{pending: 1}}] = report.strands
    end

    test "a delivered completion undecodable after a vocabulary shrink is present by its dedup key",
         %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      {:ok, :appended} =
        Host.append(
          ref,
          Input.message(%{"id" => "w", "actions" => [{:run, {:reply, 1}, %{}}]}),
          nil,
          store
        )

      assert {:parked, _} = step!(store, ref)
      {:ok, child} = LoopProtocol.child_ref(Host, ref, {:reply, 1}, ctx: store)

      Agent.update(store, fn state ->
        update_in(state.runs[child], &%{&1 | status: :completed})
      end)

      # Control: terminal child, no completion row — a real strand.
      assert Enum.any?(inspect!(store, ref).strands, &(&1.class == :stranded_completion))

      # The completion WAS delivered under the machinery's canonical key,
      # but a vocabulary-shrinking deploy left its payload undecodable.
      # Delivery already happened: the doctor must not send operators to
      # the reconcile path for it.
      tag_key = Codec.key({:reply, 1}, vocabulary: [:reply])

      forge_row!(store, ref, Input.completed({:reply, 1}, Result.completed(output: "ok")),
        dedup_key: "completed:#{tag_key}:#{child}",
        decode_error: %Clementine.Error{code: :undecodable_input, message: "vocab shrank"}
      )

      report = inspect!(store, ref)
      refute Enum.any?(report.strands, &(&1.class == :stranded_completion))

      # The undecodable row itself stays visible evidence: it is pending
      # against a parked loop, which is the honest remaining strand.
      assert [%{class: :parked_with_pending}] = report.strands
    end

    test "L15: a queued loop past :stale_after diagnoses :stale_queued", %{store: store} do
      ref =
        Host.seed(store,
          status: :queued,
          queued_at: DateTime.add(DateTime.utc_now(), -10, :minute)
        )

      report = inspect!(store, ref, stale_after: :timer.minutes(5))
      assert [%{class: :stale_queued, detail: %{queued_for_ms: waited}}] = report.strands
      assert waited >= :timer.minutes(10)

      fresh = Host.seed(store, status: :queued, queued_at: DateTime.utc_now())
      assert inspect!(store, fresh).strands == []
    end
  end

  describe "render/1" do
    test "renders the operator block with children, timers, pending, dead letters, strands", %{
      store: store
    } do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)

      {:ok, :appended} =
        Host.append(
          ref,
          Input.message(%{
            "id" => "w",
            "actions" => [{:run, {:reply, 7}, %{}}, {:timer, :poll, 60_000}]
          }),
          nil,
          store
        )

      assert {:parked, _} = step!(store, ref)
      forge_row!(store, ref, Input.message(%{"id" => "lost"}))

      rendered = store |> inspect!(ref) |> Report.render()

      assert rendered =~ "loop #{ref} — waiting, epoch 2"
      assert rendered =~ "Clementine.Test.ScriptedLoop state_version 1 (declared 1)"
      assert rendered =~ "{:reply, 7} -> run"
      assert rendered =~ ":poll"
      assert rendered =~ "pending (1)"
      assert rendered =~ "! parked_with_pending"
    end

    test "renders an incompatible spec loudly", %{store: store} do
      ref = create!(store, ScriptedLoop)
      assert {:parked, _} = step!(store, ref)
      Host.rewrite_module!(store, ref, "Meli.Gone.Agent")

      rendered = store |> inspect!(ref) |> Report.render()
      assert rendered =~ "INCOMPATIBLE"
      assert rendered =~ "! incompatible_spec"
    end
  end
end
