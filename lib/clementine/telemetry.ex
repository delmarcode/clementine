defmodule Clementine.Telemetry do
  @moduledoc """
  Telemetry events emitted by Clementine.

  Clementine uses `:telemetry` for instrumentation, in two layers that
  mirror the execution model: rollout-scoped events from the Gather → Act
  engine (`:rollout`, `:llm`, `:tool`), and run-scoped events from the
  lifecycle protocol (`:run`) — one event per committed protocol write plus
  every lease-loss discovery, so every protocol operation and runner
  outcome is observable regardless of which caller drove it (runner,
  control plane, reaper, or the ephemeral facade).

  > #### Breaking rename {: .warning}
  >
  > The pre-RFC `[:clementine, :loop, ...]` events are gone; the engine
  > emits `[:clementine, :rollout, ...]` instead. Dashboards and handlers
  > swap the event name — measurements and metadata keep their shapes.
  > `:llm` and `:tool` events are unchanged.

  ## Rollout Events

  ### `[:clementine, :rollout, :start]`

  Emitted when the Gather → Act engine begins animating a rollout.

  - Measurements: `%{system_time: integer}`
  - Metadata: `%{model: model_ref, max_iterations: integer, tool_count: integer}`

  ### `[:clementine, :rollout, :stop]`

  Emitted when the engine returns a non-error branch of its closed set.

  - Measurements: `%{duration: native_time, iterations: integer}`
  - Metadata: `%{model: model_ref, status: :success | :suspended | :cancelled | :drained | :lost_lease}`

  ### `[:clementine, :rollout, :exception]`

  Emitted when the engine returns `{:error, %Clementine.Error{}}` — the
  legacy `:loop` reading of "exception", kept across the rename (note that
  hitting `max_iterations` is now a normalized error, no longer a `:stop`
  status) — and when a raise escapes toward the runner's rescue tier.

  - Measurements: `%{duration: native_time, iterations: integer}` —
    `iterations` is absent on a genuine raise
  - Metadata: `%{model: model_ref, kind: atom, reason: term}` — a returned
    error carries `kind: :error, reason: %Clementine.Error{}`; a raise
    carries the raise's `kind`, `reason`, and `stacktrace`

  ## Run Events

  One event per committed lifecycle write, emitted by
  `Clementine.Lifecycle.Protocol` after the guarded CAS succeeds. Terminal
  observability splits by mechanism: `:finished` is a terminal written by a
  live execution (or a direct cancel of an unowned run); `:reaped` is a
  terminal written by reconciliation or an admin.

  ### `[:clementine, :run, :claimed]`

  A `claim` succeeded: the run is `running` and the epoch — which doubles
  as the attempt counter — was minted.

  - Measurements: `%{epoch: pos_integer}`
  - Metadata: `%{run_ref: term, executor_id: String.t()}`

  ### `[:clementine, :run, :heartbeat]`

  A heartbeat renewed the lease.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: pos_integer}`

  ### `[:clementine, :run, :suspended]`

  The run parked in `waiting` with a durable checkpoint.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: pos_integer, reason_type: atom}`

  ### `[:clementine, :run, :resumed]`

  A resume token was honored: `waiting -> queued`, payload stamped.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: pos_integer}`

  ### `[:clementine, :run, :finished]`

  A terminal was written by a live execution, or by a direct cancel of a
  run nobody owned.

  - Measurements: `%{duration: native_time}` — claim to finish on the
    storage clock; `0` when no execution owned the run
  - Metadata: `%{run_ref: term, epoch: non_neg_integer, terminal: :completed | :failed | :cancelled | :interrupted, usage: Clementine.Usage.t()}`

  ### `[:clementine, :run, :requeued]`

  The fence-gated same-run retry path fired (drain or reaper policy):
  `running -> queued`, same epoch until the next claim.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: pos_integer, reason: term}`

  ### `[:clementine, :run, :lease_lost]`

  A lease-holding operation discovered the lease is gone — heartbeat,
  cancellation poll, effect fence, suspend, finish, or drain requeue.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: pos_integer}`

  ### `[:clementine, :run, :reaped]`

  Reconciliation (or an admin) interrupted the run.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: non_neg_integer, code: Clementine.InterruptReason.code()}`

  ## Loop Events

  The loop layer owns the `:loop` prefix the engine rename vacated. Two
  emitters split the events by what they can honestly see: the **step
  runner** emits everything derivable from a committed `StepCommit`
  (`:step`, `:step_failed`, `:spawned`, `:cascade`) after — never
  before — the host's atomic unit commits, and the **storage adapter**
  (`Clementine.Loop.Ecto`) emits the inbox-side events (`:input`,
  `:dead_letter`, `:inbox`) through the deferred-emission seam, so an
  event describing an append or dead letter fires only when the
  transaction that created it commits. Hand-written hosts get the runner
  events for free; the inbox events are theirs to emit if they want the
  same signals.

  ### Paging signals (LOOP_RFC §Operations)

  The operations story in one table — alert on these, drill down with
  `Clementine.Loop.inspect/3`:

  | Signal | Source |
  |--------|--------|
  | per-loop inbox depth / oldest-unconsumed-input age | `[:clementine, :loop, :inbox]` via `Clementine.Loop.Ecto.emit_inbox_depths/1` on a `:telemetry_poller` |
  | dead-letter creation rate by reason | `[:clementine, :loop, :dead_letter]`, `reason` tag |
  | appends-to-terminal rate | `[:clementine, :loop, :dead_letter]` with `reason: :terminal` |
  | `:reconcile_children` / `:wake_pending` firing rates | `[:clementine, :loop, :verdict]`, `verdict` tag — ~zero on Postgres; nonzero is a substrate or glue bug surfacing safely |
  | step duration and batch size | `[:clementine, :loop, :step]` |

  ### `[:clementine, :loop, :verdict]`

  Reconciliation judged a loop-kind run and the verdict was not
  `:healthy` (LOOP_RFC amendment A3). Emitted at judgment time by
  `Clementine.Reconciler.judge_loop/4` and by the Oban cross-check's
  loop-kind verdicts (`Clementine.Lifecycle.Ecto.Oban.judge_job/2`):
  three of the four loop verdicts are host actions with no lifecycle
  commit to ride, so the judgment is the one seam every firing crosses.
  Nonzero
  `:reconcile_children` / `:wake_pending` rates on a transactional
  substrate (Postgres) are the alarm condition — the sweep is healing
  strands that atomic delivery glue should make impossible.

  - Measurements: `%{}`
  - Metadata: `%{loop_ref: term, epoch: non_neg_integer, verdict: :requeue | :reenqueue | :reconcile_children | :wake_pending | :interrupt, detail: term}` —
    `detail` is the verdict's payload: the evidence reason, the strand
    list, or the `InterruptReason`

  ### `[:clementine, :loop, :step]`

  One step committed (LOOP_RFC §The Step). Emitted by
  `Clementine.Loop.Runner.step/2` after — never before — the host's
  `apply_step` unit commits; the outcome names the committed facts, so a
  park the host downgraded inside its unit reports `:continued`.

  - Measurements: `%{duration: native}` — claim to commit
  - Metadata: `%{loop_ref: term, epoch: pos_integer, outcome: :parked | :continued | :finished, mode: :normal | :cascade, batch: non_neg_integer}` —
    `batch` is the drained input count (0 for a threshold poison step)

  ### `[:clementine, :loop, :step_failed]`

  An in-step exception was rescued and resolved down the attempts path —
  requeue plus re-enqueue, never terminal `finish(failed)`: the loop
  analog of two-tier failure (LOOP_RFC matrix rows L1/L7). Step duration
  and per-input attempts pressure live here; the poison threshold's
  dead-letter shows up in dead-letter telemetry, not this event.

  - Measurements: `%{}`
  - Metadata: `%{loop_ref: term, epoch: pos_integer, error: Clementine.Error.t(), requeued: boolean}` —
    `requeued: false` means the requeue could not commit and the reaper
    will requeue on the stale claim stamp instead (A3a)

  ### `[:clementine, :loop, :spawned]`

  One child rollout-run created as commit cargo (LOOP_RFC §Children).
  Emitted by the step runner per child spec of the committed step, after
  the atomic unit that inserted the child row and its job.

  - Measurements: `%{}`
  - Metadata: `%{loop_ref: term, epoch: pos_integer, tag: term, tag_key: String.t()}`

  ### `[:clementine, :loop, :cascade]`

  A committed step entered cascade mode (LOOP_RFC §Cancellation And
  Halt): a halt landed with children in flight, or the cancel flag's
  first drain — including the no-children short-circuit that finishes
  immediately (`children: 0`). Exactly one event per entry: replays of a
  crashed entry re-detect, but only one commit ever lands.

  - Measurements: `%{}`
  - Metadata: `%{loop_ref: term, epoch: pos_integer, trigger: :cancel | :halt, children: non_neg_integer}` —
    `children` is the live-child count being cancelled as cargo

  ### `[:clementine, :loop, :input]`

  One input landed in a loop's inbox — durable and pending
  (`outcome: :appended`), or recognized by its dedup key
  (`outcome: :duplicate`: webhook retries, replayed sends, a scheduler's
  redelivered fire). Emitted by the storage adapter inside whichever
  atomic unit carried the append (a host `append/4`, a timer fire, a
  child's terminal projection, step cargo), deferred to that unit's
  commit. Appends retained as dead letters emit `:dead_letter` instead —
  every inbox row's birth is exactly one event.

  - Measurements: `%{}`
  - Metadata: `%{loop_ref: term, kind: :message | :completed | :elapsed | :input_failed, outcome: :appended | :duplicate}`

  ### `[:clementine, :loop, :dead_letter]`

  Dead letters created — retained evidence that will never be consumed
  (Governing Invariant 11). Emitted by the storage adapter with the
  creating unit's commit: drain-time marks, the terminal sweep, and
  born-dead appends (post-terminal arrivals, provably stale fires). The
  rate by `reason` is a paging signal; `reason: :terminal` is the
  appends-to-terminal rate.

  - Measurements: `%{count: pos_integer}` — rows this creation covered
    (marks group by reason; the terminal sweep is one event)
  - Metadata: `%{loop_ref: term, reason: :poison | :unknown_tag | :stale_elapsed | :terminal_sweep | :terminal}`

  ### `[:clementine, :loop, :inbox]`

  The per-loop pending-inbox gauge — depth and oldest-unconsumed-input
  age, the stuck detector. Not event-driven: emitted by
  `Clementine.Loop.Ecto.emit_inbox_depths/1`, which the host wires onto
  a `:telemetry_poller` (one aggregate query per poll; loops with empty
  pending windows emit nothing).

  - Measurements: `%{depth: non_neg_integer, oldest_age_ms: non_neg_integer}` —
    both on the storage clock
  - Metadata: `%{loop_ref: term}`

  ## LLM Events

  Emitted by the engine around each provider call. The engine always
  streams, so `streaming` is always `true`; the key is kept so existing
  handlers and queries need no change.

  ### `[:clementine, :llm, :start]`

  Emitted before calling the LLM API.

  - Measurements: `%{system_time: integer}`
  - Metadata: `%{model: model_ref, iteration: integer, message_count: integer, tool_count: integer, streaming: boolean}`

  ### `[:clementine, :llm, :stop]`

  Emitted when the LLM call completes — or when a runner signal (lease
  loss, drain, cancel push) aborts the in-flight stream, in which case
  `stop_reason` is `nil` and the token counts are the partial usage that
  actually burned.

  - Measurements: `%{duration: native_time, input_tokens: integer, output_tokens: integer}`
  - Metadata: `%{model: model_ref, iteration: integer, stop_reason: String.t() | nil, streaming: boolean}`

  ### `[:clementine, :llm, :exception]`

  Emitted when the LLM call fails.

  - Measurements: `%{duration: native_time}`
  - Metadata: `%{model: model_ref, iteration: integer, kind: atom, reason: term, streaming: boolean}`

  ## Tool Events

  ### `[:clementine, :tool, :start]`

  Emitted before executing a single tool.

  - Measurements: `%{system_time: integer}`
  - Metadata: `%{tool: String.t(), tool_call_id: String.t(), iteration: integer}`

  ### `[:clementine, :tool, :stop]`

  Emitted when a tool completes execution.

  - Measurements: `%{duration: native_time}`
  - Metadata: `%{tool: String.t(), tool_call_id: String.t(), iteration: integer, result: :ok | :error}`

  ### `[:clementine, :tool, :exception]`

  Emitted when a tool crashes.

  - Measurements: `%{duration: native_time}`
  - Metadata: `%{tool: String.t(), tool_call_id: String.t(), iteration: integer, kind: atom, reason: term}`

  ## Logging

  To enable development logging:

      # In your application.ex start/2:
      Clementine.Telemetry.Logger.install(level: :info)

  ## Metrics

  To add Clementine metrics to your Telemetry supervisor:

      def metrics do
        Clementine.Telemetry.metrics() ++ [
          # your other metrics...
        ]
      end

  ## Prometheus

  Clementine's `metrics/0` returns standard `Telemetry.Metrics` structs.
  Any Telemetry.Metrics-compatible reporter works — for Prometheus:

      # mix.exs
      {:telemetry_metrics_prometheus_core, "~> 1.0"}  # or peep, promex, etc.

      # In your telemetry supervisor:
      children = [
        {TelemetryMetricsPrometheus, metrics: Clementine.Telemetry.metrics() ++ your_metrics()}
      ]
  """

  import Telemetry.Metrics

  @doc """
  Returns a list of `Telemetry.Metrics` definitions for Clementine events.

  These can be passed to any `Telemetry.Metrics`-compatible reporter.
  """
  def metrics do
    [
      # Rollouts
      summary("clementine.rollout.stop.duration", unit: {:native, :millisecond}),
      summary("clementine.rollout.stop.iterations"),
      counter("clementine.rollout.stop.iterations", tags: [:status]),
      # The mechanical rename of clementine.loop.exception.iterations. The
      # count is synthesized because reporters drop an event whose
      # measurement is missing, and the raise flavor omits :iterations —
      # every exception must stay countable.
      counter("clementine.rollout.exception.iterations",
        event_name: [:clementine, :rollout, :exception],
        measurement: fn _measurements -> 1 end
      ),

      # Runs
      counter("clementine.run.claimed.epoch"),
      summary("clementine.run.claimed.epoch"),
      counter("clementine.run.heartbeat.count",
        event_name: [:clementine, :run, :heartbeat],
        measurement: fn _measurements -> 1 end
      ),
      counter("clementine.run.suspended.count",
        event_name: [:clementine, :run, :suspended],
        measurement: fn _measurements -> 1 end,
        tags: [:reason_type]
      ),
      counter("clementine.run.resumed.count",
        event_name: [:clementine, :run, :resumed],
        measurement: fn _measurements -> 1 end
      ),
      summary("clementine.run.finished.duration",
        unit: {:native, :millisecond},
        tags: [:terminal]
      ),
      counter("clementine.run.finished.count",
        event_name: [:clementine, :run, :finished],
        measurement: fn _measurements -> 1 end,
        tags: [:terminal]
      ),
      counter("clementine.run.requeued.count",
        event_name: [:clementine, :run, :requeued],
        measurement: fn _measurements -> 1 end
      ),
      counter("clementine.run.lease_lost.count",
        event_name: [:clementine, :run, :lease_lost],
        measurement: fn _measurements -> 1 end
      ),
      counter("clementine.run.reaped.count",
        event_name: [:clementine, :run, :reaped],
        measurement: fn _measurements -> 1 end,
        tags: [:code],
        tag_values: &reaped_tag_values/1
      ),

      # Loops — alert on nonzero reconcile_children/wake_pending rates
      # where the substrate is transactional (LOOP_RFC §Operations).
      counter("clementine.loop.verdict.count",
        event_name: [:clementine, :loop, :verdict],
        measurement: fn _measurements -> 1 end,
        tags: [:verdict]
      ),
      summary("clementine.loop.step.duration",
        unit: {:native, :millisecond},
        tags: [:outcome, :mode]
      ),
      summary("clementine.loop.step.batch",
        event_name: [:clementine, :loop, :step],
        measurement: fn _measurements, metadata -> metadata.batch end
      ),
      counter("clementine.loop.step_failed.count",
        event_name: [:clementine, :loop, :step_failed],
        measurement: fn _measurements -> 1 end,
        tags: [:requeued]
      ),
      counter("clementine.loop.input.count",
        event_name: [:clementine, :loop, :input],
        measurement: fn _measurements -> 1 end,
        tags: [:kind, :outcome]
      ),
      counter("clementine.loop.spawned.count",
        event_name: [:clementine, :loop, :spawned],
        measurement: fn _measurements -> 1 end
      ),
      # The paging rate by reason; reason: :terminal is the
      # appends-to-terminal rate.
      sum("clementine.loop.dead_letter.count", tags: [:reason]),
      counter("clementine.loop.cascade.count",
        event_name: [:clementine, :loop, :cascade],
        measurement: fn _measurements -> 1 end,
        tags: [:trigger]
      ),
      # Fleet distributions per poll; per-loop drill-down is the doctor's
      # job (a loop_ref tag would be unbounded label cardinality).
      summary("clementine.loop.inbox.depth"),
      summary("clementine.loop.inbox.oldest_age_ms", unit: :millisecond),

      # LLM
      summary("clementine.llm.stop.duration", unit: {:native, :millisecond}),
      summary("clementine.llm.stop.input_tokens"),
      summary("clementine.llm.stop.output_tokens"),
      counter("clementine.llm.stop.input_tokens"),
      counter("clementine.llm.exception.duration",
        event_name: [:clementine, :llm, :exception],
        measurement: fn _measurements -> 1 end
      ),

      # Tools
      summary("clementine.tool.stop.duration", unit: {:native, :millisecond}, tags: [:tool]),
      counter("clementine.tool.stop.duration",
        event_name: [:clementine, :tool, :stop],
        measurement: fn _measurements -> 1 end,
        tags: [:tool, :result]
      ),
      counter("clementine.tool.exception.duration",
        event_name: [:clementine, :tool, :exception],
        measurement: fn _measurements -> 1 end,
        tags: [:tool]
      )
    ]
  end

  # `{:app, term}` interrupt codes collapse to `:app`: the tuple's payload
  # is host vocabulary with unbounded cardinality, which a label must not
  # carry.
  defp reaped_tag_values(metadata) do
    Map.update!(metadata, :code, fn
      {:app, _term} -> :app
      code -> code
    end)
  end
end
