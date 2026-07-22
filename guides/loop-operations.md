# Loop Operations

A fleet of durable loops runs itself: parked loops are single rows,
crashed steps replay, strands self-heal. Operating one is therefore two
jobs — **watch the rates that page** (this is telemetry's half) and
**diagnose the one loop that froze** (the doctor's half). This guide
wires both for the host built in [Durable Loops](durable-loops.md).

## The signals

Every loop event is documented with its shape in `Clementine.Telemetry`;
the operations story reduces to five signals (LOOP_RFC §Operations):

| Page on | Watch | Why |
|---------|-------|-----|
| Inbox depth / oldest-input age | `[:clementine, :loop, :inbox]` gauges | The stuck detector: input rate outran step rate, or a loop froze with mail waiting |
| Dead-letter rate by `reason` | `[:clementine, :loop, :dead_letter]` | Retained evidence, never silent: `:poison` is a bad payload or handler bug, `:unknown_tag` is deploy drift, `:terminal` is senders addressing a finished loop |
| `:reconcile_children` / `:wake_pending` verdict rates | `[:clementine, :loop, :verdict]` | The self-healing pair — ~zero on Postgres; nonzero means the sweep is healing strands atomic glue should make impossible |
| Step duration / failure rate | `[:clementine, :loop, :step]`, `[:clementine, :loop, :step_failed]` | Steps are short by construction; a slow drain is a hot `handle/2` or a saturated queue |
| Cascade rate | `[:clementine, :loop, :cascade]` | Cancellations and halts entering the drain-down path, with the live-child count each carries |

Arrival-side context rides `[:clementine, :loop, :input]` (per-append,
tagged `kind` and `outcome` — a `:duplicate` surge is a webhook retry
storm) and `[:clementine, :loop, :spawned]` (children created per
commit). Emission honesty is part of the contract: the step runner emits
only after the host's atomic unit commits, and the storage adapter
defers inbox events to the transaction that created them — no event ever
describes a write that rolled back.

## Wiring the metrics and the poller

`Clementine.Telemetry.metrics/0` already includes the loop metrics
(counters tagged by `kind`/`outcome`/`reason`/`verdict`/`trigger`, step
duration and batch summaries, inbox gauge summaries). The one piece that
needs a schedule is the inbox gauge — depth and age are states, not
events, so a poller emits them from one aggregate query per period:

```elixir
defmodule MyApp.Telemetry do
  use Supervisor

  import Telemetry.Metrics

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller,
       measurements: [
         # One GROUP BY over pending inbox rows; emits one
         # [:clementine, :loop, :inbox] event per loop with mail waiting.
         {Clementine.Loop.Ecto, :emit_inbox_depths, [MyApp.LoopHost]}
       ],
       period: :timer.seconds(30)},
      {TelemetryMetricsPrometheus, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    Clementine.Telemetry.metrics() ++
      [
        # Your product metrics here.
        counter("my_app.emails.delivered.count")
      ]
  end
end
```

Alert suggestions, in the shipped metric names:

- `clementine.loop.inbox.oldest_age_ms` max over 5m above your reply
  SLO — a loop is stuck or starved; the doctor names which one.
- `clementine.loop.dead_letter.count` rate by `reason` — any sustained
  `:poison` is a handler bug; any `:unknown_tag` after a deploy is tag
  vocabulary drift (matrix row L17).
- `clementine.loop.verdict.count` where `verdict` is
  `:reconcile_children` or `:wake_pending` — nonzero on a transactional
  substrate is a glue bug surfacing safely. Fix the glue; the sweep is
  meanwhile keeping users whole.

The shipped inbox metrics are fleet distributions (a `loop_ref` label
would be unbounded cardinality); per-loop drill-down is the doctor's
job, below. For development, `Clementine.Telemetry.Logger.install/1`
logs every loop event — dead letters at `:warning`, per-input arrivals
and gauge polls at `:debug`.

## The doctor

`Clementine.Loop.inspect/3` is frozen-loop diagnosis as one call: it
reads the host seam (never writes, takes no lease) and returns a
`Clementine.Loop.Report` — lifecycle facts, the persisted spec and its
version compatibility, the decoded envelope, live children joined to
their run statuses, the timer schedule, pending inputs with ages,
retained dead letters, and the diagnosed **strands**:

<!-- guide-sample: parse-only -->
```elixir
{:ok, report} =
  Clementine.Loop.inspect(MyApp.LoopHost, loop_ref,
    lifecycle: MyApp.ClementineLifecycle
  )

report |> Clementine.Loop.Report.render() |> IO.puts()
```

```text
loop 42 — waiting, epoch 17
  spec: MyApp.ThreadAgent state_version 1 (declared 1)
  children (1 live):
    {:reply, 508} -> run 91 [completed]
  timers (1):
    {:retry, 497, :overloaded} %{"schedule_id" => 3311}
  pending (2):
    #212 message age=421s
    #218 message age=12s
  dead letters (1):
    #171 elapsed :stale_elapsed
  strands (2):
    ! stranded_completion %{child_ref: 91, child_status: :completed, tag_key: "[\"t\",[[\"a\",\"reply\"],508]]"}
    ! parked_with_pending %{oldest_age_ms: 421000, pending: 2}
```

That report reads: child 91 finished but its completion never reached
the inbox, and the loop parked over pending mail — both strands the
reaper's next sweep will heal (`:reconcile_children`, `:wake_pending`),
and both worth a glue investigation because on Postgres they should be
unreachable.

Every strand class maps to a failure-matrix row and a healing mechanism
(shapes documented on `Clementine.Loop.Report`):

| Strand | Matrix row | Healed by |
|--------|-----------|-----------|
| `:incompatible_spec` | L2 | a deploy carrying the module (or a cancel — the cascade never loads state) |
| `:incompatible_state` | L2 | a deploy declaring the stored `state_version`, or one whose `handle_upgrade/2` chain covers it — the next wake upgrades and drains |
| `:parked_with_pending` | L4 | the reaper's `:wake_pending` verdict |
| `:parked_with_cancel` | L8 | the next wake — the flag reads at claim, ahead of the drain |
| `:stranded_completion` | L13 | the reaper's `:reconcile_children` verdict |
| `:stale_queued` | L15 | the reaper's `:reenqueue` verdict |

Options that shape the report: `:lifecycle` (resolve child statuses —
without it children read `:unknown` and stranded completions cannot be
detected), `:limit` (pending/dead-letter window, default 50; diagnosis
is bounded by it), `:stale_after` (the `:stale_queued` threshold,
default five minutes).

## Dead letters

Dead letters are retained rows, never deleted by the machinery: every
input ends exactly one of consumed or dead-lettered, and the letters are
the audit trail of the second path. The reason set is closed —
`:poison` (attempts exhausted; a synthesized `{:input_failed}` told the
loop), `:unknown_tag` (a completion for no live child — deploy-window
evidence), `:stale_elapsed` (a timer fire that lost a race with cancel
or re-arm), `:terminal_sweep` (rows a finishing loop could never
consume), `:terminal` (appends that arrived after the finish; the
*sender* also got `{:ok, :dead_lettered}` and knew at the call).

Read them through the host (`MyApp.LoopHost.dead_letters(loop_ref, 50, nil)`
— the doctor includes them) and own their retention: they are rows in
your inbox table, so TTL, archival, and the GDPR answer are ordinary
data policy — `DELETE FROM agent_loop_inbox WHERE dead_at < ...` on your
schedule. If a dead letter deserves another chance (the poison was a
since-fixed handler bug), append a fresh input with a fresh dedup key —
dead rows are evidence, not a retry queue.

## Fleet scale and billing

- A parked loop is one `waiting` row: no process, no heartbeat, no
  scheduler entry. "Hibernation" is what `waiting` already is; dormant
  loops cost storage, not compute.
- Keep the rollout reaper's sweep scoped `kind = 'rollout'` and the loop
  sweep on its own slower cadence over `kind = 'loop'` rows only — the
  two-sweep topology from the [walkthrough](durable-loops.md). Judgment
  forks on `Facts.kind` either way; scoping is the cost story.
- Billing queries exclude loop rows or count double: the machinery
  aggregates children's usage into the parent loop's row as completions
  fold. Sum `WHERE kind = 'rollout'` for spend; read the loop row for
  per-agent reporting (one read, no join).
