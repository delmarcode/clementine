# Durable Loops

A loop is a durable receive: OTP process semantics lifted to
organizational timescale, with your database as the mailbox. Where a
[run](runtime.md) is one attempt at one bounded piece of work, a loop is
a *standing entity*: an agent that owns a conversation for months, a
judge that retries until quality passes, a watcher that polls forever.
Messages, child completions, and timer expirations arrive in its
**inbox**; each wake is a **step** that drains inputs through your pure
`handle/2` and commits *everything the step caused* (consumed inputs,
new state, child runs and their jobs, outbound messages, timer
schedules, and the park/continue/finish transition) in **one atomic
unit**. Nothing durable exists that a committed step did not create,
which is why a crashed step replays to an identical commit and a loop is
always safe to retry.

The division of labor: **the loop decides; children act.** All real work
(model calls, tools, effects, approval gates) lives in child runs with
their own leases and fences. A loop never builds an agent: a step emits
the JSON-safe description of a child, naming the agent by its key, and
the runtime builds that agent at the child's claim, exactly as it builds
any run.

In the durable runtime (`Clementine.Runs`) a loop *is* a run. Its row in
`agent_runs` has `kind = "loop"`, its controller's key in `agent_key`,
its creation args in `input`, and it occupies the lane of its controller
and subject like any run, which is what makes starting one insert-or-get.
Its inbox is the `agent_run_inbox` table. Its children are runs its steps
started, each pointing back at it with a tag. The runtime owns the step
worker, the timer worker, the child's build at its claim, the completion
that reaches the parent when a child ends, and the loop sweep that heals
strands. You write the controller, list it, start it, and feed it.

This guide wires a conversation thread end to end: the controller, the
child spec, starting and feeding, cancellation, and what the runtime does
underneath; the judge and watcher shapes and the local script path close
it out. It assumes the [runtime guide](runtime.md)'s setup (the child
after Oban, the migration at version 3, a turn agent for the thread).
The operations story (telemetry, paging signals, and the loop doctor) is
[its own guide](loop-operations.md).

## The shape

```text
Runs.send ───append──▶ inbox ──wake──▶ step (claim ▶ drain ▶ commit)
                                         │ commit cargo
                                         ├─▶ child run rows + jobs ──▶ Runs.Worker
                                         │      built at the claim ▶ Runner.execute
                                         │      its end ──append──▶ inbox
                                         ├─▶ timer jobs ──fire──▶ inbox
                                         └─▶ sends to other loops ──▶ their inboxes
```

Everything arrives through the inbox; the inbox is the only wake source.
A parked loop is a `waiting` run row: one cheap row, no process, no
heartbeat. Dormant loops cost storage, not compute.

Two atomicity sentences carry the whole design, and the runtime
implements both as single Postgres transactions:

1. **The step commit is one atomic unit**, and a park re-verifies inside
   that unit that nothing arrived mid-step, downgrading itself to a
   continue if something did.
2. **An append is one atomic unit**: input row, wake, and step-job
   enqueue commit together, under the loop row's lock, which serializes
   it against a step's park.

Together they close every lost-wakeup interleaving at the database lock.

## Step 1 — The controller

The behaviour is decision logic only. `init/1` and `handle/2` are **pure
over their arguments**: no reads (a config row is not stable across a
deploy), no clock, no randomness. Everything a decision needs arrives in
the input payload or lives in state; everything it wants done is action
data. Purity is what makes a crashed step replay from unchanged inputs to
an identical commit; an impure loop forfeits that convergence alone.

A thread controller that queues messages while a turn runs, with every
input the machinery can hand it:

```elixir
defmodule MyApp.ThreadLoop do
  use Clementine.Loop, key: "thread", state_version: 1, vocabulary: [:turn, :retry]

  alias Clementine.Result

  # The args name the turn agent (by its key, as the child spec lists it);
  # the state holds the message whose turn is in flight and the queue
  # behind it. Never a transcript: the thread's messages live in your
  # tables, and the turn agent's history/1 reads them at the child's claim.
  def init(%{"agent" => agent}) do
    {:ok, %{"agent" => agent, "turn" => nil, "queue" => []}, []}
  end

  # A message arrives. No turn in flight: start one. One in flight: queue
  # it; the thread's lane holds one active turn, and the next starts when
  # this one's completion folds.
  def handle({:message, message}, %{"turn" => nil} = state) do
    {:ok, %{state | "turn" => message}, [turn(state, message)]}
  end

  def handle({:message, message}, state) do
    {:ok, Map.update!(state, "queue", &(&1 ++ [message])), []}
  end

  # The turn ended, however it ended: the host's run_finished/2 already
  # stored what it said. Advance to the next queued message, or park.
  def handle({:completed, {:turn, _id}, %Result.Completed{}}, state) do
    next(state)
  end

  # Pod death mid-turn: the reaper interrupted the child and its end
  # reached here like any other completion. Retry it once, after a pause.
  def handle({:completed, {:turn, id}, %Result.Interrupted{}}, state) do
    {:ok, state, [{:timer, {:retry, id}, :timer.seconds(30)}]}
  end

  def handle({:elapsed, {:retry, _id}}, %{"turn" => message} = state) do
    {:ok, state, [turn(state, message)]}
  end

  # A failed or cancelled turn: the host saw the result; move on.
  def handle({:completed, {:turn, _id}, _failed_or_cancelled}, state) do
    next(state)
  end

  # Poison evidence: an input burned its attempts (a malformed payload, a
  # handler bug). The mailbox never jams; this is your notification.
  def handle({:input_failed, _ref, _error}, state) do
    {:ok, state, []}
  end

  # A child is JSON: the agent's key, its prompt, and metadata for its row.
  # Its subject and actor default to the loop's own.
  defp turn(state, %{"id" => id, "prompt" => prompt}) do
    child = %{"agent" => state["agent"], "prompt" => prompt, "metadata" => %{"message_id" => id}}
    {:run, {:turn, id}, child}
  end

  defp next(%{"queue" => []} = state), do: {:ok, %{state | "turn" => nil}, []}

  defp next(%{"queue" => [message | rest]} = state) do
    {:ok, %{state | "turn" => message, "queue" => rest}, [turn(state, message)]}
  end
end
```

The actions, as `Clementine.Loop` documents them:

- `{:run, tag, child}` starts a child run under a two-part tag,
  `{kind, id}`. `child` is a JSON map: `"agent"`, the key of an agent the
  child spec lists; `"prompt"`; and optionally `"subject"` and `"actor"`
  as `[type, id]` (both default to the loop's own) and `"metadata"`,
  which lands on the child's row. One live child per tag; the tag re-arms
  once the child ends.
- `{:cancel, tag}` flags the live child under the tag; its `Cancelled`
  completion arrives like any other. A tag with no live child is a
  no-op.
- `{:timer, tag, ms_or_datetime}` schedules a durable timer that fires as
  `{:elapsed, tag}`; `{:cancel_timer, tag}` retires it.
- `{:send, loop_id, payload}` appends to another loop's inbox.

Three contract points:

- **The lane holds inside a loop.** A turn child occupies the thread's
  lane like any turn, so a step whose commit would start a second active
  turn on the thread fails, and the input that asked for it walks the
  poison path. A controller that wants to interrupt cancels the running
  turn first and starts the next one when the cancelled child's
  completion folds, never both in one step.
- **`state_version`** is recorded in every commit. When a deploy bumps
  it, ship one `handle_upgrade/2` clause per bump, the `code_change`
  analog: `handle_upgrade(n, dumped_map)` returns `{:ok, map}` at
  `n + 1`, and the machinery chains stored → declared stepwise on the
  loop's next wake. Without the callback (or on any chain failure) the
  loop parks visibly as `:incompatible_state`, never a crash, until
  compatible code ships. A key the child spec no longer lists parks as
  `:incompatible_spec` the same way.
- **`vocabulary`** is the atom whitelist for durable tags and payloads.
  Tags persist in the envelope and in dedup keys, so atoms must be
  declared; tuples like `{:turn, 42}` encode canonically.

## Step 2 — List it, start it, feed it

The controller goes in the child spec's `agents:` beside the agents it
starts; they share one key namespace:

<!-- guide-sample: parse-only -->
```elixir
{Clementine,
 repo: MyApp.Repo,
 oban: Oban,
 queue: :agents,
 agents: [MyApp.Agents.Chat, MyApp.ThreadLoop],
 host: MyApp.Agents.Host}
```

A conversation gets its loop when it is created, in the same transaction
as its row: the loop's row and its first step's job commit with it, and
`init/1` runs in that first step. Each message then goes to the loop,
with the message's id as the dedup key, so a redelivered webhook or a
double-clicked send collapses to `{:ok, :duplicate}`:

```elixir
defmodule MyApp.Chat.Threads do
  @moduledoc "A conversation is a loop; a message is a send to it."

  alias Clementine.Runs

  def create_conversation(attrs) do
    MyApp.Repo.transaction(fn ->
      conversation = MyApp.Chat.insert_conversation!(attrs)

      {:ok, _loop} =
        Runs.start_loop(MyApp.ThreadLoop, %{"agent" => conversation.agent_key},
          subject: {"conversation", conversation.id},
          actor: {"user", conversation.user_id}
        )

      conversation
    end)
  end

  def send_message(conversation, content) do
    MyApp.Repo.transaction(fn ->
      message = MyApp.Chat.insert_message!(conversation, content)
      loop = Runs.active({"conversation", conversation.id}, kind: :loop)

      case Runs.send(loop.id, %{"id" => message.id, "prompt" => content},
             dedup_key: "message:#{message.id}"
           ) do
        {:ok, :appended} -> message
        {:ok, :duplicate} -> message
        {:ok, :dead_lettered} -> MyApp.Repo.rollback(:conversation_closed)
      end
    end)
  end

  # Stop the turn in flight; the queued messages still answer, because
  # the controller advances on the Cancelled completion.
  def stop_turn(conversation) do
    case Runs.active({"conversation", conversation.id}) do
      nil -> {:error, :no_turn}
      turn -> Runs.cancel(turn.id)
    end
  end

  # Close the conversation: the loop cancels its live turn, keeps any
  # queued message as evidence, and ends.
  def close(conversation) do
    loop = Runs.active({"conversation", conversation.id}, kind: :loop)
    Runs.cancel(loop.id)
  end
end
```

`Runs.start_loop/3` is insert-or-get on the lane: a second start of the
same controller on the same subject returns
`{:ok, :already_exists, loop}` with the standing loop. `Runs.send/3`
appends, wakes a parked loop, and enqueues its step in one transaction;
inside the caller's transaction they commit with it. A loop that has
ended answers `{:ok, :dead_lettered}`: the message was kept as evidence,
never to be consumed, and the caller knows.

The rest of the surface: `Runs.cancel/1` on a loop flags it
(`{:ok, :flagged}`) and wakes it, and the next step cancels its live
children, absorbs their ends without calling the controller, finishes
the loop `cancelled` last, and dead-letters any input left in the inbox.
`Runs.child(loop_id, tag)` is the live child under a tag (a streaming UI
attaches to the turn as it starts); `Runs.turns(loop_id)` and
`Runs.list(parent: loop_id)` are its children; `Runs.pending(loop_id)` is
the inbox window, for a UI that shows queued messages. The host hears a
loop's transitions like any run's (`:claimed` at each step, `:suspended`
at each park, `:resumed` at each wake), with `run.kind == "loop"`, and
its end through the finish hooks; a host that only wants rollouts
matches on the kind.

## What the runtime does

- **The step.** `Runs.send/3`, a child's end, and a timer's fire enqueue
  the loop's step job (worker `Runs.StepWorker`) on the child spec's
  queue. A step claims the loop row, drains up to the batch cap through
  your controller, and commits as one transaction: consumed inputs,
  dead-letter marks, the child rows and their jobs, timer jobs, child
  cancels, sends, the envelope, and the transition. A step that raises
  (a malformed action, a child that cannot start) requeues the loop and
  counts against the head input's attempts; at the threshold the input is
  dead-lettered with a synthesized `{:input_failed, ref, error}` the
  controller hears, and the mailbox never jams.
- **The child.** It is inserted through the same path as
  `Runs.start/3`, with its parent and tag, in the step's commit, and
  built at its claim like any run: its agent from its key, its subject
  and actor through the host's resolvers, its history through the turn
  agent's `history/1`. Tools see `context.parent_id` and `context.tag`
  beside the rest. When it ends, however it ends, its terminal transaction
  appends `{:completed, tag, result}` to the loop's inbox, exactly once,
  and the loop wakes after the commit.
- **Timers** are Oban jobs scheduled in the step's commit
  (worker `Runs.TimerWorker`); a fire appends `{:elapsed, tag}` under
  the schedule's own dedup key, so a redelivered fire is a duplicate and
  a fire out-raced by a cancel or a re-arm is a retained dead letter,
  never a ghost the controller sees.
- **The loop sweep** runs beside the reaper's rollout sweep, slower, over
  loop rows alone, and no verdict but the deadline belt ends a loop: a
  crashed step requeues, a lost step job is re-inserted, a child's lost
  completion is synthesized from its row, and a park stranded over
  pending inputs is woken. [Loop Operations](loop-operations.md) names
  the signals.

## The judge loop

Run → judge (a pure function of the completion) → re-run with feedback,
halt on pass or exhausted attempts. `Clementine.Verifier`'s durable,
final form:

```elixir
defmodule MyApp.JudgeLoop do
  use Clementine.Loop, key: "judge", state_version: 1, vocabulary: [:attempt, :retry]

  alias Clementine.Result

  def init(%{"prompt" => prompt} = args) do
    state = %{"prompt" => prompt, "max" => Map.get(args, "max_attempts", 3)}
    {:ok, state, [{:run, {:attempt, 1}, attempt(prompt, 1)}]}
  end

  def handle({:completed, {:attempt, n}, %Result.Completed{} = r}, state) do
    if judge_pass?(r.output) do
      {:halt, Result.completed(output: r.output), state}
    else
      {:ok, state, [{:timer, {:retry, n}, :timer.minutes(5)}]}
    end
  end

  def handle({:completed, {:attempt, n}, _failed_or_interrupted}, state) do
    {:ok, state, [{:timer, {:retry, n}, :timer.minutes(5)}]}
  end

  def handle({:elapsed, {:retry, n}}, state) do
    next = n + 1

    if next > state["max"] do
      error = %Clementine.Error{message: "no attempt passed", code: :attempts_exhausted}
      {:halt, Result.failed(error), state}
    else
      feedback = "Attempt #{n} was judged a fail; address the rubric and try again."
      {:ok, state, [{:run, {:attempt, next}, attempt(state["prompt"] <> "\n\n" <> feedback, next)}]}
    end
  end

  def handle({:input_failed, _ref, _error}, state), do: {:ok, state, []}

  defp attempt(prompt, n), do: %{"agent" => "writer", "prompt" => prompt, "metadata" => %{"attempt" => n}}

  # The judge: pure over the completion. A model-graded judge is a CHILD
  # (start a grading run and fold its completion), never a call from here.
  defp judge_pass?(output), do: is_binary(output) and String.contains?(output, "PASS")
end
```

A halt with children still in flight enters the cascade automatically:
children reach their ends first, the loop's end is last, leftovers
sweep to dead letters. `{:halt, result}` is a decision like any other.

## The watcher

A cron with memory and judgment. `init` arms a timer; each elapse starts
a read-only child; the completion decides notify-or-sleep and re-arms.
Re-arming a fired tag is legal (live-key lifetime):

```elixir
defmodule MyApp.WatcherLoop do
  use Clementine.Loop, key: "watcher", state_version: 1, vocabulary: [:poll, :check]

  alias Clementine.Result

  def init(%{"target" => target} = args) do
    state = %{"target" => target, "every_ms" => Map.get(args, "every_ms", 900_000)}
    {:ok, state, [{:timer, :poll, 0}]}
  end

  def handle({:elapsed, :poll}, state) do
    check = %{"agent" => "checker", "prompt" => "Check #{state["target"]} for anomalies."}
    {:ok, state, [{:run, {:check, state["target"]}, check}]}
  end

  def handle({:completed, {:check, _target}, %Result.Completed{} = r}, state) do
    actions =
      if String.contains?(r.output || "", "ANOMALY") do
        [{:send, state["ops_loop"], %{"anomaly" => r.output}}]
      else
        []
      end

    {:ok, state, actions ++ [{:timer, :poll, state["every_ms"]}]}
  end

  def handle({:completed, {:check, _}, _failed_or_interrupted}, state) do
    {:ok, state, [{:timer, :poll, state["every_ms"]}]}
  end

  def handle({:input_failed, _ref, _error}, state), do: {:ok, state, []}
end
```

## The script path: run_local

The same controller, animated in-process for evals and scripts: an
in-memory inbox with identical FIFO semantics, children executed for
real but their completions **enqueued as inputs** (the hop is modeled, so
ordering matches production), timers on a virtual clock that jumps to
the next deadline when the loop is idle. A five-minute retry costs
nothing and fires in order. The script supplies what the runtime would
build from the `"agent"` key:

<!-- guide-sample: parse-only -->
```elixir
{:ok, result} =
  Clementine.Loop.run_local(MyApp.JudgeLoop, %{"prompt" => "write the summary"},
    build_child: fn _tag, child ->
      {:ok, Clementine.Rollout.new(agent: my_agent, input: child["prompt"])}
    end
  )
```

Deterministic controllers (and mock LLM clients) make this the eval
harness: same decisions, same ordering, no database.

## Where next

- Alert before users notice, and diagnose a frozen loop in one call:
  [Loop Operations](loop-operations.md).
- Gate a child's tool on a human decision: the child is an ordinary run,
  so [Approvals & Suspension](approvals.md) applies unchanged.
- The design rationale, the amendment ledger, and failure matrix rows
  L1–L18: `docs/LOOP_RFC.md` in the repository.
