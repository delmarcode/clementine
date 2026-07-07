defmodule Clementine.Loop.CodecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Clementine.Loop.Codec

  @vocab [:poll, :reply, :retry]

  describe "encode/decode" do
    test "JSON scalars pass through unchanged" do
      for term <- [nil, true, false, 0, -7, 3.5, "text", ""] do
        assert Codec.encode(term) == term
        assert Codec.decode(term) == term
      end
    end

    test "tuples encode as tagged arrays — tuple tags are legal" do
      assert Codec.encode({:reply, 5}, vocabulary: @vocab) == ["t", [["a", "reply"], 5]]
      assert Codec.decode(["t", [["a", "reply"], 5]], vocabulary: @vocab) == {:reply, 5}
    end

    test "lists are tagged, so a stored array is never ambiguous" do
      assert Codec.encode(["a", "x"]) == ["l", ["a", "x"]]
      assert Codec.decode(["l", ["a", "x"]]) == ["a", "x"]
    end

    test "atoms whitelist through the declared vocabulary" do
      assert Codec.encode(:poll, vocabulary: @vocab) == ["a", "poll"]
      assert Codec.decode(["a", "poll"], vocabulary: @vocab) == :poll
    end

    test "an undeclared atom refuses to encode, naming the fix" do
      error = assert_raise ArgumentError, fn -> Codec.encode(:rogue, vocabulary: @vocab) end
      assert error.message =~ "vocabulary"
    end

    test "a stored atom outside the current vocabulary refuses to decode" do
      error =
        assert_raise ArgumentError, fn -> Codec.decode(["a", "rogue"], vocabulary: @vocab) end

      assert error.message =~ "shrink"
    end

    test "string-keyed maps pass through with encoded values" do
      assert Codec.encode(%{"k" => {:reply, 1}}, vocabulary: @vocab) ==
               %{"k" => ["t", [["a", "reply"], 1]]}

      assert Codec.decode(%{"k" => ["t", [["a", "reply"], 1]]}, vocabulary: @vocab) ==
               %{"k" => {:reply, 1}}
    end

    test "atom-keyed maps are refused — they do not survive storage" do
      assert_raise ArgumentError, ~r/keys must be strings/, fn ->
        Codec.encode(%{id: 1})
      end
    end

    test "structs, pids, and invalid binaries are outside the vocabulary" do
      assert_raise ArgumentError, fn -> Codec.encode(%Clementine.Usage{}) end
      assert_raise ArgumentError, fn -> Codec.encode(self()) end
      assert_raise ArgumentError, fn -> Codec.encode(<<0xFF, 0xFE>>) end
    end

    test "malformed stored forms refuse to decode" do
      assert_raise ArgumentError, fn -> Codec.decode(["t", "not-a-list"]) end
      assert_raise ArgumentError, fn -> Codec.decode({:tuple, "raw"}) end
    end

    property "encode/decode round-trips every codec-safe term" do
      check all(term <- codec_term(@vocab)) do
        assert term |> Codec.encode(vocabulary: @vocab) |> Codec.decode(vocabulary: @vocab) ==
                 term
      end
    end

    property "encoded forms are JSON-serializable" do
      check all(term <- codec_term(@vocab)) do
        assert term |> Codec.encode(vocabulary: @vocab) |> Jason.encode!() |> is_binary()
      end
    end
  end

  describe "key/2" do
    test "canonical string forms are stable and collision-free across types" do
      assert Codec.key(42) == "42"
      assert Codec.key("42") == "\"42\""
      assert Codec.key(:poll, vocabulary: @vocab) == "[\"a\",\"poll\"]"
      assert Codec.key({:reply, 5}, vocabulary: @vocab) == "[\"t\",[[\"a\",\"reply\"],5]]"
    end

    test "tags may not contain maps — no canonical key form exists" do
      assert_raise ArgumentError, ~r/canonical key form/, fn ->
        Codec.key({:reply, %{"a" => 1}}, vocabulary: @vocab)
      end
    end

    property "keys are deterministic and injective over tag terms" do
      check all(a <- tag_term(@vocab), b <- tag_term(@vocab)) do
        key_a = Codec.key(a, vocabulary: @vocab)
        assert key_a == Codec.key(a, vocabulary: @vocab)

        if a != b do
          assert key_a != Codec.key(b, vocabulary: @vocab)
        end
      end
    end
  end

  describe "validate_json_map!/2" do
    test "accepts plain JSON maps" do
      assert Codec.validate_json_map!(%{"k" => [1, %{"n" => nil}]}, "args") == %{
               "k" => [1, %{"n" => nil}]
             }
    end

    test "refuses atoms, tuples, and non-map input" do
      assert_raise ArgumentError, fn -> Codec.validate_json_map!(%{"k" => :atom}, "args") end
      assert_raise ArgumentError, fn -> Codec.validate_json_map!(%{k: 1}, "args") end
      assert_raise ArgumentError, fn -> Codec.validate_json_map!([], "args") end
    end
  end

  # Terms the codec accepts: scalars, vocabulary atoms, tuples/lists of
  # them, string-keyed maps.
  defp codec_term(vocab) do
    scalar =
      StreamData.one_of([
        StreamData.constant(nil),
        StreamData.boolean(),
        StreamData.integer(),
        StreamData.float(min: -1.0e6, max: 1.0e6),
        StreamData.string(:printable, max_length: 12),
        StreamData.member_of(vocab)
      ])

    StreamData.tree(scalar, fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 4),
        StreamData.map_of(StreamData.string(:printable, max_length: 6), child, max_length: 4),
        StreamData.list_of(child, max_length: 4) |> StreamData.map(&List.to_tuple/1)
      ])
    end)
  end

  # Tag terms additionally exclude maps.
  defp tag_term(vocab) do
    scalar =
      StreamData.one_of([
        StreamData.constant(nil),
        StreamData.boolean(),
        StreamData.integer(),
        StreamData.string(:printable, max_length: 12),
        StreamData.member_of(vocab)
      ])

    StreamData.tree(scalar, fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 4),
        StreamData.list_of(child, max_length: 4) |> StreamData.map(&List.to_tuple/1)
      ])
    end)
  end
end
