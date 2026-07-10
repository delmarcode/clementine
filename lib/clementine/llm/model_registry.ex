defmodule Clementine.LLM.ModelRegistry do
  @moduledoc """
  Central registry for configured model aliases and direct model references.

  Supported model references:

  - Alias atom configured under `:clementine, :models` (e.g. `:claude_sonnet`)
  - Direct provider tuple (e.g. `{:openai, "gpt-5"}`)

  ## Config contract

      config :clementine, :models,
        claude_sonnet: [
          provider: :anthropic,
          id: "claude-sonnet-4-20250514",
          defaults: [max_tokens: 8192],
          reasoning: [thinking: :adaptive, effort: :high]
        ],
        gpt_5: [
          provider: :openai,
          id: "gpt-5",
          defaults: [max_output_tokens: 4096],
          reasoning: [effort: :medium]
        ],
        deepseek: [
          provider: :openrouter,
          id: "deepseek/deepseek-v3.2",
          reasoning: [effort: :high]
        ],
        qwen_finetune: [
          provider: :openai_compatible,
          base_url: "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1",
          api_key: {:system, "TINKER_API_KEY"},
          id: "tinker://my-run:train:0/sampler_weights/000080"
        ]

  `:reasoning` is provider-neutral at this level; the provider adapter
  owns the wire translation (see `Clementine.LLM.Reasoning`). Aliases are
  cheap — configure one alias per reasoning level to run the same model id
  at several levels.

  `:openrouter`, `:bedrock`, `:vertex`, and `:openai_compatible` models
  are served by the shared `Clementine.LLM.ChatCompletions` client; only
  those entries may carry `:base_url`/`:api_key` overrides (see that
  module for provider endpoint and credential configuration).
  """

  alias Clementine.LLM.Reasoning

  @providers [:anthropic, :bedrock, :openai, :openai_compatible, :openrouter, :vertex]

  # Providers served by the shared Chat Completions client; only their
  # catalog entries may carry endpoint credentials.
  @chat_completions_providers [:bedrock, :openai_compatible, :openrouter, :vertex]

  @type provider ::
          :anthropic | :bedrock | :openai | :openai_compatible | :openrouter | :vertex
  @type model_ref :: atom() | {provider(), String.t()}
  @type reasoning_config :: Reasoning.config()
  @type api_key :: String.t() | {:system, String.t()} | {module(), atom(), [term()]}

  @type resolved_model :: %{
          provider: provider(),
          id: String.t(),
          defaults: keyword(),
          reasoning: reasoning_config(),
          base_url: String.t() | nil,
          api_key: api_key() | nil,
          alias: atom() | nil
        }

  @model_schema [
    provider: [type: {:in, @providers}, required: true],
    id: [type: :string, required: true],
    defaults: [type: :keyword_list, default: []],
    reasoning: [
      type: {:custom, Reasoning, :validate_config, []},
      default: nil
    ],
    base_url: [type: :string],
    api_key: [type: {:custom, __MODULE__, :validate_api_key, []}]
  ]

  @doc false
  @spec validate_api_key(term()) :: {:ok, api_key() | nil} | {:error, String.t()}
  def validate_api_key(nil), do: {:ok, nil}
  def validate_api_key(key) when is_binary(key), do: {:ok, key}
  def validate_api_key({:system, env_var} = key) when is_binary(env_var), do: {:ok, key}

  def validate_api_key({module, function, args} = key)
      when is_atom(module) and is_atom(function) and is_list(args),
      do: {:ok, key}

  def validate_api_key(_value) do
    {:error, ~s(expected a string, {:system, "ENV_VAR"}, or {module, function, args})}
  end

  @doc """
  Validates configured model aliases. Raises on invalid configuration.
  """
  @spec validate_config!() :: :ok
  def validate_config! do
    models = Application.get_env(:clementine, :models, [])

    unless Keyword.keyword?(models) do
      raise ArgumentError,
            "Invalid :clementine, :models configuration: expected keyword list, got #{inspect(models)}"
    end

    Enum.each(models, fn
      {alias_name, config} when is_atom(alias_name) ->
        validate_model_config!(alias_name, config)
        :ok

      {alias_name, _config} ->
        raise ArgumentError,
              "Invalid :clementine, :models key #{inspect(alias_name)}: expected atom alias"

      other ->
        raise ArgumentError,
              "Invalid :clementine, :models entry: expected {alias_atom, keyword_config}, got #{inspect(other)}"
    end)

    :ok
  end

  @doc """
  Resolves a model reference to `{provider, id, defaults, reasoning}`.
  """
  @spec resolve!(model_ref()) :: resolved_model()
  def resolve!(model_ref)

  def resolve!({provider, id}) when is_atom(provider) and is_binary(id) do
    cond do
      provider not in @providers ->
        raise ArgumentError,
              "Unknown provider #{inspect(provider)} in model tuple #{inspect({provider, id})}. " <>
                "Supported providers: #{inspect(@providers)}"

      String.trim(id) == "" ->
        raise ArgumentError,
              "Invalid model tuple #{inspect({provider, id})}: model id must be a non-empty string"

      true ->
        %{
          provider: provider,
          id: id,
          defaults: [],
          reasoning: nil,
          base_url: nil,
          api_key: nil,
          alias: nil
        }
    end
  end

  def resolve!(model_alias) when is_atom(model_alias) do
    models = Application.get_env(:clementine, :models, [])

    case Keyword.get(models, model_alias) do
      nil ->
        raise ArgumentError,
              "Unknown model alias: #{inspect(model_alias)}. Configure it in :clementine, :models"

      config ->
        validated = validate_model_config!(model_alias, config)

        %{
          provider: Keyword.fetch!(validated, :provider),
          id: Keyword.fetch!(validated, :id),
          defaults: Keyword.get(validated, :defaults, []),
          reasoning: Keyword.get(validated, :reasoning),
          base_url: Keyword.get(validated, :base_url),
          api_key: Keyword.get(validated, :api_key),
          alias: model_alias
        }
    end
  end

  def resolve!(other) do
    raise ArgumentError,
          "Invalid model reference #{inspect(other)}. Expected alias atom or {provider, model_id} tuple"
  end

  defp ensure_non_empty_id!(id, context) when is_binary(id) do
    if String.trim(id) == "" do
      raise ArgumentError, "#{context}: :id must be a non-empty string"
    end

    id
  end

  defp validate_model_config!(model_alias, config) do
    validated =
      case NimbleOptions.validate(config, @model_schema) do
        {:ok, value} ->
          value

        {:error, %NimbleOptions.ValidationError{} = error} ->
          raise ArgumentError,
                "Invalid model config for #{inspect(model_alias)}: #{Exception.message(error)}"
      end

    context = model_config_context(model_alias)
    provider = Keyword.fetch!(validated, :provider)
    id = ensure_non_empty_id!(Keyword.fetch!(validated, :id), context)
    reasoning = Keyword.get(validated, :reasoning)

    ensure_endpoint_keys_supported!(validated, provider, context)

    case Reasoning.validate_model_config(provider, reasoning) do
      {:ok, _reasoning} ->
        Keyword.put(validated, :id, id)

      {:error, message} ->
        raise ArgumentError, "#{context}: :reasoning #{message}"
    end
  end

  defp ensure_endpoint_keys_supported!(validated, provider, context) do
    unless provider in @chat_completions_providers do
      Enum.each([:base_url, :api_key], fn key ->
        if Keyword.get(validated, key) do
          raise ArgumentError,
                "#{context}: #{inspect(key)} is only supported for chat completions " <>
                  "providers #{inspect(@chat_completions_providers)}"
        end
      end)
    end
  end

  defp model_config_context(model_alias) do
    "Invalid model config for #{inspect(model_alias)}"
  end
end
