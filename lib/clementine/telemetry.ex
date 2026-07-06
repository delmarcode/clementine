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
