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

defmodule Clementine.Test.ChildGlueLoop do
  @moduledoc """
  The thread-agent shape from LOOP_RFC §Worked Examples, sized for the
  child-glue end-to-end battery: state holds a cursor (never a
  transcript), a `%{"reply_to" => id}` message spawns `{:reply, id}` with
  the cursor in the child args, a completion advances the cursor by the
  child's real message count, and an interrupted child is retried as
  `{:retry, id}` — the parent deciding, matrix row L12. Every callback
  appends to the JSON-safe `"log"` so assertions read delivery out of
  committed envelopes.
  """

  use Clementine.Loop, state_version: 1, vocabulary: [:reply, :retry]

  alias Clementine.Result

  def init(_args), do: {:ok, %{"cursor" => 0, "log" => ["init"]}, []}

  def handle({:message, %{"reply_to" => id} = payload}, state) do
    args = %{
      "input" => Map.get(payload, "input", "go"),
      "history_through" => state["cursor"]
    }

    {:ok, log(state, "spawn:#{id}"), [{:run, {:reply, id}, args}]}
  end

  def handle({:message, %{"halt" => output}}, state) do
    {:halt, Result.completed(output: output), log(state, "halt")}
  end

  def handle({:completed, {:reply, id}, %Result.Completed{} = r}, state) do
    state = %{state | "cursor" => state["cursor"] + length(r.messages)}
    {:ok, log(state, "completed:#{id}:#{r.output}"), []}
  end

  def handle({:completed, {:reply, id}, %Result.Interrupted{}}, state) do
    {:ok, log(state, "interrupted:#{id}"), [{:run, {:retry, id}, %{"input" => "retry"}}]}
  end

  def handle({:completed, {:retry, id}, %Result.Completed{} = r}, state) do
    state = %{state | "cursor" => state["cursor"] + length(r.messages)}
    {:ok, log(state, "retried:#{id}:#{r.output}"), []}
  end

  def handle({:completed, tag, _result}, state) do
    {:ok, log(state, "completed:#{inspect(tag)}"), []}
  end

  def handle({:elapsed, tag}, state), do: {:ok, log(state, "elapsed:#{inspect(tag)}"), []}

  def handle({:input_failed, _ref, error}, state) do
    {:ok, log(state, "input_failed:#{error.code}"), []}
  end

  defp log(state, entry), do: Map.update!(state, "log", &(&1 ++ [entry]))
end

defmodule Clementine.Test.JudgeLoop do
  @moduledoc """
  The judge loop from LOOP_RFC §Worked Examples — Verifier's durable,
  final form: run → judge (a pure function of the completion) → re-run
  with feedback args after a retry timer, `{:halt, result}` on pass or
  attempts exhausted. The trace rides the halt output (`"log"` joined),
  so determinism and production-trace equality assert on the result
  alone, whatever substrate animated the loop.
  """

  use Clementine.Loop, state_version: 1, vocabulary: [:attempt, :retry]

  alias Clementine.Result

  def init(%{"prompt" => prompt} = args) do
    state = %{
      "prompt" => prompt,
      "max" => Map.get(args, "max_attempts", 3),
      "log" => ["spawn:1"]
    }

    {:ok, state, [{:run, {:attempt, 1}, %{"prompt" => prompt, "attempt" => 1}}]}
  end

  def handle({:completed, {:attempt, n}, %Result.Completed{output: output}}, state) do
    if judge_pass?(output) do
      state = log(state, "pass:#{n}")
      {:halt, Result.completed(output: trace(state)), state}
    else
      {:ok, log(state, "fail:#{n}"), [{:timer, {:retry, n}, :timer.minutes(5)}]}
    end
  end

  def handle({:completed, {:attempt, n}, _failed_or_interrupted}, state) do
    {:ok, log(state, "child_error:#{n}"), [{:timer, {:retry, n}, :timer.minutes(5)}]}
  end

  def handle({:elapsed, {:retry, n}}, state) do
    next = n + 1

    if next > state["max"] do
      state = log(state, "exhausted:#{n}")
      error = %Clementine.Error{message: trace(state), code: :attempts_exhausted}
      {:halt, Result.failed(error), state}
    else
      args = %{
        "prompt" => state["prompt"],
        "attempt" => next,
        "feedback" => "attempt #{n} was judged a fail; try again"
      }

      {:ok, log(state, "spawn:#{next}"), [{:run, {:attempt, next}, args}]}
    end
  end

  # The judge: pure over the completion, as the RFC prescribes.
  defp judge_pass?(output), do: is_binary(output) and String.contains?(output, "pass")

  defp log(state, entry), do: Map.update!(state, "log", &(&1 ++ [entry]))
  defp trace(state), do: Enum.join(state["log"], ",")
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

defmodule Clementine.Test.UpgradedScriptedLoop do
  @moduledoc """
  The v2 deploy of `Clementine.Test.ScriptedLoop`, carrying the
  `handle_upgrade/2` clause the bump demands (LOOP_RFC §State Upgrade).
  The chain's marker lands in the log, so assertions read exactly when
  the upgrade ran relative to the inputs around it.
  """

  use Clementine.Loop,
    state_version: 2,
    vocabulary: [:poll, :reply, :retry, :note, :run, :timer, :cancel_timer, :send]

  def handle_upgrade(1, state) do
    {:ok,
     state
     |> Map.update!("log", &(&1 ++ ["upgrade:1->2"]))
     |> Map.put("format", "v2")}
  end

  def init(args) do
    case Clementine.Test.ScriptedLoop.init(args) do
      {:ok, state, actions} -> {:ok, Map.put(state, "format", "v2"), actions}
      halt -> halt
    end
  end

  defdelegate handle(input, state), to: Clementine.Test.ScriptedLoop
end

defmodule Clementine.Test.BadDumpLoop do
  @moduledoc "dump/1 violates the contract by returning a non-map."

  use Clementine.Loop

  def init(_args), do: {:ok, %{}, []}
  def handle(_input, state), do: {:ok, state, []}
  def dump(_state), do: :not_a_map
end
