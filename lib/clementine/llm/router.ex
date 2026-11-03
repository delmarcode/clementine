defmodule Clementine.LLM.Router do
  @moduledoc """
  Routes a call to the client for the wire its platform speaks
  (`Clementine.Platform.protocol/2`): Messages to
  `Clementine.LLM.Anthropic` (Claude on the Claude API, Bedrock, or
  Foundry), Responses to `Clementine.LLM.OpenAI`, and Chat Completions to
  `Clementine.LLM.ChatCompletions` (OpenRouter, the open models on
  Bedrock and Vertex, an OpenAI-compatible server). The platform is the
  request's `platform:` choice, else the model's default
  (`Clementine.Models.default_platform/1`).
  """

  @behaviour Clementine.LLM.ClientBehaviour
  alias Clementine.LLM.Policy
  alias Clementine.{Models, Platform}

  @clients %{
    messages: Clementine.LLM.Anthropic,
    responses: Clementine.LLM.OpenAI,
    chat_completions: Clementine.LLM.ChatCompletions
  }

  @impl true
  def call(model_ref, system, messages, tools, opts \\ []) do
    client(model_ref, opts).call(model_ref, system, messages, tools, opts)
  end

  @impl true
  def stream(model_ref, system, messages, tools, opts \\ []) do
    client(model_ref, opts).stream(model_ref, system, messages, tools, opts)
  end

  @doc false
  # Whether the platform a resolved request goes to is configured with
  # the credential its wire needs: present in config, not resolved, so
  # `{:system, "VAR"}` passes before the variable is set. Boot checks it
  # for every agent.
  @spec credential(Policy.t()) :: :ok | {:error, String.t()}
  def credential(%Policy{platform: platform, model: model}), do: Platform.check(platform, model)

  @doc false
  # Boot's credential check: `credential/1` where the app routes its
  # calls here; under another client (a test's mock), none is needed.
  @spec check_credential(Policy.t()) :: :ok | {:error, String.t()}
  def check_credential(policy) do
    if Application.get_env(:clementine, :llm_client, __MODULE__) == __MODULE__,
      do: credential(policy),
      else: :ok
  end

  # `:llm_provider_clients` (tests) sends one platform's requests to
  # another client.
  defp client(id, opts) do
    model = Models.get!(id)
    platform = Keyword.get(opts, :platform) || Models.default_platform(model)

    overrides = Application.get_env(:clementine, :llm_provider_clients, [])

    with nil <- List.keyfind(overrides, platform, 0),
         {:ok, protocol} <- protocol(model, platform) do
      Map.fetch!(@clients, protocol)
    else
      {:error, message} -> raise ArgumentError, "#{inspect(id)}: #{message}"
      {^platform, client} -> client
    end
  end

  defp protocol(model, nil),
    do:
      {:error,
       "is served on #{inspect(Keyword.keys(model.platforms))}, none of which Clementine can " <>
         "send a #{inspect(model.vendor)} model to"}

  defp protocol(model, platform) when is_atom(platform),
    do: Platform.protocol(platform, model.vendor)

  defp protocol(_model, other),
    do:
      {:error,
       "platform: takes a platform's name, an atom such as :bedrock, got: #{inspect(other)}"}
end
