defmodule Clementine.Loop.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Clementine.Loop.Envelope
  alias Clementine.{Result, Usage}

  test "encode/decode round-trips an empty envelope" do
    envelope = %Envelope{}
    assert {:ok, ^envelope} = envelope |> Envelope.encode() |> Envelope.decode()
  end

  test "encode/decode round-trips a populated envelope" do
    envelope = %Envelope{
      state_version: 3,
      state: %{"cursor" => 7},
      children: %{"42" => 901, "[\"a\",\"poll\"]" => nil},
      timers: %{"\"tick\"" => %{"job" => 5}},
      pending_halt: %{result: Result.completed(output: "done")},
      usage: %Usage{input_tokens: 10, output_tokens: 4}
    }

    assert {:ok, ^envelope} = envelope |> Envelope.encode() |> Envelope.decode()
  end

  test "encoded form is JSON-serializable, including non-JSON refs via the ETF branch" do
    envelope = %Envelope{
      children: %{"1" => {:host, :ref}},
      pending_halt: %{result: Result.cancelled({:user, "u1"})}
    }

    encoded = Envelope.encode(envelope)
    assert encoded |> Jason.encode!() |> is_binary()
    assert {:ok, ^envelope} = Envelope.decode(encoded)
  end

  test "matrix row L2 (state half): an unknown envelope version decodes to :incompatible_state, never a crash" do
    encoded = Envelope.encode(%Envelope{})
    future = Map.put(encoded, "v", 99)

    assert {:error, {:incompatible_state, %{envelope_version: 99, supported: 1}}} =
             Envelope.decode(future)

    assert {:error, {:incompatible_state, %{envelope: :malformed}}} = Envelope.decode(%{})
  end

  test "cascading? reads the pending halt" do
    refute Envelope.cascading?(%Envelope{})
    assert Envelope.cascading?(%Envelope{pending_halt: %{result: Result.cancelled(:x)}})
  end
end
