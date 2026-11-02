defmodule Clementine.LLM.Cache do
  @moduledoc """
  Prompt caching on the wire, and the key that keeps a run's requests on
  one cache.

  Caching is on by default. An agent's `cache:` choice (`true`, `false`,
  or `[ttl: ...]`) is checked against its model's `cache.ttls` on its
  platform (`Clementine.LLM.Policy`), and the TTLs a sheet offers decide
  how a request asks (`Clementine.Model`): `:five_minutes` and
  `:one_hour` are `cache_control` markers (Anthropic, and Claude behind
  OpenRouter or a proxy); `:thirty_minutes` and `:twelve_hours` are
  OpenAI's `prompt_cache_options` (GPT-5.6 and later), where `cache:
  false` sends `mode: "explicit"` with no breakpoints, which turns
  caching and its write charge off; a model that offers none caches on
  its own, if at all, and gets no hints. `docs/MODELS.md` has the table,
  and every client reports cache reads and writes in `Clementine.Usage`.
  """

  @ttls %{
    five_minutes: "5m",
    one_hour: "1h",
    thirty_minutes: "30m",
    twelve_hours: "12h"
  }

  @type ttl :: Clementine.Model.ttl()

  @typedoc """
  A request's resolved caching (`Clementine.LLM.Policy`): whether hints
  go at all, the TTL its cache writes are billed at (`nil` where none is
  sent), and whether `cache_control` markers carry it.
  """
  @type t :: %{enabled: boolean(), ttl: ttl() | nil, markers: boolean()}

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
  The `prompt_cache_key` for a run's requests, or `nil`.

  A run on the durable runtime is keyed by its agent and its actor, one
  key per user as OpenAI's guide recommends: a user's runs and threads
  with the agent share a cache, and two users never do, which keeps one
  user from probing for another's cached prompts. A run with no actor is
  keyed by its agent and subject, and one with neither by its agent and
  run. The key is a hash, so no raw host id reaches the provider. An
  in-process run without an `agent_key` in its context gets no key, and
  the provider routes by the prompt's prefix.
  """
  @spec key(map()) :: String.t() | nil
  def key(%{agent_key: agent} = context) when is_binary(agent) do
    case context do
      %{actor_type: type, actor_id: id} when not is_nil(type) and not is_nil(id) ->
        hash([agent, "actor", to_string(type), to_string(id)])

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
