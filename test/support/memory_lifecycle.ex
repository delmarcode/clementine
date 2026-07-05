defmodule Clementine.Test.MemoryLifecycle do
  @moduledoc """
  An in-memory `Clementine.Lifecycle` with real CAS semantics, for protocol
  tests: exact `(status, epoch)` matching, absent-key-untouched /
  explicit-nil-writes-NULL set semantics, symbolic `:now` /
  `{:now_plus, ms}` resolution against a single clock, and terminal-result
  projections recorded for assertions.

  The store is an Agent, so applies serialize — which is exactly a
  single-writer storage engine, making concurrent-claim races honest.
  `ctx` is the store pid.
  """

  @behaviour Clementine.Lifecycle

  alias Clementine.Lifecycle.{Facts, Transition}

  def start_store do
    {:ok, store} = Agent.start_link(fn -> %{runs: %{}, projections: []} end)
    store
  end

  def seed(store, %Facts{} = facts) do
    Agent.update(store, fn state ->
      %{state | runs: Map.put(state.runs, facts.ref, facts)}
    end)

    facts
  end

  def seed_queued(store, ref, overrides \\ []) do
    seed(store, struct!(%Facts{ref: ref, queued_at: DateTime.utc_now()}, overrides))
  end

  def facts!(store, ref) do
    Agent.get(store, fn state -> Map.fetch!(state.runs, ref) end)
  end

  @doc "Terminal results the host projection saw, in commit order."
  def projections(store) do
    Agent.get(store, fn state -> state.projections end)
  end

  @impl true
  def fetch(run_ref, store) do
    Agent.get(store, fn state ->
      case Map.fetch(state.runs, run_ref) do
        {:ok, facts} -> {:ok, facts}
        :error -> {:error, :not_found}
      end
    end)
  end

  @impl true
  def apply(%Transition{} = transition, store) do
    now = DateTime.utc_now()

    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.runs, transition.run_ref) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, %Facts{} = facts} ->
          if facts.status == transition.expect.status and
               facts.epoch == transition.expect.epoch do
            new_facts = apply_set(facts, transition.set, now)
            state = put_in(state.runs[transition.run_ref], new_facts)

            state =
              if transition.result do
                update_in(state.projections, &(&1 ++ [{transition.run_ref, transition.result}]))
              else
                state
              end

            {{:ok, new_facts}, state}
          else
            {{:error, :stale}, state}
          end
      end
    end)
  end

  # Absent keys untouched; present keys written (nil writes NULL); symbolic
  # stamps resolve against this store's single clock, one plain-map level
  # deep (structs like DateTime pass through untouched).
  defp apply_set(%Facts{} = facts, set, now) do
    Enum.reduce(set, facts, fn {key, value}, acc ->
      Map.replace!(acc, key, resolve(value, now))
    end)
  end

  defp resolve(:now, now), do: now
  defp resolve({:now_plus, ms}, now), do: DateTime.add(now, ms, :millisecond)

  defp resolve(value, now) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {k, resolve(v, now)} end)
  end

  defp resolve(value, _now), do: value
end
