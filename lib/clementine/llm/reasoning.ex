defmodule Clementine.LLM.Reasoning do
  @moduledoc """
  Normalizes provider-neutral reasoning config into provider request fields.

  Model catalog entries have a provider-neutral top-level `:reasoning` slot.
  Each provider adapter that supports reasoning owns the final wire translation
  because providers expose different controls for reasoning effort, token
  budgets, and returned reasoning content.
  """

  @type config :: nil | atom() | String.t() | keyword() | map()

  @openai_reasoning_keys ~w(effort summary generate_summary)
  @openai_reasoning_efforts ~w(none minimal low medium high xhigh)
  @openai_reasoning_summaries ~w(auto concise detailed)

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

  def validate_model_config(:openai, config) do
    with {:ok, _wire_config} <- to_provider_config(:openai, config) do
      {:ok, config}
    end
  end

  def validate_model_config(provider, _config) do
    {:error, "is not supported by Clementine's #{inspect(provider)} adapter yet"}
  end

  @doc false
  @spec to_provider_config!(:openai, config()) :: map()
  def to_provider_config!(provider, config) do
    case to_provider_config(provider, config) do
      {:ok, value} ->
        value

      {:error, message} ->
        raise ArgumentError, message
    end
  end

  @doc false
  @spec to_provider_config(:openai, config()) :: {:ok, map()} | {:error, String.t()}
  def to_provider_config(:openai, config), do: to_openai_config(config)

  defp to_openai_config(nil), do: {:ok, %{}}

  defp to_openai_config(effort) when is_atom(effort) or is_binary(effort) do
    with {:ok, effort} <- validate_openai_reasoning_value("effort", effort) do
      {:ok, %{"effort" => effort}}
    end
  end

  defp to_openai_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      encode_openai_entries(config)
    else
      {:error, "OpenAI reasoning config must be an atom, string, keyword list, or map"}
    end
  end

  defp to_openai_config(config) when is_map(config) do
    encode_openai_entries(config)
  end

  defp to_openai_config(_config) do
    {:error, "OpenAI reasoning config must be an atom, string, keyword list, or map"}
  end

  defp encode_openai_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- normalize_openai_reasoning_key(key),
           {:ok, value} <- validate_openai_reasoning_value(key, value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp normalize_openai_reasoning_key(key) when is_atom(key) do
    normalize_openai_reasoning_key(Atom.to_string(key))
  end

  defp normalize_openai_reasoning_key(key) when is_binary(key) do
    if key in @openai_reasoning_keys do
      {:ok, key}
    else
      {:error,
       "unsupported OpenAI reasoning key #{inspect(key)}; expected one of #{inspect(@openai_reasoning_keys)}"}
    end
  end

  defp normalize_openai_reasoning_key(key) do
    {:error, "unsupported OpenAI reasoning key #{inspect(key)}; expected atom or string"}
  end

  defp validate_openai_reasoning_value("effort", value) do
    validate_openai_string_value("reasoning effort", value, @openai_reasoning_efforts)
  end

  defp validate_openai_reasoning_value(key, value)
       when key in ["summary", "generate_summary"] do
    validate_openai_string_value("reasoning #{key}", value, @openai_reasoning_summaries)
  end

  defp validate_openai_string_value(label, value, supported) when is_atom(value) do
    validate_openai_string_value(label, Atom.to_string(value), supported)
  end

  defp validate_openai_string_value(label, value, supported) when is_binary(value) do
    if value in supported do
      {:ok, value}
    else
      {:error,
       "unsupported OpenAI #{label} #{inspect(value)}; expected one of #{inspect(supported)}"}
    end
  end

  defp validate_openai_string_value(label, value, _supported) do
    {:error, "unsupported OpenAI #{label} #{inspect(value)}; expected atom or string"}
  end
end
