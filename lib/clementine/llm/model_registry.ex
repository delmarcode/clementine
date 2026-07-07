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
          defaults: [max_tokens: 8192]
        ],
        gpt_5: [
          provider: :openai,
          id: "gpt-5",
          defaults: [max_output_tokens: 4096],
          reasoning: [effort: :medium]
        ]
  """

  alias Clementine.LLM.Reasoning

  @providers [:anthropic, :openai]

  @type provider :: :anthropic | :openai
  @type model_ref :: atom() | {provider(), String.t()}
  @type reasoning_config :: Reasoning.config()

  @type resolved_model :: %{
          provider: provider(),
          id: String.t(),
          defaults: keyword(),
          reasoning: reasoning_config(),
          alias: atom() | nil
        }

  @model_schema [
    provider: [type: {:in, @providers}, required: true],
    id: [type: :string, required: true],
    defaults: [type: :keyword_list, default: []],
    reasoning: [
      type: {:custom, Reasoning, :validate_config, []},
      default: nil
    ]
  ]

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
        %{provider: provider, id: id, defaults: [], reasoning: nil, alias: nil}
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

    case Reasoning.validate_model_config(provider, reasoning) do
      {:ok, _reasoning} ->
        Keyword.put(validated, :id, id)

      {:error, message} ->
        raise ArgumentError, "#{context}: :reasoning #{message}"
    end
  end

  defp model_config_context(model_alias) do
    "Invalid model config for #{inspect(model_alias)}"
  end
end
