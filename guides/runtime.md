# The Durable Runtime

Clementine ships the durable machinery as a runtime: it owns the
`agent_runs` table, the Oban worker, the reaper, and the drain, and the
host writes only glue. Runs survive deploys, pause for approval, and get
finished by the reaper when their node dies, and a fix to any of that
reaches every host as a dependency bump.

The host keeps three things:

- a child after Oban in its supervision tree;
- one migration calling `Clementine.Migration.up(version: 4)`;
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

`repo` is required, and must be the repo Oban uses: a run and its job
commit in one transaction. `oban` defaults to `Oban`, `queue` to `:agents`
(declare it in the Oban config: `queues: [agents: 10]`), `agents` to
none, and `host` to none. Nothing else is configurable.

The migration builds `agent_runs`, keyed by UUID, with the column recipe,
the subject, the actor, the turn flag, and the lane index, plus the
loop inbox and the run trace beside it:

```elixir
defmodule MyApp.Repo.Migrations.AddClementine do
  use Ecto.Migration

  def up, do: Clementine.Migration.up(version: 4)
  def down, do: Clementine.Migration.down(version: 4)
end
```

Each version's DDL is frozen in `Clementine.Migration`, and each stamps
its number on the table. The runtime checks the stamp as it starts and
refuses to start against a table behind the code's version, naming the
migration to write: a host on version 3 adds one calling
`Clementine.Migration.up(from: 3, version: 4)`.

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

An agent that converses is a turn agent: `turn: true`, and `history/1`,
the messages before the run's prompt, oldest first, read from the app's
own tables. The runtime sends them to the model, then the prompt. It
runs when a run starts from its prompt, not when a run resumes after an
approval, whose checkpoint already holds the conversation:

```elixir
defmodule MyApp.Agents.Chat do
  use Clementine.Agent,
    key: "chat",
    turn: true,
    model: :claude_sonnet,
    instructions: "You are a helpful assistant. Be brief."

  @impl true
  def history(run), do: MyApp.Chat.messages(run.subject_id)
end
```

A turn is a run on a thread: its subject is the thread, and the host's
`run_finished/2` appends what it said (below). A turn agent without
`history/1` fails the build; any other agent is a task, and may define
one too.

## Subject, actor, and the lane

A run carries up to two references, stored as text and resolved by the
host at every claim: its subject, what it is about
(`subject: {"ticket", id}`), and its actor, whose authority it acts with
(`actor: {"user", id}`). Either refusal cancels the run as unstartable,
so a run acting for an account suspended while it waited for approval
never resumes.

Which decides the run's lane, the key under which active runs (queued,
running, or waiting) are exclusive, held by one unique index:

- a turn's lane is its thread, whichever agent it belongs to: at most
  one active turn per thread, so a second agent's turn on a busy thread
  is refused too;
- a task's lane is its agent and subject: tasks of different agents on
  one subject, and a turn and a task, run side by side;
- a run with no subject has no lane and blocks nothing.

Busy means refused: `start/3` returns `{:error, :active_run_exists}`. A
thread that should queue messages instead gets a loop, which holds the
lane and starts one turn at a time: `Clementine.Thread`, the controller
that ships with the runtime, or one of your own; see
[Durable Loops](durable-loops.md).

## Running agents

`Clementine.Runs` is the whole API:

<!-- guide-sample: parse-only -->
```elixir
{:ok, run} =
  Clementine.Runs.start(MyApp.Agents.Triage, prompt,
    subject: {"ticket", ticket.id},
    actor: {"user", user.id}
  )

Clementine.Runs.get(run.id)
#=> %Clementine.Runs.AgentRun{status: "completed", result: %{"output" => "..."}}

:ok = Clementine.Runs.resume(run.id, {:approved, %{by: user.id}})
{:ok, :finished} = Clementine.Runs.cancel(run.id)

Clementine.Runs.active?(MyApp.Agents.Triage, {"conversation", id})  # a screen in flight?
Clementine.Runs.active({"conversation", id})                        # the turn in flight, or nil
Clementine.Runs.latest({"conversation", id}, turn: true)            # the thread's newest turn
Clementine.Runs.list(actor: {"user", id}, limit: 50)                # an account's runs
```

A completed run stores its output in `result["output"]`: the answer's
text, or, for an agent with `output_schema:`, the decoded answer
(`%{"verdict" => "pass", ...}`), the same map `run_finished/2` sees in
`Result.Completed`'s `output`.

- `start/3` inserts the run and its Oban job in one transaction, and
  copies the agent's `turn` to the row. A start in a busy lane returns
  `{:error, :active_run_exists}`; a turn without a subject id,
  `{:error, :subject_required}`.
- `get/1` returns the row. Read it freely; only the runtime writes it.
  `AgentRun.active?/1` and `terminal?/1` read its status.
- `trace/1` returns the run's trace, below.
- `active?/2`, `active/1`, `latest/2`, and `list/1` read runs by subject,
  agent, turn, and actor, newest first, rollouts unless told
  `kind: :loop`.
- `resume/2` takes a waiting run's decision, `{:approved, meta}` or
  `{:denied, meta}`. A tool declared `approval: :required` parks its run
  in `waiting` before it executes, and one declared `{:policy, term}`
  does when the host's `authorize_tool/3` says so (see
  [Approvals](approvals.md)). The
  resume and the run's new job commit in one transaction, so a sweep can
  never find the resumed run without a job, and the claim that follows
  resolves the subject and actor again. A run waiting on the agents it
  asked takes no decision: `{:error, :delegating}`.
- `cancel/1` finishes a queued or waiting run at once and flags a running
  one. The flag goes on to the process running it, on whichever node, so
  the model call in flight is aborted and the run ends `cancelled`
  mid-response. On this node the runtime sends it directly; for another
  it notifies every node through Oban's notifier, so a notifier that
  cannot listen (Postgres behind a transaction pooler) leaves the run to
  find the flag at its next step.

## Asking other agents

An agent that needs another agent's answer before it goes on lists the
agents it may ask with `delegates:` (`Clementine.Delegation`):

<!-- guide-sample: parse-only -->
```elixir
defmodule MyApp.Agents.Planner do
  use Clementine.Agent,
    key: "planner",
    model: :claude_sonnet,
    instructions: "Plan the launch. Ask the researcher for facts you lack.",
    delegates: [MyApp.Agents.Researcher, MyApp.Agents.Writer]
end
```

The model sees a `delegate` tool taking `agent`, an enum of the
delegates' keys, and `prompt`, the child's whole brief. The tool lists
each delegate with its `description:`, so give each one a sentence on
when to ask it (`use Clementine.Agent, key: "researcher", description:
"Finds and cites facts.", ...`). Only `Clementine.Runs` offers
`delegate`; on `Clementine.run/3`, `stream/3`, and `AgentServer` the
agent's delegates are left out.

- **The call.** Each call starts a run of that agent: a child whose
  `parent_id` is the parent's, tagged `{:delegate, tool_use_id}`, with the
  parent's subject and actor and `metadata: %{"delegated_by" => "planner"}`.
  The children of one batch start in the transaction that parks the
  parent, so they exist exactly when it waits on them. A batch that also
  holds an approval-gated call waits for the decision first, then parks
  once for its children.
- **The resume.** A child's end reaches its parent inside the child's
  terminal transaction. The last one resumes the parent, on a new job,
  and each `delegate` call settles with its child's output: text as is,
  anything else (a map from `output_schema:`) JSON-encoded. A child that
  failed, was cancelled, or was interrupted settles as an error the model
  reads. A parent resumed and then drained before any effect requeues
  and resumes again with the same answers.
- **Lanes and cycles.** A child is a task on the parent's subject. A
  turn agent is never a delegate: the call is refused at once. A
  delegate with an active task on the subject, the parent itself or a
  sibling of the same batch included, is refused when the parent parks,
  and so is an agent above the parent in its chain of asks, subject or
  not. Each refusal is an error result the model reads; if no child of
  a batch could start, the parent resumes once its execution is over.
- **Cancel.** `cancel/1` of a waiting parent flags it (`{:ok, :flagged}`)
  and cancels its live children in the same transaction: a queued child
  ends, a running one gets its flag. The parent ends `cancelled` after
  the last of them, so a thread's erasure works as for any thread:
  cancel the loop, and purge from its `run_committed/2`, which runs once
  the turn and the turn's delegates have all ended. `cancel/1` of one
  child settles that call as cancelled once its siblings have ended.
- **The reaper** leaves a waiting parent alone, and a child it interrupts
  (its node died, or it was never claimed) resumes the parent like any
  end. A parent still waiting on children that have all ended (an end
  that never reached it) is resumed by a sweep once its park and its
  last child's end are a sweep interval old. `max_wait:` on
  the policy bounds a parent's wait as it bounds an approval's, and its
  end cancels the children.
- **Purge** follows `parent_id`, so `purge/1` of the subject takes the
  children and their traces.

`delegate` blocks the run that asks until every child ends. Fan-out
that a product drives (start several, decide on each answer, keep
answering the user meanwhile) belongs in a loop.

**Deploying it.** Ship this version of Clementine one deploy before any
agent offers `delegates:`. Nodes on older code drop a child's end when
its parent is a rollout, and cannot read a delegation's checkpoint: a
child they ran during a rolling deploy would leave its parent waiting
until a new node's reaper resumes it, and a parent they claimed would
fail as `:incompatible_checkpoint`.

## The trace

Every run records what it did, and `Clementine.Runs.trace/1` reads it
back, oldest first, as `Clementine.Trace.Entry` structs:

<!-- guide-sample: parse-only -->
```elixir
Clementine.Runs.trace(run.id)
#=> [
#=>   %Clementine.Trace.Entry{epoch: 1, seq: 1, kind: :execution,
#=>     payload: %{"model" => "claude-sonnet-5", "tools" => ["lookup"], "deferred" => [],
#=>                "agent_fingerprint" => "33e5…", "instructions" => "…", "resumed" => false}},
#=>   %Clementine.Trace.Entry{epoch: 1, seq: 2, kind: :model_call,
#=>     payload: %{"iteration" => 1, "stop_reason" => "tool_use", "duration_ms" => 812,
#=>                "usage" => %{"input_tokens" => 1204, "output_tokens" => 38,
#=>                             "cache_read_tokens" => 1100, "cache_write_tokens" => 96},
#=>                "alias" => "claude_sonnet", "cost" => %{"currency" => "USD", "micros" => 1284},
#=>                "content" => […]}},
#=>   %Clementine.Trace.Entry{epoch: 1, seq: 3, kind: :tool_call,
#=>     payload: %{"name" => "lookup", "args" => %{"query" => "…"}, "result" => "…",
#=>                "is_error" => false, "duration_ms" => 40, "approval" => nil,
#=>                "policy" => nil, …}},
#=>   …
#=> ]

tools_called = for %{kind: :tool_call, payload: %{"name" => name}} <- Clementine.Runs.trace(run.id), do: name
```

- An `:execution` entry opens each execution: when the run starts, and
  again, `"resumed" => true`, when it resumes after an approval or a
  delegation, under the next epoch. `"tools"` names every tool offered,
  `"deferred"` the ones among them the model loads through tool search,
  `"skills"` the skills it may load, and `"delegates"` the agents it may
  ask. Its `"agent_fingerprint"` is a sha256 over the system prompt, the
  tool schemas, the model id, which tools are deferred, the output
  schema, the skills offered (names, descriptions, and their tools'
  schemas), and the delegates' keys, so runs that offered the model the
  same thing group together.
- A `:model_call` entry records each call to the model, a call cut off
  by a cancel included, with the usage it had reported, the alias it ran
  on, and its cost at that alias's prices then (`nil` without prices;
  `Clementine.Runs.cost/2` sums a run's, and `docs/MODELS.md` has the
  `pricing:` key). A `:tool_call`
  entry records each tool call started, with the arguments it ran with
  and the decision it waited on (`"approval" => %{"verdict" => "approved",
  "by" => ...}`); a call to a `{:policy, term}` tool also carries the
  tool policy's verdict (`"policy" => %{"verdict" => "allow" |
  "require_approval" | "deny", "reason" => ..., "failed" => ...}`), and a
  call it denied ran nothing. A `:policy` entry records each answer the
  policy gave, as it gave it, so a run that ends while it waits still
  shows the policy asked for approval. A call a cancel or a drain cut off is there too: with
  its result if it had one, and `"killed" => true` if it was killed
  before it answered, so what it did is unknown. A `:skill_load` entry
  records each skill the model loaded (`Clementine.Skill`), with the
  tools it brought and a sha256 of the body the model read, just before
  the `use_skill` call that loaded it. A `:delegate` entry records each
  child a `delegate` call started, with its agent, its run id (`trace/1`
  of it is the child's own trace), and how it ended, just before the
  call's `:tool_call` entry, when the parent resumes.
- The runner writes new entries at every iteration boundary, fenced on
  the epoch like the heartbeat, and the rest with the run's end or park,
  in the same transaction: `run_finished/2` already sees the whole trace.
  A run reaped after its node died has its trace up to its last
  boundary.
- `trace: :facts` on the agent keeps names, arguments, ids, timing,
  usage, and the fingerprint, and leaves out the system prompt, what the
  model said, and what each tool returned. A turn agent whose host stores
  the conversation loses nothing by it; a task agent keeps the default,
  `:content`, because nothing else holds its trajectory.
- The trace lives in `agent_run_trace`, which only Clementine writes, and
  goes with the run: `purge/1` erases it. It is not your audit log: a
  security event that must outlive a purged conversation goes in your
  own table, from the tool or the context function that caused it.
- `trace/1` checks nothing, like `get/1`: check the run's subject or actor
  before showing a trace to anyone.

## The host module

Eight questions belong to the app, and one optional module answers them.
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

  # Whether a call to a tool declared approval: {:policy, term} runs,
  # waits for approval, or is refused with a reason the model reads.
  # Before the call's batch runs anything; a raise denies the call.
  @impl true
  def authorize_tool(run, %Clementine.ApprovalRequest{args: args}, :refund) do
    cond do
      not MyApp.Accounts.may_refund?(run.actor) -> {:deny, "You may not issue refunds."}
      args["amount_cents"] > 50_00 -> :require_approval
      true -> :allow
    end
  end

  def authorize_tool(_run, _request, _term), do: {:deny, "No policy covers this tool."}

  # Tokens and tool activity while a run executes, for a UI. In a process
  # of its own, in order, outside any transaction.
  @impl true
  def run_event(run, %Clementine.Event{type: :text_delta, payload: %{content: text}}) do
    broadcast(run, {:run_text, run.id, text})
  end

  def run_event(_run, _event), do: :ok

  # Every change short of the end: claimed, suspended, resumed, requeued,
  # cancel requested. After the commit, best-effort.
  @impl true
  def run_transition(run, transition) do
    broadcast(run, {:run_status, run.id, transition})
  end

  # What must happen when a run ends. Inside the transaction that ends
  # it: these writes, and the mail job, commit with the run's end or not
  # at all. A chat turn stores its messages here.
  @impl true
  def run_finished(%{agent_key: "chat"} = run, %Result.Completed{} = result) do
    MyApp.Chat.append!(run.subject_id, [result.input_message | result.messages])
  end

  def run_finished(run, %Result.Completed{output: output}) do
    MyApp.Tickets.record_triage!(run.subject_id, output)
    Oban.insert!(MyApp.Workers.TriageMail.new(%{"ticket_id" => run.subject_id}))
  end

  def run_finished(_run, _result), do: :ok

  # Who hears of the end. After the commit, once, best-effort.
  @impl true
  def run_committed(run, _result) do
    broadcast(run, {:run_ended, run.id})
  end

  # How a subject resolves, at every claim. An error cancels the run as
  # unstartable.
  @impl true
  def resolve_subject("ticket", id) do
    case MyApp.Tickets.get(id) do
      nil -> {:error, :ticket_not_found}
      ticket -> {:ok, ticket}
    end
  end

  def resolve_subject(_type, _id), do: {:ok, nil}

  # How an actor resolves, at every claim, the one after a resume
  # included. A refusal cancels the run as unstartable.
  @impl true
  def resolve_actor("user", id) do
    case MyApp.Accounts.get_user(id) do
      %{suspended_at: nil} = user -> {:ok, user}
      nil -> {:error, :user_not_found}
      _suspended -> {:error, :user_suspended}
    end
  end

  def resolve_actor(_type, _id), do: {:ok, nil}

  defp broadcast(run, message) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "#{run.subject_type}:#{run.subject_id}", message)
  end
end
```

A run reaches the host in order: its claim, its events, then the change
that stops the execution (a suspension, a requeue, or the end), every
event before the change that follows it. Only `run_finished/2` runs
inside a transaction; everything else comes after a commit, never for a
write that rolled back. A `Clementine.Result.Cancelled` carries the
stored reason: `%{"code" => "cancelled"}` from `cancel/1`, and
`%{"code" => "unstartable", "detail" => why}` for a run the runtime could
not build at a claim. A `Clementine.RunView` closes on the run
`run_committed/2` hands over (`RunView.close(view, run)`).

`run_event/2` gets each `Clementine.Event` in a process of its own. The
run does not wait for each call, but it waits once the callback falls 64
events behind, and a callback still stuck five seconds later hears no
more of that execution while the run goes on. Events are advisory: a UI
that misses some recovers from the stored conversation and the run's
end. `run_transition/2` hears every change short of the end, in
whichever process wrote it, with the run as that change committed it;
the end reaches only the two finish hooks.

Both finish hooks see every end (`Completed`, `Failed`, `Cancelled`,
`Interrupted`), after the runtime stored a completed run's output in
`result`. To choose between them, ask whether losing the work matters:

- **It matters**: `run_finished/2`, inside the transaction that ends the
  run. Raising aborts the end, and the runner retries it, so nothing that
  leaves the database belongs here: send mail or call services from an
  Oban job inserted here, which commits with the run.
- **It may be lost**: `run_committed/2`, after that transaction commits,
  once, and never for an end that rolled back. It runs in whichever
  process wrote the end (the worker, the reaper, or the caller of
  `cancel/1`), and a raise there is logged. A node that dies between the
  commit and the call loses it.

Keep every callback fast, and call `resume/2` and `cancel/1` outside a
transaction (they raise inside one, because the host would hear of their
writes before the caller's commit). The resolved subject and actor reach
`agent/1` and `history/1` as `run.subject` and `run.actor`, and every
tool as `context.subject` and `context.actor`, beside `context.run_id`,
`context.agent_key`, `context.turn`, and `context.metadata` (the run's
metadata as `start/3` stored it).

Coding agents working in the app get these rules from
[`usage-rules.md`](../usage-rules.md), which the
[`usage_rules`](https://hexdocs.pm/usage_rules) package gathers into the
app's `AGENTS.md`.

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
- **Retries.** None (`max_attempts: 1`): a failed or interrupted run may
  already have acted. The reaper interrupts; only the drain requeues, and
  only runs that have not touched the world.

## Moving from a copied runtime

Before the runtime moved into the library, `mix clementine.install`
copied it into the app as `MyApp.Agents.{AgentRun, Lifecycle, Definition,
Catalog, Runs, RunWorker, Reaper, DrainNotifier}`. Its table (for apps
generated with binary ids) is version 1's table before two changes: the
agent column was `agent`, and the single-active index covered
`(subject_type, subject_id)`. Step 6 migrates it, and every row stays.

Move in one switch deploy. The migration renames a column the copied
runtime reads, so stop every old node before it runs; a rolling deploy
would leave old nodes failing on the missing column.

1. Delete those modules except `RunWorker`, their tests, and the
   `MyApp.Agents.Runners`, `Reaper`, and `DrainNotifier` children.
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
   `get/1`, `run.agent` with `run.agent_key`, and `RunWorker` with
   `Runs.Worker` in tests.
6. Keep the old migration, and do not add `Clementine.Migration.up/1`:
   the table exists. Add one that brings it to version 1, then one
   calling `Clementine.Migration.up(from: 1, version: 2)` (the runtime
   refuses to start against version 1, and says so). The hand-rolled
   version 1 carries no version stamp; the upgrade stamps it. The
   upgrade adds `turn` as `false` on every row and backfills nothing,
   because which keys are turn agents is the app's code: when the table
   holds rows, set `turn` for the turn agents' rows in that same
   migration, right after the upgrade
   (`execute "UPDATE agent_runs SET turn = true WHERE agent_key IN ('chat')"`),
   so an active turn keeps its thread the moment the lane index exists:

   ```elixir
   defmodule MyApp.Repo.Migrations.MatchClementineVersion1 do
     use Ecto.Migration

     def change do
       rename table(:agent_runs), :agent, to: :agent_key
       execute "ALTER INDEX agent_runs_agent_index RENAME TO agent_runs_agent_key_index",
               "ALTER INDEX agent_runs_agent_key_index RENAME TO agent_runs_agent_index"

       drop index(:agent_runs, [:subject_type, :subject_id],
              name: :agent_runs_single_active_run_index,
              unique: true,
              where: "status IN ('queued', 'running', 'waiting') AND kind = 'rollout'"
            )

       create unique_index(:agent_runs, [:agent_key, :subject_type, :subject_id],
                name: :agent_runs_single_active_run_index,
                where: "status IN ('queued', 'running', 'waiting') AND kind = 'rollout'"
              )
     end
   end
   ```

   Any later version arrives the same way, `up(from: 3, version: 4)`.
7. Keep `RunWorker` for one deploy, reduced to a forwarder. Jobs queued
   before the switch name it, and so do jobs the old nodes requeued while
   they drained; without it they fail, and the reaper interrupts their
   runs. The job arguments are the same:

   ```elixir
   defmodule MyApp.Agents.RunWorker do
     use Oban.Worker, queue: :agents, max_attempts: 1

     @impl Oban.Worker
     def perform(job), do: Clementine.Runs.Worker.perform(job)
   end
   ```

   Delete it in a later deploy, once no unfinished job names it:
   `SELECT count(*) FROM oban_jobs WHERE worker = 'MyApp.Agents.RunWorker'
   AND state NOT IN ('completed', 'cancelled', 'discarded')` returns 0.

An app whose run machinery grew on its own (yakky's `Yakky.Agents`)
moves the same way once its table matches version 1, and then takes
version 2. Compare it column by column first: version 1 names the agent
column `agent_key`, stores `subject_id` as text, scopes the single-active
index by `(agent_key, subject_type, subject_id)`, and inserts rows with
no other required columns. Product columns that version 2 answers (who
the run acts for, whether it is a turn, the thread's latest turn) go;
the rest may stay as long as they are nullable or have defaults. A chat
turn's history moves to the agent's `history/1`, its token stream to
`run_event/2`, broadcasts of its other transitions to
`run_transition/2`, and broadcasts of its end to `run_committed/2`.
