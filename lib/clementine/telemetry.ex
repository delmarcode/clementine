defmodule Clementine.Telemetry do
  @moduledoc """
  Telemetry events emitted by Clementine.

  Clementine uses `:telemetry` for instrumentation. The following events are
  published during agent loop execution.

  ## Loop Events

  ### `[:clementine, :loop, :start]`

  Emitted when the agentic loop begins.

  - Measurements: `%{system_time: integer}`
  - Metadata: `%{model: model_ref, max_iterations: integer, tool_count: integer}`

  ### `[:clementine, :loop, :stop]`

  Emitted when the loop ends successfully or hits max iterations.

  - Measurements: `%{duration: native_time, iterations: integer}`
  - Metadata: `%{model: model_ref, status: :success | :max_iterations}`

  ### `[:clementine, :loop, :exception]`

  Emitted when the loop ends with an error.

  - Measurements: `%{duration: native_time, iterations: integer}`
  - Metadata: `%{model: model_ref, kind: :error, reason: term}`

  ## LLM Events

  ### `[:clementine, :llm, :start]`

  Emitted before calling the LLM API.

  - Measurements: `%{system_time: integer}`
  - Metadata: `%{model: model_ref, iteration: integer, message_count: integer, tool_count: integer, streaming: boolean}`

  ### `[:clementine, :llm, :stop]`

  Emitted when the LLM call completes successfully.

  - Measurements: `%{duration: native_time, input_tokens: integer, output_tokens: integer}`
  - Metadata: `%{model: model_ref, iteration: integer, stop_reason: String.t(), streaming: boolean}`

  ### `[:clementine, :llm, :exception]`

  Emitted when the LLM call fails.

  - Measurements: `%{duration: native_time}`
  - Metadata: `%{model: model_ref, iteration: integer, kind: :error, reason: term, streaming: boolean}`

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
      # Loop
      summary("clementine.loop.stop.duration", unit: {:native, :millisecond}),
      summary("clementine.loop.stop.iterations"),
      counter("clementine.loop.stop.iterations", tags: [:status]),
      counter("clementine.loop.exception.iterations"),

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
end
