defmodule Clementine.LLM.ProviderUsage do
  @moduledoc false

  # Each wire dialect's usage object, normalized into the keys
  # `Clementine.Usage` reads: `input_tokens` is every input token the
  # request processed, and `cache_read_tokens` and `cache_write_tokens`
  # are parts of it. A count the provider did not report is left out, so
  # a stream's later usage merges over its earlier one without zeroing
  # what the earlier one said.
  #
  # A total smaller than its own cache parts is raised to their sum, so
  # uncached input never goes negative, and `[:clementine, :llm,
  # :usage_clamped]` says so: a provider that changed its convention
  # shows up there instead of being undercounted quietly. `meta`
  # (`%{provider: atom, model: String.t()}`) is that event's metadata.

  @doc """
  The Messages API's usage. Its `input_tokens` is only what came after
  the last cache breakpoint ("total_input_tokens = cache_read_input_tokens
  + cache_creation_input_tokens + input_tokens", Anthropic's prompt
  caching docs), so the cache counts are added back in.
  """
  @spec anthropic(map() | nil) :: map()
  def anthropic(usage) when is_map(usage) do
    read = count(usage, "cache_read_input_tokens")
    write = count(usage, "cache_creation_input_tokens")
    uncached = count(usage, "input_tokens")

    input =
      if Enum.any?([uncached, read, write], & &1) do
        %{
          "input_tokens" => (uncached || 0) + (read || 0) + (write || 0),
          "cache_read_tokens" => read || 0,
          "cache_write_tokens" => write || 0
        }
      else
        %{}
      end

    put_output(input, count(usage, "output_tokens"))
  end

  def anthropic(_usage), do: %{}

  @doc """
  The Responses API's usage. Its `input_tokens` already counts cached
  tokens and cache writes; `input_tokens_details` breaks them out.
  """
  @spec openai(map() | nil, map()) :: map()
  def openai(usage, meta \\ %{})

  def openai(usage, meta) when is_map(usage) do
    details = details(usage, "input_tokens_details")

    usage
    |> count("input_tokens")
    |> with_parts(count(details, "cached_tokens"), count(details, "cache_write_tokens"), meta)
    |> put_output(count(usage, "output_tokens"))
  end

  def openai(_usage, _meta), do: %{}

  @doc """
  Chat Completions usage. `prompt_tokens` counts cached tokens and cache
  writes as OpenAI's does; `prompt_tokens_details` breaks out what the
  server reports (OpenRouter both, Vertex and vLLM reads only). A LiteLLM
  proxy in front of Claude reports writes as a top-level
  `cache_creation_input_tokens` (and may report reads as
  `cache_read_input_tokens`), and its `prompt_tokens` is "all prompt
  tokens including cache-miss and cache-hit input tokens" (LiteLLM's
  prompt caching docs), so those are read as the same parts.
  """
  @spec chat_completions(map() | nil, map()) :: map()
  def chat_completions(usage, meta \\ %{})

  def chat_completions(usage, meta) when is_map(usage) do
    details = details(usage, "prompt_tokens_details")
    read = count(details, "cached_tokens") || count(usage, "cache_read_input_tokens")
    write = count(details, "cache_write_tokens") || count(usage, "cache_creation_input_tokens")

    usage
    |> count("prompt_tokens")
    |> with_parts(read, write, meta)
    |> put_output(count(usage, "completion_tokens"))
  end

  def chat_completions(_usage, _meta), do: %{}

  # A total that includes its parts.
  defp with_parts(nil, nil, nil, _meta), do: %{}

  defp with_parts(total, read, write, meta) do
    read = read || 0
    write = write || 0
    reported = total || 0

    if reported < read + write do
      :telemetry.execute(
        [:clementine, :llm, :usage_clamped],
        %{input_tokens: reported, cache_read_tokens: read, cache_write_tokens: write},
        Map.merge(%{provider: nil, model: nil}, meta)
      )
    end

    %{
      "input_tokens" => max(reported, read + write),
      "cache_read_tokens" => read,
      "cache_write_tokens" => write
    }
  end

  defp put_output(map, nil), do: map
  defp put_output(map, output), do: Map.put(map, "output_tokens", output)

  defp details(usage, key) do
    case Map.get(usage, key) do
      %{} = details -> details
      _ -> %{}
    end
  end

  defp count(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end
end
