defmodule Clementine.Loop.StepPropertyTest do
  @moduledoc """
  Generative check of the pure step core (SKUNK-146 acceptance; LOOP_RFC
  Governing Invariants 2–4, 7, 11) over arbitrary — deliberately
  unfiltered — input sequences and crash-replay re-drains:

  - identical inputs compute the identical `StepCommit`, raises included
    (the purity dividend; matrix rows L1/L16's replay convergence);
  - no silent drops: every batch input is consumed, dead-letter marked, or
    a leftover the commit's own halt/cascade accounts for;
  - the in-fold dedup delivers early completions exactly once (row L5);
  - live-key tag lifetime holds across multi-step histories with random
    pre-commit crashes, where the drain-time attempts bump is the only
    surviving write and poison walks head-blame → degrade → dead-letter.

  App-contract violations (tag collisions the generators are free to
  emit) raise `ArgumentError` by design; the properties assert those
  raises are as deterministic as the commits.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Clementine.Loop.{Codec, Envelope, Input, Step, StoredInput}
  alias Clementine.Test.ScriptedLoop
  alias Clementine.{Error, Result, Usage}

  @vocab [:poll, :reply, :retry, :note]
  @opts [loop_ref: "prop-loop", epoch: 1]

  property "crash-replay re-drains compute the identical StepCommit, raises included" do
    check all(scenario <- scenario()) do
      first = attempt(scenario)
      assert attempt(scenario) == first
      assert attempt(scenario) == first
    end
  end

  property "no silent drops: every batch input is consumed, marked, or a halt/cascade leftover" do
    check all(scenario <- scenario()) do
      {envelope, pending, opts} = scenario

      case attempt(scenario) do
        {:ok, commit} ->
          plan = Step.plan(envelope, pending, opts)
          batch_refs = Enum.map(plan.batch, & &1.ref)
          mark_refs = Enum.map(commit.marks, & &1.ref)

          # Consumption and marking are disjoint verdicts, with closed reasons.
          assert commit.consumed -- batch_refs == []
          assert Enum.uniq(commit.consumed) == commit.consumed
          assert mark_refs -- (batch_refs ++ Enum.map(plan.dead, & &1.ref)) == []
          assert commit.consumed -- (commit.consumed -- mark_refs) == []

          for mark <- commit.marks do
            assert mark.reason in Clementine.Loop.StepCommit.dead_reasons()
          end

          unaccounted = batch_refs -- (commit.consumed ++ mark_refs)

          envelope = commit.set[:envelope]

          cond do
            # Terminal: the in-unit sweep dead-letters every remaining row.
            commit.op == :finish ->
              assert commit.terminal_sweep

            # Cascade batches hold only completions, and every completion
            # is consumed (live) or marked (unknown tag) — nothing skips.
            plan.mode == :cascade ->
              assert unaccounted == []

            # Halt-mid-batch: the leftovers wait for the post-cascade sweep.
            envelope && envelope.pending_halt != nil ->
              :ok

            # Steady state: everything in the batch is accounted for.
            true ->
              assert unaccounted == []
          end

        {:raise, message} ->
          assert is_binary(message)
      end
    end
  end

  property "matrix row L5: an early completion behind its own spawn delivers exactly once, drops never" do
    tag = {:reply, 99}

    check all(
            prefix <- list_of(noise_input(), max_length: 3),
            mid <- list_of(noise_input(), max_length: 2),
            suffix <- list_of(noise_input(), max_length: 3),
            usage <- usage()
          ) do
      spawn_msg = Input.message(%{"id" => 0, "actions" => [{:run, tag, %{"n" => 1}}]})
      completion = Input.completed(tag, Result.completed(usage: usage))

      inputs = prefix ++ [spawn_msg] ++ mid ++ [completion] ++ suffix
      pending = Enum.with_index(inputs, fn input, index -> stored(index, input) end)
      plan = Step.plan(nil, pending, batch_cap: length(pending))

      case attempt({nil, pending, [batch_cap: length(pending)]}) do
        {:ok, commit} ->
          {spawn_ref, completion_ref} = refs_of(pending, spawn_msg, completion)
          delivered = Enum.count(log(commit), &(&1 == "completed:#{inspect(tag)}"))

          if spawn_ref in commit.consumed do
            # The spawn folded before the completion was judged: delivered
            # exactly once, never dead-lettered, cargo retired.
            assert delivered == 1
            assert completion_ref in commit.consumed
            refute Enum.any?(commit.marks, &(&1.ref == completion_ref))
            refute Enum.any?(commit.children, &(&1.tag == tag))
            refute Map.has_key?(commit.set.envelope.children, key(tag))
          else
            # A halt in the prefix stopped the drain first; the pair stays
            # unconsumed for the sweep — dropped never.
            assert delivered == 0
            refute completion_ref in commit.consumed
          end

        {:raise, _message} ->
          # A noise collision (e.g. double-arm) walked the poison path;
          # nothing was committed, so nothing was dropped.
          assert plan.bump != [] or plan.batch == []
      end
    end
  end

  property "multi-step histories with random pre-commit crashes: replay converges, envelopes round-trip, the mailbox never jams" do
    check all(
            rounds <-
              list_of(
                {list_of(any_input(), max_length: 4), boolean(), integer(1..4)},
                min_length: 1,
                max_length: 6
              )
          ) do
      simulate(rounds)
    end
  end

  defp simulate(rounds) do
    initial = %{envelope: nil, pending: [], next_ref: 0, finished: false}

    Enum.reduce_while(rounds, initial, fn {new_inputs, crash?, cap}, sim ->
      if sim.finished do
        {:halt, sim}
      else
        {stored_new, next_ref} = store(new_inputs, sim.next_ref)
        pending = sim.pending ++ stored_new
        opts = [batch_cap: cap, dead_letter_after: 2]

        plan = Step.plan(sim.envelope, pending, opts)
        outcome = attempt({sim.envelope, pending, opts})

        # Replay convergence: whatever this step computes — commit or
        # deterministic contract raise — a re-drain computes it again.
        assert attempt({sim.envelope, pending, opts}) == outcome

        case {outcome, crash?} do
          # Pre-commit crash (or a poison raise): the only surviving write
          # is the drain-time attempts bump; inputs and envelope are
          # untouched (Governing Invariant 3's exception and corollary 4).
          {_outcome, true} ->
            {:cont, %{sim | pending: bump(pending, plan.bump), next_ref: next_ref}}

          {{:raise, _message}, false} ->
            {:cont, %{sim | pending: bump(pending, plan.bump), next_ref: next_ref}}

          {{:ok, commit}, false} ->
            # The committed envelope must survive its storage round trip; a
            # threshold commit omits it, leaving the stored one in place.
            envelope =
              case commit.set[:envelope] do
                nil ->
                  sim.envelope

                written ->
                  {:ok, decoded} = written |> Envelope.encode() |> Envelope.decode()
                  assert decoded == written
                  decoded
              end

            if commit.op == :finish do
              {:cont, %{sim | finished: true}}
            else
              consumed_or_dead =
                MapSet.new(commit.consumed ++ Enum.map(commit.marks, & &1.ref))

              remaining =
                pending
                |> bump(plan.bump)
                |> Enum.reject(&MapSet.member?(consumed_or_dead, &1.ref))

              {appended, next_ref} = store(commit.appends, next_ref)

              {:cont,
               %{
                 sim
                 | envelope: envelope,
                   pending: remaining ++ appended,
                   next_ref: next_ref
               }}
            end
        end
      end
    end)
  end

  defp store(inputs, next_ref) do
    stored =
      Enum.with_index(inputs, fn input, offset -> stored(next_ref + offset, input) end)

    {stored, next_ref + length(inputs)}
  end

  defp bump(pending, bump_refs) do
    Enum.map(pending, fn stored ->
      if stored.ref in bump_refs do
        %{stored | attempts: stored.attempts + 1}
      else
        stored
      end
    end)
  end

  ## Scenario generation

  defp scenario do
    gen all(
          envelope <- one_of([constant(nil), envelope()]),
          inputs <- list_of(any_input(), max_length: 6),
          attempts <- list_of(integer(0..3), length: length(inputs)),
          cap <- integer(1..5),
          threshold <- integer(1..4),
          cancel <- one_of([constant(nil), constant(:prop_cancel)])
        ) do
      pending =
        inputs
        |> Enum.zip(attempts)
        |> Enum.with_index(fn {input, attempts}, index -> stored(index, input, attempts) end)

      {envelope, pending, [batch_cap: cap, dead_letter_after: threshold, cancel: cancel]}
    end
  end

  defp envelope do
    gen all(
          child_tags <- uniq_list_of(tag(), max_length: 3),
          timer_tags <- uniq_list_of(tag(), max_length: 3),
          usage <- usage(),
          pending_halt <-
            one_of([
              constant(nil),
              constant(%{result: Result.cancelled(:earlier_halt)})
            ])
        ) do
      %Envelope{
        state_version: 1,
        state: Codec.encode(%{"log" => []}, vocabulary: @vocab),
        children: Map.new(child_tags, fn tag -> {key(tag), 900} end),
        timers: Map.new(timer_tags, fn tag -> {key(tag), %{}} end),
        pending_halt: pending_halt,
        usage: usage
      }
    end
  end

  defp any_input do
    frequency([
      {4, message()},
      {3, map(tag(), &Input.completed(&1, Result.completed(usage: %Usage{input_tokens: 1})))},
      {2, map(tag(), &Input.elapsed/1)},
      {1, constant(Input.input_failed(0, %Error{code: :evidence}))},
      {1, constant(Input.message(%{"halt" => "stop"}))}
    ])
  end

  # Noise for the L5 property: never touches the reserved {:reply, 99} tag.
  defp noise_input do
    frequency([
      {4, message()},
      {2, map(tag(), &Input.completed(&1, Result.completed()))},
      {2, map(tag(), &Input.elapsed/1)}
    ])
  end

  defp message do
    gen all(id <- integer(0..99), actions <- list_of(action(), max_length: 3)) do
      Input.message(%{"id" => id, "actions" => actions})
    end
  end

  defp action do
    one_of([
      tuple({constant(:run), tag(), constant(%{"n" => 1})}),
      tuple({constant(:timer), tag(), integer(1..1_000)}),
      tuple({constant(:cancel_timer), tag()}),
      tuple({constant(:send), integer(1..3), constant(%{"m" => 1})})
    ])
  end

  # A deliberately small tag space, so lives collide, tags get reused, and
  # unknown-tag arrivals happen organically.
  defp tag do
    one_of([
      integer(0..4),
      member_of(@vocab),
      tuple({member_of([:reply, :retry]), integer(0..2)})
    ])
  end

  defp usage do
    gen all(input_tokens <- integer(0..50), output_tokens <- integer(0..50)) do
      %Usage{input_tokens: input_tokens, output_tokens: output_tokens}
    end
  end

  ## Execution helpers

  defp attempt({envelope, pending, opts}) do
    plan = Step.plan(envelope, pending, opts)
    {:ok, _commit} = result = Step.drain(ScriptedLoop, envelope, plan, @opts)
    result
  rescue
    e in ArgumentError -> {:raise, Exception.message(e)}
  end

  defp stored(ref, input, attempts \\ 0),
    do: %StoredInput{ref: ref, input: input, attempts: attempts}

  defp key(tag), do: Codec.key(tag, vocabulary: @vocab)

  defp log(commit) do
    case commit.set.envelope.state do
      nil -> []
      state -> Codec.decode(state, vocabulary: @vocab)["log"]
    end
  end

  defp refs_of(pending, spawn_msg, completion) do
    spawn_ref = Enum.find(pending, &(&1.input == spawn_msg)).ref
    completion_ref = Enum.find(pending, &(&1.input == completion)).ref
    {spawn_ref, completion_ref}
  end
end
