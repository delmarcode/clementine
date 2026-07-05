defmodule Clementine.Usage do
  @moduledoc """
  Token accounting, accumulated from provider responses.

  Providers report usage as loosely-shaped maps; this struct is the typed,
  additive form the rest of the system carries. Results include it on every
  terminal variant (tokens burn on failures too), checkpoints preserve it
  across suspensions, and heartbeats may piggyback it so even interrupted
  runs carry billing-grade numbers.
  """

  defstruct input_tokens: 0, output_tokens: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer()
        }

  @doc """
  Builds usage from a provider usage map (string or atom keys). Missing or
  malformed counts read as zero — usage is accounting, never a crash source.
  """
  @spec new(map() | nil) :: t()
  def new(nil), do: %__MODULE__{}

  def new(map) when is_map(map) do
    %__MODULE__{
      input_tokens: fetch_count(map, :input_tokens),
      output_tokens: fetch_count(map, :output_tokens)
    }
  end

  @doc "Adds two usages field-wise. The right side may be a raw provider map."
  @spec add(t(), t() | map() | nil) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens
    }
  end

  def add(%__MODULE__{} = a, other), do: add(a, new(other))

  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{} = usage), do: usage.input_tokens + usage.output_tokens

  @doc "JSON-safe map form, for checkpoints and host storage."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = usage) do
    %{"input_tokens" => usage.input_tokens, "output_tokens" => usage.output_tokens}
  end

  @doc "Rebuilds usage from `to_map/1` output (tolerant of provider maps)."
  @spec from_map(map() | nil) :: t()
  def from_map(map), do: new(map)

  defp fetch_count(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end
end
