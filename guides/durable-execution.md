# Durable Execution

This is the complete path from "I have a Phoenix app" to "agent runs
execute durably, survive deploys, and can pause for approval." Every step
is ordinary host code; nothing is hidden behind a macro. It assumes
Phoenix, Ecto/Postgres, and Oban — the canonical substrate — but nothing
below requires them: the contract is a two-function behaviour any storage
can implement.

The division of labor: **your app owns product meaning** (its tables, its
worker, which rows a finished run writes, who may approve what), and
**Clementine owns execution mechanism** (claims, lease fencing,
heartbeats, suspension, resume, reaping, event ordering). You write one
migration, one lifecycle module with one projection function, one enqueue
function, and one worker. The subtle concurrency code — the parts that are
easy to get wrong — ships in the library and is verified against *your*
storage by a generated conformance suite.

## The shape

A run's lifecycle is a small state machine. Terminal states are dead ends
— that dead-endedness is itself a fencing mechanism:

```text
queued ──claim──▶ running ──finish──▶ completed | failed | cancelled
                     │                            interrupted
                     ├──suspend──▶ waiting ──resume──▶ queued
                     └──requeue──▶ queued        (drain / reaper policy)
```

Three invariants carry the design; everything below is elaboration:

- **Every lifecycle write is a guarded compare-and-swap** on
  `(status, epoch)`. The epoch increments at claim and nowhere else, so it
  names one execution — a zombie worker from a previous epoch cannot
  write, no matter how late it wakes.
- **Exactly one terminal writer per run**, decided by the database. A
  reaper racing a live finish loses cleanly, and that is correct.
- **The terminal result is truth; events are advisory.** Your
  conversation history is a fold of terminal results, never of event
  streams.

Your worker's whole job is:

<!-- guide-sample: parse-only -->
```elixir
Clementine.Runner.execute(run,
  lifecycle: MyApp.ClementineLifecycle,
  events: MyApp.ClementineEvents,
  executor_id: "oban:#{job.id}:#{node()}"
)
```

The rest of this guide builds everything that line touches.

## Step 0 — The migration

Clementine does not own a table. It ships a **column recipe** your own
migration applies to your own table — you keep the table name, foreign
keys, product columns, and migration history. For a new app:

```elixir
defmodule MyApp.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs) do
      # Product columns — yours. The scope for "one active run at a
      # time", the input this run answers, and the app's job correlation.
      add :conversation_id, :bigint, null: false
      add :user_message, :text, null: false
      add :oban_job_id, :bigint

      timestamps()
    end

    alter table(:agent_runs) do
      Clementine.Lifecycle.Ecto.Migration.run_columns()
    end

    Clementine.Lifecycle.Ecto.Migration.single_active_index(
      :agent_runs,
      scope: :conversation_id
    )
  end
end
```

`run_columns/0` adds exactly the columns the lifecycle contract needs —
`status`, `lease_epoch`, `executor_id`, `heartbeat_at`, `deadline`,
`queued_at`, `cancel`, `suspension`, `resume`, `effects`, `usage`,
`error`, `interrupt`, `finished_at` — typed so
`Clementine.Lifecycle.Facts` round-trips exactly. `queued_at` defaults to
`now()`, so enqueue-time inserts stamp it for free; the reaper's
claim-timeout check counts from it. See
`Clementine.Lifecycle.Ecto.Migration` for the full column table.

The matching Ecto schema is ordinary:

```elixir
defmodule MyApp.Runs.AgentRun do
  use Ecto.Schema

  import Ecto.Changeset

  schema "agent_runs" do
    field :conversation_id, :integer
    field :user_message, :string
    field :oban_job_id, :integer

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

    timestamps()
  end

  @doc """
  A freshly enqueued run. The `unique_constraint` names the single-active
  index so a double-send surfaces as a changeset error, not an exception.
  """
  def queued_changeset(conversation_id, user_message) do
    %__MODULE__{}
    |> change(conversation_id: conversation_id, user_message: user_message)
    |> unique_constraint(:conversation_id,
      name: :agent_runs_single_active_run_index
    )
  end
end
```

### The single-active index is a product decision

`single_active_index/2` enforces one active run per scope — the
single-flight guard. A double-clicked send button inserts one run; the
second insert is refused by the database, not by application code hoping
to win a race.

By default "active" means `queued`, `running`, **and `waiting`**. That
default is deliberate: a run parked in `waiting` for a three-day approval
blocks new runs in its conversation. If your product wants "chat continues
while an approval is parked," pass `statuses: [:queued, :running]` and own
the resulting concurrency.

### Write load and jsonb sizing

Steady state is one small `UPDATE` per active run per heartbeat interval
(15 seconds by default) — HOT-update friendly, because the recipe keeps
the hot columns small and the heartbeat never rewrites the large jsonb
columns (`suspension`, `error`).

The `suspension` column is the one to watch: it stores the checkpoint —
the full canonical message list accumulated so far — bounded in practice
by the model's context window. It is written once per suspension, not per
heartbeat. If your checkpoints run large (long histories, big tool
results), move the value to a side table behind your `apply` — the
adapter moduledoc (`Clementine.Lifecycle.Ecto`) documents the escape
hatch; nothing in the protocol observes the difference.

## Step 1 — The lifecycle module

The lifecycle is the storage contract: two functions, `fetch/2` and
`apply/2`, where `apply` executes one guarded compare-and-swap. With the
Ecto adapter, both are generated from your repo and schema, and you write
the one genuinely product-meaning function — the **projection**:

```elixir
defmodule MyApp.ClementineLifecycle do
  use Clementine.Lifecycle.Ecto,
    repo: MyApp.Repo,
    schema: MyApp.Runs.AgentRun

  @impl Clementine.Lifecycle.Ecto
  def project(%Clementine.Result.Completed{} = result, run, _ctx) do
    MyApp.Chat.append_messages!(run.conversation_id, result.messages)
  end

  def project(_result, _run, _ctx), do: :ok
end
```

The projection runs **inside the same transaction** as the terminal state
write, for every transition into a terminal status — a runner's finish, a
reaper's interrupt, and a direct cancel alike, each carrying its
`Clementine.Result` variant. Write whatever completion means in your
product: append the generated messages, update counters, mark the
conversation idle. If the projection raises, the transition does not
commit. Project the variants you care about; ignore the rest.

Column names default to the recipe's; if yours differ, map them with
`fields:` (for example `fields: [epoch: :run_epoch]`). The adapter also
takes `pubsub:` for token-latency cancellation, and an
`after_transition/3` hook — the observation seam covered in
[Observing Runs](observation.md). If you cannot use the adapter at all,
the de-sugared two-function implementation is public contract, documented
in `Clementine.Lifecycle.Ecto` — about sixty lines, and the same
conformance suite (below) verifies either path.

## Step 2 — Enqueue, atomically

The run row and the job that will execute it insert in one transaction, so
neither exists without the other. The partial unique index is the
double-send guard, and its violation is a normal user-facing outcome, not
an exception:

```elixir
defmodule MyApp.Runs do
  import Ecto.Query

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Runs.AgentRun
  alias MyApp.Workers.AgentRunWorker

  def start_turn(conversation_id, user_message) do
    Multi.new()
    |> Multi.insert(:run, AgentRun.queued_changeset(conversation_id, user_message))
    |> Oban.insert(:job, fn %{run: run} ->
      AgentRunWorker.new(%{"run_id" => run.id})
    end)
    |> Multi.update(:linked, fn %{run: run, job: job} ->
      Ecto.Changeset.change(run, oban_job_id: job.id)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{linked: run}} ->
        {:ok, run}

      {:error, :run, %Ecto.Changeset{} = changeset, _changes} ->
        if active_run_conflict?(changeset) do
          # Surface as "the agent is already working on this conversation."
          {:error, :active_run_exists}
        else
          {:error, changeset}
        end

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp active_run_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:conversation_id, {_message, opts}} -> opts[:constraint] == :unique
      _other -> false
    end)
  end

  @doc """
  A new job for an existing run — after a resume, a drain requeue, or a
  reaper requeue. Same worker; the run row's job correlation follows.
  """
  def re_enqueue!(run_id) do
    {:ok, job} = Oban.insert(AgentRunWorker.new(%{"run_id" => run_id}))

    {1, _} =
      from(r in AgentRun, where: r.id == ^run_id)
      |> Repo.update_all(set: [oban_job_id: job.id])

    :ok
  end

  def get_run!(run_id), do: Repo.get!(AgentRun, run_id)
end
```

The `oban_job_id` column is the app's job correlation — updated at enqueue
and at every re-enqueue. The reaper's Oban cross-check reads it;
`executor_id` is a human-readable telemetry string and is never parsed for
correlation.

## Step 3 — The worker

The worker is ordinary host code: load your row, build the inert values,
call the runner, map its closed return union. Agents and rollouts are
runtime-constructed — resolve models, tools, instructions, and history
from your own data at execution time:

```elixir
defmodule MyApp.Runs.Builder do
  alias MyApp.Runs.AgentRun

  def build_run(%AgentRun{} = row) do
    agent =
      Clementine.Agent.new(
        model: :claude_sonnet,
        instructions: "You are a helpful assistant.",
        tools: [MyApp.Tools.Weather],
        defaults: [max_iterations: 20]
      )

    rollout =
      Clementine.Rollout.new(
        agent: agent,
        input: row.user_message,
        messages: MyApp.Chat.history(row.conversation_id),
        context: %{conversation_id: row.conversation_id},
        limits: [max_duration: :timer.minutes(10)]
      )

    Clementine.Run.new(ref: row.id, rollout: rollout)
  end
end
```

`max_duration` becomes the execution deadline, minted fresh at every claim
— a run that waited three days for approval is not born dead on resume.

The worker itself:

```elixir
defmodule MyApp.Workers.AgentRunWorker do
  use Oban.Worker, queue: :agents, max_attempts: 1

  alias Clementine.Lifecycle.Facts

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"run_id" => run_id}}) do
    MyApp.DrainNotifier.register()

    run = run_id |> MyApp.Runs.get_run!() |> MyApp.Runs.Builder.build_run()

    case Clementine.Runner.execute(run,
           lifecycle: MyApp.ClementineLifecycle,
           executor_id: "oban:#{job_id}:#{node()}"
         ) do
      {:finished, %Facts{status: :queued}} ->
        # A graceful drain requeued the run before any effect fired;
        # hand it to the next pod and it survives the deploy invisibly.
        MyApp.Runs.re_enqueue!(run_id)

      {:finished, _facts} ->
        # Any terminal: completed, failed, cancelled, or interrupted.
        # The projection already committed with it.
        :ok

      {:suspended, _token} ->
        # Parked in `waiting` with a durable checkpoint; the approval
        # flow owns it now. The job is done — completing here is normal.
        :ok

      {:discard, reason} ->
        # Nothing was written and nothing may be: a lost claim race, a
        # lost lease, or a terminal that already exists.
        {:cancel, inspect(reason)}

      {:error, reason} ->
        # The terminal write exhausted its retries; the run is still
        # `running` and the reaper will finish the story. Re-performing
        # could double-execute effects, so cancel the job instead.
        {:cancel, inspect(reason)}
    end
  end
end
```

Two lines deserve emphasis:

- **`max_attempts: 1` is correct.** Retry is the *reaper's* decision
  through requeue policy (below), never Oban's blind re-perform — a failed
  or interrupted turn may already have caused external effects.
- **Resume needs no branch.** After an approval resume or a requeue,
  `re_enqueue!/1` runs this same worker; the claim hands the checkpoint
  back through the lease, and the runner picks up where the run parked.
  The worker cannot tell the difference, by design.

## The effect fence

Several paths above hinge on one question: *did this run touch the world
yet?* Tools declare it — `retry: :safe` marks a tool safe to re-execute
(reads, queries), anything else is presumed effectful:

<!-- guide-sample: parse-only -->
```elixir
use Clementine.Tool,
  name: "delete_records",
  description: "Deletes records permanently",
  retry: :unsafe,
  parameters: [...]
```

Before the first non-`:safe` tool executes, the runner durably sets the
**effect fence** (`effects` in your table). A fence-unset run is
re-executable from scratch by construction — which is exactly what drain
and reaper requeues check. Runs that only read can silently retry across
deploys and crashes; runs that wrote cannot, and are labeled honestly
instead.

## Step 4 — The reaper

Process death writes nothing — that is deliberate (a dying pod cannot be
trusted to write truthfully). The reaper is the other half: a periodic
sweep that judges stale runs and writes the terminal the dead executor
could not. Judgment is pure library code; the sweep query is yours,
because the table is yours.

```elixir
defmodule MyApp.Workers.RunReaperWorker do
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
    # The storage clock — the same source that stamped the facts. A
    # node-local DateTime.utc_now/0 would reintroduce the two-clock
    # problem the protocol's symbolic timestamps exist to remove.
    %{rows: [[now]]} = Repo.query!("SELECT now()")

    rows =
      Repo.all(from(r in AgentRun, where: r.status in ~w(queued running waiting)))

    jobs = jobs_by_id(rows)

    for row <- rows do
      facts = Codec.to_facts(row, @fields)

      case judge(facts, jobs[row.oban_job_id], now) do
        :healthy ->
          :ok

        {:interrupt, reason} ->
          # Guarded by the exact observed (status, epoch): a reaper
          # racing a live finish — or another reaper — loses cleanly.
          Protocol.interrupt(MyApp.ClementineLifecycle, facts, reason)

        {:requeue, reason} ->
          with {:ok, _facts} <- Protocol.requeue(MyApp.ClementineLifecycle, facts, reason) do
            MyApp.Runs.re_enqueue!(facts.ref)
          end
      end
    end

    :ok
  end

  # Library judgment first (heartbeat, deadline, queue age, wait ceiling),
  # then the Oban cross-check for runs the clock alone cannot convict.
  defp judge(facts, job, now) do
    case Reconciler.judge(facts, now, @policy) do
      :healthy -> Clementine.Lifecycle.Ecto.Oban.judge_job(facts, job)
      verdict -> verdict
    end
  end

  defp jobs_by_id(rows) do
    ids = rows |> Enum.map(& &1.oban_job_id) |> Enum.reject(&is_nil/1)

    from(j in Oban.Job, where: j.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end
end
```

Schedule it on Oban Cron:

<!-- guide-sample: parse-only -->
```elixir
# config/config.exs
config :my_app, Oban,
  queues: [agents: [limit: 10], maintenance: [limit: 1]],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [{"* * * * *", MyApp.Workers.RunReaperWorker}]}
  ]
```

Multiple nodes may sweep concurrently without coordination — every verdict
lands as a CAS guarded by the exact facts the sweep observed, so exactly
one terminal writer wins no matter how many reapers race.

Judgment is **status-scoped**; each check applies only where its evidence
means something (see `Clementine.Reconciler` for the full table):

- `running` — stale heartbeat → `:lease_expired`; fresh heartbeat past
  `deadline + grace` → `:deadline_exceeded` (the belt for a buggy runner's
  suspenders).
- `queued` — `queued_at` older than the claim timeout → `:claim_timeout`;
  the claimer is gone or wedged.
- `waiting` — only the policy ceiling (`max_wait`, off by default): a
  suspended run has no heartbeat, no deadline, and no executor *by
  design*, and leaves `waiting` only by explicit policy. The Oban
  cross-check agrees: a suspended run's job **completed on purpose** at
  suspend — `Clementine.Lifecycle.Ecto.Oban.judge_job/2` judges `waiting`
  as always healthy, which is the line that keeps the first sweep from
  interrupting every parked approval.

The default `Clementine.Reconciler.Policy` is deliberately conservative:
2-minute stale threshold (eight missed 15-second heartbeats — generous
enough to absorb a transient database blip), 15-minute claim timeout, no
`max_wait` ceiling, and `retry: :never`. Opting into same-run retry:

<!-- guide-sample: parse-only -->
```elixir
Clementine.Reconciler.Policy.new(
  max_wait: :timer.hours(72),
  retry: {:requeue, max_claims: 3}
)
```

With retry on, a crashed run whose effect fence is unset gets a
`{:requeue, _}` verdict instead of an interrupt — same run, next epoch,
re-executed from scratch. The epoch counts claims, so it doubles as the
attempt counter; `max_claims` caps it. Runs whose fence is set are
interrupted, never silently re-executed.

## Step 5 — Drain

A deploy should not kill read-only runs. Oban's `shutdown_grace_period`
gives executing jobs time; the missing piece is *telling* the runner to
stop gathering and unwind. That signal is one message —
`{:clementine, :drain}` — delivered to the process running
`Runner.execute/2`. The rollout's blocking points (the provider stream,
the tool await) match it, unwind, and the runner resolves the run:
**requeue** if the effect fence is unset (the run silently survives the
deploy — the worker's `{:finished, %{status: :queued}}` arm re-enqueues
it), or **finish as `interrupted(:drain)`** if effects already fired — an
immediate, labeled outcome instead of a two-minute reaped mystery.

Delivery is host wiring, and a `Registry` plus one shutdown-ordered
GenServer is all it takes:

```elixir
defmodule MyApp.DrainNotifier do
  @moduledoc """
  Broadcasts {:clementine, :drain} to every registered runner process
  when the app begins shutting down. Sits *after* Oban in the supervision
  tree, so it terminates *before* Oban starts waiting out its
  shutdown_grace_period — runners unwind and requeue inside the grace
  window instead of being killed at the end of it.
  """

  use GenServer

  @registry MyApp.Runners

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Workers call this at the top of perform/1."
  def register, do: Registry.register(@registry, :active, nil)

  @impl GenServer
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    Registry.dispatch(@registry, :active, fn entries ->
      for {pid, _value} <- entries, do: send(pid, {:clementine, :drain})
    end)
  end
end
```

Supervision order does the sequencing — children shut down in reverse
start order, so the notifier (listed after Oban) drains the runners while
Oban still owes them the grace period:

<!-- guide-sample: parse-only -->
```elixir
# application.ex
children = [
  MyApp.Repo,
  {Registry, keys: :duplicate, name: MyApp.Runners},
  {Oban, Application.fetch_env!(:my_app, Oban)},
  MyApp.DrainNotifier
]
```

<!-- guide-sample: parse-only -->
```elixir
# config/config.exs — give runs time to unwind and requeue
config :my_app, Oban,
  shutdown_grace_period: :timer.seconds(25)
```

On Kubernetes, keep `terminationGracePeriodSeconds` comfortably above the
Oban grace period. And the reaper remains the fallback for the pod that
never got to drain: a `kill -9` writes nothing, the heartbeat dies with
the process, and the sweep interrupts the run after the stale threshold.

## Prove it: the conformance suite

The entire correctness burden your storage carries is one sentence: *the
`apply` write must be atomic and conditional on `(status, epoch)` exactly
matching `expect`, with the projection in the same atomic unit.* The
generated conformance suite verifies that sentence against your real
lifecycle, schema, and database — concurrent claim races, zombie fencing
across suspend/resume cycles, cancel-racing-suspend in both orders,
projection atomicity, storage-clock stamps:

<!-- guide-sample: parse-only -->
```elixir
defmodule MyApp.ClementineLifecycleTest do
  use Clementine.LifecycleCase,
    lifecycle: MyApp.ClementineLifecycle,
    create_run: fn attrs ->
      MyApp.Factory.insert_queued_run!(attrs).id
    end,
    storage_now: &MyApp.Runs.db_now!/0,
    nonexistent_ref: -1

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
```

A hand-written lifecycle that forgets half the guard fails this suite on
day one. `Clementine.LifecycleCase` documents the `create_run` contract
(fresh scope per call, a projection probe convention) and the sandbox
setup for genuinely racing writers. It is fiddly exactly once, in this
file.

## Adopting in an app that already has run machinery

If your app already built its own run table and glue — a claim query, a
heartbeat process, a stale-run reconciler, a draft cache, error
normalizers — adoption is a swap of mechanism, not a rewrite of product.
The app this design was extracted from (Meli, the production Phoenix app
behind the RFC) deletes on adoption:

- its claim SQL and hand-rolled status transition table,
- its heartbeat GenServer,
- its reconciler's judgment logic,
- its draft cache's event-accumulation logic, and
- its provider error normalizers.

And it keeps, unchanged in kind:

- its run table (now carrying the recipe columns),
- its projection — the product rows written at terminal commit,
- its sweep query (its table, its indexes, its tenancy),
- its Oban worker and queue topology, and
- its PubSub topics and channel payloads.

For an existing table, the migration is the `alter` form — add the recipe
columns next to the columns you already have, map any name collisions
with the adapter's `fields:` option, and run the conformance suite before
trusting the swap:

<!-- guide-sample: parse-only -->
```elixir
def change do
  alter table(:conversation_runs) do
    Clementine.Lifecycle.Ecto.Migration.run_columns()
  end

  Clementine.Lifecycle.Ecto.Migration.single_active_index(
    :conversation_runs, scope: :conversation_id
  )
end
```

## Where next

- Gate a tool on a human decision, park the run for days, resume it —
  [Approvals & Suspension](approvals.md).
- Stream tokens to browsers, survive reconnects, and broadcast lifecycle
  changes — [Observing Runs](observation.md).
- The design rationale, failure matrix, and invariants —
  `docs/DURABLE_EXECUTION_RFC.md` in the repository.
