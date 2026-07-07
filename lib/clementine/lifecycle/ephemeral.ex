defmodule Clementine.Lifecycle.Ephemeral do
  @moduledoc """
  The in-memory lifecycle behind `Clementine.run/3` and
  `Clementine.stream/3` — scripts, evals, and IEx.

  Facts live in the calling process (the process dictionary), so the CAS in
  `apply/2` always matches by construction: a single process is the only
  writer. The runner algorithm is the same one production uses, with two
  honest substitutions — no heartbeat process (lease loss is impossible in
  a single process) and no reaper (a crash is the caller's crash). Deadline
  and `max_iterations` are enforced identically; symbolic timestamps
  resolve against this process's clock, which *is* the storage clock here.

  The host projection collapses to remembering the terminal result:
  every transition into a terminal status carries its `Result`, and
  `result/1` hands it back to the facade.

  `ctx` is the value returned by `create/1`; it is single-process by
  construction and never escapes the facade.
  """

  @behaviour Clementine.Lifecycle

  alias Clementine.Lifecycle.{Facts, Transition}

  @type ctx :: %{key: {module(), reference()}, forward_to: {pid(), reference()} | nil}

  @doc """
  Seeds a fresh queued run in this process and returns `{run_ref, ctx}`.

  `:forward_to` names the `{pid, tag}` destination the internal
  Clementine.Events.Forwarder sink mails stamped events to (the streaming
  facade — the tag pins delivery to one stream enumerable); `nil` means no
  forwarding.
  """
  @spec create(keyword()) :: {reference(), ctx()}
  def create(opts \\ []) do
    ref = make_ref()
    ctx = %{key: {__MODULE__, ref}, forward_to: Keyword.get(opts, :forward_to)}

    Process.put(ctx.key, %{
      facts: %Facts{ref: ref, status: :queued, queued_at: DateTime.utc_now()},
      result: nil
    })

    {ref, ctx}
  end

  @doc "The terminal result the projection captured, or nil while active."
  @spec result(ctx()) :: Clementine.Result.t() | nil
  def result(%{key: key}) do
    case Process.get(key) do
      %{result: result} -> result
      nil -> nil
    end
  end

  @doc "Drops the run's state from this process."
  @spec delete(ctx()) :: :ok
  def delete(%{key: key}) do
    Process.delete(key)
    :ok
  end

  @impl true
  def fetch(run_ref, %{key: key}) do
    case Process.get(key) do
      %{facts: %Facts{ref: ^run_ref} = facts} -> {:ok, facts}
      _other -> {:error, :not_found}
    end
  end

  @impl true
  def apply(%Transition{} = transition, %{key: key} = _ctx) do
    now = DateTime.utc_now()

    case Process.get(key) do
      %{facts: %Facts{ref: ref} = facts} = state when ref == transition.run_ref ->
        if facts.status == transition.expect.status and
             facts.epoch == transition.expect.epoch do
          new_facts = apply_set(facts, transition.set, now)
          state = %{state | facts: new_facts}
          state = if transition.result, do: %{state | result: transition.result}, else: state
          Process.put(key, state)
          {:ok, new_facts}
        else
          {:error, :stale}
        end

      _other ->
        {:error, :not_found}
    end
  end

  # Absent keys untouched; present keys written (nil writes NULL); symbolic
  # stamps resolve against this process's clock, one plain-map level deep
  # (structs like DateTime pass through untouched).
  defp apply_set(%Facts{} = facts, set, now) do
    Enum.reduce(set, facts, fn {field, value}, acc ->
      Map.replace!(acc, field, resolve(value, now))
    end)
  end

  defp resolve(:now, now), do: now
  defp resolve({:now_plus, ms}, now), do: DateTime.add(now, ms, :millisecond)

  defp resolve(value, now) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {k, resolve(v, now)} end)
  end

  defp resolve(value, _now), do: value
end
