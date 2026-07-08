defmodule Clementine.ReconcilerPropertyTest do
  @moduledoc """
  Generative check of the reaper's judgment invariants: over arbitrary —
  including nonconforming — facts, evidence, and policies, a verdict can
  never escape its kind-and-status scope, rollout requeue can never
  bypass its three gates while loop requeue answers to none of them
  (amendment A3), no loop verdict is terminal except the deadline belt,
  and health is monotone in time.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Clementine.InterruptReason
  alias Clementine.Lifecycle.Facts
  alias Clementine.Reconciler
  alias Clementine.Reconciler.{LoopEvidence, Policy}

  @base ~U[2026-07-06 12:00:00.000000Z]

  property "verdicts are kind- and status-scoped: nothing escapes its scope" do
    check all(facts <- facts_gen(), policy <- policy_gen()) do
      case Reconciler.judge(facts, @base, policy) do
        :healthy ->
          :ok

        {:requeue, reason} ->
          assert facts.status == :running
          assert reason == :lease_expired

        {:reenqueue, reason} ->
          assert {facts.kind, facts.status} == {:loop, :queued}
          assert reason == :claim_timeout

        {:interrupt, %InterruptReason{code: code}} ->
          allowed =
            case {facts.kind, facts.status} do
              {:rollout, :running} -> [:lease_expired, :deadline_exceeded]
              {:rollout, :queued} -> [:claim_timeout]
              {:rollout, :waiting} -> [:suspension_expired]
              {:loop, :running} -> [:deadline_exceeded]
              {_kind, _terminal_or_exempt} -> []
            end

          assert code in allowed,
                 "#{inspect(code)} escaped its scope for a #{facts.kind} #{facts.status} run"

        {evidence_verdict, _} when evidence_verdict in [:reconcile_children, :wake_pending] ->
          flunk("judge/3 gathers no evidence; #{inspect(evidence_verdict)} cannot fire from it")
      end
    end
  end

  property "requeue gates fork by kind: rollouts pass three gates, loops answer to none" do
    check all(facts <- facts_gen(), policy <- policy_gen()) do
      case {facts.kind, Reconciler.judge(facts, @base, policy)} do
        {:rollout, {:requeue, _reason}} ->
          assert {:requeue, opts} = policy.retry
          refute facts.effects?
          assert facts.epoch < Keyword.fetch!(opts, :max_claims)

        {:loop, {:requeue, _reason}} ->
          # The only gate is the evidence itself; policy, fence, and
          # epoch were consulted for nothing.
          assert facts.status == :running

        _other ->
          :ok
      end
    end
  end

  property "matrix row L16, generalized: a stale running loop requeues under every policy, fence, and epoch" do
    check all(
            %Facts{} = facts <- facts_gen(),
            policy <- policy_gen(),
            stale_age <- integer(300_001..900_000)
          ) do
      # policy_gen draws stale_after from 1..300_000, so this heartbeat is
      # stale under every generated policy — even one whose deadline is
      # also overdue (stale evidence outranks the deadline belt).
      loop = %Facts{facts | kind: :loop, status: :running, heartbeat_at: stamp(stale_age)}

      assert Reconciler.judge(loop, @base, policy) == {:requeue, :lease_expired}
    end
  end

  property "matrix rows L15/L16: no loop verdict is terminal except the fresh-heartbeat deadline belt" do
    check all(
            %Facts{} = facts <- facts_gen(),
            evidence <- one_of([constant(nil), evidence_gen()]),
            policy <- policy_gen()
          ) do
      loop = %Facts{facts | kind: :loop, deadline: nil}

      refute match?(
               {:interrupt, _reason},
               Reconciler.judge_loop(loop, evidence, @base, policy)
             )
    end
  end

  property "matrix row L13, generalized: the parked-loop verdicts are sound and complete over arbitrary evidence" do
    check all(
            evidence <- evidence_gen(),
            policy <- policy_gen(),
            queued_age <- one_of([constant(nil), integer(0..2_000_000)])
          ) do
      parked = %Facts{
        ref: "prop",
        kind: :loop,
        status: :waiting,
        epoch: 3,
        queued_at: stamp(queued_age)
      }

      strands =
        for child <- evidence.children,
            child.terminal? and not child.completion_present? do
          %{tag_key: child.tag_key, child_ref: child.child_ref}
        end

      stale_pending? =
        evidence.oldest_pending_at != nil and
          DateTime.diff(@base, evidence.oldest_pending_at, :millisecond) >
            policy.wake_pending_after

      expected =
        cond do
          strands != [] -> {:reconcile_children, strands}
          stale_pending? -> {:wake_pending, :stale_inputs}
          true -> :healthy
        end

      # Note what never entered the computation: queued_at and
      # policy.max_wait — the exemption, held generatively.
      assert Reconciler.judge_loop(parked, evidence, @base, policy) == expected
    end
  end

  property "the default policy never touches a waiting run of either kind" do
    check all(%Facts{} = facts <- facts_gen()) do
      waiting = %Facts{facts | status: :waiting}
      assert Reconciler.judge(waiting, @base, Policy.new()) == :healthy
    end
  end

  property "health is monotone in time: healthy now was healthy at every earlier instant" do
    check all(facts <- facts_gen(), policy <- policy_gen(), delta <- integer(1..600_000)) do
      if Reconciler.judge(facts, @base, policy) == :healthy do
        earlier = DateTime.add(@base, -delta, :millisecond)
        assert Reconciler.judge(facts, earlier, policy) == :healthy
      end
    end
  end

  property "loop health is monotone in time, evidence included" do
    check all(
            %Facts{} = facts <- facts_gen(),
            evidence <- evidence_gen(),
            policy <- policy_gen(),
            delta <- integer(1..600_000)
          ) do
      loop = %Facts{facts | kind: :loop}

      if Reconciler.judge_loop(loop, evidence, @base, policy) == :healthy do
        earlier = DateTime.add(@base, -delta, :millisecond)
        assert Reconciler.judge_loop(loop, evidence, earlier, policy) == :healthy
      end
    end
  end

  # Deliberately generates nonconforming shapes too — execution stamps on
  # waiting runs, missing stamps on running ones, effect fences on loops —
  # because the scoping must hold against facts a buggy host could present.
  defp facts_gen do
    gen all(
          kind <- member_of(Facts.kinds()),
          status <- member_of(Facts.statuses()),
          epoch <- integer(0..2000),
          effects? <- boolean(),
          heartbeat_age <- one_of([constant(nil), integer(-60_000..600_000)]),
          deadline_age <- one_of([constant(nil), integer(-600_000..600_000)]),
          queued_age <- one_of([constant(nil), integer(0..2_000_000)])
        ) do
      %Facts{
        ref: "prop",
        kind: kind,
        status: status,
        epoch: epoch,
        effects?: effects?,
        heartbeat_at: stamp(heartbeat_age),
        deadline: stamp(deadline_age),
        queued_at: stamp(queued_age)
      }
    end
  end

  defp policy_gen do
    gen all(
          stale_after <- integer(1..300_000),
          deadline_grace <- integer(1..300_000),
          claim_timeout <- integer(1..300_000),
          max_wait <- one_of([constant(nil), integer(1..2_000_000)]),
          wake_pending_after <- integer(1..600_000),
          retry <-
            one_of([
              constant(:never),
              map(integer(1..5), &{:requeue, [max_claims: &1]})
            ])
        ) do
      Policy.new(
        stale_after: stale_after,
        deadline_grace: deadline_grace,
        claim_timeout: claim_timeout,
        max_wait: max_wait,
        wake_pending_after: wake_pending_after,
        retry: retry
      )
    end
  end

  defp evidence_gen do
    gen all(
          children <- list_of(child_gen(), max_length: 4),
          oldest_age <- one_of([constant(nil), integer(0..2_000_000)])
        ) do
      %LoopEvidence{children: children, oldest_pending_at: stamp(oldest_age)}
    end
  end

  defp child_gen do
    gen all(
          tag_key <- string(:alphanumeric, min_length: 1, max_length: 6),
          terminal? <- boolean(),
          completion_present? <- boolean()
        ) do
      %{
        tag_key: tag_key,
        child_ref: {:child, tag_key},
        terminal?: terminal?,
        completion_present?: completion_present?
      }
    end
  end

  defp stamp(nil), do: nil
  defp stamp(age_ms), do: DateTime.add(@base, -age_ms, :millisecond)
end
