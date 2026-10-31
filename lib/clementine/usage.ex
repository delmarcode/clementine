defmodule Clementine.Usage do
  @moduledoc """
  Token accounting, accumulated from provider responses.

  Providers report usage as loosely-shaped maps; each client normalizes
  its provider's counts into the keys below, and this struct is the typed,
  additive form the rest of the system carries. Results include it on every
  terminal variant (tokens burn on failures too), checkpoints preserve it
  across suspensions, and heartbeats may piggyback it so even interrupted
  runs carry billing-grade numbers.

  - `input_tokens` is every input token the requests processed, cached or
    not.
  - `cache_read_tokens` and `cache_write_tokens` are parts of
    `input_tokens`: the tokens read from a provider's prompt cache, and
    the tokens written to it. A provider that does not report one reports
    zero. The rest of `input_tokens` is uncached input.
  - `output_tokens` is every token generated, reasoning included.

  `total/1` is input plus output, so it means the same thing with or
  without caching.
  """

  defstruct input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer()
        }

  @keys [:input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens]

  @doc """
  Builds usage from a normalized usage map (string or atom keys). Missing or
  malformed counts read as zero — usage is accounting, never a crash source.
  """
  @spec new(map() | nil) :: t()
  def new(nil), do: %__MODULE__{}

  def new(map) when is_map(map) do
    struct!(__MODULE__, Enum.map(@keys, &{&1, fetch_count(map, &1)}))
  end

  @doc "Adds two usages field-wise. The right side may be a usage map."
  @spec add(t(), t() | map() | nil) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens,
      cache_read_tokens: a.cache_read_tokens + b.cache_read_tokens,
      cache_write_tokens: a.cache_write_tokens + b.cache_write_tokens
    }
  end

  def add(%__MODULE__{} = a, other), do: add(a, new(other))

  @doc "Input plus output tokens. Cache reads and writes are parts of the input."
  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{} = usage), do: usage.input_tokens + usage.output_tokens

  @doc "JSON-safe map form, for checkpoints, the trace, and host storage."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = usage) do
    %{
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cache_read_tokens" => usage.cache_read_tokens,
      "cache_write_tokens" => usage.cache_write_tokens
    }
  end

  @doc "Rebuilds usage from `to_map/1` output. A missing key reads as zero."
  @spec from_map(map() | nil) :: t()
  def from_map(map), do: new(map)

  defp fetch_count(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end
end
