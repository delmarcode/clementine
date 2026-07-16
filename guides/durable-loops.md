# Durable Loops

A loop is a durable receive: OTP process semantics lifted to
organizational timescale, with your database as the mailbox. Where a
[durable run](durable-execution.md) is one attempt at one bounded piece
of work, a loop is a *standing entity* — an agent that owns an email
thread for months, a judge that retries until quality passes, a watcher
that polls forever. Messages, child completions, and timer expirations
arrive in its **inbox**; each wake is a **step** that drains inputs
through your pure `handle/2` and commits *everything the step caused* —
consumed inputs, new state, child runs and their jobs, outbound messages,
timer schedules, and the park/continue/finish transition — in **one
atomic unit**. Nothing durable exists that a committed step did not
create, which is why a crashed step replays to an identical commit and a
loop is always safe to retry.

The division of labor is the durable-execution guide's, extended one
floor up: **the loop decides; children act.** All real work — model
calls, tools, effects, approval gates — lives in child rollout-runs with
their own leases and fences. Loops never build rollouts: steps emit
JSON-safe child *args*, and your host constructs the rollout at the child
boundary, exactly like the worker you already have.

This guide wires a webhook-fed email thread agent end to end: migration,
host module, the loop itself, the Oban topology, webhook feeding, and the
reaper's loop sweep. It assumes the durable-execution guide's setup
(`agent_runs` table, `MyApp.ClementineLifecycle`, a run worker); the
judge and watcher shapes and the local script path close it out. The
operations story — telemetry, paging signals, and the loop doctor — is
[its own guide](loop-operations.md).

## The shape

```text
webhook ──create/append──▶ inbox ──wake──▶ step (claim ▶ drain ▶ commit)
                                             │ commit cargo
                                             ├─▶ child run rows + jobs ──▶ child worker
                                             │      build_child ▶ Runner.execute
                                             │      terminal projection ──append──▶ inbox
                                             ├─▶ timer schedules ──fire──▶ inbox
                                             └─▶ sends to other loops ──▶ their inboxes
```

Everything arrives through the inbox; the inbox is the only wake source.
A parked loop is a `waiting` run row — one cheap row, no process, no
heartbeat. Dormant loops cost storage, not compute.

Two atomicity sentences carry the whole design (the library's Ecto
adapter implements both; the conformance battery verifies either path):

1. **The step commit is one atomic unit** — and a park re-verifies inside
   that unit that nothing arrived mid-step, downgrading itself to a
   continue if something did.
2. **An append is one atomic unit** — input row, wake, and step-job
   enqueue commit together.

Together they close every lost-wakeup interleaving at the database lock.

## Step 0 — The migration

The loop recipe extends the run table you already have (`kind` ships with
`run_columns/0`) and adds the inbox table. Loops live in the *same* table
as runs, discriminated by `kind` — a conversation's loop row and its turn
children are rows in one table:

```elixir
defmodule MyApp.Repo.Migrations.AddLoopSupport do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      # loop_module, loop_args, loop_policy, envelope, state_version,
      # loop_scope — the persisted spec and the machinery's state wrapper.
      Clementine.Loop.Ecto.Migration.loop_columns()

      # loop_ref + tag_key — the child side of the correlation.
      Clementine.Loop.Ecto.Migration.child_columns()
    end

    # Creation's insert-or-get key: unique where present.
    Clementine.Loop.Ecto.Migration.loop_scope_index(:agent_runs)

    # (loop_ref, tag_key) unique WHERE ACTIVE — a dedup index, not
    # single-active: crash-replay re-dispatch no-ops, fan-out is free.
    Clementine.Loop.Ecto.Migration.child_dedup_index(:agent_runs)

    # The per-loop FIFO: kind, payload, dedup_key (unique per loop),
    # attempts, inserted_at, dead_at/dead_reason.
    Clementine.Loop.Ecto.Migration.create_inbox(:agent_loop_inbox)
  end
end
```

Your Ecto schema grows the matching fields:

```elixir
defmodule MyApp.Runs.AgentRun do
  use Ecto.Schema

  schema "agent_runs" do
    field :conversation_id, :integer
    field :user_message, :string
    field :oban_job_id, :integer

    field :kind, :string, default: "rollout"
    field :status, :string, default: "queued"
    field :lease_epoch, :integer, default: 0
    field :executor_id, :string
    field :heartbeat_at, :utc_datetime_usec
    field :deadline, :utc_datetime_usec
    field :queued_at, :utc_datetime_usec
    field :cancel, :map
    field :suspension, :map
    field :resume, :map
    field :effects, :boolean, default: false
    field :usage, :map
    field :error, :map
    field :interrupt, :map
    field :finished_at, :utc_datetime_usec

    field :loop_module, :string
    field :loop_args, :map
    field :loop_policy, :map
    field :envelope, :map
    field :state_version, :integer
    field :loop_scope, :string
    field :loop_ref, :integer
    field :tag_key, :string

    timestamps()
  end
end
```

Two consequences to internalize now, both from the shared table:

- **Billing queries must discriminate on `kind`.** The machinery
  aggregates every child's usage into its parent loop's row (that is the
  reporting surface — per-agent spend in one read), so a naive
  `SUM(usage)` counts every token twice. Sum `WHERE kind = 'rollout'`.
- **If you had a single-active-per-scope index for conversations, it
  retires** when those conversations become loops — a loop is permanently
  active by design. Its two jobs move to their successors: duplicate
  protection to the loop scope key and the `(loop_ref, tag_key)` index,
  one-turn-at-a-time to `handle/2` logic, where it belongs.

## Step 1 — The lifecycle glue and the loop host

Two small additions to the lifecycle module you already have, then the
loop host module. The additions are the **completion glue** — the pair
that makes child-terminal delivery exactly-once:

```elixir
defmodule MyApp.ClementineLifecycle do
  use Clementine.Lifecycle.Ecto,
    repo: MyApp.Repo,
    schema: MyApp.Runs.AgentRun

  @impl Clementine.Lifecycle.Ecto
  def project(result, run, ctx) do
    # Your product projection, unchanged: runs that belong to a
    # conversation append their messages.
    if run.conversation_id do
      MyApp.Chat.project_result!(run, result)
    end

    # The loop glue, called unconditionally: for a loop child this
    # appends {:completed, tag, result} to the parent's inbox INSIDE the
    # child's terminal transaction — exactly-once at source, because
    # terminals are dead ends. For every other row it is a no-op.
    Clementine.Loop.Ecto.append_completion(MyApp.LoopHost, result, run, ctx)
  end

  @impl Clementine.Lifecycle.Ecto
  def after_transition(facts, transition, ctx) do
    # Post-commit, best-effort by design: wake the parent loop whose
    # child just reached a terminal. Delivery was already durable in the
    # transaction above; a lost wake is healed by the reaper's
    # :wake_pending verdict.
    Clementine.Loop.Ecto.wake_parent(MyApp.LoopHost, transition, ctx)

    MyApp.Observation.broadcast(facts, transition)
    :ok
  end
end
```

The loop host implements `Clementine.Loop.Host` — the loop layer's
storage contract. With the Ecto adapter you write four functions, all
host meaning:

```elixir
defmodule MyApp.LoopHost do
  use Clementine.Loop.Ecto,
    lifecycle: MyApp.ClementineLifecycle,
    inbox_table: "agent_loop_inbox"

  # Where rollouts come from: the child worker calls this at spawn
  # execution time with the JSON-safe args the step committed. Load
  # whatever they reference — agent config, history BY CURSOR from the
  # messages table — and build the rollout here, never in the loop.
  @impl Clementine.Loop.Host
  def build_child(_facts, _tag, %{"agent_id" => agent_id} = args, _ctx) do
    agent = MyApp.Agents.load!(agent_id)
    history = MyApp.Chat.messages_through(agent_id, args["history_through"])

    {:ok,
     Clementine.Rollout.new(
       agent: agent,
       input: MyApp.Chat.render_email!(args["email_id"], args["feedback"]),
       messages: history
     )}
  end

  # The step job. Called inside the atomic units (creation, appends,
  # continues, park downgrades) and standalone (the reaper's :reenqueue)
  # — Oban.insert/2 against the same repo commits with whichever unit is
  # open, because jobs are rows.
  @impl Clementine.Loop.Host
  def enqueue_step(loop_ref, _ctx) do
    {:ok, _job} = Oban.insert(MyApp.Workers.LoopStepWorker.new(%{"loop_ref" => loop_ref}))
    :ok
  end

  # The child's job, inserted in the same unit as its run row. The
  # durable args ride the job to build_child/4.
  @impl Clementine.Loop.Ecto
  def enqueue_child(child_row, child_args, _ctx) do
    {:ok, _job} =
      Oban.insert(
        MyApp.Workers.AgentRunWorker.new(%{"run_id" => child_row.id, "args" => child_args})
      )

    :ok
  end

  # Timers on the scheduler seam: the schedule commits with the envelope
  # entry recording it, or not at all. "schedule_id" is the reserved meta
  # key — it makes the envelope entry the schedule's retained identity,
  # so a redelivered or out-raced fire dead-letters at the door instead
  # of masquerading as a fresh one.
  @impl Clementine.Loop.Ecto
  def schedule_timer(loop_row, spec, _ctx) do
    {:ok, job} =
      Oban.insert(
        MyApp.Workers.LoopTimerWorker.new(
          %{"loop_ref" => loop_row.id, "tag_key" => spec.tag_key},
          scheduled_at: Clementine.Loop.Ecto.fire_at(__MODULE__, spec.fire)
        )
      )

    {:ok, %{"schedule_id" => job.id}}
  end

  @impl Clementine.Loop.Ecto
  def cancel_timer(_loop_row, _tag_key, %{"schedule_id" => job_id}, _ctx) do
    Oban.cancel_job(job_id)
    :ok
  end

  def cancel_timer(_loop_row, _tag_key, _meta, _ctx), do: :ok
end
```

## Step 2 — The loop itself

The behaviour is decision logic only. `init/1` and `handle/2` are **pure
over their arguments** — no reads (a config row is not stable across a
deploy), no clock, no randomness. Everything a decision needs arrives in
the input payload or lives in state; everything it wants done is action
data. Purity is what makes a crashed step replay from unchanged inputs to
an identical commit; an impure loop forfeits that convergence alone.

The thread agent, with every failure clause the machinery can hand it:

```elixir
defmodule MyApp.ThreadAgent do
  use Clementine.Loop, state_version: 1, vocabulary: [:reply, :reply_retry, :retry]

  alias Clementine.Result

  # State is a cursor, never a transcript: history lives in the messages
  # table, loaded by build_child/4 at spawn time. One source of truth.
  def init(%{"agent_id" => agent_id}) do
    {:ok, %{"agent_id" => agent_id, "cursor" => 0}, []}
  end

  # An email arrived: spawn one reply child. Actions are JSON-safe data;
  # the tag is the correlation and idempotency key.
  def handle({:message, %{"email_id" => email_id}}, state) do
    {:ok, state, [{:run, {:reply, email_id}, reply_args(state, email_id)}]}
  end

  # The child already sent the reply — via a tool, behind the approval
  # gate if policy demands — and its projection appended the new messages
  # to the messages table. The loop advances its cursor.
  def handle({:completed, {:reply, _id}, %Result.Completed{} = r}, state) do
    {:ok, advance_cursor(state, r), []}
  end

  def handle({:completed, {:reply_retry, _id}, %Result.Completed{} = r}, state) do
    {:ok, advance_cursor(state, r), []}
  end

  # The child failed cleanly: wait five minutes, then decide again.
  def handle({:completed, {:reply, id}, %Result.Failed{error: e}}, state) do
    {:ok, state, [{:timer, {:retry, id, e.code}, :timer.minutes(5)}]}
  end

  # Pod died mid-reply; the reaper interrupted the child and its terminal
  # projection delivered this like any other completion. The parent
  # decides — here: try once more, immediately.
  def handle({:completed, {:reply, id}, %Result.Interrupted{}}, state) do
    {:ok, state, [{:run, {:reply_retry, id}, reply_args(state, id)}]}
  end

  # A cascade cancelled the child (conversation deletion, operator stop):
  # absorb and wait for the sweep.
  def handle({:completed, _tag, %Result.Cancelled{}}, state) do
    {:ok, state, []}
  end

  def handle({:elapsed, {:retry, id, _code}}, state) do
    {:ok, state, [{:run, {:reply_retry, id}, reply_args(state, id)}]}
  end

  def handle({:completed, {:reply_retry, id}, _failed_or_interrupted}, state) do
    # Second failure on one email: stop retrying, leave a note for a
    # human. Still a decision, still data.
    {:ok, state, [{:send, state["ops_loop"], %{"stuck_email" => id}}]}
  end

  # Poison evidence: an input burned its attempts (malformed payload, a
  # handler bug). The mailbox never jams — the input was dead-lettered
  # and this is your notification. Decide; do not crash.
  def handle({:input_failed, _ref, _error}, state) do
    {:ok, state, []}
  end

  defp reply_args(state, email_id) do
    %{
      "agent_id" => state["agent_id"],
      "email_id" => email_id,
      "history_through" => state["cursor"]
    }
  end

  defp advance_cursor(state, %Result.Completed{} = r) do
    %{state | "cursor" => state["cursor"] + length(r.messages) + 1}
  end
end
```

Days pass between clauses; deploys pass between clauses; the loop does
not care. Three contract points:

- **`state_version`** is recorded in every commit. When a deploy bumps
  it, ship one `handle_upgrade/2` clause per bump — the `code_change`
  analog: `handle_upgrade(n, dumped_map)` returns `{:ok, map}` at
  `n + 1`, the machinery chains stored → declared stepwise on the loop's
  next wake, and `load/1` stays the only dumped→state door. Pure, like
  `init/1` and `handle/2`. Without the callback (or on any chain
  failure, or a rollback deploy) the loop parks visibly as
  `:incompatible_state` — never a crash, never a dead-letter (inputs are
  innocent of deploys) — until compatible code ships. A renamed
  `loop_module` parks as `:incompatible_spec` the same way.

  ```elixir
  # v2 renames "cursor" and adds a budget; v1 loops upgrade on next wake.
  use Clementine.Loop, state_version: 2

  def handle_upgrade(1, state) do
    {:ok,
     state
     |> Map.put("message_cursor", state["cursor"])
     |> Map.delete("cursor")
     |> Map.put_new("budget", 100)}
  end
  ```
- **`vocabulary`** is the atom whitelist for durable tags and payloads.
  Tags persist in indexes and idempotency keys, so atoms must be
  declared; tuples like `{:reply, id}` encode canonically and are why
  tuple tags are legal.
- **Tags are unique among live children/timers.** Re-arming a fired
  timer tag is legal (live-key lifetime); spawning a tag that is already
  a live child raises — that is an app bug, loud at the drain.

## Step 3 — The workers and the queue topology

Three workers animate the loop layer; you already have the run worker.
The step worker maps `Clementine.Loop.Runner.step/2`'s closed outcome
union exactly as your run worker maps `Clementine.Runner.execute/2`:

```elixir
defmodule MyApp.Workers.LoopStepWorker do
  use Oban.Worker, queue: :loop_steps, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"loop_ref" => loop_ref}}) do
    case Clementine.Loop.Runner.step(loop_ref,
           host: MyApp.LoopHost,
           lifecycle: MyApp.ClementineLifecycle,
           executor_id: "oban:step:#{loop_ref}:#{node()}"
         ) do
      # Parked, or the next step's job is already enqueued (a continue,
      # or a park the host downgraded inside its own commit).
      {:parked, _facts} -> :ok
      {:continued, _facts} -> :ok
      {:finished, _facts} -> :ok
      # A lost claim race, a vanished row, an already-terminal loop:
      # nothing was written, nothing to retry.
      {:discard, reason} -> {:cancel, inspect(reason)}
      # The machinery, not the job queue, owns the retry: an in-step
      # failure already requeued the loop and enqueued its next step;
      # a failed commit is requeued by the reaper (A3a). Ack.
      {:error, reason} -> {:cancel, inspect(reason)}
    end
  end
end
```

The child worker is the run worker pattern with construction at the
boundary — `build_child_run/4` turns the durable args into a ready
`Clementine.Run` via your `build_child/4`:

```elixir
defmodule MyApp.Workers.AgentRunWorker do
  use Oban.Worker, queue: :agents, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id, "args" => child_args}}) do
    with {:ok, run} <-
           Clementine.Loop.Ecto.build_child_run(MyApp.LoopHost, run_id, child_args) do
      case Clementine.Runner.execute(run,
             lifecycle: MyApp.ClementineLifecycle,
             executor_id: "oban:child:#{run_id}:#{node()}"
           ) do
        {:finished, %{status: :queued} = facts} -> MyApp.Runs.re_enqueue!(facts.ref)
        {:finished, _facts} -> :ok
        {:suspended, _token} -> :ok
        {:discard, reason} -> {:cancel, inspect(reason)}
        {:error, reason} -> {:cancel, inspect(reason)}
      end
    end
  end
end
```

The worker never reports back to the parent — the child's terminal
projection appends the completion, whatever terminalized it (a finish, a
reaper interrupt, a cascade cancel). A cascade-cancelled child may reach
its terminal before its job even fires; the claim discards it — ack.

The timer worker is the fire door:

```elixir
defmodule MyApp.Workers.LoopTimerWorker do
  use Oban.Worker, queue: :loop_timers, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"loop_ref" => loop_ref, "tag_key" => tag_key}}) do
    case Clementine.Loop.Ecto.fire_timer(MyApp.LoopHost, loop_ref, tag_key, id) do
      # :appended, :duplicate (our own retry), or :dead_lettered (the
      # loop is terminal, or the schedule was cancelled/superseded —
      # retained evidence either way). All acked.
      {:ok, _outcome} -> :ok
      {:error, :not_found} -> {:cancel, "loop row deleted"}
      {:error, :rollout_run} -> {:cancel, "not a loop"}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

The topology, in one config — steps are short by construction (one drain,
one commit; the real work is in children), so a small `loop_steps` limit
goes a long way; `agents` is where your model-call concurrency lives:

<!-- guide-sample: parse-only -->
```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    loop_steps: [limit: 10],
    agents: [limit: 10],
    loop_timers: [limit: 5],
    maintenance: [limit: 1]
  ],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # The rollout reaper from the durable-execution guide, minutely.
       {"* * * * *", MyApp.Workers.RunReaperWorker},
       # The loop sweep, on its own slower cadence (Step 5).
       {"*/5 * * * *", MyApp.Workers.LoopSweepWorker}
     ]}
  ]
```

## Step 4 — Webhook feeding

Creation is insert-or-get, idempotent on a **scope key** you compose from
your domain; appends are idempotent on a **dedup key** the provider gives
you for free. Together they make the webhook safe under every retry the
provider throws at it:

```elixir
defmodule MyApp.Inbound do
  @moduledoc "One inbound email: ensure the thread's loop, append the message."

  def deliver_email!(mailbox_id, thread_key, provider_message_id, email_id) do
    {:ok, _facts} = ensure_thread_loop(mailbox_id, thread_key)

    # The provider's message id is the dedup key: a redelivered webhook
    # collapses to {:ok, :duplicate}. A terminal loop answers
    # {:ok, :dead_lettered} — the message was RETAINED as evidence, and
    # you know: ack the webhook and alert, nothing was lost silently.
    case Clementine.Loop.Protocol.send(
           MyApp.LoopHost,
           loop_ref!(mailbox_id, thread_key),
           %{"email_id" => email_id},
           dedup_key: provider_message_id
         ) do
      {:ok, :appended} -> :ok
      {:ok, :duplicate} -> :ok
      {:ok, :dead_lettered} -> MyApp.Alerts.thread_closed!(mailbox_id, thread_key)
    end
  end

  defp ensure_thread_loop(mailbox_id, thread_key) do
    case Clementine.Loop.Protocol.create(MyApp.LoopHost, %{
           module: MyApp.ThreadAgent,
           scope: "thread:#{mailbox_id}:#{thread_key}",
           args: %{"agent_id" => mailbox_id},
           policy: %{}
         }) do
      {:ok, facts} -> {:ok, facts}
      {:ok, :already_exists, facts} -> {:ok, facts}
    end
  end

  defp loop_ref!(mailbox_id, thread_key) do
    MyApp.Runs.loop_ref_by_scope!("thread:#{mailbox_id}:#{thread_key}")
  end
end
```

The controller is plain Phoenix:

<!-- guide-sample: parse-only -->
```elixir
defmodule MyAppWeb.EmailWebhookController do
  use MyAppWeb, :controller

  def create(conn, %{"message_id" => mid, "mailbox" => mailbox, "thread" => thread} = params) do
    email = MyApp.Inbound.store_raw_email!(params)
    MyApp.Inbound.deliver_email!(mailbox, thread, mid, email.id)
    send_resp(conn, 204, "")
  end
end
```

The row lands `queued` with the spec persisted; `init/1` runs inside the
**first step**, not at creation — so creation is cheap and webhook-safe,
and the first message rides the same request as the append.

`Clementine.Loop.Protocol.send/4` is the same verb loops use to message
each other (`{:send, target, payload}` actions), with the same
exactly-once-in-effect dedup discipline. Two more host-facing verbs
complete the surface: `Clementine.Loop.Protocol.cancel/4` — the
loop-owned stop (sets the kind-aware flag, wakes, and the machinery runs
the cascade: children reach their terminals first, then the loop, then a
terminal sweep dead-letters anything left; `request_cancel` refuses
loop-kind runs by design) — and `Clementine.Loop.Protocol.child_ref/4`,
which resolves a live tag to its child run ref (attach streaming UIs,
await a turn's terminal notification).

## Step 5 — The reaper's loop sweep

Two amendments to the reaper you already run, then a second sweep. First:
the **rollout sweep excludes loop rows in SQL** — a parked loop is
permanently `waiting` by design, and judging dormant loops on every
minutely sweep is wasted work:

<!-- guide-sample: parse-only -->
```elixir
# In MyApp.Workers.RunReaperWorker's query:
from(r in AgentRun,
  where: r.status in ~w(queued running waiting),
  where: r.kind == "rollout"
)
```

(Judgment itself forks on `Facts.kind`, so a mis-scoped sweep still
judges loops correctly — the scoping is a cost story, not a correctness
one. But scope it.)

Second, the **loop sweep**: slower cadence, loop rows only, gathering the
per-row evidence facts cannot carry and acting on four loop verdicts. No
verdict is terminal — a standing entity self-heals:

```elixir
defmodule MyApp.Workers.LoopSweepWorker do
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Clementine.Lifecycle.Ecto.Codec
  alias Clementine.Lifecycle.Protocol
  alias Clementine.Reconciler
  alias MyApp.Repo
  alias MyApp.Runs.AgentRun

  @fields Codec.resolve_fields(:id, [])
  @policy Reconciler.Policy.new()

  @impl Oban.Worker
  def perform(_job) do
    %{rows: [[now]]} = Repo.query!("SELECT now()")

    rows =
      Repo.all(
        from(r in AgentRun,
          where: r.status in ~w(queued running waiting),
          where: r.kind == "loop"
        )
      )

    for row <- rows do
      facts = Codec.to_facts(row, @fields)
      evidence = if row.status == "waiting", do: MyApp.Runs.loop_evidence(row)

      case Reconciler.judge_loop(facts, evidence, now, @policy) do
        :healthy ->
          :ok

        # A3a — a crashed step requeues unconditionally: the epoch counts
        # a loop's lifetime claims, and capping it would kill loops for
        # having lived. The commit is replayable by construction.
        {:requeue, reason} ->
          with {:ok, _} <- Protocol.requeue(MyApp.ClementineLifecycle, facts, reason) do
            MyApp.LoopHost.enqueue_step(facts.ref, nil)
          end

        # A3b — claim-timeout evidence means the step job is lost, not
        # that the loop should die. Re-insert it; duplicates no-op on the
        # claim CAS.
        {:reenqueue, _reason} ->
          MyApp.LoopHost.enqueue_step(facts.ref, nil)

        # A3c — a live child reached its terminal but the completion
        # append is missing (lost glue, non-transactional substrate):
        # synthesize it under the canonical dedup key. Firing rate should
        # be ~zero on Postgres — nonzero is a glue bug surfacing safely.
        {:reconcile_children, strands} ->
          for strand <- strands, do: MyApp.Runs.reconcile_child!(row, strand)

        # A3c — unconsumed inputs sat past the threshold against a parked
        # loop: the wake was lost; take it now.
        {:wake_pending, _reason} ->
          Clementine.Loop.Ecto.wake(MyApp.LoopHost, facts.ref, nil)
      end
    end

    :ok
  end
end
```

The evidence gathering and the synthesized completion are yours (the
table is yours); both lean on machinery codecs so the dedup key is
byte-identical to the one the projection glue would have written:

```elixir
defmodule MyApp.Runs.LoopEvidenceQueries do
  @moduledoc "The loop sweep's host half: evidence in, synthesized appends out."

  import Ecto.Query

  alias Clementine.Loop.Ecto.Codec, as: InboxCodec
  alias Clementine.Loop.{Envelope, Input}
  alias Clementine.Reconciler.LoopEvidence
  alias Clementine.Result
  alias MyApp.Repo
  alias MyApp.Runs.AgentRun

  @inbox "agent_loop_inbox"

  def loop_evidence(row) do
    children =
      case decode_envelope(row.envelope) do
        %Envelope{children: children} -> Enum.map(children, &child_evidence(row.id, &1))
        nil -> []
      end

    %LoopEvidence{children: children, oldest_pending_at: oldest_pending_at(row.id)}
  end

  defp child_evidence(loop_ref, {tag_key, child_ref}) do
    child = Repo.get(AgentRun, child_ref)

    %{
      tag_key: tag_key,
      child_ref: child_ref,
      terminal?: child != nil and child.status in ~w(completed failed cancelled interrupted),
      # Present AT ALL — pending, or dead-lettered: dead letters are
      # retained evidence, and re-synthesizing a poison completion would
      # only re-poison. The canonical dedup key is an exact index hit.
      completion_present?:
        Repo.exists?(
          from(i in @inbox,
            where: i.loop_ref == ^loop_ref,
            where: i.dedup_key == ^InboxCodec.completion_dedup_key(tag_key, child_ref)
          )
        )
    }
  end

  def reconcile_child!(row, %{tag_key: tag_key, child_ref: child_ref}) do
    child = Repo.get!(AgentRun, child_ref)
    vocab = MyApp.ThreadAgent.__loop__(:vocabulary)
    tag = InboxCodec.decode_tag(tag_key, vocabulary: vocab)

    {:ok, _outcome} =
      MyApp.LoopHost.append(
        row.id,
        Input.completed(tag, synthesized_result(child)),
        InboxCodec.completion_dedup_key(tag_key, child_ref),
        nil
      )

    :ok
  end

  # The parent's fold needs the variant and the usage; the child's real
  # output lives wherever its projection put it (the messages table).
  defp synthesized_result(child) do
    usage = Clementine.Usage.from_map(child.usage || %{})

    case child.status do
      "completed" -> Result.completed(usage: usage)
      "failed" -> Result.failed(%Clementine.Error{message: "child failed"}, usage)
      "cancelled" -> Result.cancelled(:reconciled, usage)
      "interrupted" -> Result.interrupted({:app, :reconciled}, usage)
    end
  end

  defp oldest_pending_at(loop_ref) do
    Repo.one(
      from(i in @inbox,
        where: i.loop_ref == ^loop_ref,
        where: is_nil(i.dead_at),
        select: min(i.inserted_at)
      )
    )
  end

  defp decode_envelope(nil), do: nil

  defp decode_envelope(data) do
    case Envelope.decode(data) do
      {:ok, envelope} -> envelope
      # An undecodable envelope is the :incompatible_state park's
      # territory, not the sweep's.
      {:error, _} -> nil
    end
  end
end
```

Every non-`:healthy` loop verdict emits
`[:clementine, :loop, :verdict]` telemetry at judgment time — the
[operations guide](loop-operations.md) wires the alert: nonzero
`:reconcile_children`/`:wake_pending` rates on Postgres mean a glue bug
is being healed instead of hurting, and you want to know.

## The judge loop

Run → judge (a pure function of the completion) → re-run with feedback
args, halt on pass or exhausted attempts. `Clementine.Verifier`'s
durable, final form:

```elixir
defmodule MyApp.JudgeLoop do
  use Clementine.Loop, state_version: 1, vocabulary: [:attempt, :retry]

  alias Clementine.Result

  def init(%{"prompt" => prompt} = args) do
    state = %{"prompt" => prompt, "max" => Map.get(args, "max_attempts", 3)}
    {:ok, state, [{:run, {:attempt, 1}, %{"prompt" => prompt, "attempt" => 1}}]}
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
      args = %{
        "prompt" => state["prompt"],
        "attempt" => next,
        "feedback" => "attempt #{n} was judged a fail; address the rubric and try again"
      }

      {:ok, state, [{:run, {:attempt, next}, args}]}
    end
  end

  def handle({:input_failed, _ref, _error}, state), do: {:ok, state, []}

  # The judge: pure over the completion. A model-graded judge is a CHILD
  # (spawn a grading run and fold its completion), never a call from here.
  defp judge_pass?(output), do: is_binary(output) and String.contains?(output, "PASS")
end
```

A halt with children still in flight enters the cascade automatically:
children reach terminals first, the loop's terminal is last, leftovers
sweep to dead letters. `{:halt, result}` is a decision like any other.

## The watcher

A cron with memory and judgment. `init` arms a timer; each elapse spawns
a read-only child; the completion decides notify-or-sleep and re-arms —
re-arming a fired tag is legal (live-key lifetime):

```elixir
defmodule MyApp.WatcherLoop do
  use Clementine.Loop, state_version: 1, vocabulary: [:poll, :check]

  alias Clementine.Result

  def init(%{"target" => target} = args) do
    state = %{"target" => target, "every_ms" => Map.get(args, "every_ms", 900_000)}
    {:ok, state, [{:timer, :poll, 0}]}
  end

  def handle({:elapsed, :poll}, state) do
    {:ok, state, [{:run, {:check, state["target"]}, %{"target" => state["target"]}}]}
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

The same behaviour module, animated in-process for evals and scripts —
an in-memory inbox with identical FIFO semantics, children executed for
real but their completions **enqueued as inputs** (the hop is modeled,
so ordering matches production), timers on a virtual clock that jumps to
the next deadline when the loop is idle. A five-minute retry costs
nothing and fires in order:

<!-- guide-sample: parse-only -->
```elixir
{:ok, result} =
  Clementine.Loop.run_local(MyApp.JudgeLoop, %{"prompt" => "write the summary"},
    build_child: fn _tag, args ->
      {:ok, Clementine.Rollout.new(agent: my_agent, input: args["prompt"])}
    end
  )
```

`build_child` is the same seam the host implements — the local stand-in
for `c:Clementine.Loop.Host.build_child/4`. Deterministic loops (and
mock LLM clients) make this the eval harness: same decisions, same
ordering, no database.

## Where next

- Alert before users notice, and diagnose a frozen loop in one call —
  [Loop Operations](loop-operations.md).
- Gate a child's tool on a human decision — the child is an ordinary
  run, so [Approvals & Suspension](approvals.md) applies unchanged.
- The design rationale, the amendment ledger, and failure matrix rows
  L1–L18 — `docs/LOOP_RFC.md` in the repository.
