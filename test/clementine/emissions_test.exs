defmodule Clementine.EmissionsTest do
  use ExUnit.Case, async: true

  alias Clementine.Emissions

  # The seam is process-local state; every test drives its own process's
  # frames and observes firing order through messages to self.

  defp emit(label), do: Emissions.emit(fn -> send(self(), {:fired, label}) end)

  defp fired do
    receive do
      {:fired, label} -> [label | fired()]
    after
      0 -> []
    end
  end

  test "without a bracket, emit fires immediately" do
    emit(:a)
    assert fired() == [:a]
  end

  test "a bracket defers until flush, in arrival order" do
    token = Emissions.begin_deferral()
    emit(:a)
    emit(:b)
    assert fired() == []

    Emissions.flush(token)
    assert fired() == [:a, :b]
  end

  test "drop discards the frame; nothing ever fires" do
    token = Emissions.begin_deferral()
    emit(:a)
    Emissions.drop(token)
    assert fired() == []

    # The seam is fully closed: later emits are immediate again.
    emit(:b)
    assert fired() == [:b]
  end

  test "drop after flush is a no-op — the after-block safety pattern" do
    token = Emissions.begin_deferral()
    emit(:a)
    Emissions.flush(token)
    Emissions.drop(token)
    assert fired() == [:a]

    emit(:b)
    assert fired() == [:b]
  end

  test "a nested flush hands emissions to the enclosing frame, preserving arrival order" do
    outer = Emissions.begin_deferral()
    emit(:outer_before)

    inner = Emissions.begin_deferral()
    emit(:inner)
    # The inner unit is a savepoint: its "commit" must not fire anything
    # while the outer unit is still in flight.
    Emissions.flush(inner)
    assert fired() == []

    emit(:outer_after)
    Emissions.flush(outer)
    assert fired() == [:outer_before, :inner, :outer_after]
  end

  test "a nested drop discards the inner frame alone" do
    outer = Emissions.begin_deferral()
    emit(:outer)

    inner = Emissions.begin_deferral()
    emit(:inner)
    Emissions.drop(inner)

    Emissions.flush(outer)
    assert fired() == [:outer]
  end

  test "the outer drop discards handed-up inner emissions with everything else" do
    outer = Emissions.begin_deferral()

    inner = Emissions.begin_deferral()
    emit(:inner)
    Emissions.flush(inner)

    Emissions.drop(outer)
    assert fired() == []
  end

  describe "after_commit/1" do
    test "fires what the transaction emitted once it returns {:ok, _}" do
      assert {:ok, :value} =
               Emissions.after_commit(fn ->
                 emit(:a)
                 assert fired() == []
                 {:ok, :value}
               end)

      assert fired() == [:a]
    end

    test "drops what it emitted when it returns anything else, or raises" do
      assert {:error, :rolled_back} =
               Emissions.after_commit(fn ->
                 emit(:a)
                 {:error, :rolled_back}
               end)

      assert_raise RuntimeError, fn ->
        Emissions.after_commit(fn ->
          emit(:b)
          raise "boom"
        end)
      end

      assert fired() == []

      # Nothing is left open: emits fire at once again.
      emit(:c)
      assert fired() == [:c]
    end
  end
end
