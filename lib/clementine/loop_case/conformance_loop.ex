defmodule Clementine.LoopCase.ConformanceLoop do
  @moduledoc """
  The deterministic loop `Clementine.LoopCase` drives: message payloads
  carry the action list to emit (`%{"actions" => [...]}`), a halt
  instruction (`%{"halt" => output}`), or a poison marker
  (`%{"boom" => true}`, which raises — the deterministic in-step failure
  the poison battery walks to its threshold). Every callback invocation
  appends to the JSON-safe `"log"` in state, which the battery reads back
  out of committed envelopes — delivery is asserted through storage, never
  through process state.

  Hosts never reference this module directly; `create_loop` receives it in
  `attrs[:module]` and must persist it verbatim (see the `create_loop`
  contract in `Clementine.LoopCase`). It ships in the library so the
  persisted `loop_module` name resolves inside any host application
  running the battery.
  """

  use Clementine.Loop,
    state_version: 1,
    vocabulary: [:run, :send, :reply, :retry]

  alias Clementine.Result

  def init(args) do
    {:ok, %{"log" => ["init"]}, Map.get(args, "actions", [])}
  end

  def handle({:message, %{"halt" => output}}, state) do
    {:halt, Result.completed(output: output), log(state, "halt:#{output}")}
  end

  def handle({:message, %{"boom" => true}}, _state) do
    raise "conformance poison payload"
  end

  def handle({:message, payload}, state) when is_map(payload) do
    {:ok, log(state, "message:#{payload["id"]}"), Map.get(payload, "actions", [])}
  end

  def handle({:completed, tag, _result}, state) do
    {:ok, log(state, "completed:#{inspect(tag)}"), []}
  end

  def handle({:elapsed, tag}, state) do
    {:ok, log(state, "elapsed:#{inspect(tag)}"), []}
  end

  def handle({:input_failed, _ref, error}, state) do
    {:ok, log(state, "input_failed:#{error.code}"), []}
  end

  defp log(state, entry), do: Map.update!(state, "log", &(&1 ++ [entry]))
end
