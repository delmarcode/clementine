defmodule Clementine.Loop.Envelope do
  @moduledoc """
  The machinery-owned durable wrapper around a loop's state (LOOP_RFC
  §Vocabulary): envelope format version, the app's `state_version`, the
  dumped state, live children (`tag_key => child run ref`), pending timers
  (`tag_key => host meta`), the pending halt held during a cascade, and
  machinery-aggregated usage.

  The pure step core records new children and timers with placeholder
  values (`nil` ref, empty meta); the host's `apply_step` fills real run
  refs and schedule handles inside the same atomic unit it creates them.
  Filled values survive later folds verbatim — the fold copies entries it
  does not retire.

  `encode/1`/`decode/1` are the storage doors for the envelope column.
  State, children keys, and timer keys are canonical-codec territory;
  the two open positions (child refs, the pending halt's `Result`) use the
  tagged json/ETF convention the Ecto codec established for trusted open
  `term()` storage — the envelope is written and read only by this
  machinery, on the BEAM, whatever the substrate.

  A stored envelope version this code does not know decodes to
  `{:error, {:incompatible_state, detail}}` — the same clean-failure path
  as an app `state_version` mismatch, because the operator story is
  identical: park visibly, deploy compatible code (LOOP_RFC §The
  Behaviour, matrix row L2).
  """

  alias Clementine.{Result, Usage}

  @version 1

  defstruct version: @version,
            state_version: 1,
            state: nil,
            children: %{},
            timers: %{},
            pending_halt: nil,
            usage: %Usage{}

  @type tag_key :: String.t()

  @type t :: %__MODULE__{
          version: pos_integer(),
          state_version: pos_integer(),
          state: map() | nil,
          children: %{optional(tag_key()) => term()},
          timers: %{optional(tag_key()) => map()},
          pending_halt: nil | %{result: Result.t()},
          usage: Usage.t()
        }

  @spec version() :: pos_integer()
  def version, do: @version

  @doc "True when the loop is mid-cascade: a halt result is parked in the envelope."
  @spec cascading?(t()) :: boolean()
  def cascading?(%__MODULE__{pending_halt: nil}), do: false
  def cascading?(%__MODULE__{}), do: true

  @doc "JSON-safe map form for the host's envelope column."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = envelope) do
    %{
      "v" => envelope.version,
      "state_version" => envelope.state_version,
      "state" => envelope.state,
      "children" => Map.new(envelope.children, fn {key, ref} -> {key, encode_open(ref)} end),
      "timers" => envelope.timers,
      "pending_halt" => encode_pending_halt(envelope.pending_halt),
      "usage" => Usage.to_map(envelope.usage)
    }
  end

  @doc "Rebuilds the envelope from `encode/1` output."
  @spec decode(map()) :: {:ok, t()} | {:error, {:incompatible_state, map()}}
  def decode(%{"v" => @version} = data) do
    {:ok,
     %__MODULE__{
       version: @version,
       state_version: Map.fetch!(data, "state_version"),
       state: Map.fetch!(data, "state"),
       children:
         Map.new(Map.fetch!(data, "children"), fn {key, ref} -> {key, decode_open(ref)} end),
       timers: Map.fetch!(data, "timers"),
       pending_halt: decode_pending_halt(Map.fetch!(data, "pending_halt")),
       usage: Usage.from_map(Map.fetch!(data, "usage"))
     }}
  end

  def decode(%{"v" => version}) do
    {:error, {:incompatible_state, %{envelope_version: version, supported: @version}}}
  end

  def decode(other) do
    {:error, {:incompatible_state, %{envelope: :malformed, got: inspect(other)}}}
  end

  defp encode_pending_halt(nil), do: nil
  defp encode_pending_halt(%{result: result}), do: %{"result" => encode_open(result)}

  defp decode_pending_halt(nil), do: nil
  defp decode_pending_halt(%{"result" => result}), do: %{result: decode_open(result)}

  # Trusted machinery storage: JSON-exact values stay inspectable, anything
  # else rides ETF. Decode omits :safe deliberately — an atom this codec
  # durably wrote may not be interned yet in a fresh VM, and decode must
  # stay total on its own writes (the Ecto codec states the full argument).
  defp encode_open(term) do
    if json_exact?(term) do
      %{"t" => "json", "v" => term}
    else
      %{"t" => "etf", "v" => Base.encode64(:erlang.term_to_binary(term))}
    end
  end

  defp decode_open(%{"t" => "json", "v" => value}), do: value

  defp decode_open(%{"t" => "etf", "v" => encoded}),
    do: :erlang.binary_to_term(Base.decode64!(encoded))

  defp json_exact?(value)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: true

  defp json_exact?(value) when is_binary(value), do: String.valid?(value)
  defp json_exact?(value) when is_list(value), do: Enum.all?(value, &json_exact?/1)

  defp json_exact?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {k, v} -> is_binary(k) and String.valid?(k) and json_exact?(v) end)
  end

  defp json_exact?(_value), do: false
end
