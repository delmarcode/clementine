# Clementine usage rules

Clementine runs an app's agents durably on the app's own Postgres and
Oban. The app keeps three pieces of glue, and Clementine owns the rest:
the `agent_runs` table, the worker, claims, heartbeats, the reaper, and
the drain at shutdown.

## The glue

- One child after Oban, whose `repo` is Oban's repo:
  `{Clementine, repo: MyApp.Repo, oban: Oban, queue: :agents, agents: [MyApp.Agents.Triage], host: MyApp.Agents.Host}`.
- One migration calling `Clementine.Migration.up(version: 1)`.
- Agent modules, each listed in `agents:`:
  `use Clementine.Agent, key: "triage", model: :claude_sonnet, instructions: "...", tools: [...]`.
  Every run row stores the key, so never rename a key that has runs.

`mix clementine.install` writes the glue, and `mix clementine.gen.agent
Triage` adds an agent with a tool and a test. Never copy a worker, a
lifecycle, or a reaper into the app.

## The API: `Clementine.Runs`

```elixir
{:ok, run} = Clementine.Runs.start(MyApp.Agents.Triage, prompt, subject: {"ticket", ticket.id})
:ok = Clementine.Runs.resume(run.id, {:approved, %{by: user.id}})
{:ok, :finished} = Clementine.Runs.cancel(run.id)
%Clementine.Runs.AgentRun{status: "completed", result: %{"output" => output}} = Clementine.Runs.get(run.id)
```

- `start/3` takes the agent module. Each agent has at most one queued,
  running, or waiting run per subject: starting the same agent again
  returns `{:error, :active_run_exists}`, and a different agent on the
  same subject starts. It returns `:unknown_agent` or `:blank_prompt` for
  bad input. `metadata: %{}` is stored as given.
- `resume/2` takes `{:approved, meta}` or `{:denied, meta}` for a waiting
  run; a denial's `meta[:message]` reaches the model. It returns
  `{:error, :not_found | :not_waiting}`, or the host's refusal.
- `cancel/1` returns `{:ok, :finished}` for a queued or waiting run and
  `{:ok, :flagged}` for a running one, which stops at its next step.
  Check who may cancel before calling it, and call it outside a
  transaction: inside one it raises.
- `get/1` returns the run or `nil`. Read `agent_runs` freely; only
  Clementine writes it.

## The host module: which callback

One optional module, `@behaviour Clementine.Host`, named in `host:`. Every
callback is optional.

When a run ends, ask whether losing the work matters. Both hooks see
every end, as `Clementine.Result.Completed`, `Failed`, `Cancelled`, or
`Interrupted`, after a completed run's output is stored in `run.result`.

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
and the call loses it.

```elixir
@impl true
def run_committed(run, _result) do
  Phoenix.PubSub.broadcast(MyApp.PubSub, "ticket:#{run.subject_id}", {:run_ended, run.id})
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
`context.subject`; `{:error, reason}` cancels the run.

```elixir
@impl true
def resolve_subject("ticket", id) do
  case MyApp.Tickets.get(id) do
    nil -> {:error, :ticket_not_found}
    ticket -> {:ok, ticket}
  end
end
```

## Never

- Never send mail, call a service, broadcast, or write files in
  `run_finished/2`. A rollback cannot take them back, and a retried end
  repeats them. Insert an Oban job there instead.
- Never put work that must happen in `run_committed/2`.
- Never do slow work in either hook. `run_finished/2` holds the run's
  transaction open, and `run_committed/2` runs in the run's worker, the
  reaper's sweep, or the caller of `cancel/1`. Slow work is an Oban job
  inserted in `run_finished/2`.
- Never write `agent_runs`, or insert, cancel, or retry a run's Oban job
  yourself.
- Never call `Clementine.Runs.cancel/1` inside a transaction.

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
`text_events/1`, and `tool_events/3`.
