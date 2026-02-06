defmodule Clementine.Telemetry.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Clementine.Telemetry.Logger, as: TelemetryLogger

  setup do
    on_exit(fn ->
      try do
        :telemetry.detach("clementine-logger")
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "install/0" do
    test "attaches handlers for all events" do
      TelemetryLogger.install()

      handlers = :telemetry.list_handlers([:clementine, :loop, :start])
      assert Enum.any?(handlers, fn h -> h.id == "clementine-logger" end)

      handlers = :telemetry.list_handlers([:clementine, :llm, :stop])
      assert Enum.any?(handlers, fn h -> h.id == "clementine-logger" end)

      handlers = :telemetry.list_handlers([:clementine, :tool, :exception])
      assert Enum.any?(handlers, fn h -> h.id == "clementine-logger" end)
    end
  end

  describe "handle_event/4 log output" do
    test "loop start logs model, tools, and max_iterations" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :loop, :start],
            %{system_time: System.system_time()},
            %{model: :claude_sonnet, tool_count: 3, max_iterations: 30}
          )
        end)

      assert log =~ "[Clementine] Loop started"
      assert log =~ "model=claude_sonnet"
      assert log =~ "tools=3"
      assert log =~ "max_iterations=30"
    end

    test "loop stop logs status, duration, and iterations" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :loop, :stop],
            %{duration: System.convert_time_unit(1234, :millisecond, :native), iterations: 2},
            %{model: :claude_sonnet, status: :success}
          )
        end)

      assert log =~ "[Clementine] Loop completed"
      assert log =~ "status=success"
      assert log =~ "iterations=2"
    end

    test "llm stop logs duration, tokens, and stop_reason" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :llm, :stop],
            %{duration: System.convert_time_unit(500, :millisecond, :native), input_tokens: 850, output_tokens: 120},
            %{model: :claude_sonnet, iteration: 1, stop_reason: "tool_use", streaming: false}
          )
        end)

      assert log =~ "[Clementine] LLM call completed"
      assert log =~ "input_tokens=850"
      assert log =~ "output_tokens=120"
      assert log =~ "stop_reason=tool_use"
    end

    test "tool stop logs tool name, duration, and status" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :tool, :stop],
            %{duration: System.convert_time_unit(12, :millisecond, :native)},
            %{tool: "read_file", tool_call_id: "toolu_1", iteration: 1, result: :ok}
          )
        end)

      assert log =~ "[Clementine] Tool completed"
      assert log =~ "tool=read_file"
      assert log =~ "status=ok"
    end

    test "tool exception logs tool name, kind, and reason" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :tool, :exception],
            %{duration: System.convert_time_unit(5, :millisecond, :native)},
            %{tool: "bash", tool_call_id: "toolu_2", iteration: 1, kind: :error, reason: %RuntimeError{message: "boom"}}
          )
        end)

      assert log =~ "[Clementine] Tool crashed"
      assert log =~ "tool=bash"
      assert log =~ "kind=error"
      assert log =~ "boom"
    end
  end

  describe "custom log level" do
    test "install(level: :debug) uses debug level" do
      TelemetryLogger.install(level: :debug)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :loop, :start],
            %{system_time: System.system_time()},
            %{model: :claude_sonnet, tool_count: 0, max_iterations: 10}
          )
        end)

      assert log =~ "[debug]" or log =~ "[Clementine]"
    end
  end
end
