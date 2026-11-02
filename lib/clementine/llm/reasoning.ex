defmodule Clementine.LLM.Reasoning do
  @moduledoc """
  Translates a request's resolved thinking choices (`Clementine.LLM.Policy`)
  into each wire's fields. The policy has already checked them against
  the model's sheet, so a translation never refuses.

  - Anthropic's Messages API: `thinking` and `output_config.effort`. A
    `thinking` field goes only where the agent's choice differs from
    what the model does without one: `:off` is `{"type": "disabled"}` on
    a model that thinks by default and nothing on one that does not;
    `:adaptive` is nothing on a model that thinks adaptively by default,
    unless a `display` other than the model's default or a
    `prefix_mismatch` rides on it; `:enabled` carries its
    `budget_tokens`; `:between_tools` takes no other field. Effort goes
    whenever the policy has one, so a vendor's recalibrated default
    never moves an agent.
  - OpenAI's Responses API: `reasoning.effort` and `reasoning.summary`
    (the reference deprecates `generate_summary` for it).
  - Chat Completions: OpenRouter's `reasoning` object (`effort`, and its
    `max_tokens`, `exclude`, and `enabled`); every other platform's
    `reasoning_effort`.
  """

  alias Clementine.LLM.Policy

  @doc "The Messages API fields for `policy`."
  @spec anthropic(Policy.t()) :: map()
  def anthropic(%Policy{} = policy) do
    %{}
    |> put("thinking", anthropic_thinking(policy))
    |> put("output_config", policy.effort && %{"effort" => to_string(policy.effort)})
  end

  defp anthropic_thinking(%Policy{thinking: :off, model: %{thinking: %{default: :off}}}), do: nil
  defp anthropic_thinking(%Policy{thinking: :off}), do: %{"type" => "disabled"}
  defp anthropic_thinking(%Policy{thinking: :between_tools}), do: %{"type" => "between_tools"}

  defp anthropic_thinking(%Policy{thinking: :adaptive} = policy) do
    extras = thinking_extras(policy)

    if policy.model.thinking.default == :adaptive and extras == %{},
      do: nil,
      else: Map.put(extras, "type", "adaptive")
  end

  defp anthropic_thinking(%Policy{thinking: :enabled} = policy) do
    policy
    |> thinking_extras()
    |> Map.merge(%{
      "type" => "enabled",
      "budget_tokens" => Keyword.fetch!(policy.provider_options, :budget_tokens)
    })
  end

  # The display goes only where it is not the model's own default; the
  # binding controls only where asked for (they need a beta header).
  defp thinking_extras(%Policy{} = policy) do
    display =
      if policy.display not in [nil, policy.model.thinking.display],
        do: to_string(policy.display)

    mismatch = Keyword.get(policy.provider_options, :prefix_mismatch)

    %{}
    |> put("display", display)
    |> put("block_binding", mismatch && %{"prefix_mismatch_behavior" => to_string(mismatch)})
  end

  @doc "The Responses API fields for `policy`."
  @spec openai(Policy.t()) :: map()
  def openai(%Policy{} = policy) do
    reasoning =
      %{}
      |> put("effort", policy.effort && to_string(policy.effort))
      |> put_option(policy, :summary)

    put(%{}, "reasoning", if(reasoning != %{}, do: reasoning))
  end

  @doc "The Chat Completions fields for `policy` on its platform."
  @spec chat_completions(Policy.t()) :: map()
  def chat_completions(%Policy{platform: :openrouter} = policy) do
    reasoning =
      %{}
      |> put("effort", policy.effort && to_string(policy.effort))
      |> put_option(policy, :max_tokens)
      |> put_option(policy, :exclude)
      |> put_option(policy, :enabled)

    put(%{}, "reasoning", if(reasoning != %{}, do: reasoning))
  end

  def chat_completions(%Policy{} = policy) do
    put(%{}, "reasoning_effort", policy.effort && to_string(policy.effort))
  end

  defp put_option(map, policy, key) do
    case Keyword.fetch(policy.provider_options, key) do
      {:ok, value} when is_atom(value) and not is_boolean(value) ->
        Map.put(map, to_string(key), to_string(value))

      {:ok, value} ->
        Map.put(map, to_string(key), value)

      :error ->
        map
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
