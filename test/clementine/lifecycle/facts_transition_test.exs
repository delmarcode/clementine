defmodule Clementine.Lifecycle.FactsTransitionTest do
  use ExUnit.Case, async: true

  alias Clementine.Lifecycle.{Facts, Transition}
  alias Clementine.Result

  describe "Facts statuses" do
    test "the status universe is closed and partitioned" do
      assert Enum.sort(Facts.statuses()) ==
               Enum.sort(Facts.terminal_statuses() ++ Facts.active_statuses())
    end

    test "terminal statuses are dead ends; active ones are not" do
      for status <- Facts.terminal_statuses() do
        assert Facts.terminal?(status)
        refute Facts.active?(status)
      end

      for status <- Facts.active_statuses() do
        refute Facts.terminal?(status)
        assert Facts.active?(status)
      end
    end

    test "helpers accept facts structs" do
      assert Facts.terminal?(%Facts{status: :completed})
      assert Facts.active?(%Facts{status: :waiting})
    end

    test "unknown statuses are refused, not guessed" do
      assert_raise FunctionClauseError, fn -> Facts.terminal?(:paused) end
    end

    test "defaults describe a fresh queued run at epoch zero" do
      facts = %Facts{ref: "run_1"}

      assert facts.status == :queued
      assert facts.epoch == 0
      refute facts.effects?
      assert facts.executor_id == nil
    end
  end

  describe "Facts kinds" do
    test "the kind universe is closed and defaults to :rollout — amendment A1" do
      assert Facts.kinds() == [:rollout, :loop]
      assert %Facts{ref: "run_1"}.kind == :rollout
    end
  end

  describe "Facts observation order" do
    defp facts(status, epoch), do: %Facts{ref: "run_1", status: status, epoch: epoch}

    test "a full lifecycle trajectory is strictly increasing — notifications order themselves" do
      trajectory = [
        facts(:queued, 0),
        facts(:running, 1),
        facts(:waiting, 1),
        facts(:queued, 1),
        facts(:running, 2),
        facts(:completed, 2)
      ]

      for [earlier, later] <- Enum.chunk_every(trajectory, 2, 1, :discard) do
        assert Facts.compare(earlier, later) == :lt
        assert Facts.supersedes?(later, earlier)
        refute Facts.supersedes?(earlier, later)
      end
    end

    test "requeue orders after running within the same epoch" do
      assert Facts.supersedes?(facts(:queued, 3), facts(:running, 3))
    end

    test "every terminal outranks every active status at the same epoch" do
      for terminal <- Facts.terminal_statuses(), active <- Facts.active_statuses() do
        assert Facts.supersedes?(facts(terminal, 2), facts(active, 2))
      end
    end

    test "epoch dominates status rank — a fresh claim supersedes an old wait" do
      assert Facts.supersedes?(facts(:running, 6), facts(:waiting, 5))
    end

    test "same-slot updates (heartbeat, flags) compare equal; latest arrival wins" do
      flagged = %Facts{ref: "run_1", status: :running, epoch: 4, cancel: %{reason: :user}}

      assert Facts.compare(facts(:running, 4), flagged) == :eq
      refute Facts.supersedes?(flagged, facts(:running, 4))
    end
  end

  describe "Transition" do
    test "the op set matches the protocol" do
      assert Enum.sort(Transition.ops()) ==
               Enum.sort([
                 :claim,
                 :heartbeat,
                 :mark_effects,
                 :suspend,
                 :resume,
                 :requeue,
                 :cancel_request,
                 :finish,
                 :interrupt
               ])
    end

    test "terminal?/1 keys off result presence" do
      base = %Transition{
        op: :heartbeat,
        run_ref: "run_1",
        expect: %{status: :running, epoch: 3},
        set: %{heartbeat_at: :now}
      }

      refute Transition.terminal?(base)

      terminal = %Transition{
        base
        | op: :interrupt,
          result: Result.interrupted(:lease_expired)
      }

      assert Transition.terminal?(terminal)
    end
  end
end
