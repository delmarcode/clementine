defmodule Clementine.LLM.Reasoning do
  @moduledoc """
  Normalizes provider-neutral reasoning config into provider request fields.

  Model catalog entries have a provider-neutral top-level `:reasoning` slot.
  Each provider adapter that supports reasoning owns the final wire
  translation because providers expose different controls for reasoning
  effort, token budgets, and returned reasoning content. A translation
  returns the top-level request-body fields to merge, so one config slot
  can fan out to however many body fields a provider's wire format needs.

  A bare atom or string is shorthand for the provider's effort control.

  ## Provider mapping

  - `:openai` — `%{"reasoning" => ...}` on the Responses API body. Keys:
    `:effort` (`none minimal low medium high xhigh`), `:summary` and
    `:generate_summary` (`auto concise detailed`).
  - `:anthropic` — `%{"thinking" => ..., "output_config" => ...}` on the
    Messages API body. Keys: `:effort` (`low medium high xhigh max`) →
    `output_config.effort`; `:thinking` (`adaptive enabled disabled`) →
    `thinking.type`; `:budget_tokens` (positive integer, implies
    `thinking: :enabled`) → `thinking.budget_tokens`; `:display`
    (`summarized omitted`) → `thinking.display`.
  - `:openrouter` — `%{"reasoning" => ...}`, OpenRouter's unified
    reasoning object, normalized across the models it fronts (DeepSeek,
    Qwen, GLM, ...). Keys: `:effort`
    (`none minimal low medium high xhigh max`), `:max_tokens` (positive
    integer), `:exclude` and `:enabled` (booleans).
  - `:bedrock`, `:vertex`, `:openai_compatible` —
    `%{"reasoning_effort" => ...}`, the Chat Completions dialect's
    standard effort field (`none minimal low medium high xhigh`). Only
    `:effort` is accepted; models with bespoke knobs beyond it are the
    host's affair.

  Key and enum validity are checked here, at config-validation time.
  Whether a given model accepts a given combination (`budget_tokens` is
  rejected by models that only take adaptive thinking, `effort` by models
  that predate it) is left to the provider API — Clementine keeps no
  per-model capability matrix.
  """

  @type config :: nil | atom() | String.t() | keyword() | map()
  @type provider ::
          :anthropic | :bedrock | :openai | :openai_compatible | :openrouter | :vertex

  @reasoning_providers [:anthropic, :bedrock, :openai, :openai_compatible, :openrouter, :vertex]
  @reasoning_effort_providers [:bedrock, :vertex, :openai_compatible]

  @openai_reasoning_keys ~w(effort summary generate_summary)
  @openai_reasoning_efforts ~w(none minimal low medium high xhigh)
  @openai_reasoning_summaries ~w(auto concise detailed)

  @anthropic_reasoning_keys ~w(effort thinking budget_tokens display)
  @anthropic_reasoning_efforts ~w(low medium high xhigh max)
  @anthropic_thinking_types ~w(adaptive enabled disabled)
  @anthropic_thinking_displays ~w(summarized omitted)

  @openrouter_reasoning_keys ~w(effort max_tokens exclude enabled)
  @openrouter_reasoning_efforts ~w(none minimal low medium high xhigh max)

  @doc false
  @spec validate_config(config()) :: {:ok, config()} | {:error, String.t()}
  def validate_config(nil), do: {:ok, nil}
  def validate_config(value) when is_atom(value), do: {:ok, value}
  def validate_config(value) when is_binary(value), do: {:ok, value}

  def validate_config(value) when is_list(value) do
    if Keyword.keyword?(value) do
      {:ok, value}
    else
      {:error, "expected atom, string, keyword list, or map"}
    end
  end

  def validate_config(value) when is_map(value), do: {:ok, value}
  def validate_config(_value), do: {:error, "expected atom, string, keyword list, or map"}

  @doc false
  @spec validate_model_config(atom(), config()) :: {:ok, config()} | {:error, String.t()}
  def validate_model_config(_provider, nil), do: {:ok, nil}

  def validate_model_config(provider, config) when provider in @reasoning_providers do
    with {:ok, _fields} <- to_provider_config(provider, config) do
      {:ok, config}
    end
  end

  def validate_model_config(provider, _config) do
    {:error, "is not supported by Clementine's #{inspect(provider)} adapter yet"}
  end

  @doc false
  @spec to_provider_config!(provider(), config()) :: map()
  def to_provider_config!(provider, config) do
    case to_provider_config(provider, config) do
      {:ok, value} ->
        value

      {:error, message} ->
        raise ArgumentError, message
    end
  end

  @doc false
  @spec to_provider_config(provider(), config()) :: {:ok, map()} | {:error, String.t()}
  def to_provider_config(:openai, config), do: to_openai_config(config)
  def to_provider_config(:anthropic, config), do: to_anthropic_config(config)
  def to_provider_config(:openrouter, config), do: to_openrouter_config(config)

  def to_provider_config(provider, config) when provider in @reasoning_effort_providers do
    to_reasoning_effort_config(provider_label(provider), config)
  end

  ## OpenAI

  defp to_openai_config(nil), do: {:ok, %{}}

  defp to_openai_config(effort) when is_atom(effort) or is_binary(effort) do
    with {:ok, effort} <- validate_openai_reasoning_value("effort", effort) do
      {:ok, %{"reasoning" => %{"effort" => effort}}}
    end
  end

  defp to_openai_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      with {:ok, reasoning} <- encode_openai_entries(config) do
        {:ok, wrap_openai_reasoning(reasoning)}
      end
    else
      {:error, "OpenAI reasoning config must be an atom, string, keyword list, or map"}
    end
  end

  defp to_openai_config(config) when is_map(config) do
    with {:ok, reasoning} <- encode_openai_entries(config) do
      {:ok, wrap_openai_reasoning(reasoning)}
    end
  end

  defp to_openai_config(_config) do
    {:error, "OpenAI reasoning config must be an atom, string, keyword list, or map"}
  end

  defp wrap_openai_reasoning(reasoning) when map_size(reasoning) == 0, do: %{}
  defp wrap_openai_reasoning(reasoning), do: %{"reasoning" => reasoning}

  defp encode_openai_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- normalize_key(key, "OpenAI", @openai_reasoning_keys),
           {:ok, value} <- validate_openai_reasoning_value(key, value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp validate_openai_reasoning_value("effort", value) do
    validate_enum_value("OpenAI reasoning effort", value, @openai_reasoning_efforts)
  end

  defp validate_openai_reasoning_value(key, value)
       when key in ["summary", "generate_summary"] do
    validate_enum_value("OpenAI reasoning #{key}", value, @openai_reasoning_summaries)
  end

  ## Anthropic

  defp to_anthropic_config(nil), do: {:ok, %{}}

  defp to_anthropic_config(effort) when is_atom(effort) or is_binary(effort) do
    with {:ok, effort} <-
           validate_enum_value("Anthropic reasoning effort", effort, @anthropic_reasoning_efforts) do
      {:ok, %{"output_config" => %{"effort" => effort}}}
    end
  end

  defp to_anthropic_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      encode_anthropic_entries(config)
    else
      {:error, "Anthropic reasoning config must be an atom, string, keyword list, or map"}
    end
  end

  defp to_anthropic_config(config) when is_map(config) do
    encode_anthropic_entries(config)
  end

  defp to_anthropic_config(_config) do
    {:error, "Anthropic reasoning config must be an atom, string, keyword list, or map"}
  end

  defp encode_anthropic_entries(entries) do
    normalized_result =
      Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        with {:ok, key} <- normalize_key(key, "Anthropic", @anthropic_reasoning_keys),
             {:ok, value} <- validate_anthropic_reasoning_value(key, value) do
          {:cont, {:ok, Map.put(acc, key, value)}}
        else
          {:error, message} -> {:halt, {:error, message}}
        end
      end)

    with {:ok, normalized} <- normalized_result,
         {:ok, thinking} <- anthropic_thinking_field(normalized) do
      fields =
        case normalized do
          %{"effort" => effort} -> %{"output_config" => %{"effort" => effort}}
          _ -> %{}
        end

      if thinking do
        {:ok, Map.put(fields, "thinking", thinking)}
      else
        {:ok, fields}
      end
    end
  end

  defp validate_anthropic_reasoning_value("effort", value) do
    validate_enum_value("Anthropic reasoning effort", value, @anthropic_reasoning_efforts)
  end

  defp validate_anthropic_reasoning_value("thinking", value) do
    validate_enum_value("Anthropic reasoning thinking", value, @anthropic_thinking_types)
  end

  defp validate_anthropic_reasoning_value("display", value) do
    validate_enum_value("Anthropic reasoning display", value, @anthropic_thinking_displays)
  end

  defp validate_anthropic_reasoning_value("budget_tokens", value)
       when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp validate_anthropic_reasoning_value("budget_tokens", value) do
    {:error,
     "unsupported Anthropic reasoning budget_tokens #{inspect(value)}; expected a positive integer"}
  end

  # A missing thinking type with a budget means enabled: budget_tokens only
  # exists inside the wire's enabled thinking object.
  defp anthropic_thinking_field(normalized) do
    thinking = Map.get(normalized, "thinking")
    budget = Map.get(normalized, "budget_tokens")
    display = Map.get(normalized, "display")

    case {thinking, budget} do
      {nil, nil} when display != nil ->
        {:error, anthropic_display_error()}

      {nil, nil} ->
        {:ok, nil}

      {"adaptive", nil} ->
        {:ok, put_thinking_display(%{"type" => "adaptive"}, display)}

      {"disabled", nil} when display != nil ->
        {:error, anthropic_display_error()}

      {"disabled", nil} ->
        {:ok, %{"type" => "disabled"}}

      {"enabled", nil} ->
        {:error, ~s(Anthropic reasoning thinking "enabled" requires budget_tokens)}

      {thinking, budget} when thinking in [nil, "enabled"] ->
        {:ok, put_thinking_display(%{"type" => "enabled", "budget_tokens" => budget}, display)}

      {_thinking, _budget} ->
        {:error, ~s(Anthropic reasoning budget_tokens is only supported with thinking "enabled")}
    end
  end

  defp anthropic_display_error do
    ~s(Anthropic reasoning display requires thinking "adaptive" or "enabled")
  end

  defp put_thinking_display(thinking, nil), do: thinking
  defp put_thinking_display(thinking, display), do: Map.put(thinking, "display", display)

  ## OpenRouter

  defp to_openrouter_config(nil), do: {:ok, %{}}

  defp to_openrouter_config(effort) when is_atom(effort) or is_binary(effort) do
    with {:ok, effort} <-
           validate_enum_value(
             "OpenRouter reasoning effort",
             effort,
             @openrouter_reasoning_efforts
           ) do
      {:ok, %{"reasoning" => %{"effort" => effort}}}
    end
  end

  defp to_openrouter_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      with {:ok, reasoning} <- encode_openrouter_entries(config) do
        {:ok, wrap_openrouter_reasoning(reasoning)}
      end
    else
      {:error, "OpenRouter reasoning config must be an atom, string, keyword list, or map"}
    end
  end

  defp to_openrouter_config(config) when is_map(config) do
    with {:ok, reasoning} <- encode_openrouter_entries(config) do
      {:ok, wrap_openrouter_reasoning(reasoning)}
    end
  end

  defp to_openrouter_config(_config) do
    {:error, "OpenRouter reasoning config must be an atom, string, keyword list, or map"}
  end

  defp wrap_openrouter_reasoning(reasoning) when map_size(reasoning) == 0, do: %{}
  defp wrap_openrouter_reasoning(reasoning), do: %{"reasoning" => reasoning}

  defp encode_openrouter_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- normalize_key(key, "OpenRouter", @openrouter_reasoning_keys),
           {:ok, value} <- validate_openrouter_reasoning_value(key, value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp validate_openrouter_reasoning_value("effort", value) do
    validate_enum_value("OpenRouter reasoning effort", value, @openrouter_reasoning_efforts)
  end

  defp validate_openrouter_reasoning_value("max_tokens", value)
       when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp validate_openrouter_reasoning_value("max_tokens", value) do
    {:error,
     "unsupported OpenRouter reasoning max_tokens #{inspect(value)}; expected a positive integer"}
  end

  defp validate_openrouter_reasoning_value(key, value)
       when key in ["exclude", "enabled"] do
    if is_boolean(value) do
      {:ok, value}
    else
      {:error, "unsupported OpenRouter reasoning #{key} #{inspect(value)}; expected a boolean"}
    end
  end

  ## Chat Completions reasoning_effort (Bedrock, Vertex, OpenAI-compatible)

  defp to_reasoning_effort_config(_label, nil), do: {:ok, %{}}

  defp to_reasoning_effort_config(label, effort) when is_atom(effort) or is_binary(effort) do
    with {:ok, effort} <-
           validate_enum_value("#{label} reasoning effort", effort, @openai_reasoning_efforts) do
      {:ok, %{"reasoning_effort" => effort}}
    end
  end

  defp to_reasoning_effort_config(label, config) when is_list(config) do
    if Keyword.keyword?(config) do
      encode_reasoning_effort_entries(label, config)
    else
      {:error, "#{label} reasoning config must be an atom, string, keyword list, or map"}
    end
  end

  defp to_reasoning_effort_config(label, config) when is_map(config) do
    encode_reasoning_effort_entries(label, config)
  end

  defp to_reasoning_effort_config(label, _config) do
    {:error, "#{label} reasoning config must be an atom, string, keyword list, or map"}
  end

  defp encode_reasoning_effort_entries(label, entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, _key} <- normalize_key(key, label, ~w(effort)),
           {:ok, value} <-
             validate_enum_value("#{label} reasoning effort", value, @openai_reasoning_efforts) do
        {:cont, {:ok, Map.put(acc, "reasoning_effort", value)}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp provider_label(:bedrock), do: "Bedrock"
  defp provider_label(:vertex), do: "Vertex"
  defp provider_label(:openai_compatible), do: "OpenAI-compatible"

  ## Shared validation

  defp normalize_key(key, provider_label, supported) when is_atom(key) do
    normalize_key(Atom.to_string(key), provider_label, supported)
  end

  defp normalize_key(key, provider_label, supported) when is_binary(key) do
    if key in supported do
      {:ok, key}
    else
      {:error,
       "unsupported #{provider_label} reasoning key #{inspect(key)}; expected one of #{inspect(supported)}"}
    end
  end

  defp normalize_key(key, provider_label, _supported) do
    {:error,
     "unsupported #{provider_label} reasoning key #{inspect(key)}; expected atom or string"}
  end

  defp validate_enum_value(label, value, supported) when is_atom(value) do
    validate_enum_value(label, Atom.to_string(value), supported)
  end

  defp validate_enum_value(label, value, supported) when is_binary(value) do
    if value in supported do
      {:ok, value}
    else
      {:error, "unsupported #{label} #{inspect(value)}; expected one of #{inspect(supported)}"}
    end
  end

  defp validate_enum_value(label, value, _supported) do
    {:error, "unsupported #{label} #{inspect(value)}; expected atom or string"}
  end
end
