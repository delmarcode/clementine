defmodule Clementine.Telemetry.Logger do
  @moduledoc """
  A telemetry handler that logs Clementine events using Elixir's `Logger`.

  Follows the same pattern as `Phoenix.Logger`. Call `install/0` in your
  application startup to attach handlers for all Clementine telemetry events.

  ## Usage

      # In your application.ex start/2:
      Clementine.Telemetry.Logger.install()

      # With custom log level:
      Clementine.Telemetry.Logger.install(level: :debug)

  """

  require Logger

  @handler_id "clementine-logger"

  @events [
    [:clementine, :loop, :start],
    [:clementine, :loop, :stop],
    [:clementine, :loop, :exception],
    [:clementine, :llm, :start],
    [:clementine, :llm, :stop],
    [:clementine, :llm, :exception],
    [:clementine, :tool, :start],
    [:clementine, :tool, :stop],
    [:clementine, :tool, :exception]
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
  def handle_event([:clementine, :loop, :start], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "[Clementine] Loop started model=#{metadata.model} tools=#{metadata.tool_count} max_iterations=#{metadata.max_iterations}"
    end)
  end

  def handle_event([:clementine, :loop, :stop], measurements, metadata, config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.log(config.level, fn ->
      "[Clementine] Loop completed status=#{metadata.status} duration=#{duration_ms}ms iterations=#{measurements.iterations}"
    end)
  end

  def handle_event([:clementine, :loop, :exception], measurements, metadata, config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.log(:error, fn ->
      "[Clementine] Loop failed duration=#{duration_ms}ms iterations=#{measurements.iterations} reason=#{inspect(metadata.reason)}"
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
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.log(config.level, fn ->
      streaming = if metadata.streaming, do: " streaming=true", else: ""

      "[Clementine] LLM call completed iteration=#{metadata.iteration} duration=#{duration_ms}ms input_tokens=#{measurements.input_tokens} output_tokens=#{measurements.output_tokens} stop_reason=#{metadata.stop_reason}#{streaming}"
    end)
  end

  def handle_event([:clementine, :llm, :exception], measurements, metadata, config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.log(:error, fn ->
      "[Clementine] LLM call failed iteration=#{metadata.iteration} duration=#{duration_ms}ms reason=#{inspect(metadata.reason)}"
    end)

    _ = config
  end

  def handle_event([:clementine, :tool, :start], _measurements, metadata, config) do
    Logger.log(config.level, fn ->
      "[Clementine] Tool executing #{tool_summary(metadata)}"
    end)
  end

  def handle_event([:clementine, :tool, :stop], measurements, metadata, config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.log(config.level, fn ->
      "[Clementine] Tool completed #{tool_summary(metadata)} duration=#{duration_ms}ms status=#{metadata.result}"
    end)
  end

  def handle_event([:clementine, :tool, :exception], measurements, metadata, config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.log(:error, fn ->
      "[Clementine] Tool crashed #{tool_summary(metadata)} duration=#{duration_ms}ms kind=#{metadata.kind} reason=#{inspect(metadata.reason)}"
    end)

    _ = config
  end

  defp tool_summary(%{tool_module: module, args: args}) when not is_nil(module) do
    module.summarize(args)
  rescue
    _ -> Map.get(%{tool: "unknown"}, :tool, "unknown")
  end

  defp tool_summary(%{tool: name}), do: name
end
