# The Durable Runtime

Clementine ships the durable machinery as a runtime: it owns the
`agent_runs` table, the Oban worker, the reaper, and the drain, and the
host writes only glue. Runs survive deploys, pause for approval, and get
finished by the reaper when their node dies, and a fix to any of that
reaches every host as a dependency bump.

The host keeps three things:

- a child after Oban in its supervision tree;
- one migration calling `Clementine.Migration.up(version: 1)`;
- `use Clementine.Agent` modules.

`mix clementine.install` writes them (plus the config and a test case),
and `mix clementine.gen.agent Weather` adds an agent with a tool and a
test. An app that needs its own run table and worker builds them from the
pieces instead; [Durable Execution](durable-execution.md) walks that
path.

## The glue

The child goes after Oban, so the runtime can check Oban is running, and
so it stops first at shutdown and drains its runs while Oban still owes
them the grace period:

<!-- guide-sample: parse-only -->
```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Oban, Application.fetch_env!(:my_app, Oban)},
  {Clementine,
   repo: MyApp.Repo,
   oban: Oban,
   queue: :agents,
   agents: [MyApp.Agents.Weather],
   host: MyApp.Agents.Host}
]
```

`repo` is required. `oban` defaults to `Oban`, `queue` to `:agents`
(declare it in the Oban config: `queues: [agents: 10]`), `agents` to
none, and `host` to none. Nothing else is configurable.

The migration builds `agent_runs`, keyed by UUID, with the column recipe
and the single-active index on `(subject_type, subject_id)`:

```elixir
defmodule MyApp.Repo.Migrations.AddClementine do
  use Ecto.Migration

  def up, do: Clementine.Migration.up(version: 1)
  def down, do: Clementine.Migration.down(version: 1)
end
```

An agent is a module with a stable key, the string its run rows store:

```elixir
defmodule MyApp.Agents.Weather do
  use Clementine.Agent,
    key: "weather",
    model: :claude_sonnet,
    instructions: "Answer questions about the weather in a few sentences.",
    tools: [],
    defaults: [max_iterations: 10, max_duration: :timer.minutes(5)]
end
```

When the agent depends on the run, write `agent/1` instead; the runtime
calls it at every claim:

```elixir
defmodule MyApp.Agents.Triage do
  use Clementine.Agent, key: "triage"

  @impl true
  def agent(run) do
    Clementine.Agent.new(
      model: :claude_sonnet,
      instructions: "Triage this ticket: #{inspect(run.subject)}"
    )
  end
end
```

## Running agents

`Clementine.Runs` is the whole API:

<!-- guide-sample: parse-only -->
```elixir
{:ok, run} = Clementine.Runs.start(MyApp.Agents.Triage, prompt, subject: {"ticket", ticket.id})

Clementine.Runs.get(run.id)
#=> %Clementine.Runs.AgentRun{status: "completed", result: %{"output" => "..."}}

:ok = Clementine.Runs.resume(run.id, {:approved, %{by: user.id}})
{:ok, :finished} = Clementine.Runs.cancel(run.id)
```

- `start/3` inserts the run and its Oban job in one transaction. A
  subject has at most one active run (queued, running, or waiting):
  a second start returns `{:error, :active_run_exists}`. A subject with a
  `nil` id never blocks another.
- `get/1` returns the row. Read it freely; only the runtime writes it.
- `resume/2` takes a waiting run's decision, `{:approved, meta}` or
  `{:denied, meta}`. A tool declared `approval: :required` parks its run
  in `waiting` before it executes (see [Approvals](approvals.md)). The
  resume and the run's new job commit in one transaction, so a sweep can
  never find the resumed run without a job.
- `cancel/1` finishes a queued or waiting run at once and flags a running
  one, which stops at its next boundary.

## The host module

Three questions belong to the app, and one optional module answers them.
Every callback is optional:

```elixir
defmodule MyApp.Agents.Host do
  @behaviour Clementine.Host

  alias Clementine.Result

  # Who may approve or deny a waiting run.
  @impl true
  def authorize_resume(run, {_verdict, %{by: user_id}}) do
    if MyApp.Tickets.may_approve?(user_id, run.subject_id), do: :ok, else: {:error, :forbidden}
  end

  def authorize_resume(_run, _decision), do: {:error, :forbidden}

  # What happens when a run finishes. Inside the terminal write's
  # transaction: these writes commit with the status or not at all.
  @impl true
  def run_finished(run, %Result.Completed{output: output}) do
    MyApp.Tickets.record_triage!(run.subject_id, output)
  end

  def run_finished(_run, _result), do: :ok

  # How a subject resolves, at every claim. An error cancels the run as
  # unstartable.
  @impl true
  def resolve_subject("ticket", id) do
    case MyApp.Tickets.get(id) do
      nil -> {:error, :ticket_not_found}
      ticket -> {:ok, ticket}
    end
  end
end
```

`run_finished/2` sees every terminal (`Completed`, `Failed`, `Cancelled`,
`Interrupted`), after the runtime stored a completed run's output in
`result`. Because it runs inside the transaction, raising aborts the
terminal write; send email or call services from an Oban job inserted
here, which commits with the run. The resolved subject reaches `agent/1`
as `run.subject` and every tool as `context.subject`.

## Testing

Oban runs in `:manual` testing mode in the test environment, and so the
reaper does not start there (Oban's own plugins don't either). Script the
model with a Mox mock set as Clementine's `llm_client`, and execute a run
with `Oban.Testing`:

<!-- guide-sample: parse-only -->
```elixir
{:ok, run} = Clementine.Runs.start(MyApp.Agents.Weather, "Is it sunny?")

expect(MyApp.Agents.LLMMock, :stream, fn _model, _system, _messages, _tools, _opts ->
  [{:text_delta, "Sunny."}, {:message_delta, %{"stop_reason" => "end_turn"}, %{}}]
end)

assert :ok = perform_job(Clementine.Runs.Worker, %{"run_id" => run.id})
assert %{status: "completed"} = Clementine.Runs.get(run.id)
```

`mix clementine.install` writes the mock, makes it the `llm_client` in
`config/test.exs`, and writes `MyApp.AgentsCase`, whose `expect_turn/1`,
`text_events/1`, and `tool_events/3` script turns like this one.
The runtime's own suite proves the concurrency claims against Postgres in
Clementine's CI: the conformance suite on `agent_runs`, the resume racing
a sweep, a burst that outgrows the queue, the reaper, and the drain.

## Operations

- **Reaper.** Every node sweeps once a minute with
  `Clementine.Reconciler.Policy`'s defaults: a running run whose heartbeat
  is two minutes stale is interrupted, and so is a queued run whose job
  started executing fifteen minutes ago without claiming it. Time a job
  spends waiting in a busy queue does not count, so a burst bigger than
  the queue's limit waits rather than being interrupted. A waiting run is
  never reaped. Sweeps on several nodes need no coordination.
- **Drain.** At shutdown, runs that have not touched the world are
  requeued for the next node, and the rest finish `interrupted`. Give
  them time with Oban's `shutdown_grace_period` and keep the platform's
  termination grace above it.
- **Retries.** None by default (`max_attempts: 1`): a failed or
  interrupted run may already have acted, and only the reaper may requeue.

## Moving from a copied runtime

Before the runtime moved into the library, `mix clementine.install`
copied it into the app as `MyApp.Agents.{AgentRun, Lifecycle, Definition,
Catalog, Runs, RunWorker, Reaper, DrainNotifier}`. The table it generated
is the table `Clementine.Migration` version 1 builds (for apps generated
with binary ids), so moving keeps every row:

1. Delete those modules, their tests, and the `MyApp.Agents.Runners`,
   `Reaper`, and `DrainNotifier` children.
2. Add `{Clementine, repo: ..., agents: [...]}` after Oban, listing the
   agents from `config :my_app, MyApp.Agents.Catalog`, and delete that
   config.
3. Turn each agent's `@behaviour MyApp.Agents.Definition` into
   `use Clementine.Agent, key: "..."` with the same key, keeping its
   `agent/1`.
4. Move anything the copied `Lifecycle.project/3` did beyond storing the
   output into `run_finished/2` of a host module, and any authorization
   around `Runs.resume/2` into `authorize_resume/2`.
5. Replace `MyApp.Agents.Runs.start("key", prompt)` with
   `Clementine.Runs.start(MyApp.Agents.Key, prompt)`, `get_run/1` with
   `get/1`, and `RunWorker` with `Clementine.Runs.Worker` in tests.
6. Keep the old migration and do not add `Clementine.Migration.up/1`:
   the table exists. A later version arrives as
   `Clementine.Migration.up(from: 1, version: 2)`.

An app whose run machinery grew on its own (yakky's `Yakky.Agents`)
moves the same way once its table matches version 1. Compare it column
by column first: version 1 names the agent column `agent`, stores
`subject_id` as text, scopes the single-active index by
`(subject_type, subject_id)`, and inserts rows with no other required
columns. Product columns may stay as long as they are nullable or have
defaults. What such an app does on top (chat turns that load a
conversation's history, broadcasts on every transition) stays in the
app.
