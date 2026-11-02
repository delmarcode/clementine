defmodule Clementine.Cost do
  @moduledoc """
  What tokens cost, in the currency the models' prices name
  (`Clementine.LLM.Pricing`).

  A cost is an integer count of micro-units: millionths of the currency,
  so `%Clementine.Cost{currency: "USD", micros: 1_250}` is $0.00125.
  Integers add exactly, need no dependency, and survive JSON, the trace's
  jsonb, and a host's `bigint` column unchanged; a float would drift as
  costs add up, and `Decimal` comes only with the optional Ecto deps.

  `price/2` is the pure function from one call's `Clementine.Usage` and a
  model's prices (`Clementine.LLM.Pricing`) to a cost. It picks the rates
  by the call's prompt: the tier's (`over:`) when the prompt is over the
  tier's length, else the base rates. It charges each part of the usage
  at its own rate: uncached input (`input_tokens` less the cache reads
  and writes, which are parts of it), cache reads, cache writes, and
  output. It sums the parts exactly and rounds once, half up, to the
  micro-unit, so one call's cost is within half a micro-unit of the exact
  figure.

  `nil` is "no cost can be stated": a model without prices, never zero.

  ## Where costs show

  - Each trace `model_call` entry freezes its call's cost under `"cost"`,
    priced by the call's model at the prices in force when it ran, in
    this app (`Clementine.Trace`), and stored in `agent_run_trace`'s
    `cost_micros` and `currency` columns. Changing a price never reprices
    history.
  - `Clementine.Runs.cost/2` sums a run's frozen costs (`children: true`
    adds every run it started, down the tree), and
    `Clementine.Runs.subject_cost/1` every run on a subject: `nil` while a
    run's trace is behind its usage, and once a purge has taken it.
  - `[:clementine, :llm, :stop]` carries a priced call's `cost_micros`,
    and `[:clementine, :llm, :exception]` a call's a provider error ended
    (`Clementine.Telemetry`).
  - `of/3` prices one call's usage at today's prices: a trace entry's, to
    reprice it. A tiered model prices each call by its own prompt, so a
    run's summed usage (an in-process `result.usage`) prices right on an
    untiered model only; sum the calls' costs instead.
  """

  alias Clementine.LLM.Pricing
  alias Clementine.Usage

  @enforce_keys [:currency, :micros]
  defstruct [:currency, :micros]

  @type t :: %__MODULE__{currency: String.t(), micros: non_neg_integer()}

  @million 1_000_000

  @doc """
  Prices one call's `usage` at `pricing`'s rates, with `cache_write` the
  single rate for the TTL the call wrote with (`Clementine.LLM.Pricing.of/2`
  returns prices in that form). A call whose prompt, `usage.input_tokens`,
  is over the tier's `prompt_tokens` pays the tier's rates for all of it.

  Raises `ArgumentError` for prices that still name a write rate per TTL,
  as a sheet's do (`Clementine.Models.get!(id).prices`): which rate
  applies depends on the call's TTL, so reduce them with
  `Clementine.LLM.Pricing.of/2` or `Clementine.LLM.Pricing.at_ttl/2`
  first.
  """
  @spec price(Usage.t(), Pricing.t()) :: t()
  def price(%Usage{} = usage, %Pricing{cache_write: cache_write} = pricing)
      when is_integer(cache_write) do
    rates = rates(pricing, usage)
    uncached = max(usage.input_tokens - usage.cache_read_tokens - usage.cache_write_tokens, 0)

    # Tokens times micro-units per million tokens: millionths of a
    # micro-unit, exact until the one rounding.
    exact =
      uncached * rates.input +
        usage.cache_read_tokens * rates.cache_read +
        usage.cache_write_tokens * rates.cache_write +
        usage.output_tokens * rates.output

    %__MODULE__{currency: pricing.currency, micros: div(exact + div(@million, 2), @million)}
  end

  def price(%Usage{}, %Pricing{cache_write: rates}) when is_map(rates) do
    raise ArgumentError,
          "Clementine.Cost.price/2 takes prices with one cache_write rate, and these name one " <>
            "per TTL (#{inspect(Map.keys(rates))}): reduce them to the call's TTL first, with " <>
            "Clementine.LLM.Pricing.of(id, cache_ttl: ttl) or " <>
            "Clementine.LLM.Pricing.at_ttl(prices, ttl)"
  end

  # The rates a call pays: its tier's once its prompt, every input token
  # it sent (cache reads and writes are parts of input_tokens), is over the
  # tier's length, as both vendors count a prompt toward the line.
  # `Pricing.at_ttl/2` reduces the tier's write rate with the base's.
  defp rates(%Pricing{over: %{prompt_tokens: line} = tier}, usage)
       when usage.input_tokens > line,
       do: tier

  defp rates(%Pricing{} = pricing, _usage), do: pricing

  @doc """
  Prices one call's `usage` (a `Clementine.Usage`, or a usage map such as
  a trace entry's `"usage"`) at the prices the model `id` has now. `nil`
  for a model without prices, an id no sheet holds, or a platform or TTL
  the model's prices do not cover.

  - `:platform` — where the call ran (`Clementine.Platform`). Default
    the model's default platform (`Clementine.Models.default_platform/1`).
  - `:cache_ttl` — the TTL the call's writes were billed at. Default the
    model's shortest.

  A trace `:model_call` entry records both, as strings, which these take:

      Clementine.Cost.of(entry.payload["usage"], entry.payload["model"],
        platform: entry.payload["platform"],
        cache_ttl: entry.payload["cache_ttl"]
      )
  """
  @spec of(Usage.t() | map(), String.t() | map() | nil, keyword()) :: t() | nil
  def of(usage, model, opts \\ [])

  def of(%Usage{} = usage, id, opts) when is_binary(id) do
    case Pricing.of(id, opts) do
      %Pricing{} = pricing -> price(usage, pricing)
      nil -> nil
    end
  end

  # A call's model as the engine resolved it (`Clementine.Trace`), its
  # prices already at the call's TTL.
  def of(%Usage{} = usage, %{pricing: %Pricing{} = pricing}, _opts), do: price(usage, pricing)

  def of(%Usage{}, _model, _opts), do: nil

  def of(usage, model, opts) when is_map(usage), do: of(Usage.new(usage), model, opts)

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
  Nothing spent: zero in the models' currency, or `nil` when no model has
  prices. What a run that never called a model costs.
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
