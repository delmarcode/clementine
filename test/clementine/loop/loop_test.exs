defmodule Clementine.LoopTest do
  use ExUnit.Case, async: true

  alias Clementine.Test.{DoorLoop, ScriptedLoop}

  describe "use Clementine.Loop" do
    test "declares state_version and vocabulary, with defaults" do
      assert ScriptedLoop.__loop__(:state_version) == 1

      assert ScriptedLoop.__loop__(:vocabulary) ==
               [:poll, :reply, :retry, :note, :run, :timer, :cancel_timer, :send]

      assert DoorLoop.__loop__(:state_version) == 1
      assert DoorLoop.__loop__(:vocabulary) == []
    end

    test "dump/load default to identity and are overridable" do
      assert ScriptedLoop.dump(%{"a" => 1}) == %{"a" => 1}
      assert ScriptedLoop.load(%{"a" => 1}) == %{"a" => 1}

      set = MapSet.new(["x", "b"])
      assert DoorLoop.dump(set) == %{"items" => ["b", "x"]}
      assert DoorLoop.load(%{"items" => ["b", "x"]}) == set
    end

    test "a non-positive state_version refuses to compile" do
      assert_raise ArgumentError, ~r/state_version/, fn ->
        defmodule BadVersion do
          use Clementine.Loop, state_version: 0
        end
      end
    end

    test "a non-atom vocabulary refuses to compile" do
      assert_raise ArgumentError, ~r/vocabulary/, fn ->
        defmodule BadVocab do
          use Clementine.Loop, vocabulary: ["strings"]
        end
      end
    end
  end

  describe "resolve/1" do
    test "resolves a loop module and its persisted string form" do
      assert Clementine.Loop.resolve(ScriptedLoop) == {:ok, ScriptedLoop}
      assert Clementine.Loop.resolve("Clementine.Test.ScriptedLoop") == {:ok, ScriptedLoop}
    end

    test "matrix row L2 (spec half): a renamed or missing loop_module fails clean as :incompatible_spec" do
      assert {:error, {:incompatible_spec, %{reason: :not_a_loop}}} =
               Clementine.Loop.resolve("Clementine.Test.RenamedAwayLoop")

      assert {:error, {:incompatible_spec, %{reason: :not_a_loop}}} =
               Clementine.Loop.resolve(String)
    end
  end

  describe "loop?/1" do
    test "true only for modules compiled with use Clementine.Loop" do
      assert Clementine.Loop.loop?(ScriptedLoop)
      refute Clementine.Loop.loop?(String)
      refute Clementine.Loop.loop?(:not_a_module)
    end
  end
end
