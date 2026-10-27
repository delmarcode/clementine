# Clementine usage rules

Clementine runs an app's agents durably on the app's own Postgres and
Oban. The app keeps three pieces of glue, and Clementine owns the rest:
the `agent_runs` table, the worker, claims, heartbeats, the reaper, and
the drain at shutdown.

## The glue

- One child after Oban, whose `repo` is Oban's repo:
  `{Clementine, repo: MyApp.Repo, oban: Oban, queue: :agents, agents: [MyApp.Agents.Triage], host: MyApp.Agents.Host}`.
- One migration calling `Clementine.Migration.up(version: 2)`. Each
  version stamps the table, and the runtime refuses to start against a
  table behind the code's version, naming the migration to write
  (`Clementine.Migration.up(from: 1, version: 2)`).
- Agent modules, each listed in `agents:`:
  `use Clementine.Agent, key: "triage", model: :claude_sonnet, instructions: "...", tools: [...]`.
  Every run row stores the key, so never rename a key that has runs. An
  agent whose runs are turns on a thread says `turn: true` and writes
  `history/1`.

`mix clementine.install` writes the glue, and `mix clementine.gen.agent
Triage` adds an agent with a tool and a test. Never copy a worker, a
lifecycle, or a reaper into the app.

## Subject, actor, turn, lane

- A run's **subject** is what it is about: `subject: {"ticket", ticket.id}`,
  stored as text. Its **actor** is whose authority it acts with:
  `actor: {"user", user.id}`. The host resolves both at every claim
  (`resolve_subject/2`, `resolve_actor/2`); a refusal cancels the run as
  unstartable. A run with no actor is the system's.
- A **turn** is a run on a thread: its subject is the thread, it reads
  the thread as history, and the host appends what it said. The agent
  declares it (`turn: true`), and `start/3` copies it to the row. Any
  other run is a **task**.
- The **lane** is the key under which active runs (queued, running, or
  waiting) are exclusive, held by the `agent_runs_lane_index`. A turn's
  lane is its thread, whichever agent: one active turn per thread. A
  task's lane is its agent and subject: tasks of different agents on one
  subject, and a turn and a task, run side by side. A run with no subject
  has no lane and blocks nothing.
- Busy means refused: a start in a busy lane returns
  `{:error, :active_run_exists}`. Queueing is a loop's job, not the
  runtime's.

## The API: `Clementine.Runs`

```elixir
{:ok, run} = Clementine.Runs.start(MyApp.Agents.Triage, prompt, subject: {"ticket", ticket.id}, actor: {"user", user.id})
:ok = Clementine.Runs.resume(run.id, {:approved, %{by: user.id}})
{:ok, :finished} = Clementine.Runs.cancel(run.id)
%Clementine.Runs.AgentRun{status: "completed", result: %{"output" => output}} = Clementine.Runs.get(run.id)
```

- `start/3` takes the agent module, `subject:`, `actor:`, and
  `metadata: %{}`, stored as given. It returns `:unknown_agent` or
  `:blank_prompt` for bad input, `:subject_required` for a turn without
  a subject id, and `:active_run_exists` for a busy lane. Inside the
  caller's transaction the run and its job commit with it.
- `resume/2` takes `{:approved, meta}` or `{:denied, meta}` for a waiting
  run; a denial's `meta[:message]` reaches the model. It returns
  `{:error, :not_found | :not_waiting}`, or the host's refusal. The claim
  that follows resolves the subject and actor again.
- `cancel/1` returns `{:ok, :finished}` for a queued or waiting run and
  `{:ok, :flagged}` for a running one. The flag reaches the run's process
  on whichever node runs it, which aborts the model call in flight and
  ends the run `cancelled`, unless it was already ending. A run that has
  ended returns `{:error, :already_terminal}`. Check who may cancel before
  calling it.
- Call `resume/2` and `cancel/1` outside a transaction: inside one they
  raise.
- `get/1` returns the run or `nil`. Read `agent_runs` freely; only
  Clementine writes it.
- The queries: `active?(agent, subject)` is a task's lane (does the agent
  have an active run on the subject); `active(subject)` is the thread's
  active turn, of whichever agent, or `nil`; `latest(subject, opts)` is
  the newest run on it, active or ended; `list(opts)` takes `subject:`,
  `agent:`, `turn:`, `actor:`, `kind:` (`:rollout` by default), and
  `limit:`, newest first. `AgentRun.active?/1` and `terminal?/1` read a
  run's status.

```elixir
Clementine.Runs.active?(MyApp.Agents.Triage, {"conversation", id})   # a screen in flight?
Clementine.Runs.active({"conversation", id})                         # the turn in flight, or nil
Clementine.Runs.list(subject: {"conversation", id}, turn: true)      # the thread's turns
Clementine.Runs.list(actor: {"user", id})                            # an account's runs
```

## A turn: `turn: true` and `history/1`

An agent that converses is a turn agent: `turn: true`, and `history/1`
on its module, the messages before the run's prompt, oldest first. The
runtime sends them to the model, then the prompt.

```elixir
defmodule MyApp.Agents.Chat do
  use Clementine.Agent, key: "chat", turn: true, model: :claude_sonnet, instructions: "Be brief."

  @impl true
  def history(run), do: MyApp.Chat.messages(run.subject_id)
end
```

- A turn agent with no `history/1` fails the build. A task agent may
  define one too; it defaults to `[]`.
- Return `Clementine.LLM.Message` structs: `UserMessage`,
  `AssistantMessage`, and `ToolResultMessage`. Anything else cancels the
  run as unstartable. Leave out the run's own prompt; where the cutoff
  falls is the app's rule.
- The conversation is the app's data, in its own table. Store each
  finished turn in `run_finished/2`: `result.input_message` (unless the
  app stored the user's message when it arrived) and `result.messages`,
  as `jsonb` through `Clementine.LLM.Message.to_map/1`. Read them back with
  `from_map/1`.
- One turn is one run with subject `{"conversation", id}`, so a second
  turn while one is in flight, of this agent or another, returns
  `{:error, :active_run_exists}`.
- `history/1` runs when a run starts, with `run.subject` and `run.actor`
  resolved. A run that resumes after an approval continues from its
  checkpoint and does not call it.

## The host module: which callback

One optional module, `@behaviour Clementine.Host`, named in `host:`. Every
callback is optional.

| Callback | When | Transaction |
| --- | --- | --- |
| `run_event/2` | each event while a run executes | none, in a process of its own |
| `run_transition/2` | each change short of the end | after it commits |
| `run_finished/2` | the end | inside it |
| `run_committed/2` | the end | after it commits |

The host hears a run in order: `:claimed`, its events, then the change
that stops the execution (`:suspended`, `:requeued`, or the end). Every
event arrives before the change that follows it, and
`:approval_requested` right after `:suspended`.

When a run ends, ask whether losing the work matters. Both hooks see
every end, as `Clementine.Result.Completed`, `Failed`, `Cancelled`, or
`Interrupted`, after a completed run's output is stored in `run.result`.
A `Cancelled` carries the stored reason: `%{"code" => "cancelled"}` from
`cancel/1`, and `%{"code" => "unstartable", "detail" => why}` for a run
the runtime could not build at a claim.

**It matters: `run_finished/2`.** It runs inside the transaction that ends
the run, so its writes commit with the run's end or not at all. Use it
for database writes, and for the Oban job that sends mail, calls a
webhook, or does anything else that leaves the database.

```elixir
@impl true
def run_finished(run, %Clementine.Result.Completed{output: output}) do
  MyApp.Tickets.record_triage!(run.subject_id, output)
  Oban.insert!(MyApp.Workers.TriageMail.new(%{"ticket_id" => run.subject_id}))
end

def run_finished(_run, _result), do: :ok
```

**It may be lost: `run_committed/2`.** It runs once, after the commit,
and never for an end that rolled back. Use it for PubSub broadcasts,
LiveView refreshes, and telemetry. A node that dies between the commit
and the call loses it. A `Clementine.RunView` closes on the run it hands
over (`RunView.close(view, run)`); nothing else is needed.

```elixir
@impl true
def run_committed(run, _result) do
  Phoenix.PubSub.broadcast(MyApp.PubSub, "ticket:#{run.subject_id}", {:run_ended, run.id})
end
```

**Streaming: `run_event/2`.** Each `Clementine.Event` (`:text_delta`,
`:tool_use_start`, `:tool_result`, `:approval_requested`, and the rest of
`Clementine.Event.types/0`) arrives in order, in a process of its own,
never inside a transaction. Broadcast it and return.

```elixir
@impl true
def run_event(run, %Clementine.Event{type: :text_delta, payload: %{content: text}}) do
  Phoenix.PubSub.broadcast(MyApp.PubSub, "conversation:#{run.subject_id}", {:text, run.id, text})
end

def run_event(_run, _event), do: :ok
```

The run waits for the callback once it is 64 events behind, and a
callback still stuck five seconds later hears no more of that
execution. Events are advisory: what a UI shows from them must also
follow from the stored conversation and the run's end.

**Status: `run_transition/2`.** Every change short of the end, after it
commits: `:claimed`, `:suspended`, `:resumed`, `:requeued`, or
`:cancel_requested`, with the run as the change committed it
(`run.status`, `run.lease_epoch`, `run.cancel`, and the rest): never read
the row again for them. It is best-effort, like `run_committed/2`, and
the end never reaches it: broadcast the end from `run_committed/2`.

```elixir
@impl true
def run_transition(run, transition) do
  Phoenix.PubSub.broadcast(MyApp.PubSub, "conversation:#{run.subject_id}", {:status, run.id, transition})
end
```

`authorize_resume/2` decides who may approve or deny a waiting run.
Without it, every resume is allowed.

```elixir
@impl true
def authorize_resume(run, {_verdict, %{by: user_id}}) do
  if MyApp.Tickets.may_approve?(user_id, run.subject_id), do: :ok, else: {:error, :forbidden}
end
```

`resolve_subject/2` turns the stored `{type, id}` into what the agent works
on, at every claim. Agents read it as `run.subject` and tools as
`context.subject`; `{:error, reason}` cancels the run, and so does a
subject type it has no clause for, so end with a catch-all.

```elixir
@impl true
def resolve_subject("ticket", id) do
  case MyApp.Tickets.get(id) do
    nil -> {:error, :ticket_not_found}
    ticket -> {:ok, ticket}
  end
end

def resolve_subject(_type, _id), do: {:ok, nil}
```

`resolve_actor/2` is the same contract for the stored actor: whose
authority the run acts with, as `run.actor` and `context.actor`. Refuse
it for an account that may no longer act (suspended, gone), and the run
is cancelled instead of started, or instead of resumed. A check that the
thread belongs to the actor is a comparison of `run.subject` and
`run.actor` in `agent/1` or a tool.

```elixir
@impl true
def resolve_actor("user", id) do
  case MyApp.Accounts.get_user(id) do
    %{suspended_at: nil} = user -> {:ok, user}
    nil -> {:error, :user_not_found}
    _suspended -> {:error, :user_suspended}
  end
end

def resolve_actor(_type, _id), do: {:ok, nil}
```

Tools see `context.run_id`, `context.agent_key`, `context.turn`,
`context.subject`, and `context.actor` (with `subject_type`,
`subject_id`, `actor_type`, and `actor_id` as stored).

## Never

- Never send mail, call a service, broadcast, or write files in
  `run_finished/2`. A rollback cannot take them back, and a retried end
  repeats them. Insert an Oban job there instead.
- Never put work that must happen in `run_committed/2` or
  `run_transition/2`. Only `run_finished/2` commits with the run.
- Never do slow work in any callback. `run_finished/2` holds the run's
  transaction open, `run_committed/2` and `run_transition/2` run in the
  run's worker, the reaper's sweep, or the caller of `resume/2` or
  `cancel/1`, and `run_event/2` runs once per token. Slow work is an Oban
  job inserted in `run_finished/2`.
- Never write the database from `run_event/2`. Store the conversation
  from the run's result in `run_finished/2`.
- Never write `agent_runs`, or insert, cancel, or retry a run's Oban job
  yourself.
- Never call `Clementine.Runs.resume/2` or `cancel/1` inside a
  transaction.
- Never call `Clementine.Lifecycle.*` (the protocol, the Ecto adapter,
  its codec, or its migration recipe) from an app on `Clementine.Runs`.
  `Clementine.RunView.close/2` takes the run; `Result.Cancelled.reason`
  is the stored reason.

## Not configurable

The child takes `repo`, `oban`, `queue`, `agents`, and `host`, and nothing
else is configurable. Run ids are UUIDs. A failed or interrupted run is
never retried (`max_attempts: 1`), because it may already have acted. The
reaper sweeps every minute with fixed thresholds and interrupts runs whose
node died. There is no option to look for: a need the runtime does not
meet is a change to Clementine.

## Testing

Oban runs in `:manual` testing mode, so the reaper does not start. Execute
a run with `perform_job(Clementine.Runs.Worker, %{"run_id" => run.id})`,
and script the model with `MyApp.AgentsCase`'s `expect_turn/1`,
`text_events/1`, and `tool_events/3`. Every host callback, `run_event/2`
included, has returned by the time `perform_job/2` does, so a test that
subscribed first finds the broadcasts in its mailbox.

To test a stop, run `perform_job/2` in a `Task`, wait until the model is
answering, and call `cancel/1` from the test. Script that answer as a
stream that arrives over time (an HTTP stub such as Bypass): a list from
`expect_turn/1` is already whole, so the run completes it.
