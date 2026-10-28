defmodule Clementine.Thread do
  @moduledoc """
  The thread controller that ships with the runtime: a loop that owns a
  conversation and answers each message with one turn of its agent, one
  turn at a time.

  Start one per thread when the thread is created, feed it each message,
  and read the turns back as runs:

      {:ok, loop} =
        Clementine.Runs.start_loop(Clementine.Thread, %{"agent" => "chat"},
          subject: {"conversation", conversation.id},
          actor: {"user", user.id}
        )

      {:ok, :appended} =
        Clementine.Runs.send(
          loop.id,
          %{"prompt" => content, "id" => message.id, "metadata" => %{"message_id" => message.id}},
          dedup_key: message.id
        )

      Clementine.Runs.child(loop.id, {:turn, message.id})   # the message's turn, while it runs
      Clementine.Runs.turns(loop.id)                         # every turn, newest first

  A message starts a turn: a run of the agent the args name, on the
  loop's subject and with its actor, under the tag `{:turn, id}`. The
  turn reads the thread through the agent's `c:Clementine.Agent.history/1`
  and the host stores what it said in `c:Clementine.Host.run_finished/2`;
  the thread itself holds the policy, the message whose turn is in
  flight, and the messages waiting behind it, never a transcript.

  ## Args

  - `"agent"` (required): the key of the turn agent, as the child spec
    lists it.
  - `"busy"`: what a message does while a turn runs. `"queue"` (the
    default) answers it once the turn ends. `"interrupt"` cancels the
    running turn and answers the message once the cancel completes; a
    turn waiting on a retry is dropped for it instead, since nothing is
    running. Messages queue in arrival order either way.
  - `"on_failure"`: `"surface"` (the default) moves on from a turn that
    failed; the host saw its `Clementine.Result.Failed`. `"retry"` runs
    the turn again after `"retry_after_ms"` (default `300000`, five
    minutes), under the same tag.
  - `"retry_interrupted"`: `true` (the default) runs a turn whose node
    died again at once, when the reaper's `Clementine.Result.Interrupted`
    arrives.

  A turn is retried at most once, whichever policy asked, and the retry
  runs under the same tag, so `Clementine.Runs.child/2` finds it where it
  found the first attempt. Args outside this contract end the loop
  `failed` in its first step, with the reason in the run's error.

  ## Messages

  A message is a map with `"prompt"`, the turn's prompt, and optionally:

  - `"id"`: the turn's tag id (a nonblank string or an integer; the
    message's own id, usually). Without one the thread counts.
  - `"metadata"`: a plain-JSON map stored on the turn's row, as `start/3`
    stores it.
  - `"actor"`: `[type, id]`, both nonblank, whose authority this one turn
    acts with; the loop's actor otherwise.

  A message outside this contract fails its step and walks the poison
  path: dead-lettered at the threshold, the thread informed, the next
  message answered. The check is the turn row's own, made at the
  message, so a message the row would refuse never waits in the queue
  behind a turn whose completion would then take the blame.

  ## Stopping

  `Clementine.Runs.cancel/1` on a turn stops that turn; the thread hears
  its `Cancelled` completion and answers the next message. On the loop,
  it ends the thread: the turn in flight is cancelled and the messages
  still waiting are kept as dead letters.
  """

  use Clementine.Loop, key: "thread", state_version: 1, vocabulary: [:turn, :retry]

  alias Clementine.Loop.Codec
  alias Clementine.{Error, Result}

  @busy ~w(queue interrupt)
  @on_failure ~w(surface retry)
  @default_retry_after_ms :timer.minutes(5)

  @impl Clementine.Loop
  def init(args) when is_map(args) do
    case policy(args) do
      {:ok, policy} ->
        {:ok, Map.merge(policy, %{"turn" => nil, "queue" => [], "seq" => 0}), []}

      {:error, message} ->
        {:halt, Result.failed(%Error{kind: :runtime, code: :invalid_args, message: message})}
    end
  end

  @impl Clementine.Loop
  def handle({:message, message}, state) do
    message = message!(message)
    {state, message} = identify(state, message)

    case {state["turn"], state["busy"]} do
      {nil, _busy} ->
        start_turn(state, message)

      # Cancel the running turn, and start this one on its completion
      # (the lane holds until the turn ends). Two phases, whether the
      # turn is running or still queued.
      {%{"phase" => "running", "id" => current}, "interrupt"} ->
        state = state |> enqueue(message) |> put_phase("interrupting")
        {:ok, state, [{:cancel, {:turn, current}}]}

      # Nothing runs while a turn waits on its retry: drop the retry and
      # answer this message now.
      {%{"phase" => "retry_wait", "id" => current}, "interrupt"} ->
        {:ok, state, actions} = start_turn(%{state | "turn" => nil}, message)
        {:ok, state, [{:cancel_timer, {:retry, current}} | actions]}

      # Queueing, or a cancel already in flight.
      {%{}, _busy} ->
        {:ok, enqueue(state, message), []}
    end
  end

  def handle({:completed, {:turn, id}, result}, %{"turn" => %{"id" => id} = turn} = state) do
    cond do
      # The turn was cancelled for the message at the head of the queue.
      turn["phase"] == "interrupting" ->
        advance(state)

      match?(%Result.Failed{}, result) and state["on_failure"] == "retry" and
          not turn["retried"] ->
        turn = %{turn | "phase" => "retry_wait", "retried" => true}
        {:ok, put_turn(state, turn), [{:timer, {:retry, id}, state["retry_after_ms"]}]}

      match?(%Result.Interrupted{}, result) and state["retry_interrupted"] and
          not turn["retried"] ->
        turn = %{turn | "phase" => "running", "retried" => true}
        {:ok, put_turn(state, turn), [run(state, turn)]}

      true ->
        advance(state)
    end
  end

  # A turn this thread no longer tracks: nothing to decide.
  def handle({:completed, {:turn, _other}, _result}, state), do: {:ok, state, []}

  def handle(
        {:elapsed, {:retry, id}},
        %{"turn" => %{"id" => id, "phase" => "retry_wait"}} = state
      ) do
    turn = %{state["turn"] | "phase" => "running"}
    {:ok, put_turn(state, turn), [run(state, turn)]}
  end

  # A fire that lost its race with an interrupt or a cancel.
  def handle({:elapsed, {:retry, _id}}, state), do: {:ok, state, []}

  # Poison evidence: a message without a prompt burned its attempts and
  # was dead-lettered. The mailbox never jams; nothing to decide.
  def handle({:input_failed, _ref, _error}, state), do: {:ok, state, []}

  ## The policy

  defp policy(args) do
    with :ok <- known_keys(args),
         {:ok, agent} <- agent(args),
         {:ok, busy} <- choice(args, "busy", @busy, "queue"),
         {:ok, on_failure} <- choice(args, "on_failure", @on_failure, "surface"),
         {:ok, retry_after_ms} <- retry_after_ms(args),
         {:ok, retry_interrupted} <- retry_interrupted(args) do
      {:ok,
       %{
         "agent" => agent,
         "busy" => busy,
         "on_failure" => on_failure,
         "retry_after_ms" => retry_after_ms,
         "retry_interrupted" => retry_interrupted
       }}
    end
  end

  @keys ~w(agent busy on_failure retry_after_ms retry_interrupted)

  defp known_keys(args) do
    case Enum.reject(Map.keys(args), &(&1 in @keys)) do
      [] -> :ok
      unknown -> {:error, "unknown thread args: #{inspect(unknown)} (known: #{inspect(@keys)})"}
    end
  end

  defp agent(args) do
    case Map.get(args, "agent") do
      agent when is_binary(agent) and agent != "" ->
        {:ok, agent}

      other ->
        {:error, "a thread needs an \"agent\" key naming its turn agent, got: #{inspect(other)}"}
    end
  end

  defp choice(args, key, choices, default) do
    value = Map.get(args, key, default)

    if value in choices do
      {:ok, value}
    else
      {:error, "#{inspect(key)} must be one of #{inspect(choices)}, got: #{inspect(value)}"}
    end
  end

  defp retry_after_ms(args) do
    case Map.get(args, "retry_after_ms", @default_retry_after_ms) do
      ms when is_integer(ms) and ms >= 0 ->
        {:ok, ms}

      other ->
        {:error, "\"retry_after_ms\" must be a non-negative integer, got: #{inspect(other)}"}
    end
  end

  defp retry_interrupted(args) do
    case Map.get(args, "retry_interrupted", true) do
      flag when is_boolean(flag) -> {:ok, flag}
      other -> {:error, "\"retry_interrupted\" must be a boolean, got: #{inspect(other)}"}
    end
  end

  ## Messages

  # A message outside the contract raises here, toward the poison path,
  # before any of it reaches the state. The checks are the turn row's
  # own refusals — a blank prompt, a blank tag id, an actor with a blank
  # type or id, metadata that is not plain JSON — and not the looser "is
  # a string, is a map": the inbox codec round-trips the loop's
  # vocabulary and Ecto's cast turns "" into NULL, so a message the row
  # would refuse reaches here whole, and one accepted into the queue
  # would fail only at its own {:run, ...}, in the drain that folds the
  # running turn's completion, blaming that innocent input and wedging
  # the thread behind its dead letter.
  defp message!(%{"prompt" => prompt} = message) when is_binary(prompt) do
    unless nonblank?(prompt) do
      raise ArgumentError, "a thread message needs a \"prompt\", got a blank one"
    end

    id = Map.get(message, "id")

    unless is_nil(id) or nonblank?(id) do
      raise ArgumentError,
            "a thread message's \"id\" is a nonblank string or an integer, got: #{inspect(id)}"
    end

    Codec.validate_json_map!(Map.get(message, "metadata", %{}), "a thread message's \"metadata\"")

    actor = Map.get(message, "actor")

    unless is_nil(actor) or actor?(actor) do
      raise ArgumentError,
            "a thread message's \"actor\" is [type, id], both nonblank, got: #{inspect(actor)}"
    end

    message
  end

  defp message!(other) do
    raise ArgumentError,
          "a thread message is a map with a \"prompt\" string, got: #{inspect(other)}"
  end

  defp actor?([type, id]) when is_binary(type), do: nonblank?(type) and nonblank?(id)
  defp actor?(_other), do: false

  defp nonblank?(value) when is_integer(value), do: true
  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_other), do: false

  defp identify(state, %{"id" => id} = message) when not is_nil(id), do: {state, message}

  defp identify(%{"seq" => seq} = state, message) do
    {%{state | "seq" => seq + 1}, Map.put(message, "id", seq + 1)}
  end

  defp enqueue(state, message), do: Map.update!(state, "queue", &(&1 ++ [message]))

  defp start_turn(state, message) do
    turn = %{
      "id" => message["id"],
      "message" => message,
      "phase" => "running",
      "retried" => false
    }

    {:ok, put_turn(state, turn), [run(state, turn)]}
  end

  defp advance(%{"queue" => []} = state), do: {:ok, %{state | "turn" => nil}, []}

  defp advance(%{"queue" => [next | rest]} = state),
    do: start_turn(%{state | "queue" => rest}, next)

  defp put_turn(state, turn), do: %{state | "turn" => turn}
  defp put_phase(state, phase), do: put_turn(state, %{state["turn"] | "phase" => phase})

  # The child: the agent, the prompt, the message's metadata on the row,
  # and its actor when it names one. Subject and actor otherwise default
  # to the loop's own.
  defp run(state, %{"id" => id, "message" => message}) do
    child = %{
      "agent" => state["agent"],
      "prompt" => message["prompt"],
      "metadata" => Map.get(message, "metadata", %{})
    }

    child =
      case Map.get(message, "actor") do
        nil -> child
        actor -> Map.put(child, "actor", actor)
      end

    {:run, {:turn, id}, child}
  end
end
