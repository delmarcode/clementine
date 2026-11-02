defmodule Clementine.Models do
  @moduledoc """
  The models an app can run: the fact sheets Clementine ships
  (`Clementine.Models.Anthropic`, `Clementine.Models.OpenAI`), with the
  app's overrides and declarations from `config :clementine, :models`
  merged over them.

  ## Overrides and declarations

  `config :clementine, :models` maps a model id to facts. An id
  Clementine ships is an override, merged over its sheet; any other id
  is a model the app declares, and carries what the clients need:

      config :clementine, :models, %{
        # Override: the app's own prices for a shipped model (a
        # negotiated rate); the sheet's list prices are replaced whole.
        "claude-opus-5-5" => [
          prices: [currency: "USD", input: 3.60, output: 18.00, cache_read: 0.18,
                   cache_write: [five_minutes: 4.50, one_hour: 7.20],
                   source: "contract 2026-10", read: ~D[2026-10-15]]
        ],
        # Declaration: an open model on OpenRouter.
        "deepseek/deepseek-v3.2" => [
          vendor: :deepseek,
          context: 163_840,
          max_output: 16_000,
          thinking: [default: :adaptive, types: [:adaptive], efforts: [:low, :medium, :high]],
          platforms: [openrouter: []]
        ]
      }

  An override merges key by key into `lifecycle`, `thinking`, `features`,
  `cache`, and each entry of `platforms`, and replaces any other fact
  (`prices` whole, so an override of a sheet with a tier restates its
  `over:` or clears it with `over: nil`). A declaration needs `vendor`,
  `context`, `max_output`, and `platforms`; the rest default to a model
  that does not think, binds nothing, has no structured outputs, and
  caches on its own (`Clementine.Model`). `docs/MODELS.md` has every key.

  ## A new model the day it ships

  A declaration with `based_on:` starts from a shipped sheet: the base's
  facts, the declaration's merged over them as an override's are, under
  the new id. What names the base model itself does not carry over: its
  `display_name`, `released_on`, `lifecycle`, `prices`, `source`, and
  `read`. It keeps the base's platforms, each under the new id as that
  platform's scheme gives it (`anthropic.<id>` on Bedrock, the id itself
  elsewhere) unless the declaration gives one. A retired sheet is no
  base; its replacement is:

      config :clementine, :models, %{
        "claude-sonnet-6" => [
          based_on: "claude-sonnet-5-5",
          display_name: "Claude Sonnet 6",
          released_on: ~D[2027-01-12],
          thinking: [default_effort: :medium]
        ]
      }

  The next Clementine release ships the model's own sheet, and the
  declaration can go.

  An id with no sheet and no declaration is an error wherever it is
  named: at `Clementine.Agent.new/1`, at boot, and at request time. A
  `use Clementine.Agent` builds its agent at compile time, when only
  compile-time config is read, so there an id it does not know is left
  to boot: a model declared in `config/runtime.exs` compiles.

  Config is read when a model is asked for, so a test may change it. A
  process keeps the last model it built for each declared or overridden
  id, and builds it again only when that id's config changes.
  """

  alias Clementine.LLM.Pricing
  alias Clementine.Model
  alias Clementine.Models.{Anthropic, OpenAI}

  @shipped_sheets Anthropic.sheets() ++ OpenAI.sheets()
  @sheets Map.new(@shipped_sheets, &{Keyword.fetch!(&1, :id), &1})
  # Built at compile time, so a malformed shipped sheet fails the build.
  @shipped Map.new(@shipped_sheets, &{Keyword.fetch!(&1, :id), Model.new!(&1)})
  @order Enum.map(@shipped_sheets, &Keyword.fetch!(&1, :id))
  @shipped_read @shipped_sheets |> Enum.map(&Keyword.fetch!(&1, :read)) |> Enum.max(Date)

  # Facts an override merges into key by key; every other fact it
  # replaces.
  @nested [:lifecycle, :thinking, :features, :cache]

  # The facts of a `based_on:` base that name the base model itself.
  @identity [:display_name, :released_on, :lifecycle, :prices, :source, :read]

  @doc """
  The model `id` names, with the app's override merged in, or `nil` for
  an id neither shipped nor declared.
  """
  @spec get(String.t()) :: Model.t() | nil
  def get(id) do
    case fetch(id) do
      {:ok, model} -> model
      {:error, _message} -> nil
    end
  end

  @doc "As `get/1`, raising `ArgumentError` for an unknown id."
  @spec get!(String.t()) :: Model.t()
  def get!(id) do
    case fetch(id) do
      {:ok, model} -> model
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  The model `id` names, or why there is none: an unknown id (with the
  nearest known ones), or a declaration or override that is malformed.
  """
  @spec fetch(term()) :: {:ok, Model.t()} | {:error, String.t()}
  def fetch(id) when is_binary(id) do
    config = config!()

    case {Map.fetch(@sheets, id), Map.fetch(config, id)} do
      {{:ok, _sheet}, :error} ->
        {:ok, Map.fetch!(@shipped, id)}

      {{:ok, sheet}, {:ok, facts}} ->
        memo(id, facts, fn ->
          with :ok <- tier_restated(id, sheet, facts), do: build(id, &override(sheet, &1), facts)
        end)

      {:error, {:ok, facts}} ->
        memo(id, facts, fn -> declare(id, facts) end)

      {:error, :error} ->
        {:error, unknown(id, config)}
    end
  end

  def fetch(other) do
    {:error,
     "a model is named by its id, a string such as \"claude-sonnet-5-5\"; got: #{inspect(other)}"}
  end

  @doc """
  Every model, shipped and declared, filtered by `opts`: `line:`,
  `vendor:`, `lifecycle:` (a status), and `platform:` (a platform the
  model is served on). Shipped models come in the order their vendor
  modules list them, declared ones after, by id.
  """
  @spec list(keyword()) :: [Model.t()]
  def list(opts \\ []) do
    config = config!()
    declared = config |> Map.keys() |> Enum.reject(&Map.has_key?(@sheets, &1)) |> Enum.sort()

    for id <- @order ++ declared,
        {:ok, model} <- [fetch(id)],
        matches?(model, opts),
        do: model
  end

  @doc """
  The active model in `line` released last, or `nil`. A model with no
  release date counts as older than any with one; two on the same day
  go by the order their vendor module lists them.
  """
  @spec newest(atom()) :: Model.t() | nil
  def newest(line) do
    [line: line, lifecycle: :active]
    |> list()
    |> Enum.with_index()
    |> Enum.max_by(
      fn {model, index} ->
        {Date.to_gregorian_days(model.released_on || ~D[0000-01-01]), -index}
      end,
      fn -> nil end
    )
    |> case do
      {model, _index} -> model
      nil -> nil
    end
  end

  @doc """
  `model` (or the model `id` names) on `platform`: its facts with the
  platform's deltas merged in, and `platform` set, so
  `Clementine.Model.platform_id/1` gives the id it goes by there.
  """
  @spec for_platform(Model.t() | String.t(), atom()) :: {:ok, Model.t()} | {:error, String.t()}
  def for_platform(id, platform) when is_binary(id) do
    with {:ok, model} <- fetch(id), do: for_platform(model, platform)
  end

  def for_platform(%Model{} = model, platform) do
    case model.platforms[platform] do
      nil ->
        {:error,
         "#{inspect(model.id)} is not served on #{inspect(platform)}; its platforms are " <>
           inspect(Keyword.keys(model.platforms))}

      entry ->
        {:ok,
         %{
           model
           | platform: platform,
             features: Map.merge(model.features, entry.features),
             cache: Map.merge(model.cache, entry.cache)
         }}
    end
  end

  @doc """
  The platform a request for `model` goes to: the vendor's own where the
  model lists it, else the first platform it lists that Clementine can
  send to, else `nil`. An agent's `platform:` choice arrives with
  `Clementine.Platform`.
  """
  @spec default_platform(Model.t()) :: atom() | nil
  def default_platform(%Model{} = model) do
    listed = Keyword.keys(model.platforms)

    if model.vendor in Model.served() and model.vendor in listed,
      do: model.vendor,
      else: Enum.find(listed, &(&1 in Model.served()))
  end

  @doc """
  Checks `config :clementine, :models`: every override and declaration
  builds, every declared model names a platform Clementine can send to,
  and every priced model, shipped and the app's, names one currency.
  Raises `ArgumentError` naming the id. `Clementine.Application` calls it
  at boot.
  """
  @spec validate_config!() :: :ok
  def validate_config! do
    config = config!()

    Enum.each(config, fn {id, facts} ->
      case fetch(id) do
        {:ok, model} ->
          if is_list(facts) and Keyword.has_key?(facts, :prices), do: priced_ttls!(model)

          unless default_platform(model) do
            raise ArgumentError,
                  "Invalid :clementine, :models entry #{inspect(model.id)}: it is served on " <>
                    "#{inspect(Keyword.keys(model.platforms))}, and Clementine can send to " <>
                    "#{inspect(Model.served())}"
          end

        {:error, message} ->
          raise ArgumentError, message
      end
    end)

    currencies!()
  end

  # A per-TTL price the app writes names only TTLs the model offers, so
  # no rate is written that no agent could write at. (A shipped sheet's
  # name its own TTLs; an override that narrows them leaves the rates for
  # the rest unused.)
  defp priced_ttls!(model) do
    case Pricing.priced_ttls(model.prices) -- model.cache.ttls do
      [] ->
        :ok

      extra ->
        raise ArgumentError,
              "Invalid :clementine, :models entry #{inspect(model.id)}: prices: cache_write " <>
                "names #{inspect(extra)}, which the model does not offer " <>
                "(#{inspect(model.cache.ttls)})"
    end
  end

  # Costs add up only in one currency. Clementine's sheets are in USD, so
  # an app that pays in another prices every model it runs in it, and
  # sets `prices: nil` on the rest.
  defp currencies! do
    priced = for %Model{prices: %{currency: currency}} = model <- list(), do: {currency, model.id}

    case priced |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      [_two, _or_more | _rest] = currencies ->
        examples =
          Enum.map_join(currencies, ", ", fn currency ->
            "#{inspect(currency)} on #{priced |> List.keyfind(currency, 0) |> elem(1) |> inspect()}"
          end)

        raise ArgumentError,
              "Invalid :clementine, :models configuration: every priced model names one " <>
                "currency, so their costs add up; got #{examples}. Clementine's sheets are " <>
                "priced in USD: price every model in one currency, or set prices: nil on " <>
                "those you do not"

      _one_or_none ->
        :ok
    end
  end

  @doc """
  The model ids the app offers: the ones a tenant or an eval may pick
  where the app builds agents from data (stored rows) rather than
  declaring each one's model on `use Clementine.Agent`. The offer is the
  app's; `config :clementine, :offer` points Clementine at it, as a list
  of ids or a `{module, function, args}` that returns one:

      config :clementine, :offer, {MyApp.Models, :offered, []}

  `{Clementine, ...}` checks each offered id when it starts, as it checks
  an agent's model with the model's defaults (an unknown or retired id
  fails boot), and warns for each as for an agent's
  (`Clementine.Models.Warnings`); `mix clementine.models` reports each
  beside the agents. Without the config the offer is empty.
  """
  @spec offered() :: [String.t()]
  def offered do
    case Application.get_env(:clementine, :offer) do
      nil ->
        []

      {module, function, args} = mfa
      when is_atom(module) and is_atom(function) and is_list(args) ->
        module |> apply(function, args) |> offered!("#{inspect(mfa)} returned")

      ids ->
        offered!(ids, "config :clementine, :offer is")
    end
  end

  defp offered!(ids, what) do
    if is_list(ids) and Enum.all?(ids, &is_binary/1) do
      Enum.uniq(ids)
    else
      raise ArgumentError,
            "#{what} #{inspect(ids)}; the offer is a list of model ids " <>
              ~s|(["claude-sonnet-5-5", ...]), or a {module, function, args} that returns one|
    end
  end

  @doc false
  # The newest `read` date among the sheets this release ships.
  @spec shipped_read() :: Date.t()
  def shipped_read, do: @shipped_read

  @doc false
  # Whether `id` names a shipped sheet or a model the app's config (as
  # read now) overrides or declares.
  @spec known?(term()) :: boolean()
  def known?(id), do: Map.has_key?(@sheets, id) or Map.has_key?(config!(), id)

  @doc false
  # The app's overrides and declarations, as config holds them.
  @spec config!() :: %{String.t() => keyword()}
  def config! do
    case Application.get_env(:clementine, :models) do
      nil ->
        %{}

      config when is_map(config) ->
        config

      other ->
        raise ArgumentError,
              "Invalid :clementine, :models configuration: expected a map from model id to " <>
                "facts (%{\"claude-sonnet-5-5\" => [...]}), got: #{inspect(other)}"
    end
  end

  # Building a sheet from config validates every fact, which costs about
  # a hundred times a shipped lookup; a request names its model twice
  # (the router, then the client). The process keeps the last build per
  # id, keyed by that id's config term.
  defp memo(id, facts, build) do
    key = {__MODULE__, id}

    case Process.get(key) do
      {^facts, result} ->
        result

      _stale_or_none ->
        result = build.()
        Process.put(key, {facts, result})
        result
    end
  end

  defp declare(id, facts) do
    with true <- Keyword.keyword?(facts),
         {base, facts} when not is_nil(base) <- Keyword.pop(facts, :based_on) do
      case is_binary(base) && Map.fetch(@sheets, base) do
        {:ok, sheet} ->
          case Keyword.get(sheet, :lifecycle, [])[:status] do
            :retired ->
              {:error,
               "Invalid :clementine, :models entry #{inspect(id)}: based_on: names " <>
                 "#{inspect(base)}, which is retired; base it on its replacement, " <>
                 inspect(Keyword.fetch!(sheet, :lifecycle)[:replacement])}

            _servable ->
              build(id, &(sheet |> based_on(id) |> override(&1)), facts)
          end

        _unknown ->
          {:error,
           "Invalid :clementine, :models entry #{inspect(id)}: based_on: names " <>
             "#{inspect(base)}, which is not a shipped sheet (#{inspect(hd(@order))}, say)"}
      end
    else
      _plain -> build(id, &Keyword.put(&1, :id, id), facts)
    end
  end

  # A shipped sheet as the base of a new id: its facts, without the ones
  # that name the base model, on the same platforms under the new id as
  # each platform's scheme gives it (`Clementine.Models.Anthropic`):
  # Bedrock's Messages endpoint takes `anthropic.<id>`, every other
  # platform the id itself (a new Claude model is dateless on Vertex).
  defp based_on(sheet, id) do
    vendor = Keyword.fetch!(sheet, :vendor)

    sheet
    |> Keyword.drop(@identity)
    |> Keyword.put(:id, id)
    |> Keyword.update!(:platforms, fn platforms ->
      Enum.map(platforms, fn
        {:bedrock, entry} when vendor == :anthropic ->
          {:bedrock, Keyword.put(entry, :id, "anthropic." <> id)}

        {name, entry} ->
          {name, Keyword.delete(entry, :id)}
      end)
    end)
  end

  defp build(id, merge, facts) when is_list(facts) do
    if Keyword.keyword?(facts) and Keyword.get(facts, :id, id) == id do
      case Model.new(merge.(facts)) do
        {:ok, model} ->
          {:ok, model}

        {:error, message} ->
          {:error, "Invalid :clementine, :models entry #{inspect(id)}: #{message}"}
      end
    else
      build(id, merge, :not_keyword)
    end
  end

  defp build(id, _merge, facts) do
    {:error,
     "Invalid :clementine, :models entry #{inspect(id)}: expected a keyword list of facts " <>
       "(and no other id:), got: #{inspect(Model.redact(facts))}"}
  end

  # An override replaces `prices` whole, so one that leaves out the
  # sheet's tier would price every long call at the base rates, a 5x
  # undercount on Haiku 5.5 that nobody sees. It restates the tier, or
  # clears it with `over: nil`.
  defp tier_restated(id, sheet, facts) do
    with true <- Keyword.keyword?(facts),
         prices when is_list(prices) <- Keyword.get(facts, :prices),
         true <- Keyword.keyword?(prices),
         false <- Keyword.has_key?(prices, :over),
         shipped when is_list(shipped) <- Keyword.get(sheet, :prices),
         [_ | _] = tier <- Keyword.get(shipped, :over) do
      {:error,
       "Invalid :clementine, :models entry #{inspect(id)}: prices: the shipped prices bill a " <>
         "call over #{tier[:prompt_tokens]} prompt tokens at a higher tier (over:), and an " <>
         "override replaces prices whole: restate the tier, or write over: nil if your rates " <>
         "have none"}
    else
      _no_tier_dropped -> :ok
    end
  end

  defp override(sheet, facts) do
    Keyword.merge(sheet, facts, fn
      key, base, own when key in @nested -> merge_keyword(base, own)
      :platforms, base, own -> merge_platforms(base, own)
      _key, _base, own -> own
    end)
  end

  defp merge_keyword(base, own) when is_list(base) and is_list(own) do
    if Keyword.keyword?(own), do: Keyword.merge(base, own), else: own
  end

  defp merge_keyword(_base, own), do: own

  defp merge_platforms(base, own) when is_list(own) do
    Keyword.merge(base, own, fn _platform, base_entry, own_entry ->
      Keyword.merge(base_entry, own_entry, fn
        key, b, o when key in [:features, :cache] -> merge_keyword(b, o)
        _key, _b, o -> o
      end)
    end)
  end

  defp merge_platforms(_base, own), do: own

  defp matches?(model, opts) do
    Enum.all?(opts, fn
      {:line, line} -> model.line == line
      {:vendor, vendor} -> model.vendor == vendor
      {:lifecycle, status} -> model.lifecycle.status == status
      {:platform, platform} -> Keyword.has_key?(model.platforms, platform)
    end)
  end

  defp unknown(id, config) do
    known = @order ++ Map.keys(config)

    nearest =
      known
      |> Enum.uniq()
      |> Enum.sort_by(&String.jaro_distance(&1, id), :desc)
      |> Enum.take(3)

    "unknown model #{inspect(id)}: Clementine ships no sheet for it and " <>
      "config :clementine, :models declares none. Nearest known: " <>
      Enum.map_join(nearest, ", ", &inspect/1) <>
      ". Declare a model Clementine lacks under config :clementine, :models (docs/MODELS.md)."
  end
end
