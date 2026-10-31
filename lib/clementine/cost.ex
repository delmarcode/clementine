defmodule Clementine.Cost do
  @moduledoc """
  What tokens cost, in the currency the catalog's prices name.

  A cost is an integer count of micro-units: millionths of the currency,
  so `%Clementine.Cost{currency: "USD", micros: 1_250}` is $0.00125.
  Integers add exactly, need no dependency, and survive JSON, the trace's
  jsonb, and a host's `bigint` column unchanged; a float would drift as
  costs add up, and `Decimal` comes only with the optional Ecto deps.

  `price/2` is the pure function from `Clementine.Usage` and an alias's
  prices (`Clementine.LLM.Pricing`) to a cost. It charges each part of the
  usage at its own rate: uncached input (`input_tokens` less the cache
  reads and writes, which are parts of it), cache reads, cache writes,
  and output. It sums the parts exactly and rounds once, half up, to the
  micro-unit, so one call's cost is within half a micro-unit of the exact
  figure.

  `nil` is "no cost can be stated": a model without prices, never zero.

  ## Where costs show

  - Each trace `model_call` entry freezes its call's cost under `"cost"`,
    priced by the call's model at the prices configured when it ran
    (`Clementine.Trace`). Changing a price never reprices history.
  - `Clementine.Runs.cost/2` sums a run's frozen costs (`children: true`
    adds every run it started, down the tree), and
    `Clementine.Runs.subject_cost/1` every run on a subject: `nil` while a
    run's trace is behind its usage, and once a purge has taken it.
  - `[:clementine, :llm, :stop]` carries a priced call's `cost_micros`,
    and `[:clementine, :llm, :exception]` a call's a provider error ended
    (`Clementine.Telemetry`).
  - `of/2` prices any usage at today's prices: an in-process run's
    `result.usage`, or a trace entry's usage to reprice it.
  """

  alias Clementine.LLM.{ModelRegistry, Pricing}
  alias Clementine.Usage

  @enforce_keys [:currency, :micros]
  defstruct [:currency, :micros]

  @type t :: %__MODULE__{currency: String.t(), micros: non_neg_integer()}

  @million 1_000_000

  @doc """
  Prices `usage` at `pricing`'s rates, with `cache_write` the single rate
  for the TTL the call wrote with (`Clementine.LLM.Pricing.of/1` returns
  prices in that form).
  """
  @spec price(Usage.t(), Pricing.t()) :: t()
  def price(%Usage{} = usage, %Pricing{cache_write: cache_write} = pricing)
      when is_integer(cache_write) do
    uncached = max(usage.input_tokens - usage.cache_read_tokens - usage.cache_write_tokens, 0)

    # Tokens times micro-units per million tokens: millionths of a
    # micro-unit, exact until the one rounding.
    exact =
      uncached * pricing.input +
        usage.cache_read_tokens * pricing.cache_read +
        usage.cache_write_tokens * cache_write +
        usage.output_tokens * pricing.output

    %__MODULE__{currency: pricing.currency, micros: div(exact + div(@million, 2), @million)}
  end

  @doc """
  Prices `usage` (a `Clementine.Usage` or a usage map) at the prices the
  catalog configures for `model` now. `model` is an alias, a
  `{provider, id}` reference, or an alias as a trace entry records it (a
  string). `nil` for a model without prices, or one the catalog does not
  hold.
  """
  @spec of(Usage.t() | map(), ModelRegistry.model_ref() | String.t() | nil) :: t() | nil
  def of(usage, model) when is_binary(model) do
    of(usage, String.to_existing_atom(model))
  rescue
    ArgumentError -> nil
  end

  def of(_usage, nil), do: nil

  def of(%Usage{} = usage, model) do
    case Pricing.of(model) do
      %Pricing{} = pricing -> price(usage, pricing)
      nil -> nil
    end
  end

  def of(usage, model) when is_map(usage), do: of(Usage.new(usage), model)

  @doc """
  The total of `costs`: `nil` when any is `nil` (an unpriced call makes the
  total unknown, never an undercount) or when they are in different
  currencies. The total of none is `zero/0`.
  """
  @spec sum([t() | nil]) :: t() | nil
  def sum([]), do: zero()

  def sum([first | _rest] = costs) do
    Enum.reduce_while(costs, first && %{first | micros: 0}, fn
      %__MODULE__{currency: currency, micros: micros}, %__MODULE__{currency: currency} = acc ->
        {:cont, %{acc | micros: acc.micros + micros}}

      _unpriced_or_other_currency, _acc ->
        {:halt, nil}
    end)
  end

  @doc """
  Nothing spent: zero in the catalog's currency, or `nil` when the catalog
  prices nothing. What a run that never called a model costs.
  """
  @spec zero() :: t() | nil
  def zero do
    case Pricing.currency() do
      nil -> nil
      currency -> %__MODULE__{currency: currency, micros: 0}
    end
  end

  @doc "JSON-safe map form, as the trace stores it. `nil` stays `nil`."
  @spec to_map(t() | nil) :: map() | nil
  def to_map(nil), do: nil
  def to_map(%__MODULE__{} = cost), do: %{"currency" => cost.currency, "micros" => cost.micros}

  @doc "Reads `to_map/1`'s form back. Anything else is `nil`: no cost stated."
  @spec from_map(map() | nil) :: t() | nil
  def from_map(%{"currency" => currency, "micros" => micros})
      when is_binary(currency) and is_integer(micros) and micros >= 0,
      do: %__MODULE__{currency: currency, micros: micros}

  def from_map(_other), do: nil
end
