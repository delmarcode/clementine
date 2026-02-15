defmodule Clementine.LLM.Router do
  @moduledoc """
  Routes LLM calls to the provider-specific client configured for a model.

  Models are resolved from `:clementine, :models` and must include a
  `:provider` key, for example:

      gpt_5: [provider: :openai, model: "gpt-5"]
      claude_sonnet: [provider: :anthropic, model: "claude-sonnet-4-20250514"]
  """

  @behaviour Clementine.LLM.ClientBehaviour

  @default_provider_clients [
    anthropic: Clementine.LLM.Anthropic,
    openai: Clementine.LLM.OpenAI
  ]

  @impl true
  def call(model, system, messages, tools, opts \\ []) do
    provider_client(model).call(model, system, messages, tools, opts)
  end

  @impl true
  def stream(model, system, messages, tools, opts \\ []) do
    provider_client(model).stream(model, system, messages, tools, opts)
  end

  defp provider_client(model) when is_atom(model) do
    model_config = get_model_config(model)
    provider = Keyword.get(model_config, :provider)

    if is_nil(provider) do
      raise "Model #{inspect(model)} is missing :provider in :clementine, :models"
    end

    clients = Application.get_env(:clementine, :llm_provider_clients, @default_provider_clients)

    case Keyword.get(clients, provider) do
      nil ->
        raise "No LLM client configured for provider #{inspect(provider)}"

      client when is_atom(client) ->
        client
    end
  end

  defp get_model_config(model) when is_atom(model) do
    models = Application.get_env(:clementine, :models, [])

    case Keyword.get(models, model) do
      nil -> raise "Unknown model: #{inspect(model)}. Configure it in :clementine, :models"
      config -> config
    end
  end
end
