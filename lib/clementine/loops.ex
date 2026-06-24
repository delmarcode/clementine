defmodule Clementine.Loops do
  @moduledoc """
  Outer-loop combinators — the "loops" layer that sits *above* an agent.

  Clementine.Agent and `Clementine.Loop` are the **inner** loop: an LLM in a
  cycle of gather→act→verify, calling tools until it produces a final answer.
  This module is the **outer** loop. Instead of you sitting at the keyboard
  prompting an agent, reading the result, deciding whether it's good, and
  prompting again, you write a small program that does that on your behalf.
  The agent becomes a *subroutine your program calls*.

  Everything here drives an already-started agent (any `t:agent/0`) by calling
  `Clementine.run/2` repeatedly with control flow you own:

    * `drive/3` — the primitive. Run the agent, hand its output to a `:decide`
      function, and either stop or re-prompt with new context.
    * `until_verified/4` — `drive/3` specialised for the "keep going until an
      external check passes" pattern (tests, a type-checker, CI).
    * `fan_out/3` — delegate: run many agents in parallel and collect results.

  ## The self-prompting loop

      {:ok, agent} = MyApp.CodingAgent.start_link()

      Clementine.Loops.drive(agent, "Implement the CSV exporter.",
        max_turns: 6,
        decide: fn output, _turn ->
          if String.contains?(output, "DONE"),
            do: :done,
            else: {:continue, "Not finished. Keep going:\\n\#{output}"}
        end)

  ## A judge as the `:decide` step

  Forking the agent gives the judge a clean history instead of polluting the
  worker's conversation:

      decide = fn output, _turn ->
        {:ok, judge} = Clementine.fork(agent, MyApp.JudgeAgent)

        case Clementine.run(judge, "Is this complete? Reply DONE or KEEP_GOING: <why>.\\n\\n\#{output}") do
          {:ok, "DONE" <> _}        -> :done
          {:ok, "KEEP_GOING:" <> r} -> {:continue, "Reviewer says: \#{String.trim(r)}"}
          _                         -> {:continue, "Verify and finish."}
        end
      end

      Clementine.Loops.drive(agent, goal, decide: decide)

  ## Verify-driven loop (get the build green)

      Clementine.Loops.until_verified(agent, "Add validation to the User schema.",
        fn _output ->
          case System.cmd("mix", ["test"], cd: ".", stderr_to_stdout: true) do
            {_, 0}      -> :ok
            {out, _}    -> {:retry, out}
          end
        end)

  ## Fan-out / delegate

      Clementine.Loops.fan_out(Path.wildcard("lib/**/*.ex"), fn file ->
        {:ok, agent} = MyApp.ReviewerAgent.start_link()
        {:ok, review} = Clementine.run(agent, "Review \#{file} for bugs. Be terse.")
        {file, review}
      end, max_concurrency: 8)
  """

  @typedoc "Any started agent process (a pid or registered name)."
  @type agent :: GenServer.server()

  @typedoc """
  Verdict returned by a `:decide` function.

  * `:done` — the goal is met; stop and return the latest output.
  * `{:continue, prompt}` — re-prompt the agent with `prompt` on the next turn.
  """
  @type verdict :: :done | {:continue, String.t()}

  @typedoc "Called once per turn with `%{turn: pos_integer, output: String.t()}`."
  @type on_turn :: (map() -> any())

  @default_max_turns 8

  @doc """
  Drives an agent across multiple turns until `:decide` says it's done.

  Runs `Clementine.run(agent, prompt)`, passes the output to the `:decide`
  function along with the 1-based turn number, then either returns or feeds the
  next prompt back into the agent. This is the outer-loop primitive the rest of
  the module is built on.

  ## Options

    * `:decide` — `(output, turn -> t:verdict/0)`. Defaults to a function that
      always returns `:done` (i.e. a single turn).
    * `:max_turns` — hard cap on turns (default: `#{@default_max_turns}`).
    * `:on_turn` — optional `t:on_turn/0` callback invoked after each turn, for
      logging/telemetry/reporting. Errors raised in it are ignored.

  ## Returns

    * `{:ok, output, turns}` — `:decide` returned `:done` after `turns` turns.
    * `{:error, {:max_turns_reached, last_output}}` — still not done at the cap.
    * `{:error, reason}` — a `Clementine.run/2` call failed; propagated verbatim.
  """
  @spec drive(agent(), String.t(), keyword()) ::
          {:ok, String.t(), pos_integer()}
          | {:error, {:max_turns_reached, String.t()}}
          | {:error, term()}
  def drive(agent, prompt, opts \\ []) when is_binary(prompt) do
    decide = Keyword.get(opts, :decide, fn _output, _turn -> :done end)
    on_turn = Keyword.get(opts, :on_turn, fn _ -> :ok end)
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)

    do_drive(agent, prompt, decide, on_turn, 1, max_turns)
  end

  defp do_drive(agent, prompt, decide, on_turn, turn, max_turns) do
    case Clementine.run(agent, prompt) do
      {:ok, output} ->
        safe_on_turn(on_turn, %{turn: turn, output: output})

        case decide.(output, turn) do
          :done ->
            {:ok, output, turn}

          {:continue, next_prompt} when turn < max_turns ->
            do_drive(agent, next_prompt, decide, on_turn, turn + 1, max_turns)

          {:continue, _next_prompt} ->
            {:error, {:max_turns_reached, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Drives an agent until an external `check` passes.

  A specialisation of `drive/3` for the common "keep going until verification
  succeeds" loop. After each turn the agent's output is handed to `check`:

    * `:ok` — verification passed; stop and return the output.
    * `{:retry, feedback}` — re-prompt the agent with the feedback woven in.

  The `check` is *yours* to define and typically runs something slow or external
  (a full test suite, a type-checker, a deploy smoke test) — work you'd rather
  run once per turn than bake into an in-loop `Clementine.Verifier`.

  Accepts the same `:max_turns` and `:on_turn` options as `drive/3`. Returns the
  same shapes.
  """
  @spec until_verified(agent(), String.t(), (String.t() -> :ok | {:retry, String.t()}), keyword()) ::
          {:ok, String.t(), pos_integer()}
          | {:error, {:max_turns_reached, String.t()}}
          | {:error, term()}
  def until_verified(agent, prompt, check, opts \\ [])
      when is_binary(prompt) and is_function(check, 1) do
    decide = fn output, _turn ->
      case check.(output) do
        :ok ->
          :done

        {:retry, feedback} ->
          {:continue,
           "The previous attempt did not pass verification.\n\n" <>
             "Feedback:\n#{feedback}\n\nPlease fix the issues and try again."}
      end
    end

    drive(agent, prompt, Keyword.put(opts, :decide, decide))
  end

  @doc """
  Runs `fun` over `items` concurrently, returning results in input order.

  The delegation / fan-out pattern: spin up an agent per item, run it, collect.
  `fun.(item)` does whatever you want for one item — usually start an agent and
  call `Clementine.run/2` — and its return value is captured.

  Tasks run under `Clementine.TaskSupervisor`, so a crash in one `fun` is
  isolated: it surfaces as `{:error, reason}` in that slot rather than taking
  down the caller.

  ## Options

    * `:max_concurrency` — default: `System.schedulers_online/0`.
    * `:timeout` — per-item timeout in ms, or `:infinity` (default). On timeout
      the task is killed and the slot becomes `{:error, :timeout}`.

  ## Returns

  A list, aligned with `items`, of `{:ok, result}` or `{:error, reason}`.
  """
  @spec fan_out(Enumerable.t(), (term() -> term()), keyword()) :: [
          {:ok, term()} | {:error, term()}
        ]
  def fan_out(items, fun, opts \\ []) when is_function(fun, 1) do
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, :infinity)

    Clementine.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(items, fun,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> {:ok, result}
      {:exit, :timeout} -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end)
  end

  defp safe_on_turn(on_turn, info) when is_function(on_turn, 1) do
    on_turn.(info)
  rescue
    _ -> :ok
  end
end
