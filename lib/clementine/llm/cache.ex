defmodule Clementine.LLM.Cache do
  @moduledoc """
  Prompt caching: the catalog's per-alias `cache:` key, and the key that
  keeps a run's requests on one cache.

  Caching is on by default. Each client sends what its provider needs
  (`docs/MODELS.md` has the table), and every client reports cache reads
  and writes in `Clementine.Usage`. An alias changes the default with
  `cache:`:

      config :clementine, :models,
        claude_sonnet: [provider: :anthropic, id: "claude-sonnet-5", cache: [ttl: :one_hour]],
        classifier: [provider: :anthropic, id: "claude-haiku-5-5", cache: false],
        proxied_claude: [
          provider: :openai_compatible,
          base_url: "https://llm-proxy.internal/v1",
          id: "claude-sonnet-5",
          cache: [markers: true]
        ]

  - `cache: false` sends no cache hints. A provider that caches on its
    own (OpenAI, DeepSeek, vLLM) still does; on GPT-5.6 and later,
    Clementine turns that off too.
  - `ttl:` how long a cache write lives, which sets its price. Each
    provider takes its own durations: `:five_minutes` (the default) or
    `:one_hour` where `cache_control` markers go (Anthropic, and
    Anthropic models through OpenRouter or a proxy); `:thirty_minutes`
    (the default) or `:twelve_hours` on OpenAI's GPT-5.6 and later.
  - `markers:` for the Chat Completions providers: whether to send
    Anthropic-style `cache_control` markers. OpenRouter sends them to
    `anthropic/` models by default; `:openai_compatible` sends none
    unless asked, for a proxy that fronts Claude. Bedrock and Vertex
    take none.

  Validation runs at boot with the rest of the alias, and a value the
  provider cannot honour raises there.
  """

  @ttls %{
    five_minutes: "5m",
    one_hour: "1h",
    thirty_minutes: "30m",
    twelve_hours: "12h"
  }

  @marker_ttls [:five_minutes, :one_hour]
  @openai_ttls [:thirty_minutes, :twelve_hours]

  @type ttl :: :five_minutes | :one_hour | :thirty_minutes | :twelve_hours
  @type config :: boolean() | keyword()

  @typedoc """
  An alias's resolved caching: whether hints go at all, the TTL its cache
  writes are billed at (`nil` where Clementine sends none and the
  provider documents none), and whether `cache_control` markers go.
  """
  @type t :: %{enabled: boolean(), ttl: ttl() | nil, markers: boolean()}

  @doc false
  # The catalog schema's custom validator: the shape only. What each
  # provider accepts is checked by `resolve/3`, which knows the provider.
  @spec validate_config(term()) :: {:ok, config()} | {:error, String.t()}
  def validate_config(value) when is_boolean(value), do: {:ok, value}

  def validate_config(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.reduce_while(value, {:ok, value}, fn
        {:ttl, ttl}, acc when is_map_key(@ttls, ttl) ->
          {:cont, acc}

        {:ttl, ttl}, _acc ->
          {:halt,
           {:error,
            "expected :ttl to be one of #{inspect(Map.keys(@ttls))}, got: #{inspect(ttl)}"}}

        {:markers, markers}, acc when is_boolean(markers) ->
          {:cont, acc}

        {:markers, markers}, _acc ->
          {:halt, {:error, "expected :markers to be a boolean, got: #{inspect(markers)}"}}

        {key, _value}, _acc ->
          {:halt, {:error, "unknown key #{inspect(key)}; it takes :ttl and :markers"}}
      end)
    else
      shape_error(value)
    end
  end

  def validate_config(value), do: shape_error(value)

  defp shape_error(value) do
    {:error,
     "expected true, false, or a keyword list of :ttl and :markers, got: #{inspect(value)}"}
  end

  @doc false
  # Resolves an alias's `cache:` value for its provider and model id, or
  # explains why the provider cannot honour it.
  @spec resolve(atom(), String.t(), config()) :: {:ok, t()} | {:error, String.t()}
  def resolve(_provider, _id, false), do: {:ok, %{enabled: false, ttl: nil, markers: false}}
  def resolve(provider, id, true), do: resolve(provider, id, [])

  def resolve(provider, id, opts) when is_list(opts) do
    with {:ok, markers} <- markers(provider, id, Keyword.fetch(opts, :markers)),
         {:ok, ttl} <- ttl(provider, id, markers, Keyword.fetch(opts, :ttl)) do
      {:ok, %{enabled: true, ttl: ttl, markers: markers}}
    end
  end

  # Anthropic always marks its own requests; OpenAI has no markers to send.
  defp markers(:anthropic, _id, :error), do: {:ok, true}
  defp markers(:openai, _id, :error), do: {:ok, false}
  defp markers(:openrouter, id, :error), do: {:ok, String.starts_with?(id, "anthropic/")}
  defp markers(:openai_compatible, _id, :error), do: {:ok, false}
  defp markers(provider, _id, :error) when provider in [:bedrock, :vertex], do: {:ok, false}

  defp markers(provider, _id, {:ok, markers}) when provider in [:openrouter, :openai_compatible],
    do: {:ok, markers}

  defp markers(provider, _id, {:ok, _markers}) do
    {:error,
     ":markers is only for :openrouter and :openai_compatible; #{inspect(provider)} " <>
       "decides its own (see docs/MODELS.md)"}
  end

  defp ttl(:openai, id, _markers, setting) do
    cond do
      not prompt_cache_options?(id) and setting == :error ->
        {:ok, nil}

      not prompt_cache_options?(id) ->
        {:error,
         ":ttl needs GPT-5.6 or later on :openai, where prompt_cache_options is " <>
           "documented; #{inspect(id)} keeps its own retention"}

      true ->
        pick_ttl(:openai, setting, @openai_ttls, :thirty_minutes)
    end
  end

  defp ttl(_provider, _id, true, setting),
    do: pick_ttl(:markers, setting, @marker_ttls, :five_minutes)

  defp ttl(_provider, _id, false, :error), do: {:ok, nil}

  defp ttl(provider, _id, false, {:ok, _ttl}) do
    {:error,
     ":ttl needs cache_control markers, and #{inspect(provider)} sends none for this " <>
       "model; set markers: true where the server takes them"}
  end

  defp pick_ttl(_kind, :error, _allowed, default), do: {:ok, default}

  defp pick_ttl(kind, {:ok, ttl}, allowed, _default) do
    if ttl in allowed do
      {:ok, ttl}
    else
      where = if kind == :openai, do: "on :openai", else: "with cache_control markers"
      {:error, "expected :ttl #{where} to be one of #{inspect(allowed)}, got: #{inspect(ttl)}"}
    end
  end

  @doc false
  # Whether an OpenAI model id documents `prompt_cache_options`: GPT-5.6
  # and later ("Supported for gpt-5.6 and later models", the Responses
  # API reference, read 2026-10-30). Ids are `gpt-<major>[.<minor>]...`.
  @spec prompt_cache_options?(String.t()) :: boolean()
  def prompt_cache_options?(id) when is_binary(id) do
    case Regex.run(~r/^gpt-(\d+)(?:\.(\d+))?/, id) do
      [_, major] -> String.to_integer(major) >= 6
      [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)} >= {5, 6}
      nil -> false
    end
  end

  @doc false
  # The wire value of a TTL: `cache_control.ttl` or `prompt_cache_options.ttl`.
  @spec wire_ttl(ttl()) :: String.t()
  def wire_ttl(ttl), do: Map.fetch!(@ttls, ttl)

  @doc false
  # An Anthropic-style `cache_control` value. The 5-minute TTL is the
  # API's default and goes without a `ttl` field, which some platforms
  # refuse for models that have only that TTL.
  @spec cache_control(t()) :: map()
  def cache_control(%{ttl: :one_hour}), do: %{"type" => "ephemeral", "ttl" => "1h"}
  def cache_control(%{}), do: %{"type" => "ephemeral"}

  @doc """
  The key that keeps one lane's requests on one cache, or `nil`.

  A run on the durable runtime is keyed by its agent and subject (a
  thread's turns share their conversation's key), or by its agent and run
  when it has no subject. The key is a hash, so no host id reaches the
  provider, and two tenants never share one. An in-process run with
  neither gets no key, and the provider routes by the prompt's prefix.
  """
  @spec key(map()) :: String.t() | nil
  def key(%{agent_key: agent} = context) when is_binary(agent) do
    case context do
      %{subject_type: type, subject_id: id} when not is_nil(type) and not is_nil(id) ->
        hash([agent, "subject", to_string(type), to_string(id)])

      %{run_id: run_id} when not is_nil(run_id) ->
        hash([agent, "run", to_string(run_id)])

      _ ->
        nil
    end
  end

  def key(_context), do: nil

  defp hash(parts) do
    digest = :crypto.hash(:sha256, Enum.join(parts, <<0>>))
    "clementine-" <> binary_part(Base.encode16(digest, case: :lower), 0, 32)
  end
end
