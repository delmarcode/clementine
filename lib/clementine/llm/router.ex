defmodule Clementine.LLM.Router do
  @moduledoc """
  Routes LLM calls to the provider-specific client configured for a model.

  Models are resolved from `:clementine, :models` and must include a
  `:provider` key, for example:

      gpt_5: [provider: :openai, id: "gpt-5", defaults: [max_output_tokens: 4096]]
      claude_sonnet: [provider: :anthropic, id: "claude-sonnet-4-20250514", defaults: [max_tokens: 8192]]

  Direct references are also supported:

      {:openai, "gpt-5"}
  """

  @behaviour Clementine.LLM.ClientBehaviour
  alias Clementine.LLM.ModelRegistry

  @default_provider_clients [
    anthropic: Clementine.LLM.Anthropic,
    openai: Clementine.LLM.OpenAI
  ]

  @impl true
  def call(model_ref, system, messages, tools, opts \\ []) do
    provider_client(model_ref).call(model_ref, system, messages, tools, opts)
  end

  @impl true
  def stream(model_ref, system, messages, tools, opts \\ []) do
    provider_client(model_ref).stream(model_ref, system, messages, tools, opts)
  end

  defp provider_client(model_ref) do
    provider = ModelRegistry.resolve!(model_ref).provider

    clients = Application.get_env(:clementine, :llm_provider_clients, @default_provider_clients)

    case Keyword.get(clients, provider) do
      nil ->
        raise "No LLM client configured for provider #{inspect(provider)}"

      client when is_atom(client) ->
        client
    end
  end
end
