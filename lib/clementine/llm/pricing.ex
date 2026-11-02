defmodule Clementine.LLM.Pricing do
  @moduledoc """
  A model's prices: the `prices:` fact of its sheet (`Clementine.Model`).

  Clementine's sheets carry each vendor's list prices, with the page they
  were read from and the date (`Clementine.Models.Anthropic`,
  `Clementine.Models.OpenAI`). An app that pays something else (a
  negotiated rate, a regional endpoint) overrides them under
  `config :clementine, :models`, and a model the app declares carries its
  own or none (`docs/MODELS.md` has the reference):

      config :clementine, :models, %{
        "claude-opus-5-5" => [
          prices: [
            currency: "USD",
            input: 3.60,
            output: 18.00,
            cache_read: 0.18,
            cache_write: [five_minutes: 4.50, one_hour: 7.20],
            source: "contract 2026-10",
            read: ~D[2026-10-15]
          ]
        ]
      }

  An override replaces `prices` whole: it names every rate, and a tier
  if it has one. `source:` and `read:` say where the numbers came from
  and when; neither is required.

  Every rate is in the named `currency` per million tokens, as a provider's
  price card states it, to six decimal places at most (a finer rate fails
  at boot rather than rounding away). A priced model names
  all four: `input` (uncached input), `output` (reasoning included),
  `cache_read`, and `cache_write`. `cache_write` is one rate, or a rate per
  cache TTL where the provider charges more to keep a cache entry longer;
  the TTL the call writes with (`billed_ttl/2`) picks one. A model that
  offers no TTL takes one rate.

  ## Tiers

  `over:` is a second set of rates for a call whose prompt is over a
  length, as Claude Haiku 5.5 bills above 100,000 tokens and the GPT-6
  family above 272,000:

      prices: [
        currency: "USD", input: 0.10, output: 0.50, cache_read: 0.01,
        cache_write: [five_minutes: 0.125, one_hour: 0.20],
        over: [prompt_tokens: 100_000, input: 0.50, output: 2.50, cache_read: 0.05,
               cache_write: [five_minutes: 0.625, one_hour: 1.00]]
      ]

  A call whose prompt is over `prompt_tokens` pays the tier's rates for
  every token it burned, output included, since both vendors price the
  whole request at the tier, not the tokens past the line. Its prompt is
  every input token it sent, cache reads and writes included
  (`Clementine.Usage`'s `input_tokens`), which is how Anthropic and OpenAI
  both count it toward the line. Each call is priced on its own. The
  tier names all four rates, and a per-TTL `cache_write` names the same
  TTLs as the base rates.

  ## What fails, and where

  A model without `prices:` costs `nil`. A partial price list, a finer
  rate, a per-TTL `cache_write` naming a TTL the model does not offer or
  missing the agent's, or a second currency fails at boot and at
  `Clementine.Agent.new/1`, never as a silent `nil` or an undercount
  mid-run. Every priced model, shipped and the app's, names the same
  currency, so costs add up: Clementine's sheets are in USD.

  Rates are held as integers, in micro-units (millionths of the currency)
  per million tokens, so `Clementine.Cost` prices usage in integer
  arithmetic.
  """

  alias Clementine.{Model, Models}

  @enforce_keys [:currency, :input, :output, :cache_read, :cache_write]
  defstruct [:currency, :input, :output, :cache_read, :cache_write, :over, :source, :read]

  @typedoc "A cache TTL a `cache_write` rate may be keyed by: `Clementine.Model`'s."
  @type ttl :: Model.ttl()

  @typedoc "A rate in micro-units of the currency per million tokens."
  @type rate :: non_neg_integer()

  @typedoc """
  The rates of a tier: what a call whose prompt is over `prompt_tokens`
  pays.
  """
  @type tier :: %{
          prompt_tokens: pos_integer(),
          input: rate(),
          output: rate(),
          cache_read: rate(),
          cache_write: rate() | %{ttl() => rate()}
        }

  @typedoc """
  A model's prices. `cache_write` is one rate, or a rate per TTL until
  `at_ttl/2` picks the call's, in the base rates and the tier alike.
  """
  @type t :: %__MODULE__{
          currency: String.t(),
          input: rate(),
          output: rate(),
          cache_read: rate(),
          cache_write: rate() | %{ttl() => rate()},
          over: tier() | nil,
          source: String.t() | nil,
          read: Date.t() | nil
        }

  @rates [:input, :output, :cache_read, :cache_write]
  @keys [:currency | @rates]
  @optional [:over, :source, :read]
  @tier_keys [:prompt_tokens | @rates]

  @micro 1_000_000

  @doc false
  # The `prices:` fact's validator in `Clementine.Model`'s schema.
  @spec validate(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def validate(nil), do: {:ok, nil}

  def validate(pricing) when is_list(pricing) do
    with :ok <- keyword(pricing, @keys),
         :ok <- known_keys(pricing, @keys ++ @optional, ""),
         :ok <- all_keys(pricing, @keys, ""),
         {:ok, currency} <- currency(Keyword.fetch!(pricing, :currency)),
         {:ok, rates} <- rates(pricing, ""),
         {:ok, over} <- over(Keyword.get(pricing, :over), rates[:cache_write]),
         {:ok, provenance} <- provenance(pricing) do
      {:ok, struct!(__MODULE__, [currency: currency, over: over] ++ rates ++ provenance)}
    end
  end

  def validate(other) do
    {:error, "expected a keyword list of #{inspect(@keys)}, got: #{inspect(other)}"}
  end

  @doc false
  # The TTLs a per-TTL `cache_write` names, so a sheet can check them
  # against the TTLs its model offers. A single rate names none.
  @spec priced_ttls(t() | nil) :: [ttl()]
  def priced_ttls(%__MODULE__{cache_write: rates}) when is_map(rates), do: Map.keys(rates)
  def priced_ttls(_pricing), do: []

  @doc false
  # What a model's prices need from the call's caching: a per-TTL
  # cache_write names the rate for the TTL the call is billed at.
  @spec validate_ttl(t() | nil, ttl() | nil) :: :ok | {:error, String.t()}
  def validate_ttl(%__MODULE__{cache_write: rates}, ttl) when is_map(rates) do
    cond do
      is_nil(ttl) ->
        {:error,
         "cache_write is per TTL, but the model offers no cache TTL its writes are billed " <>
           "at: give one cache_write rate"}

      Map.has_key?(rates, ttl) ->
        :ok

      true ->
        {:error, "cache_write names no rate for #{inspect(ttl)}, the TTL this agent writes with"}
    end
  end

  def validate_ttl(_pricing, _ttl), do: :ok

  @doc """
  The cache TTL a call to `model` (its sheet on the call's platform,
  `Clementine.Models.for_platform/2`) is billed at, given the TTL the
  agent writes with (`ttl`, `nil` with caching off): the agent's. With
  caching off, the shortest the model offers and its prices name, since
  a write the provider still makes on its own is a short one; so an
  agent with caching off runs on any priced model. `nil` for a model
  that offers no TTL.
  """
  @spec billed_ttl(Model.t(), ttl() | nil) :: ttl() | nil
  def billed_ttl(%Model{cache: %{ttls: ttls}, prices: prices}, nil) do
    priced = priced_ttls(prices)
    Enum.find(ttls, &(&1 in priced)) || List.first(ttls)
  end

  def billed_ttl(%Model{}, ttl), do: ttl

  @doc """
  `pricing` with `cache_write` reduced to the rate for `ttl`, in its base
  rates and its tier: what `Clementine.Cost.price/2` takes. `nil` for no
  prices, or a per-TTL `cache_write` with no rate for `ttl`.
  """
  @spec at_ttl(t() | nil, ttl() | nil) :: t() | nil
  def at_ttl(nil, _ttl), do: nil

  def at_ttl(%__MODULE__{} = pricing, ttl) do
    with {:ok, rate} <- write_rate(pricing.cache_write, ttl),
         {:ok, over} <- tier_at_ttl(pricing.over, ttl) do
      %{pricing | cache_write: rate, over: over}
    else
      :error -> nil
    end
  end

  defp tier_at_ttl(nil, _ttl), do: {:ok, nil}

  defp tier_at_ttl(tier, ttl) do
    with {:ok, rate} <- write_rate(tier.cache_write, ttl), do: {:ok, %{tier | cache_write: rate}}
  end

  defp write_rate(rate, _ttl) when is_integer(rate), do: {:ok, rate}
  defp write_rate(rates, ttl) when is_map(rates), do: Map.fetch(rates, ttl)

  @doc """
  The prices of the model `id` names, as they are now, reduced to the
  write rate of one TTL (`at_ttl/2`). `nil` for a model without prices,
  an id no sheet holds, a platform the model is not served on, or a TTL
  its prices name no rate for.

  - `:platform` — where the call ran: an atom, or its name as a trace
    entry stores it (`"anthropic"`). Default the model's default
    platform (`Clementine.Models.default_platform/1`), the only one a
    request goes to until `Clementine.Platform` arrives (OPS-195).
  - `:cache_ttl` — the TTL the call's writes are billed at, an atom or
    its name, as a trace `:model_call` entry records it. Default the
    model's shortest on that platform.
  """
  @spec of(String.t(), keyword()) :: t() | nil
  def of(id, opts \\ [])

  def of(id, opts) when is_binary(id) and is_list(opts) do
    with {:ok, model} <- Models.fetch(id),
         {:ok, platform} <- platform(model, Keyword.get(opts, :platform)),
         {:ok, model} <- Models.for_platform(model, platform),
         {:ok, ttl} <- ttl(model, Keyword.get(opts, :cache_ttl)) do
      at_ttl(model.prices, ttl)
    else
      _unpriced -> nil
    end
  end

  def of(_model, _opts), do: nil

  defp platform(model, nil) do
    case Models.default_platform(model) do
      nil -> :error
      platform -> {:ok, platform}
    end
  end

  defp platform(model, platform), do: named(Keyword.keys(model.platforms), platform)

  defp ttl(model, nil), do: {:ok, billed_ttl(model, nil)}
  defp ttl(model, ttl), do: named(model.cache.ttls, ttl)

  # An atom among `names`, or one's name as the trace stores it.
  defp named(names, name) when is_atom(name) do
    if name in names, do: {:ok, name}, else: :error
  end

  defp named(names, name) when is_binary(name) do
    case Enum.find(names, &(Atom.to_string(&1) == name)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  defp named(_names, _name), do: :error

  @doc """
  The currency models are priced in: the one every priced model names,
  shipped and the app's, which boot holds to one (`"USD"` unless the app
  prices every model otherwise). `nil` when no model has prices.
  """
  @spec currency() :: String.t() | nil
  def currency do
    Enum.find_value(Models.list(), fn
      %Model{prices: %__MODULE__{currency: currency}} -> currency
      _unpriced -> nil
    end)
  end

  defp keyword(pricing, keys) do
    if Keyword.keyword?(pricing),
      do: :ok,
      else: {:error, "expected a keyword list of #{inspect(keys)}, got: #{inspect(pricing)}"}
  end

  defp known_keys(pricing, keys, prefix) do
    case Keyword.keys(pricing) -- keys do
      [] -> :ok
      unknown -> {:error, "#{prefix}unknown keys #{inspect(unknown)}; it takes #{inspect(keys)}"}
    end
  end

  defp provenance(pricing) do
    source = Keyword.get(pricing, :source)
    read = Keyword.get(pricing, :read)

    cond do
      not (is_nil(source) or is_binary(source)) ->
        {:error, "source must be a string, got: #{inspect(source)}"}

      not (is_nil(read) or is_struct(read, Date)) ->
        {:error, "read must be a Date, got: #{inspect(read)}"}

      true ->
        {:ok, [source: source, read: read]}
    end
  end

  # A partial price list is a config error: a call charged for some of
  # its tokens is an undercount nobody would see.
  defp all_keys(pricing, keys, prefix) do
    case keys -- Keyword.keys(pricing) do
      [] ->
        :ok

      missing ->
        {:error,
         "#{prefix}missing #{inspect(missing)}: a priced model names its currency and all of " <>
           "#{inspect(@rates)} (a rate of 0 for what the provider does not charge)"}
    end
  end

  defp currency(currency) when is_binary(currency) do
    if currency =~ ~r/\A[A-Z]{3}\z/,
      do: {:ok, currency},
      else: {:error, "currency must be a three-letter ISO 4217 code, got: #{inspect(currency)}"}
  end

  defp currency(other),
    do: {:error, "currency must be a three-letter ISO 4217 code, got: #{inspect(other)}"}

  # The tier: a prompt length and its own four rates, its cache_write in
  # the base rates' shape, so whichever TTL a call writes at has a rate
  # on both sides of the line.
  defp over(nil, _base_write), do: {:ok, nil}

  defp over(tier, base_write) when is_list(tier) and tier != [] do
    with :ok <- keyword(tier, @tier_keys),
         :ok <- known_keys(tier, @tier_keys, "over: "),
         :ok <- all_tier_keys(tier),
         {:ok, threshold} <- threshold(Keyword.fetch!(tier, :prompt_tokens)),
         {:ok, rates} <- rates(tier, "over: "),
         :ok <- same_shape(base_write, rates[:cache_write]) do
      {:ok, Map.new([{:prompt_tokens, threshold} | rates])}
    end
  end

  defp over(other, _base_write) do
    {:error, "over: expected a keyword list of #{inspect(@tier_keys)}, got: #{inspect(other)}"}
  end

  defp all_tier_keys(tier) do
    case @tier_keys -- Keyword.keys(tier) do
      [] ->
        :ok

      missing ->
        {:error,
         "over: missing #{inspect(missing)}: a tier names the prompt length it starts above " <>
           "and all of #{inspect(@rates)}"}
    end
  end

  defp threshold(tokens) when is_integer(tokens) and tokens > 0, do: {:ok, tokens}

  defp threshold(other) do
    {:error,
     "over: prompt_tokens must be a positive integer, the prompt length the tier starts " <>
       "above, got: #{inspect(other)}"}
  end

  defp same_shape(base, tier) when is_integer(base) and is_integer(tier), do: :ok

  defp same_shape(base, tier) when is_map(base) and is_map(tier) do
    if Map.keys(base) == Map.keys(tier),
      do: :ok,
      else:
        {:error,
         "over: cache_write names TTLs #{inspect(Map.keys(tier))}, and the base rates " <>
           "#{inspect(Map.keys(base))}: a tier prices the same TTLs"}
  end

  defp same_shape(_base, _tier) do
    {:error,
     "over: cache_write is one rate where the base rates are per TTL, or the other way: " <>
       "a tier prices writes the same way"}
  end

  defp rates(pricing, prefix) do
    Enum.reduce_while(@rates, {:ok, []}, fn key, {:ok, acc} ->
      case rate(key, Keyword.fetch!(pricing, key)) do
        {:ok, rate} -> {:cont, {:ok, acc ++ [{key, rate}]}}
        {:error, message} -> {:halt, {:error, prefix <> message}}
      end
    end)
  end

  defp rate(:cache_write, per_ttl) when is_list(per_ttl) and per_ttl != [] do
    ttls = Model.ttls()

    cond do
      not Keyword.keyword?(per_ttl) ->
        {:error,
         "cache_write must be a rate or a keyword list of TTL rates, got: #{inspect(per_ttl)}"}

      (unknown = Keyword.keys(per_ttl) -- ttls) != [] ->
        {:error, "cache_write names unknown TTLs #{inspect(unknown)}; it takes #{inspect(ttls)}"}

      true ->
        Enum.reduce_while(per_ttl, {:ok, %{}}, fn {ttl, value}, {:ok, acc} ->
          case rate({:cache_write, ttl}, value) do
            {:ok, rate} -> {:cont, {:ok, Map.put(acc, ttl, rate)}}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)
    end
  end

  defp rate(_key, value) when is_integer(value) and value >= 0, do: {:ok, value * @micro}
  # A rate finer than a micro-unit per million tokens would round away,
  # silently: 0.0000003 would be free. The tolerance absorbs the float's
  # own representation error, which grows with the rate.
  defp rate(key, value) when is_float(value) and value >= 0 do
    scaled = value * @micro
    micros = round(scaled)

    if abs(scaled - micros) <= max(1.0e-6, abs(scaled) * 1.0e-12) do
      {:ok, micros}
    else
      {:error,
       "#{label(key)} #{inspect(value)} is finer than six decimal places per million " <>
         "tokens, the unit costs are counted in"}
    end
  end

  defp rate(key, value) do
    {:error,
     "#{label(key)} must be a non-negative number, per million tokens, got: #{inspect(value)}"}
  end

  defp label({:cache_write, ttl}), do: "cache_write #{inspect(ttl)}"
  defp label(key), do: Atom.to_string(key)
end
