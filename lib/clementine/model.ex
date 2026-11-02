defmodule Clementine.Model do
  @moduledoc """
  A model's fact sheet: what is true of one vendor model wherever it runs,
  keyed by the vendor's own id (`"claude-sonnet-5-5"`, `"gpt-6.1-sol"`).

  Clementine ships a sheet for each current and recent Anthropic and
  OpenAI model (`Clementine.Models.Anthropic`, `Clementine.Models.OpenAI`),
  each with the page it was read from and the date it was read. An app
  overrides a shipped fact, or declares a model Clementine does not ship,
  under `config :clementine, :models` (`Clementine.Models`). The clients
  read the sheet to decide what to send and what to withhold, and boot
  and `Clementine.Agent.new/1` check an agent's choices against it, so an
  app never encodes what a model accepts.

  ## Fields

  - `id`: the vendor's model id, as the vendor's own API takes it.
  - `vendor`: whose model it is (`:anthropic`, `:openai`, or an app's
    atom for a model it declares).
  - `line`: the family it belongs to (Anthropic's Models API `line`:
    `:haiku`, `:sonnet`, `:opus`, `:fable`, `:mythos`; OpenAI's tier:
    `:astra`, `:sol`, `:terra`, `:luna`), or `nil`. `Clementine.Models.newest/1`
    reads it.
  - `display_name`, `released_on`.
  - `lifecycle`: `status` (`:active`, `:deprecated`, or `:retired`),
    `deprecated_on`, `retires_not_before` (the date the vendor promises
    the model until), `retires_on` (a retirement or shutdown date the
    vendor has set), and `replacement` (the id the vendor names). A
    `:retired` status fails boot; a date never does.
  - `context` and `max_output`: the context window and the most output
    tokens one response may carry, thinking included. `nil` only on a
    retired sheet whose ceilings no page still lists.
  - `thinking`: `default`, what the API does with no thinking field
    (`:adaptive` or `:off`); `types`, the thinking settings it accepts
    (`:adaptive`, `:enabled` with a token budget, `:between_tools`,
    `:off`); `efforts`, the effort levels it accepts, lowest first, and
    `default_effort` (a declaration may name a level Clementine does not,
    which goes to the wire as written); `max_effort`, a thinking setting that accepts only
    efforts up to a level (`between_tools: :high`); `binding`, `:prefix`
    where the model binds each thinking block to the conversation it was
    produced after (the runtime guide's "Models that bind their
    thinking"), else `:none`; `display`, the API's default for returned
    thinking (`:omitted` or `:summarized`, `nil` where the vendor has no
    such field).
  - `rejects`: request features the API refuses on this model:
    `:temperature`, `:top_p`, `:top_k`, `:prefill`, `:forced_tool_choice`,
    `:budget_tokens`, and `:concise_summary` (OpenAI's `summary:
    :concise`).
  - `features`: `tool_search` (deferred tools go with `defer_loading`),
    `structured_outputs`, `mid_conversation_system` (a skill's load
    goes inline as a system message rather than folding into `system`
    and `tools`), and `streaming` (default `true`; an agent's runs
    always stream, so one on a model that does not is refused).
  - `cache`: `min_prefix`, the fewest tokens a cached prefix holds
    (`nil` where the vendor states none), and
    `ttls`, the cache lifetimes it offers, shortest first. Which TTLs
    decide how a request asks: `:five_minutes` and `:one_hour` are
    `cache_control` markers, `:thirty_minutes` and `:twelve_hours` are
    OpenAI's `prompt_cache_options`, and none means the provider caches
    on its own, if at all.
  - `prices`: the model's list prices, per million tokens, with their
    `source` and `read` date, and a tier (`over:`) where the vendor
    bills more above a prompt length (`Clementine.LLM.Pricing`). An app
    overrides them where it pays something else; `nil` costs `nil`.
  - `platforms`: where the model is served, each with the id it goes by
    there and how its facts differ there: `[anthropic: [id: ...],
    bedrock: [id: "anthropic.claude-...", lifecycle: :partner], ...]`.
    `:partner` marks a platform that sets its own retirement dates. A
    declared model's `openrouter`, `bedrock`, `vertex`, or
    `openai_compatible` entry may carry `base_url:` and `api_key:` until
    platforms own their endpoints (OPS-195); `inspect/2` redacts a
    literal key.
  - `source` and `read`: the page the sheet was read from, and when.

  `platform` is set only on a sheet `Clementine.Models.for_platform/2`
  merged for one platform: the platform its facts are for.
  """

  alias Clementine.LLM.Pricing

  @thinking_types [:adaptive, :enabled, :between_tools, :off]
  @efforts [:none, :minimal, :low, :medium, :high, :xhigh, :max]
  @rejects [
    :temperature,
    :top_p,
    :top_k,
    :prefill,
    :forced_tool_choice,
    :budget_tokens,
    :concise_summary
  ]
  @marker_ttls [:five_minutes, :one_hour]
  @option_ttls [:thirty_minutes, :twelve_hours]
  @ttls @marker_ttls ++ @option_ttls
  @statuses [:active, :deprecated, :retired]

  @platforms [
    :anthropic,
    :openai,
    :openrouter,
    :bedrock,
    :vertex,
    :foundry,
    :claude_on_aws,
    :openai_compatible
  ]

  @enforce_keys [:id, :vendor]
  defstruct [
    :id,
    :vendor,
    :line,
    :display_name,
    :released_on,
    :context,
    :max_output,
    :prices,
    :source,
    :read,
    :platform,
    lifecycle: %{},
    thinking: %{},
    rejects: [],
    features: %{},
    cache: %{},
    platforms: []
  ]

  @type thinking_type :: :adaptive | :enabled | :between_tools | :off
  @typedoc "An effort level: one Clementine names, or a declared model's own."
  @type effort :: :none | :minimal | :low | :medium | :high | :xhigh | :max | atom()
  @type ttl :: :five_minutes | :one_hour | :thirty_minutes | :twelve_hours
  @type platform :: atom()

  @type t :: %__MODULE__{
          id: String.t(),
          vendor: atom(),
          line: atom() | nil,
          display_name: String.t() | nil,
          released_on: Date.t() | nil,
          lifecycle: %{
            status: :active | :deprecated | :retired,
            deprecated_on: Date.t() | nil,
            retires_not_before: Date.t() | nil,
            retires_on: Date.t() | nil,
            replacement: String.t() | nil
          },
          context: pos_integer() | nil,
          max_output: pos_integer() | nil,
          thinking: %{
            default: thinking_type(),
            types: [thinking_type()],
            efforts: [effort()],
            default_effort: effort() | nil,
            max_effort: %{thinking_type() => effort()},
            binding: :prefix | :none,
            display: :omitted | :summarized | nil
          },
          rejects: [atom()],
          features: %{
            tool_search: boolean(),
            structured_outputs: boolean(),
            mid_conversation_system: boolean(),
            streaming: boolean()
          },
          cache: %{min_prefix: non_neg_integer() | nil, ttls: [ttl()]},
          prices: Pricing.t() | nil,
          platforms: [{platform(), map()}],
          source: String.t() | nil,
          read: Date.t() | nil,
          platform: platform() | nil
        }

  @date {:or, [{:struct, Date}, nil]}

  @schema [
    id: [type: :string, required: true],
    vendor: [type: :atom, required: true],
    line: [type: {:or, [:atom, nil]}, default: nil],
    display_name: [type: {:or, [:string, nil]}, default: nil],
    released_on: [type: @date, default: nil],
    lifecycle: [
      type: :keyword_list,
      default: [],
      keys: [
        status: [type: {:in, @statuses}],
        deprecated_on: [type: @date],
        retires_not_before: [type: @date],
        retires_on: [type: @date],
        replacement: [type: {:or, [:string, nil]}]
      ]
    ],
    context: [type: {:or, [:pos_integer, nil]}, default: nil],
    max_output: [type: {:or, [:pos_integer, nil]}, default: nil],
    thinking: [
      type: :keyword_list,
      default: [],
      keys: [
        default: [type: {:in, @thinking_types}],
        types: [type: {:list, {:in, @thinking_types}}],
        efforts: [type: {:list, {:custom, __MODULE__, :validate_effort, []}}],
        default_effort: [type: {:or, [{:custom, __MODULE__, :validate_effort, []}, nil]}],
        max_effort: [type: :keyword_list],
        binding: [type: {:in, [:prefix, :none]}],
        display: [type: {:in, [:omitted, :summarized, nil]}]
      ]
    ],
    rejects: [type: {:list, {:in, @rejects}}, default: []],
    features: [
      type: :keyword_list,
      default: [],
      keys: [
        tool_search: [type: :boolean],
        structured_outputs: [type: :boolean],
        mid_conversation_system: [type: :boolean],
        streaming: [type: :boolean]
      ]
    ],
    cache: [
      type: :keyword_list,
      default: [],
      keys: [
        min_prefix: [type: {:or, [:non_neg_integer, nil]}],
        ttls: [type: {:list, {:in, @ttls}}]
      ]
    ],
    prices: [type: {:custom, Pricing, :validate, []}, default: nil],
    platforms: [type: :keyword_list, required: true],
    source: [type: {:or, [:string, nil]}, default: nil],
    read: [type: @date, default: nil]
  ]

  @platform_schema [
    id: [type: :string],
    lifecycle: [type: {:in, [:partner, nil]}, default: nil],
    features: [
      type: :keyword_list,
      default: [],
      keys: [
        tool_search: [type: :boolean],
        structured_outputs: [type: :boolean],
        mid_conversation_system: [type: :boolean],
        streaming: [type: :boolean]
      ]
    ],
    cache: [
      type: :keyword_list,
      default: [],
      keys: [
        min_prefix: [type: {:or, [:non_neg_integer, nil]}],
        ttls: [type: {:list, {:in, @ttls}}]
      ]
    ],
    base_url: [type: :string],
    api_key: [type: {:custom, __MODULE__, :validate_credential, []}]
  ]

  @lifecycle_defaults %{
    status: :active,
    deprecated_on: nil,
    retires_not_before: nil,
    retires_on: nil,
    replacement: nil
  }

  @thinking_defaults %{
    default: :off,
    types: [:off],
    efforts: [],
    default_effort: nil,
    max_effort: %{},
    binding: :none,
    display: nil
  }

  @feature_defaults %{
    tool_search: false,
    structured_outputs: false,
    mid_conversation_system: false,
    streaming: true
  }
  @cache_defaults %{min_prefix: nil, ttls: []}

  # The platforms a request can go to before `Clementine.Platform`
  # (OPS-195): each has a client. The rest are facts a sheet carries.
  @served [:anthropic, :openai, :openrouter, :bedrock, :vertex, :openai_compatible]

  # Only these may carry an endpoint on the sheet, until platforms do.
  @endpoint_platforms [:openrouter, :bedrock, :vertex, :openai_compatible]

  @doc "The platforms a sheet may name."
  @spec platforms() :: [platform()]
  def platforms, do: @platforms

  @doc "The effort levels Clementine names, lowest first."
  @spec efforts() :: [effort()]
  def efforts, do: @efforts

  @doc "The thinking settings a sheet or an agent may name."
  @spec thinking_types() :: [thinking_type()]
  def thinking_types, do: @thinking_types

  @doc "The cache TTLs a sheet may offer and a price may be keyed by."
  @spec ttls() :: [ttl()]
  def ttls, do: @ttls

  @doc false
  # The platforms a request can reach today, in the order a model's
  # default is picked among them.
  @spec served() :: [platform()]
  def served, do: @served

  @doc """
  Builds a sheet from its keyword form, or explains what is wrong with it.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(sheet) when is_list(sheet) do
    with {:ok, opts} <- validate(sheet, @schema),
         {:ok, platforms} <- platforms_of(opts),
         model = build(opts, platforms),
         :ok <- consistent(model) do
      {:ok, model}
    else
      # A message may quote what failed, a literal key included.
      {:error, message} -> {:error, scrub(message, sheet)}
    end
  end

  def new(other),
    do: {:error, "expected a keyword list of facts, got: #{inspect(redact(other))}"}

  @doc "As `new/1`, raising `ArgumentError`."
  @spec new!(keyword()) :: t()
  def new!(sheet) do
    case new(sheet) do
      {:ok, model} ->
        model

      {:error, message} ->
        raise ArgumentError, "invalid model sheet #{inspect(sheet[:id])}: #{message}"
    end
  end

  @doc """
  The id `model` goes by on its platform (`Clementine.Models.for_platform/2`),
  or on `platform`: the platform entry's `id`, which defaults to the
  model's own.
  """
  @spec platform_id(t(), platform() | nil) :: String.t()
  def platform_id(%__MODULE__{} = model, platform \\ nil) do
    case model.platforms[platform || model.platform] do
      %{id: id} when is_binary(id) -> id
      _ -> model.id
    end
  end

  @doc """
  The order of `effort` among `model`'s levels, lowest first, for
  comparing two, or `nil` for a level the model does not take.
  """
  @spec effort_rank(t(), effort()) :: non_neg_integer() | nil
  def effort_rank(%__MODULE__{thinking: %{efforts: efforts}}, effort),
    do: Enum.find_index(efforts, &(&1 == effort))

  @doc false
  # Any atom but a boolean or nil: a declaration may name a vendor's new
  # level before Clementine does.
  @spec validate_effort(term()) :: {:ok, atom()} | {:error, String.t()}
  def validate_effort(effort) when is_atom(effort) and effort not in [nil, true, false],
    do: {:ok, effort}

  def validate_effort(other),
    do: {:error, "expected an effort level atom (#{inspect(@efforts)}), got: #{inspect(other)}"}

  @doc false
  # The caching mechanism a TTL list implies: `:markers`
  # (`cache_control`), `:options` (`prompt_cache_options`), or `:none`.
  @spec cache_mechanism([ttl()]) :: :markers | :options | :none
  def cache_mechanism([]), do: :none

  def cache_mechanism([ttl | _rest]) when ttl in @marker_ttls, do: :markers
  def cache_mechanism([ttl | _rest]) when ttl in @option_ttls, do: :options

  @doc false
  # `term` with every literal `api_key:` replaced, for an error message.
  @spec redact(term()) :: term()
  def redact({:api_key, key}) when is_binary(key), do: {:api_key, "**redacted**"}
  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(%{__struct__: _} = struct), do: struct

  def redact(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> redact({key, value}) end)

  def redact({key, value}), do: {key, redact(value)}
  def redact(other), do: other

  # `message` with every literal `api_key:` in `term` replaced.
  defp scrub(message, term) do
    term
    |> literal_keys()
    |> Enum.reduce(message, &String.replace(&2, &1, "**redacted**"))
  end

  defp literal_keys({:api_key, key}) when is_binary(key) and key != "", do: [key]
  defp literal_keys(list) when is_list(list), do: Enum.flat_map(list, &literal_keys/1)
  defp literal_keys(%{__struct__: _}), do: []
  defp literal_keys(map) when is_map(map), do: Enum.flat_map(map, &literal_keys/1)
  defp literal_keys({_key, value}), do: literal_keys(value)
  defp literal_keys(_other), do: []

  @doc false
  @spec validate_credential(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_credential(key) when is_binary(key), do: {:ok, key}
  def validate_credential({:system, env} = key) when is_binary(env), do: {:ok, key}

  def validate_credential({module, function, args} = key)
      when is_atom(module) and is_atom(function) and is_list(args),
      do: {:ok, key}

  def validate_credential(other) do
    {:error,
     ~s(expected a string, {:system, "ENV_VAR"}, or {module, function, args}, got: ) <>
       inspect(other)}
  end

  defp validate(opts, schema) do
    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
    end
  end

  defp platforms_of(opts) do
    platforms = Keyword.fetch!(opts, :platforms)

    cond do
      platforms == [] ->
        {:error, "platforms: names none; a model is served somewhere"}

      (unknown = Keyword.keys(platforms) -- @platforms) != [] ->
        {:error,
         "platforms: names #{inspect(unknown)}, which Clementine does not know; it knows " <>
           inspect(@platforms)}

      true ->
        platforms
        |> Enum.reduce_while({:ok, []}, fn {name, entry}, {:ok, acc} ->
          case platform_entry(name, entry) do
            {:ok, entry} -> {:cont, {:ok, [{name, entry} | acc]}}
            {:error, message} -> {:halt, {:error, "platforms: #{inspect(name)}: #{message}"}}
          end
        end)
        |> then(fn
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          error -> error
        end)
    end
  end

  defp platform_entry(name, entry) when is_list(entry) do
    with {:ok, validated} <- validate(entry, @platform_schema),
         :ok <- endpoint_allowed(name, validated) do
      {:ok,
       validated
       |> Map.new()
       |> Map.update!(:features, &Map.new/1)
       |> Map.update!(:cache, &Map.new/1)}
    end
  end

  defp platform_entry(_name, other),
    do:
      {:error,
       "expected a keyword list (id:, lifecycle:, features:, cache:), got: " <>
         inspect(redact(other))}

  defp endpoint_allowed(name, entry) do
    if name not in @endpoint_platforms and
         (Keyword.has_key?(entry, :base_url) or Keyword.has_key?(entry, :api_key)) do
      {:error,
       "base_url: and api_key: go only on #{inspect(@endpoint_platforms)}; " <>
         "#{inspect(name)} takes its endpoint from app config"}
    else
      :ok
    end
  end

  defp build(opts, platforms) do
    %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      vendor: Keyword.fetch!(opts, :vendor),
      line: opts[:line],
      display_name: opts[:display_name],
      released_on: opts[:released_on],
      lifecycle: Map.merge(@lifecycle_defaults, Map.new(opts[:lifecycle])),
      context: opts[:context],
      max_output: opts[:max_output],
      thinking: thinking(opts[:thinking]),
      rejects: opts[:rejects],
      features: Map.merge(@feature_defaults, Map.new(opts[:features])),
      cache: Map.merge(@cache_defaults, Map.new(opts[:cache])),
      prices: opts[:prices],
      platforms: platforms,
      source: opts[:source],
      read: opts[:read]
    }
  end

  defp thinking(opts) do
    thinking = Map.merge(@thinking_defaults, Map.new(opts))
    %{thinking | max_effort: Map.new(thinking.max_effort)}
  end

  defp consistent(%__MODULE__{} = model) do
    thinking = model.thinking

    cond do
      model.lifecycle.status != :retired and (is_nil(model.context) or is_nil(model.max_output)) ->
        {:error, "context: and max_output: are required on a model that is not retired"}

      thinking.default not in thinking.types ->
        {:error,
         "thinking: default #{inspect(thinking.default)} is not among its types " <>
           inspect(thinking.types)}

      thinking.default_effort && thinking.default_effort not in thinking.efforts ->
        {:error,
         "thinking: default_effort #{inspect(thinking.default_effort)} is not among its " <>
           "efforts #{inspect(thinking.efforts)}"}

      bad = Enum.find(thinking.max_effort, &bad_cap?(&1, thinking)) ->
        {:error,
         "thinking: max_effort #{inspect(bad)} names a type or effort the model does not take"}

      length(Enum.uniq(Enum.map(model.cache.ttls, &(&1 in @marker_ttls)))) > 1 ->
        {:error,
         "cache: ttls mixes cache_control TTLs #{inspect(@marker_ttls)} with " <>
           "prompt_cache_options TTLs #{inspect(@option_ttls)}"}

      true ->
        :ok
    end
  end

  defp bad_cap?({type, effort}, thinking),
    do: type not in thinking.types or effort not in thinking.efforts
end

defimpl Inspect, for: Clementine.Model do
  # A declared model's platform entry may hold a literal API key until
  # platforms own their credentials (OPS-195); inspecting the model, or a
  # policy or error that carries it, never prints it.
  def inspect(%Clementine.Model{} = model, opts) do
    platforms =
      Enum.map(model.platforms, fn
        {name, %{api_key: key} = entry} when is_binary(key) ->
          {name, %{entry | api_key: "**redacted**"}}

        other ->
          other
      end)

    Inspect.Any.inspect(%{model | platforms: platforms}, opts)
  end
end
