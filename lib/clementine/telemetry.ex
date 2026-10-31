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

  ## What a run names

  Every rollout, llm, and tool event carries the execution's identity,
  resolved once as it starts (the same resolution its trace records):

  - `agent_key` — the run's agent key on the runtime, or the agent's
    `id` in process (`use Clementine.Agent` sets it to the key); `nil`
    when the agent has neither
  - `provider` — the provider the model resolved to (`:anthropic`,
    `:openai`, ...)
  - `model` — the provider's id for the model (`"claude-sonnet-5"`)
  - `alias` — the catalog alias the agent named (`:claude_sonnet`), or
    `nil` for a `{provider, id}` reference

  A model reference the catalog does not hold (a test's, on a mock
  client) has `provider: nil` and the reference as written for `model`.
  `model` was once the agent's model reference; a handler that matched
  an alias there reads `alias` now.
  Each is fixed in code, so a metric may tag by it. Run events carry
  `agent_key` where the writer knows it: an execution's own writes (the
  claim, heartbeats, a park, its end, a drain's requeue, a lost lease),
  a loop step's on the runtime (the controller's key), and the runtime
  reaper's; a resume and a direct cancel of a run no execution holds
  carry `nil`.

  ## Rollout Events

  ### `[:clementine, :rollout, :start]`

  Emitted when the Gather → Act engine begins animating a rollout.

  - Measurements: `%{system_time: integer}`
  - Metadata: `%{agent_key, provider, model, alias, max_iterations: integer, tool_count: integer}`

  ### `[:clementine, :rollout, :stop]`

  Emitted when the engine returns a non-error branch of its closed set.

  - Measurements: `%{duration: native_time, iterations: integer}`
  - Metadata: `%{agent_key, provider, model, alias, status: :success | :suspended | :cancelled | :drained | :lost_lease}`

  ### `[:clementine, :rollout, :exception]`

  Emitted when the engine returns `{:error, %Clementine.Error{}}` — the
  legacy `:loop` reading of "exception", kept across the rename (note that
  hitting `max_iterations` is now a normalized error, no longer a `:stop`
  status) — and when a raise escapes toward the runner's rescue tier.

  - Measurements: `%{duration: native_time, iterations: integer}` —
    `iterations` is absent on a genuine raise
  - Metadata: `%{agent_key, provider, model, alias, kind: atom, reason: term}` — a returned
    error carries `kind: :error, reason: %Clementine.Error{}`; a raise
    carries the raise's `kind`, `reason`, and `stacktrace`

  ## Run Events

  One event per committed lifecycle write, emitted by
  the lifecycle protocol after the guarded CAS succeeds. Terminal
  observability splits by mechanism: `:finished` is a terminal written by a
  live execution (or a direct cancel of an unowned run); `:reaped` is a
  terminal written by reconciliation or an admin.

  ### `[:clementine, :run, :claimed]`

  A `claim` succeeded: the run is `running` and the epoch — which doubles
  as the attempt counter — was minted.

  - Measurements: `%{epoch: pos_integer}`
  - Metadata: `%{run_ref: term, executor_id: String.t(), agent_key: String.t() | nil}`

  ### `[:clementine, :run, :heartbeat]`

  A heartbeat renewed the lease.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: pos_integer, agent_key: String.t() | nil}`

  ### `[:clementine, :run, :suspended]`

  The run parked in `waiting` with a durable checkpoint.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: pos_integer, agent_key: String.t() | nil, reason_type: atom}`

  ### `[:clementine, :run, :resumed]`

  A resume token was honored: `waiting -> queued`, payload stamped.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: pos_integer, agent_key: nil}`

  ### `[:clementine, :run, :finished]`

  A terminal was written by a live execution, or by a direct cancel of a
  run nobody owned.

  - Measurements: `%{duration: native_time}` — claim to finish on the
    storage clock; `0` when no execution owned the run
  - Metadata: `%{run_ref: term, epoch: non_neg_integer, agent_key: String.t() | nil, terminal: :completed | :failed | :cancelled | :interrupted, usage: Clementine.Usage.t()}`

  ### `[:clementine, :run, :requeued]`

  The fence-gated same-run retry path fired (drain or reaper policy):
  `running -> queued`, same epoch until the next claim.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: pos_integer, agent_key: String.t() | nil, reason: term}`

  ### `[:clementine, :run, :lease_lost]`

  A lease-holding operation discovered the lease is gone — heartbeat,
  cancellation poll, effect fence, suspend, finish, or drain requeue.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: pos_integer, agent_key: String.t() | nil}`

  ### `[:clementine, :run, :reaped]`

  Reconciliation (or an admin) interrupted the run.

  - Measurements: `%{}`
  - Metadata: `%{run_ref: term, epoch: non_neg_integer, agent_key: String.t() | nil, code: Clementine.InterruptReason.code()}`

  ### `[:clementine, :runs, :purge]`

  `Clementine.Runs.purge/1` erased a subject's runs and their inbox rows,
  for audit. Outside a transaction it fires after the delete commits;
  inside the caller's, as the call returns.

  - Measurements: `%{count: non_neg_integer}` — rows deleted
  - Metadata: `%{subject_type: String.t(), subject_id: String.t() | nil}`

  ## Loop Events

  The loop layer owns the `:loop` prefix the engine rename vacated. Two
  emitters split the events by what they can honestly see: the **step
  runner** emits everything derivable from a committed `StepCommit`
  (`:step`, `:step_failed`, `:spawned`, `:cascade`, `:upgraded`) after —
  never before — the atomic unit commits, and the **durable runtime**
  emits the inbox-side events (`:input`, `:dead_letter`, `:inbox`)
  through the deferred-emission seam, so an event describing an append
  or dead letter fires only when the transaction that created it
  commits.

  ### Paging signals (LOOP_RFC §Operations)

  The operations story in one table — alert on these, drill down with
  `Clementine.Runs.inspect/1`:

  | Signal | Source |
  |--------|--------|
  | per-loop inbox depth / oldest-unconsumed-input age | `[:clementine, :loop, :inbox]` via `Clementine.Runs.emit_inbox_depths/0` on a `:telemetry_poller` |
  | dead-letter creation rate by reason | `[:clementine, :loop, :dead_letter]`, `reason` tag |
  | appends-to-terminal rate | `[:clementine, :loop, :dead_letter]` with `reason: :terminal` |
  | `:reconcile_children` / `:wake_pending` firing rates | `[:clementine, :loop, :verdict]`, `verdict` tag — ~zero on Postgres; nonzero is a substrate or glue bug surfacing safely |
  | step duration and batch size | `[:clementine, :loop, :step]` |

  ### `[:clementine, :loop, :verdict]`

  Reconciliation judged a loop-kind run and the verdict was not
  `:healthy` (LOOP_RFC amendment A3). Emitted at judgment time by
  `Clementine.Reconciler.judge_loop/4` and by the Oban cross-check's
  loop-kind verdicts:
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
  the step runner after — never before — the step's atomic unit
  commits; the outcome names the committed facts, so a park the commit
  downgraded inside its unit reports `:continued`.

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

  ### `[:clementine, :loop, :upgraded]`

  A committed step carried a `handle_upgrade/2` state upgrade (LOOP_RFC
  §State Upgrade): the written envelope's `state_version` moved past the
  stored one. Emitted by the step runner after the carrying commit — the
  deploy-verification signal: after a healing deploy, the parked fleet
  drains through this event as `:wake_pending` and fresh appends wake it.
  Once per carrying commit (a replayed crashed step re-upgrades from the
  unchanged stored envelope, and only one commit ever lands).

  - Measurements: `%{}`
  - Metadata: `%{loop_ref: term, epoch: pos_integer, from: pos_integer, to: pos_integer}` —
    the stored and declared `state_version`s the commit bridged

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
  `Clementine.Runs.emit_inbox_depths/0`, which the host wires onto a
  `:telemetry_poller` (one aggregate query per poll; loops with empty
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
  - Metadata: `%{agent_key, provider, model, alias, iteration: integer, message_count: integer, tool_count: integer, streaming: boolean}`

  ### `[:clementine, :llm, :stop]`

  Emitted when the LLM call completes — or when a runner signal (lease
  loss, drain, cancel push) aborts the in-flight stream, in which case
  `stop_reason` is `nil` and the token counts are the partial usage that
  actually burned.

  - Measurements: `%{duration: native_time, input_tokens: integer, output_tokens: integer, cache_read_tokens: integer, cache_write_tokens: integer, cost_micros: integer}`
    (`Clementine.Usage`'s fields: the cache counts are parts of `input_tokens`).
    `cost_micros` is what the call cost in micro-units of `currency`
    (`Clementine.Cost`), at the prices the alias has now, the same cost
    the call's trace entry freezes; a call on a model without prices
    leaves it out, never reports zero.
  - Metadata: `%{agent_key, provider, model, alias, iteration: integer, stop_reason: String.t() | nil, currency: String.t() | nil, streaming: boolean}`
    — `currency` is `nil` for an unpriced call

  ### `[:clementine, :llm, :exception]`

  Emitted when the LLM call fails.

  - Measurements: `%{duration: native_time}`. A provider error in the
    stream also carries what the call reported before it, as stop does:
    the four token counts and, priced, `cost_micros`. A raise carries
    `duration` alone.
  - Metadata: `%{agent_key, provider, model, alias, iteration: integer, kind: atom, reason: term, currency: String.t() | nil, streaming: boolean}`
    — `currency` is `nil` but on a priced provider error

  Spend is the `cost_micros` of `:stop` and `:exception` together; the
  trace prices both.

  ### `[:clementine, :llm, :usage_clamped]`

  Emitted when a provider reports an input total smaller than its own
  cache reads plus writes. The usage recorded raises the total to their
  sum; this event says a provider's convention differs from the one its
  client assumes, which would otherwise undercount quietly.

  - Measurements: `%{input_tokens: integer, cache_read_tokens: integer, cache_write_tokens: integer}` (as reported)
  - Metadata: `%{provider: atom, model: String.t() | nil}`

  ## Tool Events

  ### `[:clementine, :tool, :start]`

  Emitted before executing a single tool.

  - Measurements: `%{system_time: integer}`
  - Metadata: `%{agent_key, provider, model, alias, tool: String.t(), tool_call_id: String.t(), iteration: integer}`

  A tool event fires only for a tool the agent offers, so `tool` is a
  name fixed in code.

  ### `[:clementine, :tool, :stop]`

  Emitted when a tool completes execution.

  - Measurements: `%{duration: native_time}`
  - Metadata: `%{agent_key, provider, model, alias, tool: String.t(), tool_call_id: String.t(), iteration: integer, result: :ok | :error}`

  ### `[:clementine, :tool, :exception]`

  Emitted when a tool crashes.

  - Measurements: `%{duration: native_time}`
  - Metadata: `%{agent_key, provider, model, alias, tool: String.t(), tool_call_id: String.t(), iteration: integer, kind: atom, reason: term}`

  ### `[:clementine, :tool, :input_repaired]`

  Emitted when the rollout acts on a model tool call whose parameters were
  written as markup inside another string parameter, and `Clementine.ToolInput`
  recovered them before the call was gated or executed.

  - Measurements: `%{count: integer}` (parameters touched)
  - Metadata: `%{agent_key, provider, model, alias, tool: String.t(), tool_call_id: String.t(), iteration: integer, fields: [atom]}`

  ## Logging

  To enable development logging:

      # In your application.ex start/2:
      Clementine.Telemetry.Logger.install(level: :info)

  ## Metrics

  `metrics/0` is the one list every app exports: `Telemetry.Metrics`
  counters, sums, and distributions, which Prometheus reporters
  (PromEx, `TelemetryMetricsPrometheus`, Peep) take as they are and
  LiveDashboard draws. It holds no summaries, which Prometheus reporters
  drop. In Prometheus each name is its segments joined by `_`, under a
  bare `clementine_` prefix, so every app exports the same series and a
  fleet query aggregates them by the scrape's own labels.

  ### What is exported

  The engine's metrics are labeled `agent_key`, `provider`, `model`, and
  `alias` ("What a run names"), plus the label shown:

  | Series | Kind | From | Labels |
  |--------|------|------|--------|
  | `clementine_llm_calls_total` | counter | `:llm :stop` | + `stop_reason`: `"aborted"` for a call a runner signal cut off, `"other"` for one outside the providers' known reasons |
  | `clementine_llm_input_tokens_total`, `_output_tokens_total`, `_cache_read_tokens_total`, `_cache_write_tokens_total` | sum | `:llm :stop` | |
  | `clementine_llm_cost_micros_total` | sum | `:llm :stop` | + `currency` |
  | `clementine_llm_duration_milliseconds` | distribution | `:llm :stop` | |
  | `clementine_llm_exceptions_total` | counter | `:llm :exception` | |
  | `clementine_llm_exception_input_tokens_total`, ... `_cache_write_tokens_total`, `clementine_llm_exception_cost_micros_total` | sum | `:llm :exception` | (+ `currency` on cost) |
  | `clementine_tool_calls_total` | counter | `:tool :stop` | + `tool`, `result` |
  | `clementine_tool_duration_milliseconds` | distribution | `:tool :stop` | + `tool` |
  | `clementine_tool_exceptions_total`, `clementine_tool_input_repaired_total` | counter | `:tool :exception`, `:tool :input_repaired` | + `tool` |
  | `clementine_rollout_stops_total`, `clementine_rollout_duration_milliseconds`, `clementine_rollout_iterations` | counter, distributions | `:rollout :stop` | + `status` |
  | `clementine_rollout_exceptions_total` | counter | `:rollout :exception` | + `kind` |

  A call a provider error ended counts under `clementine_llm_exception_*`
  (one metric reads one event): a call's total tokens and spend are the
  two series added.

  The run metrics are labeled `agent_key`, `""` where the writer did not
  know it:

  | Series | Kind | From | Labels |
  |--------|------|------|--------|
  | `clementine_run_claims_total`, `_heartbeats_total`, `_resumed_total`, `_requeued_total`, `_lease_lost_total` | counter | `:run` events | |
  | `clementine_run_suspended_total` | counter | `:run :suspended` | + `reason_type` |
  | `clementine_run_finished_total`, `clementine_run_duration_milliseconds` | counter, distribution | `:run :finished` | + `terminal` |
  | `clementine_run_reaped_total` | counter | `:run :reaped` | + `code` (an app's own code as `app`) |
  | `clementine_runs_purged_total` | sum | `:runs :purge` | none |

  The loop metrics keep their own labels: `clementine_loop_verdicts_total`
  (`verdict`), `clementine_loop_step_duration_milliseconds` (`outcome`,
  `mode`), `clementine_loop_step_inputs_total`,
  `clementine_loop_step_failures_total` (`requeued`),
  `clementine_loop_inputs_total` (`kind`, `outcome`),
  `clementine_loop_dead_letters_total` (`reason`),
  `clementine_loop_spawned_total`, `clementine_loop_cascades_total`
  (`trigger`), `clementine_loop_upgrades_total`, and the inbox
  distributions `clementine_loop_inbox_depth` and
  `clementine_loop_inbox_oldest_age_milliseconds`, which need the
  poller (`Clementine.Runs.emit_inbox_depths/0`). The usage-clamped
  counter, `clementine_llm_usage_clamped_total`, is labeled `provider`.

  ### Wiring it

  A PromEx app passes the list to one plugin:

      defmodule MyApp.PromEx.Plugins.Clementine do
        use PromEx.Plugin

        @impl true
        def event_metrics(_opts) do
          [Event.build(:clementine_event_metrics, Clementine.Telemetry.metrics())]
        end
      end

  and lists it in `MyApp.PromEx`'s `plugins/0`. Without PromEx, a
  reporter takes it the same way:

      children = [
        {TelemetryMetricsPrometheus, metrics: Clementine.Telemetry.metrics() ++ my_metrics()}
      ]

  and LiveDashboard takes it as `metrics: {MyAppWeb.Telemetry, :metrics}`
  once `MyAppWeb.Telemetry.metrics/0` appends it.
  """

  import Telemetry.Metrics

  @llm_stop [:clementine, :llm, :stop]
  @llm_exception [:clementine, :llm, :exception]
  @tool_stop [:clementine, :tool, :stop]
  @tool_exception [:clementine, :tool, :exception]
  @rollout_stop [:clementine, :rollout, :stop]
  @rollout_exception [:clementine, :rollout, :exception]

  # What every rollout, llm, and tool event names: fixed in code, so
  # bounded label sets.
  @identity [:agent_key, :provider, :model, :alias]
  @identity_defaults Map.new(@identity, &{&1, nil})

  @tokens [:input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens]

  # The stop reasons the provider clients normalize to. A reason outside
  # them (an OpenAI-compatible server's own finish_reason) is labeled
  # "other": a label may not take whatever a server sends.
  @stop_reasons ~w(end_turn tool_use max_tokens stop_sequence pause_turn refusal
                   model_context_window_exceeded content_filter incomplete)

  @doc """
  The metrics every Clementine app exports, as `Telemetry.Metrics`
  structs: counters, sums, and distributions, never summaries, so a
  Prometheus reporter takes all of them and LiveDashboard draws them.

  Names carry a bare `clementine_` prefix in Prometheus
  (`clementine_llm_calls_total`), so every app exports the same series
  and a fleet query aggregates across them. Labels are bounded: the
  agent's key, the provider, the provider's model id, and the catalog
  alias on the engine's metrics, the agent's key on the run metrics, and
  the event's own enums (stop reason, status, terminal, tool, ...); never
  a run, a subject, or a loop. "What is exported" in the moduledoc lists
  them.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    llm_metrics() ++ tool_metrics() ++ rollout_metrics() ++ run_metrics() ++ loop_metrics()
  end

  defp llm_metrics do
    [
      counter([:clementine, :llm, :calls, :total],
        event_name: @llm_stop,
        measurement: &one/1,
        description:
          "Model calls that completed, by stop reason: aborted for one a runner signal cut " <>
            "off, other for a reason outside the known set.",
        tags: @identity ++ [:stop_reason],
        tag_values: &llm_stop_tag_values/1
      )
    ] ++
      for token <- @tokens do
        sum([:clementine, :llm, token, :total],
          event_name: @llm_stop,
          measurement: token,
          description: "#{token(token)} of model calls that completed or were cut off.",
          tags: @identity,
          tag_values: &identity/1
        )
      end ++
      [
        sum([:clementine, :llm, :cost_micros, :total],
          event_name: @llm_stop,
          measurement: :cost_micros,
          description:
            "What priced model calls cost, in micro-units of currency (unpriced calls add nothing).",
          tags: @identity ++ [:currency],
          tag_values: &identity/1
        ),
        distribution([:clementine, :llm, :duration, :milliseconds],
          event_name: @llm_stop,
          measurement: :duration,
          unit: {:native, :millisecond},
          description: "Model call duration.",
          tags: @identity,
          tag_values: &identity/1,
          reporter_options: [buckets: [250, 1_000, 2_500, 5_000, 10_000, 30_000, 60_000, 120_000]]
        ),
        counter([:clementine, :llm, :exceptions, :total],
          event_name: @llm_exception,
          measurement: &one/1,
          description: "Model calls that failed: a provider error, or a raise.",
          tags: @identity,
          tag_values: &identity/1
        )
      ] ++
      for token <- @tokens do
        sum([:clementine, :llm, :exception, token, :total],
          event_name: @llm_exception,
          measurement: token,
          description: "#{token(token)} a provider error's stream reported before it failed.",
          tags: @identity,
          tag_values: &identity/1
        )
      end ++
      [
        sum([:clementine, :llm, :exception, :cost_micros, :total],
          event_name: @llm_exception,
          measurement: :cost_micros,
          description:
            "What priced calls a provider error ended cost, in micro-units of currency.",
          tags: @identity ++ [:currency],
          tag_values: &identity/1
        ),
        counter([:clementine, :llm, :usage_clamped, :total],
          event_name: [:clementine, :llm, :usage_clamped],
          measurement: &one/1,
          description: "Provider usage reports whose input total was raised to its cache parts.",
          tags: [:provider]
        )
      ]
  end

  defp tool_metrics do
    [
      counter([:clementine, :tool, :calls, :total],
        event_name: @tool_stop,
        measurement: &one/1,
        description: "Tool executions completed, by tool and result.",
        tags: @identity ++ [:tool, :result],
        tag_values: &identity/1
      ),
      distribution([:clementine, :tool, :duration, :milliseconds],
        event_name: @tool_stop,
        measurement: :duration,
        unit: {:native, :millisecond},
        description: "Tool execution duration.",
        tags: @identity ++ [:tool],
        tag_values: &identity/1,
        reporter_options: [buckets: [10, 50, 250, 1_000, 5_000, 15_000, 60_000]]
      ),
      counter([:clementine, :tool, :exceptions, :total],
        event_name: @tool_exception,
        measurement: &one/1,
        description: "Tool executions that crashed, exited, or timed out.",
        tags: @identity ++ [:tool],
        tag_values: &identity/1
      ),
      counter([:clementine, :tool, :input_repaired, :total],
        event_name: [:clementine, :tool, :input_repaired],
        measurement: &one/1,
        description:
          "Tool calls whose parameters the model wrote as markup inside another string " <>
            "parameter, recovered before gating and execution.",
        tags: @identity ++ [:tool],
        tag_values: &identity/1
      )
    ]
  end

  defp rollout_metrics do
    [
      counter([:clementine, :rollout, :stops, :total],
        event_name: @rollout_stop,
        measurement: &one/1,
        description: "Executions that returned a non-error branch, by status.",
        tags: @identity ++ [:status],
        tag_values: &identity/1
      ),
      distribution([:clementine, :rollout, :duration, :milliseconds],
        event_name: @rollout_stop,
        measurement: :duration,
        unit: {:native, :millisecond},
        description: "Model-tool cycle time per execution.",
        tags: @identity ++ [:status],
        tag_values: &identity/1,
        reporter_options: [buckets: [1_000, 5_000, 15_000, 60_000, 300_000, 900_000]]
      ),
      distribution([:clementine, :rollout, :iterations],
        event_name: @rollout_stop,
        measurement: :iterations,
        description: "Model-tool cycle iterations per execution.",
        tags: @identity ++ [:status],
        tag_values: &identity/1,
        reporter_options: [buckets: [1, 2, 3, 5, 8, 13, 21]]
      ),
      counter([:clementine, :rollout, :exceptions, :total],
        event_name: @rollout_exception,
        measurement: &one/1,
        description: "Executions that returned an error or raised.",
        tags: @identity ++ [:kind],
        tag_values: &identity/1
      )
    ]
  end

  defp run_metrics do
    [
      run_counter(:claimed, [:clementine, :run, :claims, :total], "Run claims (epoch mints)."),
      run_counter(
        :heartbeat,
        [:clementine, :run, :heartbeats, :total],
        "Lease renewals by live executions."
      ),
      run_counter(
        :suspended,
        [:clementine, :run, :suspended, :total],
        "Runs parked in waiting with a durable checkpoint.",
        [:reason_type]
      ),
      run_counter(
        :resumed,
        [:clementine, :run, :resumed, :total],
        "Resume tokens honored (waiting -> queued)."
      ),
      run_counter(
        :finished,
        [:clementine, :run, :finished, :total],
        "Terminals written by live executions, or by a direct cancel, by terminal kind.",
        [:terminal]
      ),
      distribution([:clementine, :run, :duration, :milliseconds],
        event_name: [:clementine, :run, :finished],
        measurement: :duration,
        unit: {:native, :millisecond},
        description: "Claim-to-finish duration on the storage clock.",
        tags: [:agent_key, :terminal],
        tag_values: &agent/1,
        reporter_options: [
          buckets: [1_000, 5_000, 15_000, 60_000, 300_000, 900_000, 3_600_000, 14_400_000]
        ]
      ),
      run_counter(
        :requeued,
        [:clementine, :run, :requeued, :total],
        "Fence-gated same-run retries (drain or reaper policy)."
      ),
      run_counter(
        :lease_lost,
        [:clementine, :run, :lease_lost, :total],
        "Lease-holding operations that discovered the lease is gone."
      ),
      counter([:clementine, :run, :reaped, :total],
        event_name: [:clementine, :run, :reaped],
        measurement: &one/1,
        description: "Runs interrupted by reconciliation or an admin.",
        tags: [:agent_key, :code],
        tag_values: &reaped_tag_values/1
      ),
      sum([:clementine, :runs, :purged, :total],
        event_name: [:clementine, :runs, :purge],
        measurement: :count,
        description: "Run rows erased by Clementine.Runs.purge/1."
      )
    ]
  end

  defp loop_metrics do
    [
      counter([:clementine, :loop, :verdicts, :total],
        event_name: [:clementine, :loop, :verdict],
        measurement: &one/1,
        description:
          "Non-healthy reconciliation verdicts on loop-kind runs. " <>
            "Nonzero reconcile_children/wake_pending on Postgres is the alarm condition.",
        tags: [:verdict]
      ),
      distribution([:clementine, :loop, :step, :duration, :milliseconds],
        event_name: [:clementine, :loop, :step],
        measurement: :duration,
        unit: {:native, :millisecond},
        description: "Committed loop step duration (claim to commit).",
        tags: [:outcome, :mode],
        reporter_options: [buckets: [50, 250, 1_000, 5_000, 15_000, 60_000, 300_000]]
      ),
      sum([:clementine, :loop, :step, :inputs, :total],
        event_name: [:clementine, :loop, :step],
        measurement: fn _measurements, metadata -> metadata.batch end,
        description: "Inbox inputs drained by committed steps."
      ),
      counter([:clementine, :loop, :step_failures, :total],
        event_name: [:clementine, :loop, :step_failed],
        measurement: &one/1,
        description: "In-step exceptions resolved down the attempts path.",
        tags: [:requeued]
      ),
      counter([:clementine, :loop, :inputs, :total],
        event_name: [:clementine, :loop, :input],
        measurement: &one/1,
        description: "Inputs landed in loop inboxes, by kind and outcome.",
        tags: [:kind, :outcome]
      ),
      sum([:clementine, :loop, :dead_letters, :total],
        event_name: [:clementine, :loop, :dead_letter],
        measurement: :count,
        description:
          "Dead letters created, by reason. The rate by reason is a paging " <>
            "signal; reason=terminal is the appends-to-terminal rate.",
        tags: [:reason]
      ),
      counter([:clementine, :loop, :spawned, :total],
        event_name: [:clementine, :loop, :spawned],
        measurement: &one/1,
        description: "Child rollout-runs created as step commit cargo."
      ),
      counter([:clementine, :loop, :cascades, :total],
        event_name: [:clementine, :loop, :cascade],
        measurement: &one/1,
        description: "Committed steps that entered cascade mode.",
        tags: [:trigger]
      ),
      counter([:clementine, :loop, :upgrades, :total],
        event_name: [:clementine, :loop, :upgraded],
        measurement: &one/1,
        description: "Committed steps that carried a handle_upgrade/2 state upgrade."
      ),
      # Fleet distributions per poll: a loop_ref label would be unbounded,
      # and per-loop drill-down is the doctor's (Clementine.Runs.inspect/1).
      distribution([:clementine, :loop, :inbox, :depth],
        event_name: [:clementine, :loop, :inbox],
        measurement: :depth,
        description: "Pending inputs per loop with mail waiting, per poll.",
        reporter_options: [buckets: [1, 2, 5, 10, 25, 50, 100, 250]]
      ),
      distribution([:clementine, :loop, :inbox, :oldest_age, :milliseconds],
        event_name: [:clementine, :loop, :inbox],
        measurement: :oldest_age_ms,
        unit: :millisecond,
        description: "Age of each waiting loop's oldest pending input, per poll.",
        reporter_options: [buckets: [1_000, 5_000, 30_000, 60_000, 300_000, 900_000, 3_600_000]]
      )
    ]
  end

  defp run_counter(event, name, description, tags \\ []) do
    counter(name,
      event_name: [:clementine, :run, event],
      measurement: &one/1,
      description: description,
      tags: [:agent_key | tags],
      tag_values: &agent/1
    )
  end

  defp one(_measurements), do: 1

  defp token(:input_tokens), do: "Input tokens (cache reads and writes included)"
  defp token(:output_tokens), do: "Output tokens (reasoning included)"
  defp token(:cache_read_tokens), do: "Input tokens read from the provider's prompt cache"
  defp token(:cache_write_tokens), do: "Input tokens written to the provider's prompt cache"

  # An event from a path that does not name the run (a tool batch run
  # outside a rollout) still counts, under empty labels, rather than
  # being dropped for a missing tag.
  defp identity(metadata), do: Map.merge(@identity_defaults, metadata)

  defp agent(metadata), do: Map.put_new(metadata, :agent_key, nil)

  # stop_reason is nil when a runner signal (lease loss, drain, cancel
  # push) cut the stream off: labeled "aborted" rather than "".
  defp llm_stop_tag_values(metadata) do
    metadata |> identity() |> Map.put(:stop_reason, stop_reason(metadata[:stop_reason]))
  end

  defp stop_reason(nil), do: "aborted"
  defp stop_reason(reason) when reason in @stop_reasons, do: reason
  defp stop_reason(_other), do: "other"

  # `{:app, term}` interrupt codes collapse to `:app`: the tuple's payload
  # is host vocabulary with unbounded cardinality, which a label must not
  # carry.
  defp reaped_tag_values(metadata) do
    metadata
    |> agent()
    |> Map.update!(:code, fn
      {:app, _term} -> :app
      code -> code
    end)
  end
end
