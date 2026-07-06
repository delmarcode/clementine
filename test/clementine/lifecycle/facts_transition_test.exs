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
