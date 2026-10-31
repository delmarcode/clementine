defmodule Clementine.LLM.Pricing do
  @moduledoc """
  A catalog alias's prices: the `pricing:` key of its entry in
  `config :clementine, :models` (`docs/MODELS.md` has the reference).

      claude_sonnet: [
        provider: :anthropic,
        id: "claude-sonnet-5",
        pricing: [
          currency: "USD",
          input: 2.00,
          output: 10.00,
          cache_read: 0.20,
          cache_write: [five_minutes: 2.50, one_hour: 4.00]
        ]
      ]

  (Illustrative numbers, not anyone's current prices.)

  Every rate is in the named `currency` per million tokens, as a provider's
  price card states it, to six decimal places at most (a finer rate fails
  at boot rather than rounding away). A priced alias names
  all four: `input` (uncached input), `output` (reasoning included),
  `cache_read`, and `cache_write`. `cache_write` is one rate, or a rate per
  cache TTL where the provider charges more to keep a cache entry longer;
  the TTL the alias writes with (its resolved `cache.ttl`, `cache_ttl/1`)
  picks one. An alias whose writes carry no TTL (caching off, or a
  provider that names none) takes one rate.

  Prices are the host's: Clementine ships none, so it never ships a stale
  one. An alias without `pricing:` costs `nil`. A partial price list, or a
  per-TTL `cache_write` without the rate for the alias's TTL, fails at
  boot, never as a silent `nil` or an undercount mid-run. Every priced alias
  names the same currency, so costs across a catalog add up.

  Rates are held as integers, in micro-units (millionths of the currency)
  per million tokens, so `Clementine.Cost` prices usage in integer
  arithmetic.
  """

  alias Clementine.LLM.ModelRegistry

  @enforce_keys [:currency, :input, :output, :cache_read, :cache_write]
  defstruct [:currency, :input, :output, :cache_read, :cache_write]

  @typedoc "A cache TTL a `cache_write` rate may be keyed by: `Clementine.LLM.Cache`'s."
  @type ttl :: Clementine.LLM.Cache.ttl()

  @typedoc "A rate in micro-units of the currency per million tokens."
  @type rate :: non_neg_integer()

  @typedoc """
  An alias's prices. `cache_write` is one rate, or a rate per TTL until
  `of/1` picks the alias's.
  """
  @type t :: %__MODULE__{
          currency: String.t(),
          input: rate(),
          output: rate(),
          cache_read: rate(),
          cache_write: rate() | %{ttl() => rate()}
        }

  @rates [:input, :output, :cache_read, :cache_write]
  @keys [:currency | @rates]

  # Clementine.LLM.Cache's TTLs, every provider's.
  @ttls [:five_minutes, :one_hour, :thirty_minutes, :twelve_hours]

  @micro 1_000_000

  @doc false
  # The `pricing:` key's validator in `ModelRegistry`'s schema.
  @spec validate(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def validate(nil), do: {:ok, nil}

  def validate(pricing) when is_list(pricing) do
    with :ok <- keyword(pricing),
         :ok <- known_keys(pricing),
         :ok <- all_keys(pricing),
         {:ok, currency} <- currency(Keyword.fetch!(pricing, :currency)),
         {:ok, rates} <- rates(pricing) do
      {:ok, struct!(__MODULE__, [{:currency, currency} | rates])}
    end
  end

  def validate(other) do
    {:error, "expected a keyword list of #{inspect(@keys)}, got: #{inspect(other)}"}
  end

  @doc false
  # What boot checks of a resolved alias beyond its own key: a per-TTL
  # cache_write names the rate for the TTL the alias writes with.
  @spec validate_for_model(ModelRegistry.resolved_model()) :: :ok | {:error, String.t()}
  def validate_for_model(%{pricing: %__MODULE__{cache_write: rates}} = model)
      when is_map(rates) do
    case cache_ttl(model) do
      nil ->
        {:error,
         "cache_write is per TTL, but this alias's cache writes carry no TTL (caching is off, " <>
           "or the provider names none): give one cache_write rate"}

      ttl ->
        if Map.has_key?(rates, ttl),
          do: :ok,
          else:
            {:error,
             "cache_write names no rate for #{inspect(ttl)}, the TTL this alias writes with"}
    end
  end

  def validate_for_model(_model), do: :ok

  @doc """
  The prices of `model`, a model reference or a resolved model, with
  `cache_write` reduced to the rate for its cache TTL: what
  `Clementine.Cost.price/2` takes. `nil` for a model without prices, a
  direct `{provider, id}` reference, or a reference the catalog does not
  hold.
  """
  @spec of(ModelRegistry.model_ref() | ModelRegistry.resolved_model()) :: t() | nil
  def of(%{pricing: nil}), do: nil

  def of(%{pricing: %__MODULE__{cache_write: rate} = pricing}) when is_integer(rate), do: pricing

  def of(%{pricing: %__MODULE__{cache_write: rates} = pricing} = model) do
    case Map.fetch(rates, cache_ttl(model)) do
      {:ok, rate} -> %{pricing | cache_write: rate}
      :error -> nil
    end
  end

  def of(model_ref) do
    model_ref |> ModelRegistry.resolve!() |> of()
  rescue
    ArgumentError -> nil
  end

  @doc """
  The cache TTL a resolved `model` writes with, which its writes are billed
  at: `cache.ttl`, with the provider's default filled in, or `nil` where
  no TTL applies. The one place pricing reads the catalog's cache key.
  """
  @spec cache_ttl(map()) :: ttl() | nil
  def cache_ttl(%{cache: %{ttl: ttl}}), do: ttl
  def cache_ttl(_model), do: nil

  @doc """
  The currency the catalog prices in, or `nil` when no alias has prices.
  Boot checks that every priced alias names the same one.
  """
  @spec currency() :: String.t() | nil
  def currency do
    :clementine
    |> Application.get_env(:models, [])
    |> Enum.find_value(fn {_alias, entry} ->
      with true <- Keyword.keyword?(entry),
           pricing when is_list(pricing) <- Keyword.get(entry, :pricing),
           {:ok, %__MODULE__{currency: currency}} <- validate(pricing) do
        currency
      else
        _unpriced -> nil
      end
    end)
  end

  defp keyword(pricing) do
    if Keyword.keyword?(pricing),
      do: :ok,
      else: {:error, "expected a keyword list of #{inspect(@keys)}, got: #{inspect(pricing)}"}
  end

  defp known_keys(pricing) do
    case Keyword.keys(pricing) -- @keys do
      [] -> :ok
      unknown -> {:error, "unknown keys #{inspect(unknown)}; pricing takes #{inspect(@keys)}"}
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
         "missing #{inspect(missing)}: a priced alias names its currency and all of " <>
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
