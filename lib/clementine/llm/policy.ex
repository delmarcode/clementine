defmodule Clementine.LLM.Policy do
  @moduledoc """
  An agent's choices for its model, checked against the model's sheet
  and resolved to what a request sends.

  The choices are the agent's (`Clementine.Agent`), or a direct
  `Clementine.LLM.call/5`'s opts:

  - `platform`: where the request goes, one of the platforms the model's
    sheet lists that Clementine can send to (`Clementine.Platform`).
    Default the vendor's own (`:anthropic`, `:openai`), else the first
    the model lists. The model's facts on that platform
    (`Clementine.Models.for_platform/2`) are what every other choice is
    checked against.
  - `max_tokens`: the output ceiling of one response, thinking included.
    Default `min(16_000, model.max_output)`; over `max_output` is an
    error.
  - `effort`: one of the model's `thinking.efforts`. Default the model's
    `default_effort`, sent explicitly; a model with none sends none. A
    declared level Clementine does not name goes to the wire as written.
  - `thinking`: `:adaptive`, `:enabled` (with
    `provider_options: [budget_tokens: n]`, at least 1,024 and below
    `max_tokens`), `:between_tools`, or `:off`,
    one of the model's `thinking.types`. Default `:adaptive` where the
    model takes it, else the model's own default. A setting the model
    refuses is an error that names what it takes instead: `:off` on a
    model that always thinks names a lower effort, or `:between_tools`
    where the model has it.
  - `display`: `:omitted`, `:summarized`, or `:updates`, for a model
    whose vendor returns thinking (`thinking.display` is not `nil`), with
    `:adaptive` or `:enabled` thinking. Default the model's own
    (`:omitted` from Claude 4.7 on, `:summarized` before), sent only when
    the agent asks for another.
  - `cache`: `true` (the default: the model's shortest TTL), `false`, or
    `[ttl: ttl]`, one of the model's `cache.ttls` on its platform.
  - `provider_options`: what one vendor's wire takes and no other does:
    `budget_tokens` and `prefix_mismatch` (`:error` or `:drop_block`)
    for Anthropic; `summary` (`:auto`, `:concise`, `:detailed`;
    `:concise` only where the sheet does not reject `:concise_summary`)
    for OpenAI; `max_tokens`, `exclude`, and `enabled` for OpenRouter's
    `reasoning`.

  A model whose sheet says it does not stream (`features.streaming:
  false`) is refused for an agent, whose runs always stream; a direct
  `Clementine.LLM.call/5` may still use it. An agent with an
  `output_schema:` is refused on a model whose sheet has no structured
  outputs (`features.structured_outputs: false`) where the request goes
  over Messages or Responses, whose clients send the schema whatever the
  sheet says. A Chat Completions platform instead withholds
  `response_format` for such a model and the engine checks the answer,
  so a declared model there keeps its output schema.

  `resolve/2` is the one check, and it runs wherever a model is named:
  the child spec at boot, the start of every run (a claim on the
  durable runtime, `Clementine.run/3` in process), and each request.
  `Clementine.Agent.new/1` runs it too, leaving out what needs a choice
  the agent left unset, since the runtime may still fill that choice
  from the module's `use` (`Clementine.Agent`).
  Every error comes from the sheet and the app's config, never from the
  date, so a node that restarts after a vendor's shutdown date still
  boots; the vendor's own error ends the run that reaches it.
  """

  alias Clementine.{Model, Models, Platform}
  alias Clementine.LLM.Pricing

  @keys [:platform, :max_tokens, :effort, :thinking, :display, :cache, :provider_options]
  @default_max_tokens 16_000
  @displays [:omitted, :summarized, :updates]

  # What one wire takes and no other does: Messages (Claude, wherever it
  # runs), Responses (OpenAI), and OpenRouter's Chat Completions.
  @provider_options %{
    messages: [
      budget_tokens: [type: :pos_integer],
      prefix_mismatch: [type: {:in, [:error, :drop_block]}]
    ],
    responses: [
      summary: [type: {:in, [:auto, :concise, :detailed]}]
    ],
    openrouter: [
      max_tokens: [type: :pos_integer],
      exclude: [type: :boolean],
      enabled: [type: :boolean]
    ]
  }

  @enforce_keys [:model, :platform, :protocol]
  defstruct [
    :model,
    :platform,
    :protocol,
    :max_tokens,
    :effort,
    :thinking,
    :display,
    :cache,
    provider_options: []
  ]

  @typedoc """
  A request's resolved choices: the model's facts on the platform it goes
  to, the wire it takes there (`Clementine.Platform.protocol/2`), and
  every choice with its default filled in. `cache` is whether
  hints go, the TTL writes are billed at (`nil` where none is sent), and
  whether `cache_control` markers carry it.
  """
  @type t :: %__MODULE__{
          model: Model.t(),
          platform: atom(),
          protocol: Clementine.Platform.protocol(),
          max_tokens: pos_integer(),
          effort: Model.effort() | nil,
          thinking: Model.thinking_type(),
          display: :omitted | :summarized | :updates | nil,
          cache: %{enabled: boolean(), ttl: Model.ttl() | nil, markers: boolean()},
          provider_options: keyword()
        }

  @doc "The choices an agent may make."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc """
  Resolves `opts` (any keyword list; only the policy's keys are read)
  for the model `id` names, or explains what the model's facts refuse.
  """
  @spec resolve(String.t() | Model.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def resolve(model, opts \\ []), do: resolve(model, opts, [])

  @doc false
  # `checks`: `partial: true` leaves out every check that needs a choice
  # `opts` leaves unset, for an agent built before the runtime fills its
  # choices from its module's `use` (`Clementine.Agent.new/1`);
  # `stream: false` is a request that does not stream (`call/5`);
  # `output_schema: true` is one whose answer has a schema.
  @spec resolve(String.t() | Model.t(), keyword(), keyword()) ::
          {:ok, t()} | {:error, String.t()}
  def resolve(%Model{} = model, opts, checks) when is_list(opts) do
    opts = Keyword.take(opts, @keys)
    partial? = Keyword.get(checks, :partial, false)
    unset = if partial?, do: unset(opts), else: []

    with :ok <- servable(model),
         {:ok, platform, protocol} <- platform(model, opts[:platform]),
         {:ok, model} <- Models.for_platform(model, platform),
         :ok <- streams(model, Keyword.get(checks, :stream, true)),
         :ok <- structured(model, protocol, Keyword.get(checks, :output_schema, false)),
         {:ok, provider_options} <-
           provider_options(model, {protocol, platform}, opts[:provider_options]),
         {:ok, thinking} <- thinking(model, opts[:thinking], provider_options, partial?),
         {:ok, effort} <- effort(model, opts[:effort], thinking, unset),
         {:ok, max_tokens} <- max_tokens(model, opts[:max_tokens]),
         :ok <- budget_fits(provider_options, max_tokens, unset),
         {:ok, display} <- display(model, opts[:display], thinking, provider_options, unset),
         {:ok, cache} <- cache(model, opts[:cache]),
         :ok <- priced(model, cache, :cache in unset) do
      {:ok,
       %__MODULE__{
         model: model,
         platform: platform,
         protocol: protocol,
         max_tokens: max_tokens,
         effort: effort,
         thinking: thinking,
         display: display,
         cache: cache,
         provider_options: provider_options
       }}
    else
      {:error, message} -> {:error, "#{inspect(model.id)}: #{message}"}
    end
  end

  def resolve(id, opts, checks) when is_list(opts) do
    with {:ok, model} <- Models.fetch(id), do: resolve(model, opts, checks)
  end

  @doc "As `resolve/2`, raising `ArgumentError`."
  @spec resolve!(String.t() | Model.t(), keyword()) :: t()
  def resolve!(model, opts \\ []), do: resolve!(model, opts, [])

  @doc false
  @spec resolve!(String.t() | Model.t(), keyword(), keyword()) :: t()
  def resolve!(model, opts, checks) do
    case resolve(model, opts, checks) do
      {:ok, policy} -> policy
      {:error, message} -> raise ArgumentError, message
    end
  end

  # The choices `opts` leaves unset, which a partial check does not
  # assume the defaults of.
  defp unset(opts), do: for(key <- @keys, is_nil(opts[key]), do: key)

  defp streams(%Model{features: %{streaming: false}}, true) do
    {:error,
     "does not stream, and an agent's runs always do; call it with " <>
       "Clementine.LLM.call/5, or pick a model that streams"}
  end

  defp streams(_model, _stream?), do: :ok

  # The Messages and Responses clients send an output schema as given; a
  # model without structured outputs answers it with a 400.
  defp structured(%Model{features: %{structured_outputs: false}} = model, protocol, true)
       when protocol in [:messages, :responses] do
    {:error,
     "has no structured outputs on #{inspect(model.platform)}, and an output_schema: goes " <>
       "there as given; pick a model whose sheet has them (features.structured_outputs), or " <>
       "leave output_schema: out and read the answer as text"}
  end

  defp structured(_model, _protocol, _schema?), do: :ok

  # A retired sheet is a fact of this Clementine release, not a date
  # passing: the vendor no longer serves it.
  defp servable(%Model{lifecycle: %{status: :retired} = lifecycle}) do
    replacement =
      if lifecycle.replacement,
        do: "; its replacement is #{inspect(lifecycle.replacement)}",
        else: ""

    {:error, "is retired#{replacement}"}
  end

  defp servable(%Model{}), do: :ok

  defp platform(model, nil) do
    case Models.default_platform(model) do
      nil ->
        {:error,
         "is served on #{inspect(Keyword.keys(model.platforms))}, none of which Clementine " <>
           "can send a #{inspect(model.vendor)} model to"}

      platform ->
        platform(model, platform)
    end
  end

  defp platform(model, platform) when is_atom(platform) do
    with :ok <- served_on(model, platform),
         {:ok, protocol} <- Platform.protocol(platform, model.vendor) do
      {:ok, platform, protocol}
    else
      {:error, message} -> {:error, "platform: #{message}"}
    end
  end

  defp platform(_model, other) do
    {:error,
     "platform: takes a platform's name, an atom such as :bedrock, got: #{inspect(other)}"}
  end

  defp served_on(model, platform) do
    if Keyword.has_key?(model.platforms, platform),
      do: :ok,
      else:
        {:error,
         "#{inspect(platform)} does not serve it; its sheet lists " <>
           inspect(Keyword.keys(model.platforms))}
  end

  defp provider_options(_model, _wire, nil), do: {:ok, []}

  defp provider_options(model, {protocol, platform}, options) when is_list(options) do
    wire = if protocol == :chat_completions, do: platform, else: protocol

    case Map.fetch(@provider_options, wire) do
      :error when options == [] ->
        {:ok, []}

      :error ->
        {:error, "provider_options: #{inspect(platform)} takes none, got: #{inspect(options)}"}

      {:ok, schema} ->
        case NimbleOptions.validate(options, schema) do
          {:ok, validated} ->
            with {:ok, validated} <- budget(model, validated), do: summary(model, validated)

          {:error, error} ->
            {:error, "provider_options: #{Exception.message(error)}"}
        end
    end
  end

  defp provider_options(_model, _wire, other) do
    {:error, "provider_options: expected a keyword list, got: #{inspect(other)}"}
  end

  defp budget(model, options) do
    cond do
      not Keyword.has_key?(options, :budget_tokens) ->
        {:ok, options}

      :budget_tokens in model.rejects or :enabled not in model.thinking.types ->
        {:error,
         "refuses provider_options: [budget_tokens: ...]: it takes thinking " <>
           "#{inspect(model.thinking.types)}; set effort: instead"}

      true ->
        {:ok, options}
    end
  end

  defp summary(model, options) do
    cond do
      options[:summary] == nil ->
        {:ok, options}

      model.thinking.types == [:off] ->
        {:error, "does not reason, so takes no provider_options: [summary: ...]"}

      options[:summary] == :concise and :concise_summary in model.rejects ->
        {:error,
         "refuses provider_options: [summary: :concise]; it takes :auto or :detailed " <>
           "(OpenAI: concise summaries are for reasoning models after gpt-5)"}

      true ->
        {:ok, options}
    end
  end

  defp thinking(model, nil, options, _partial?) do
    cond do
      Keyword.has_key?(options, :budget_tokens) -> {:ok, :enabled}
      :adaptive in model.thinking.types -> {:ok, :adaptive}
      true -> {:ok, model.thinking.default}
    end
  end

  # `use`'s provider_options merge into agent/1's key by key, so a
  # partial check never knows a budget is missing.
  defp thinking(model, type, options, partial?)
       when type in [:adaptive, :enabled, :between_tools, :off] do
    budget? = Keyword.has_key?(options, :budget_tokens)

    cond do
      type not in model.thinking.types ->
        {:error, refused_thinking(model, type)}

      type == :enabled and not budget? and partial? ->
        {:ok, type}

      type == :enabled and not budget? ->
        {:error, "thinking: :enabled needs provider_options: [budget_tokens: n]"}

      type != :enabled and budget? ->
        {:error, "provider_options: [budget_tokens: ...] goes only with thinking: :enabled"}

      true ->
        {:ok, type}
    end
  end

  defp thinking(_model, other, _options, _partial?) do
    {:error, "thinking: takes one of #{inspect(Model.thinking_types())}, got: #{inspect(other)}"}
  end

  # The error names what the model takes instead, since a silent
  # translation would change what comes back (`between_tools` is not
  # `disabled`: it still returns progress updates).
  defp refused_thinking(model, :off) do
    %{types: types, efforts: efforts} = model.thinking

    instead =
      cond do
        :between_tools in types ->
          "thinking: :between_tools thinks only between tool calls" <>
            cap(model, :between_tools) <> ", or lower the effort"

        :none in efforts ->
          "effort: :none asks for no reasoning"

        efforts != [] ->
          "it always thinks; lower the effort (effort: #{inspect(hd(efforts))})"

        true ->
          "it always thinks"
      end

    "refuses thinking: :off (it takes #{inspect(types)}): #{instead}"
  end

  defp refused_thinking(model, :adaptive) do
    types = model.thinking.types

    instead =
      if :enabled in types,
        do: "; thinking: :enabled with provider_options: [budget_tokens: n] thinks to a budget",
        else: ""

    "refuses thinking: :adaptive (it takes #{inspect(types)})#{instead}"
  end

  defp refused_thinking(model, type) do
    "refuses thinking: #{inspect(type)} (it takes #{inspect(model.thinking.types)})"
  end

  defp cap(model, type) do
    case model.thinking.max_effort do
      %{^type => effort} -> " (at effort #{inspect(effort)} or below)"
      _ -> ""
    end
  end

  # A cap ties an effort to a thinking setting, so a partial check that
  # lacks either leaves it to the run's.
  defp effort(model, nil, thinking, unset) do
    if :thinking in unset,
      do: {:ok, model.thinking.default_effort},
      else: capped(model, model.thinking.default_effort, thinking)
  end

  defp effort(model, effort, thinking, unset) do
    efforts = model.thinking.efforts

    cond do
      not is_atom(effort) or is_boolean(effort) ->
        {:error,
         "effort: takes one of the model's levels #{inspect(efforts)}, got: #{inspect(effort)}"}

      efforts == [] ->
        {:error, "takes no effort setting, got: effort: #{inspect(effort)}"}

      effort not in efforts ->
        {:error, "takes effort #{inspect(efforts)}, got: #{inspect(effort)}"}

      :thinking in unset ->
        {:ok, effort}

      true ->
        capped(model, effort, thinking)
    end
  end

  defp capped(_model, nil, _thinking), do: {:ok, nil}

  # Levels rank in the order the sheet lists them, lowest first, so a
  # declared level Clementine does not name ranks too.
  defp capped(model, effort, thinking) do
    case model.thinking.max_effort do
      %{^thinking => cap} ->
        if Model.effort_rank(model, effort) > Model.effort_rank(model, cap),
          do:
            {:error,
             "thinking: #{inspect(thinking)} takes effort up to #{inspect(cap)}, got: " <>
               inspect(effort)},
          else: {:ok, effort}

      _ ->
        {:ok, effort}
    end
  end

  defp max_tokens(model, nil), do: {:ok, min(@default_max_tokens, model.max_output)}

  defp max_tokens(model, max_tokens) when is_integer(max_tokens) and max_tokens > 0 do
    if max_tokens > model.max_output,
      do:
        {:error,
         "max_tokens: #{max_tokens} is over the model's ceiling of #{model.max_output} " <>
           "output tokens"},
      else: {:ok, max_tokens}
  end

  defp max_tokens(_model, other) do
    {:error, "max_tokens: takes a positive integer, got: #{inspect(other)}"}
  end

  # Anthropic takes 1,024 thinking tokens at the least, and fewer than
  # the response's max_tokens, which they count against.
  defp budget_fits(options, max_tokens, unset) do
    case Keyword.fetch(options, :budget_tokens) do
      {:ok, budget} when budget < 1024 ->
        {:error, "provider_options: [budget_tokens: #{budget}] is under the minimum of 1024"}

      {:ok, budget} when budget >= max_tokens ->
        if :max_tokens in unset,
          do: :ok,
          else:
            {:error,
             "provider_options: [budget_tokens: #{budget}] must be below max_tokens " <>
               "(#{max_tokens}), which thinking counts against; raise max_tokens: or lower the budget"}

      _below_or_none ->
        :ok
    end
  end

  defp display(%Model{thinking: %{display: nil}}, nil, _thinking, _options, _unset),
    do: {:ok, nil}

  defp display(%Model{thinking: %{display: nil}}, display, _thinking, _options, _unset) do
    {:error, "returns no thinking to display, got: display: #{inspect(display)}"}
  end

  defp display(model, display, thinking, options, unset) do
    explicit? = display != nil or Keyword.has_key?(options, :prefix_mismatch)

    cond do
      display != nil and display not in @displays ->
        {:error, "display: takes one of #{inspect(@displays)}, got: #{inspect(display)}"}

      explicit? and thinking not in [:adaptive, :enabled] and :thinking not in unset ->
        {:error,
         "display: and provider_options: [prefix_mismatch: ...] need thinking :adaptive or " <>
           ":enabled, got: #{inspect(thinking)}"}

      true ->
        {:ok, display || model.thinking.display}
    end
  end

  defp cache(model, setting) when setting in [nil, true], do: cache(model, [])

  defp cache(_model, false), do: {:ok, %{enabled: false, ttl: nil, markers: false}}

  defp cache(model, opts) when is_list(opts) do
    ttls = model.cache.ttls

    case Keyword.split(opts, [:ttl]) do
      {_ttl, [_ | _] = unknown} ->
        {:error, "cache: takes true, false, or [ttl: ...], got: #{inspect(unknown)}"}

      {[], []} ->
        {:ok, %{enabled: true, ttl: List.first(ttls), markers: markers?(ttls)}}

      {[ttl: ttl], []} ->
        cond do
          ttl not in ttls ->
            {:error, "cache: [ttl: #{inspect(ttl)}] is not offered; #{offered(model)}"}

          unsent?(model, ttl) ->
            {:error,
             "cache: [ttl: #{inspect(ttl)}] is not sent on #{inspect(model.platform)}, which " <>
               "writes for #{inspect(hd(ttls))}; leave the TTL out"}

          true ->
            {:ok, %{enabled: true, ttl: ttl, markers: markers?(ttls)}}
        end
    end
  end

  defp cache(_model, other) do
    {:error, "cache: takes true, false, or [ttl: ...], got: #{inspect(other)}"}
  end

  # The Chat Completions client sends no prompt_cache_options TTL (OpenAI
  # models on OpenRouter or Bedrock write for the platform's default), so
  # a longer one would be billed but never asked for.
  defp unsent?(%Model{platform: platform, cache: %{ttls: [default | _]}} = model, ttl) do
    Platform.protocol(platform, model.vendor) == {:ok, :chat_completions} and
      Model.cache_mechanism(model.cache.ttls) == :options and ttl != default
  end

  defp markers?(ttls), do: Model.cache_mechanism(ttls) == :markers

  defp offered(%Model{cache: %{ttls: []}, platform: platform}),
    do: "on #{inspect(platform)} it caches on its own, if at all, and takes no TTL"

  defp offered(%Model{cache: %{ttls: ttls}, platform: platform}),
    do: "on #{inspect(platform)} it offers #{inspect(ttls)}"

  # A price per cache TTL names the rate for the TTL the agent's writes
  # are billed at: its own, or with caching off the shortest the model
  # offers and its prices name (`Pricing.billed_ttl/2`).
  defp priced(_model, _cache, true = _cache_unset), do: :ok

  defp priced(model, cache, false) do
    case Pricing.validate_ttl(model.prices, Pricing.billed_ttl(model, cache.ttl)) do
      :ok -> :ok
      {:error, message} -> {:error, "prices: #{message}"}
    end
  end
end
