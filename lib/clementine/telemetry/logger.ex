defmodule Clementine.Telemetry.Logger do
  @moduledoc """
  A telemetry handler that logs Clementine events using Elixir's `Logger`.

  Follows the same pattern as `Phoenix.Logger`. Call `install/0` in your
  application startup to attach handlers for all Clementine telemetry events.

  Rollout, LLM, tool, and run lifecycle events log at the configured level;
  heartbeats log at `:debug` (they are a liveness tick, not news), and
  failures — exceptions, lease loss, reaps — log at `:error`/`:warning`
  regardless of the configured level.

  ## Usage

      # In your application.ex start/2:
      Clementine.Telemetry.Logger.install()

      # With custom log level:
      Clementine.Telemetry.Logger.install(level: :debug)

  """

  require Logger

  @handler_id "clementine-logger"

  @events [
    [:clementine, :rollout, :start],
    [:clementine, :rollout, :stop],
    [:clementine, :rollout, :exception],
    [:clementine, :llm, :start],
    [:clementine, :llm, :stop],
    [:clementine, :llm, :exception],
    [:clementine, :tool, :start],
    [:clementine, :tool, :stop],
    [:clementine, :tool, :exception],
    [:clementine, :run, :claimed],
    [:clementine, :run, :heartbeat],
    [:clementine, :run, :suspended],
    [:clementine, :run, :resumed],
    [:clementine, :run, :finished],
    [:clementine, :run, :requeued],
    [:clementine, :run, :lease_lost],
    [:clementine, :run, :reaped],
    [:clementine, :loop, :verdict]
  ]

  @doc """
  Attaches telemetry handlers that log all Clementine events.

  ## Options

  - `:level` - The log level to use (default: `:info`)
  """
  def install(opts \\ []) do
    level = Keyword.get(opts, :level, :info)

    :telemetry.attach_many(
      @handler_id,
      @events,
      &__MODULE__.handle_event/4,
      %{level: level}
    )
  end

  @doc false
  def handle_event([:clementine, :rollout, :start], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "[Clementine] Rollout started model=#{format_model(metadata.model)} tools=#{metadata.tool_count} max_iterations=#{metadata.max_iterations}"
    end)
  end

  def handle_event([:clementine, :rollout, :stop], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "[Clementine] Rollout stopped status=#{metadata.status} duration=#{duration_ms(measurements)}ms iterations=#{measurements.iterations}"
    end)
  end

  def handle_event([:clementine, :rollout, :exception], measurements, metadata, config) do
    # A returned error carries an iteration count; a genuine raise does not.
    iterations =
      case Map.fetch(measurements, :iterations) do
        {:ok, iterations} -> " iterations=#{iterations}"
        :error -> ""
      end

    Logger.log(:error, fn ->
      "[Clementine] Rollout failed duration=#{duration_ms(measurements)}ms#{iterations} kind=#{metadata.kind} reason=#{inspect(metadata.reason)}"
    end)

    _ = config
  end

  def handle_event([:clementine, :llm, :start], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      streaming = if metadata.streaming, do: " streaming=true", else: ""

      "[Clementine] LLM call starting iteration=#{metadata.iteration} messages=#{metadata.message_count} tools=#{metadata.tool_count}#{streaming}"
    end)
  end

  def handle_event([:clementine, :llm, :stop], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      streaming = if metadata.streaming, do: " streaming=true", else: ""

      "[Clementine] LLM call completed iteration=#{metadata.iteration} duration=#{duration_ms(measurements)}ms input_tokens=#{measurements.input_tokens} output_tokens=#{measurements.output_tokens} stop_reason=#{metadata.stop_reason}#{streaming}"
    end)
  end

  def handle_event([:clementine, :llm, :exception], measurements, metadata, config) do
    Logger.log(:error, fn ->
      "[Clementine] LLM call failed iteration=#{metadata.iteration} duration=#{duration_ms(measurements)}ms reason=#{inspect(metadata.reason)}"
    end)

    _ = config
  end

  def handle_event([:clementine, :tool, :start], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "[Clementine] Tool executing #{tool_summary(metadata)}"
    end)
  end

  def handle_event([:clementine, :tool, :stop], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "[Clementine] Tool completed #{tool_summary(metadata)} duration=#{duration_ms(measurements)}ms status=#{metadata.result}"
    end)
  end

  def handle_event([:clementine, :tool, :exception], measurements, metadata, config) do
    Logger.log(:error, fn ->
      "[Clementine] Tool crashed #{tool_summary(metadata)} duration=#{duration_ms(measurements)}ms kind=#{metadata.kind} reason=#{inspect(metadata.reason)}"
    end)

    _ = config
  end

  def handle_event([:clementine, :run, :claimed], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "[Clementine] Run claimed #{run_summary(metadata, measurements)} executor=#{metadata.executor_id}"
    end)
  end

  def handle_event([:clementine, :run, :heartbeat], _measurements, metadata, config) do
    Logger.log(:debug, fn ->
      "[Clementine] Run heartbeat #{run_summary(metadata)}"
    end)

    _ = config
  end

  def handle_event([:clementine, :run, :suspended], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "[Clementine] Run suspended #{run_summary(metadata)} reason_type=#{metadata.reason_type}"
    end)
  end

  def handle_event([:clementine, :run, :resumed], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "[Clementine] Run resumed #{run_summary(metadata)}"
    end)
  end

  def handle_event([:clementine, :run, :finished], measurements, metadata, config) do
    Logger.log(config.level, fn ->
      %Clementine.Usage{} = usage = metadata.usage

      "[Clementine] Run finished #{run_summary(metadata)} terminal=#{metadata.terminal} duration=#{duration_ms(measurements)}ms input_tokens=#{usage.input_tokens} output_tokens=#{usage.output_tokens}"
    end)
  end

  def handle_event([:clementine, :run, :requeued], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "[Clementine] Run requeued #{run_summary(metadata)} reason=#{inspect(metadata.reason)}"
    end)
  end

  def handle_event([:clementine, :run, :lease_lost], _measurements, metadata, config) do
    Logger.log(:warning, fn ->
      "[Clementine] Run lease lost #{run_summary(metadata)}"
    end)

    _ = config
  end

  def handle_event([:clementine, :run, :reaped], _measurements, metadata, config) do
    Logger.log(:warning, fn ->
      "[Clementine] Run reaped #{run_summary(metadata)} code=#{inspect(metadata.code)}"
    end)

    _ = config
  end

  # The self-healing pair is the alarm condition (should be ~zero on a
  # transactional substrate), so it logs at :warning regardless of level.
  def handle_event([:clementine, :loop, :verdict], _measurements, metadata, config) do
    level =
      if metadata.verdict in [:reconcile_children, :wake_pending],
        do: :warning,
        else: config.level

    Logger.log(level, fn ->
      "[Clementine] Loop verdict loop=#{inspect(metadata.loop_ref)} epoch=#{metadata.epoch} verdict=#{metadata.verdict} detail=#{inspect(metadata.detail)}"
    end)
  end

  defp run_summary(metadata, measurements \\ %{}) do
    epoch = Map.get(metadata, :epoch) || Map.get(measurements, :epoch)
    "run=#{inspect(metadata.run_ref)} epoch=#{epoch}"
  end

  defp duration_ms(%{duration: duration}) do
    System.convert_time_unit(duration, :native, :millisecond)
  end

  defp tool_summary(%{tool_module: module, args: args}) when not is_nil(module) do
    module.summarize(args)
  rescue
    _ -> Map.get(%{tool: "unknown"}, :tool, "unknown")
  end

  defp tool_summary(%{tool: name}), do: name

  defp format_model(model) when is_atom(model), do: Atom.to_string(model)
  defp format_model(model), do: inspect(model)
end
