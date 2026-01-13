defmodule ClementineTest do
  use ExUnit.Case
  doctest Clementine

  test "greets the world" do
    assert Clementine.hello() == :world
  end
end
