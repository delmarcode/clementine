defmodule Clementine.UsageTest do
  use ExUnit.Case, async: true

  alias Clementine.Usage

  describe "new/1" do
    test "reads string-keyed provider maps" do
      assert %Usage{input_tokens: 10, output_tokens: 25} =
               Usage.new(%{"input_tokens" => 10, "output_tokens" => 25})
    end

    test "reads atom-keyed maps" do
      assert %Usage{input_tokens: 3, output_tokens: 4} =
               Usage.new(%{input_tokens: 3, output_tokens: 4})
    end

    test "missing, nil, and malformed counts read as zero" do
      assert %Usage{input_tokens: 0, output_tokens: 0} = Usage.new(nil)
      assert %Usage{input_tokens: 0, output_tokens: 0} = Usage.new(%{})

      assert %Usage{input_tokens: 0, output_tokens: 7} =
               Usage.new(%{"input_tokens" => "lots", "output_tokens" => 7})

      assert %Usage{input_tokens: 0} = Usage.new(%{"input_tokens" => -5})
    end
  end

  describe "add/2" do
    test "adds field-wise" do
      a = %Usage{input_tokens: 10, output_tokens: 5}
      b = %Usage{input_tokens: 1, output_tokens: 2}

      assert %Usage{input_tokens: 11, output_tokens: 7} = Usage.add(a, b)
    end

    test "accepts a raw provider map on the right" do
      a = %Usage{input_tokens: 10, output_tokens: 5}

      assert %Usage{input_tokens: 12, output_tokens: 5} =
               Usage.add(a, %{"input_tokens" => 2})

      assert ^a = Usage.add(a, nil)
    end
  end

  test "total/1 sums both directions" do
    assert Usage.total(%Usage{input_tokens: 10, output_tokens: 5}) == 15
  end

  test "to_map/1 and from_map/1 round-trip through JSON" do
    usage = %Usage{input_tokens: 42, output_tokens: 17}

    round_tripped =
      usage
      |> Usage.to_map()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Usage.from_map()

    assert round_tripped == usage
  end
end
