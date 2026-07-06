defmodule Clementine.ReconcilerPropertyTest do
  @moduledoc """
  Generative check of the reaper's judgment invariants: over arbitrary —
  including nonconforming — facts and policies, a verdict can never
  escape its status scope, requeue can never bypass its three gates, and
  health is monotone in time.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Clementine.InterruptReason
  alias Clementine.Lifecycle.Facts
  alias Clementine.Reconciler
  alias Clementine.Reconciler.Policy

  @base ~U[2026-07-06 12:00:00.000000Z]

  property "verdicts are status-scoped: no reason code escapes its status" do
    check all(facts <- facts_gen(), policy <- policy_gen()) do
      case Reconciler.judge(facts, @base, policy) do
        :healthy ->
          :ok

        {:requeue, _reason} ->
          assert facts.status == :running

        {:interrupt, %InterruptReason{code: code}} ->
          allowed =
            case facts.status do
              :running -> [:lease_expired, :deadline_exceeded]
              :queued -> [:claim_timeout]
              :waiting -> [:suspension_expired]
              _terminal -> []
            end

          assert code in allowed,
                 "#{inspect(code)} escaped its scope for a #{facts.status} run"
      end
    end
  end

  property "requeue never bypasses its gates: policy opt-in, fence unset, headroom under the cap" do
    check all(facts <- facts_gen(), policy <- policy_gen()) do
      case Reconciler.judge(facts, @base, policy) do
        {:requeue, _reason} ->
          assert {:requeue, opts} = policy.retry
          refute facts.effects?
          assert facts.epoch < Keyword.fetch!(opts, :max_claims)

        _other ->
          :ok
      end
    end
  end

  property "the default policy never touches a waiting run" do
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

  # Deliberately generates nonconforming shapes too — execution stamps on
  # waiting runs, missing stamps on running ones — because the scoping must
  # hold against facts a buggy host could present.
  defp facts_gen do
    gen all(
          status <- member_of(Facts.statuses()),
          epoch <- integer(0..8),
          effects? <- boolean(),
          heartbeat_age <- one_of([constant(nil), integer(-60_000..600_000)]),
          deadline_age <- one_of([constant(nil), integer(-600_000..600_000)]),
          queued_age <- one_of([constant(nil), integer(0..2_000_000)])
        ) do
      %Facts{
        ref: "prop",
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
        retry: retry
      )
    end
  end

  defp stamp(nil), do: nil
  defp stamp(age_ms), do: DateTime.add(@base, -age_ms, :millisecond)
end
