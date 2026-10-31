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

    test "reads the cache counts" do
      assert %Usage{input_tokens: 100, cache_read_tokens: 60, cache_write_tokens: 30} =
               Usage.new(%{
                 "input_tokens" => 100,
                 "cache_read_tokens" => 60,
                 "cache_write_tokens" => 30
               })
    end

    test "missing, nil, and malformed counts read as zero" do
      assert %Usage{input_tokens: 0, output_tokens: 0} = Usage.new(nil)
      assert %Usage{input_tokens: 0, output_tokens: 0} = Usage.new(%{})

      assert %Usage{input_tokens: 0, output_tokens: 7} =
               Usage.new(%{"input_tokens" => "lots", "output_tokens" => 7})

      assert %Usage{input_tokens: 0} = Usage.new(%{"input_tokens" => -5})

      assert %Usage{cache_read_tokens: 0, cache_write_tokens: 0} =
               Usage.new(%{"input_tokens" => 9, "cache_read_tokens" => nil})
    end
  end

  describe "add/2" do
    test "adds field-wise" do
      a = %Usage{input_tokens: 10, output_tokens: 5}
      b = %Usage{input_tokens: 1, output_tokens: 2}

      assert %Usage{input_tokens: 11, output_tokens: 7} = Usage.add(a, b)
    end

    test "adds the cache counts field-wise too" do
      a = %Usage{input_tokens: 100, output_tokens: 5, cache_write_tokens: 90}
      b = %Usage{input_tokens: 110, output_tokens: 6, cache_read_tokens: 90}

      assert Usage.add(a, b) == %Usage{
               input_tokens: 210,
               output_tokens: 11,
               cache_read_tokens: 90,
               cache_write_tokens: 90
             }
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

  test "total/1 counts cached input once: the cache counts are parts of input_tokens" do
    usage = %Usage{
      input_tokens: 1000,
      output_tokens: 50,
      cache_read_tokens: 800,
      cache_write_tokens: 150
    }

    assert Usage.total(usage) == 1050
  end

  test "to_map/1 writes every field" do
    assert Usage.to_map(%Usage{input_tokens: 3, cache_read_tokens: 2}) == %{
             "input_tokens" => 3,
             "output_tokens" => 0,
             "cache_read_tokens" => 2,
             "cache_write_tokens" => 0
           }
  end

  test "from_map/1 reads a map written before the cache counts as zero cache" do
    assert Usage.from_map(%{"input_tokens" => 42, "output_tokens" => 17}) ==
             %Usage{
               input_tokens: 42,
               output_tokens: 17,
               cache_read_tokens: 0,
               cache_write_tokens: 0
             }
  end

  test "to_map/1 and from_map/1 round-trip through JSON" do
    usage = %Usage{
      input_tokens: 42,
      output_tokens: 17,
      cache_read_tokens: 30,
      cache_write_tokens: 9
    }

    round_tripped =
      usage
      |> Usage.to_map()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Usage.from_map()

    assert round_tripped == usage
  end
end
