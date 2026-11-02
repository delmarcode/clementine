defmodule Clementine.LLM.Router do
  @moduledoc """
  Routes a call to the client for the platform its model is served on
  (`Clementine.Models.default_platform/1`): `"claude-sonnet-5-5"` to
  `Clementine.LLM.Anthropic`, `"gpt-6.1-sol"` to `Clementine.LLM.OpenAI`,
  and a model an app declares on OpenRouter, Bedrock, Vertex, or an
  OpenAI-compatible server to `Clementine.LLM.ChatCompletions`.
  """

  @behaviour Clementine.LLM.ClientBehaviour
  alias Clementine.Models

  @default_provider_clients [
    anthropic: Clementine.LLM.Anthropic,
    openai: Clementine.LLM.OpenAI,
    openrouter: Clementine.LLM.ChatCompletions,
    bedrock: Clementine.LLM.ChatCompletions,
    vertex: Clementine.LLM.ChatCompletions,
    openai_compatible: Clementine.LLM.ChatCompletions
  ]

  @impl true
  def call(model_ref, system, messages, tools, opts \\ []) do
    provider_client(model_ref).call(model_ref, system, messages, tools, opts)
  end

  @impl true
  def stream(model_ref, system, messages, tools, opts \\ []) do
    provider_client(model_ref).stream(model_ref, system, messages, tools, opts)
  end

  @doc false
  # Whether the platform a resolved request goes to has a credential
  # configured: present in config, not resolved, so `{:system, "VAR"}`
  # passes before the variable is set. Boot checks it for every agent.
  @spec credential(Clementine.LLM.Policy.t()) :: :ok | {:error, String.t()}
  def credential(%Clementine.LLM.Policy{platform: :openai_compatible}), do: :ok

  def credential(%Clementine.LLM.Policy{platform: platform, model: model}) do
    key = credential_key(platform)
    declared = model.platforms |> Keyword.get(platform, %{}) |> Map.get(:api_key)

    if declared || Application.get_env(:clementine, key) do
      :ok
    else
      {:error,
       "#{inspect(model.id)} goes to #{inspect(platform)}, and config :clementine, " <>
         "#{key}: is not set"}
    end
  end

  defp credential_key(:anthropic), do: :anthropic_api_key
  defp credential_key(:openai), do: :openai_api_key
  defp credential_key(platform), do: Clementine.LLM.ChatCompletions.api_key_config(platform)

  defp provider_client(model) do
    provider = model |> Models.get!() |> Models.default_platform()

    clients = Application.get_env(:clementine, :llm_provider_clients, @default_provider_clients)

    case Keyword.get(clients, provider) do
      nil ->
        raise "No LLM client configured for provider #{inspect(provider)}"

      client when is_atom(client) ->
        client
    end
  end
end
