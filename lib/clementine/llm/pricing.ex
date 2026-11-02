defmodule Clementine.LLM.Pricing do
  @moduledoc """
  A model's prices: the `prices:` fact of its sheet, which an app sets in
  `config :clementine, :models` (`docs/MODELS.md` has the reference).

      config :clementine, :models, %{
        "claude-sonnet-5" => [
          prices: [
            currency: "USD",
            input: 2.00,
            output: 10.00,
            cache_read: 0.20,
            cache_write: [five_minutes: 2.50, one_hour: 4.00],
            source: "https://platform.claude.com/docs/en/about-claude/pricing",
            read: ~D[2026-11-01]
          ]
        ]
      }

  (Illustrative numbers, not anyone's current prices.) `source:` and
  `read:` say where the numbers came from and when; neither is required.

  Every rate is in the named `currency` per million tokens, as a provider's
  price card states it, to six decimal places at most (a finer rate fails
  at boot rather than rounding away). A priced model names
  all four: `input` (uncached input), `output` (reasoning included),
  `cache_read`, and `cache_write`. `cache_write` is one rate, or a rate per
  cache TTL where the provider charges more to keep a cache entry longer;
  the TTL the agent writes with (its resolved `cache.ttl`, `cache_ttl/1`)
  picks one. Prices belong to the model and caching to the agent, so an
  agent with caching off runs on a model with per-TTL prices, and any
  writes its provider still reports are priced at the shortest TTL the
  prices name. A model that offers no TTL takes one rate.

  Prices are the host's for now: Clementine's sheets carry none yet. A
  model without `prices:` costs `nil`. A partial price list, or a per-TTL
  `cache_write` without the rate for an agent's TTL, fails at boot and at
  `Clementine.Agent.new/1`, never as a silent `nil` or an undercount
  mid-run. Every priced model names the same currency, so costs add up.

  Rates are held as integers, in micro-units (millionths of the currency)
  per million tokens, so `Clementine.Cost` prices usage in integer
  arithmetic.
  """

  alias Clementine.LLM.Policy

  @enforce_keys [:currency, :input, :output, :cache_read, :cache_write]
  defstruct [:currency, :input, :output, :cache_read, :cache_write, :source, :read]

  @typedoc "A cache TTL a `cache_write` rate may be keyed by: `Clementine.LLM.Cache`'s."
  @type ttl :: Clementine.LLM.Cache.ttl()

  @typedoc "A rate in micro-units of the currency per million tokens."
  @type rate :: non_neg_integer()

  @typedoc """
  A model's prices. `cache_write` is one rate, or a rate per TTL until
  `of/1` picks the agent's.
  """
  @type t :: %__MODULE__{
          currency: String.t(),
          input: rate(),
          output: rate(),
          cache_read: rate(),
          cache_write: rate() | %{ttl() => rate()},
          source: String.t() | nil,
          read: Date.t() | nil
        }

  @rates [:input, :output, :cache_read, :cache_write]
  @keys [:currency | @rates]
  @provenance [:source, :read]

  # Clementine.LLM.Cache's TTLs, every provider's.
  @ttls [:five_minutes, :one_hour, :thirty_minutes, :twelve_hours]
  @by_duration [:five_minutes, :thirty_minutes, :one_hour, :twelve_hours]

  @micro 1_000_000

  @doc false
  # The `prices:` fact's validator in `Clementine.Model`'s schema.
  @spec validate(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def validate(nil), do: {:ok, nil}

  def validate(pricing) when is_list(pricing) do
    with :ok <- keyword(pricing),
         :ok <- known_keys(pricing),
         :ok <- all_keys(pricing),
         {:ok, currency} <- currency(Keyword.fetch!(pricing, :currency)),
         {:ok, rates} <- rates(pricing),
         {:ok, provenance} <- provenance(pricing) do
      {:ok, struct!(__MODULE__, [{:currency, currency} | rates] ++ provenance)}
    end
  end

  def validate(other) do
    {:error, "expected a keyword list of #{inspect(@keys)}, got: #{inspect(other)}"}
  end

  @doc false
  # What a model's prices need from the agent's caching: a per-TTL
  # cache_write names the rate for the TTL the agent writes with.
  @spec validate_for_model(%{pricing: t() | nil, cache: map()}) :: :ok | {:error, String.t()}
  def validate_for_model(%{cache: %{enabled: false}}), do: :ok

  def validate_for_model(%{pricing: %__MODULE__{cache_write: rates}} = model)
      when is_map(rates) do
    case cache_ttl(model) do
      nil ->
        {:error,
         "cache_write is per TTL, but the model offers no TTL to write at: give one " <>
           "cache_write rate"}

      ttl ->
        if Map.has_key?(rates, ttl),
          do: :ok,
          else:
            {:error,
             "cache_write names no rate for #{inspect(ttl)}, the TTL this agent writes with"}
    end
  end

  def validate_for_model(_model), do: :ok

  @doc """
  The prices of `model`, a model id (at the default caching) or a call's
  resolved model (`%{pricing: ..., cache: ...}`), with `cache_write`
  reduced to the rate for its cache TTL: what `Clementine.Cost.price/2`
  takes. `nil` for a model without prices, or an id no sheet holds.
  """
  @spec of(String.t() | map()) :: t() | nil
  def of(%{pricing: nil}), do: nil

  def of(%{pricing: %__MODULE__{cache_write: rate} = pricing}) when is_integer(rate), do: pricing

  def of(%{pricing: %__MODULE__{cache_write: rates} = pricing} = model) do
    case Map.fetch(rates, cache_ttl(model) || shortest(rates)) do
      {:ok, rate} -> %{pricing | cache_write: rate}
      :error -> nil
    end
  end

  def of(id) when is_binary(id) do
    case Policy.resolve(id) do
      {:ok, policy} -> of(%{pricing: policy.model.prices, cache: policy.cache})
      {:error, _message} -> nil
    end
  end

  def of(_model), do: nil

  # With caching off a call asks for no TTL; writes a provider reports
  # anyway are priced at the shortest.
  defp shortest(rates), do: Enum.find(@by_duration, &Map.has_key?(rates, &1))

  @doc """
  The cache TTL a resolved `model` writes with, which its writes are billed
  at: `cache.ttl`, with the model's default filled in, or `nil` where
  no TTL applies. The one place pricing reads the agent's caching.
  """
  @spec cache_ttl(map()) :: ttl() | nil
  def cache_ttl(%{cache: %{ttl: ttl}}), do: ttl
  def cache_ttl(_model), do: nil

  @doc """
  The currency models are priced in, or `nil` when none has prices. Boot
  checks that every priced model names the same one.
  """
  @spec currency() :: String.t() | nil
  def currency do
    # Read as `Clementine.Models` reads the config (an unset or nil key is
    # no models), and from each model as it merges, so a price is found
    # wherever the model's facts carry it.
    Enum.find_value(Clementine.Models.config!(), fn {id, _facts} ->
      case Clementine.Models.fetch(id) do
        {:ok, %{prices: %__MODULE__{currency: currency}}} -> currency
        _unpriced_or_invalid -> nil
      end
    end)
  end

  defp keyword(pricing) do
    if Keyword.keyword?(pricing),
      do: :ok,
      else: {:error, "expected a keyword list of #{inspect(@keys)}, got: #{inspect(pricing)}"}
  end

  defp known_keys(pricing) do
    case Keyword.keys(pricing) -- (@keys ++ @provenance) do
      [] ->
        :ok

      unknown ->
        {:error, "unknown keys #{inspect(unknown)}; prices take #{inspect(@keys ++ @provenance)}"}
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
  defp all_keys(pricing) do
    case @keys -- Keyword.keys(pricing) do
      [] ->
        :ok

      missing ->
        {:error,
         "missing #{inspect(missing)}: a priced model names its currency and all of " <>
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

  defp rates(pricing) do
    Enum.reduce_while(@rates, {:ok, []}, fn key, {:ok, acc} ->
      case rate(key, Keyword.fetch!(pricing, key)) do
        {:ok, rate} -> {:cont, {:ok, [{key, rate} | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp rate(:cache_write, per_ttl) when is_list(per_ttl) and per_ttl != [] do
    cond do
      not Keyword.keyword?(per_ttl) ->
        {:error,
         "cache_write must be a rate or a keyword list of TTL rates, got: #{inspect(per_ttl)}"}

      (unknown = Keyword.keys(per_ttl) -- @ttls) != [] ->
        {:error, "cache_write names unknown TTLs #{inspect(unknown)}; it takes #{inspect(@ttls)}"}

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
