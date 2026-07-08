defmodule Clementine.Test.ScriptedLoop do
  @moduledoc """
  A deterministic loop whose behavior is driven entirely by its inputs, so
  tests and generators control every decision: message payloads carry the
  action list to emit (`%{"actions" => [...]}`) or a halt instruction
  (`%{"halt" => output}`); every callback invocation appends to the
  JSON-safe `"log"` in state, which assertions read back out of the
  committed envelope. `{:elapsed, :poll}` re-arms itself — the watcher's
  live-key lifetime.

  The action-verb atoms sit in the vocabulary so scripted payloads survive
  the inbox codec — host-seam tests deliver their scripts through real
  storage.
  """

  use Clementine.Loop,
    state_version: 1,
    vocabulary: [:poll, :reply, :retry, :note, :run, :timer, :cancel_timer, :send]

  alias Clementine.Result

  def init(%{"halt" => output}), do: {:halt, Result.completed(output: output)}

  def init(args) do
    {:ok, %{"log" => ["init"]}, Map.get(args, "actions", [])}
  end

  def handle({:message, %{"halt" => output}}, state) do
    {:halt, Result.completed(output: output), log(state, "halt:#{output}")}
  end

  def handle({:message, %{"halt_failed" => message}}, state) do
    {:halt, Result.failed(%Clementine.Error{message: message}), state}
  end

  def handle({:message, payload}, state) when is_map(payload) do
    {:ok, log(state, "message:#{payload["id"]}"), Map.get(payload, "actions", [])}
  end

  def handle({:completed, tag, _result}, state) do
    {:ok, log(state, "completed:#{inspect(tag)}"), []}
  end

  def handle({:elapsed, :poll}, state) do
    {:ok, log(state, "elapsed::poll"), [{:timer, :poll, 60_000}]}
  end

  def handle({:elapsed, tag}, state) do
    {:ok, log(state, "elapsed:#{inspect(tag)}"), []}
  end

  def handle({:input_failed, _ref, error}, state) do
    {:ok, log(state, "input_failed:#{error.code}"), []}
  end

  defp log(state, entry), do: Map.update!(state, "log", &(&1 ++ [entry]))
end

defmodule Clementine.Test.DoorLoop do
  @moduledoc """
  State is a MapSet — not JSON — proving the `dump/1`/`load/1` doors:
  dumped form is a sorted list under a string key, loaded back to the set.
  """

  use Clementine.Loop, state_version: 1

  def init(_args), do: {:ok, MapSet.new(), []}

  def handle({:message, %{"add" => item}}, state) do
    {:ok, MapSet.put(state, item), []}
  end

  def handle(_input, state), do: {:ok, state, []}

  def dump(state), do: %{"items" => state |> MapSet.to_list() |> Enum.sort()}
  def load(%{"items" => items}), do: MapSet.new(items)
end

defmodule Clementine.Test.VersionedLoop do
  @moduledoc "Declares state_version 2, for :incompatible_state paths."

  use Clementine.Loop, state_version: 2

  def init(_args), do: {:ok, %{}, []}
  def handle(_input, state), do: {:ok, state, []}
end

defmodule Clementine.Test.BadDumpLoop do
  @moduledoc "dump/1 violates the contract by returning a non-map."

  use Clementine.Loop

  def init(_args), do: {:ok, %{}, []}
  def handle(_input, state), do: {:ok, state, []}
  def dump(_state), do: :not_a_map
end
