defmodule Clementine.Telemetry.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Clementine.Telemetry.Logger, as: TelemetryLogger
  alias Clementine.Usage

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

      for event <- [
            [:clementine, :rollout, :start],
            [:clementine, :llm, :stop],
            [:clementine, :tool, :exception],
            [:clementine, :run, :claimed],
            [:clementine, :run, :finished],
            [:clementine, :run, :reaped]
          ] do
        handlers = :telemetry.list_handlers(event)
        assert Enum.any?(handlers, fn h -> h.id == "clementine-logger" end)
      end
    end
  end

  describe "handle_event/4 log output" do
    test "rollout start logs model, tools, and max_iterations" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :rollout, :start],
            %{system_time: System.system_time()},
            %{model: :claude_sonnet, tool_count: 3, max_iterations: 30}
          )
        end)

      assert log =~ "[Clementine] Rollout started"
      assert log =~ "model=claude_sonnet"
      assert log =~ "tools=3"
      assert log =~ "max_iterations=30"
    end

    test "rollout start logs tuple model refs without crashing" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :rollout, :start],
            %{system_time: System.system_time()},
            %{model: {:openai, "gpt-5"}, tool_count: 0, max_iterations: 10}
          )
        end)

      assert log =~ "[Clementine] Rollout started"
      assert log =~ ~s(model={:openai, "gpt-5"})

      handlers = :telemetry.list_handlers([:clementine, :rollout, :start])
      assert Enum.any?(handlers, fn h -> h.id == "clementine-logger" end)
    end

    test "rollout stop logs status, duration, and iterations" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :rollout, :stop],
            %{duration: System.convert_time_unit(1234, :millisecond, :native), iterations: 2},
            %{model: :claude_sonnet, status: :success}
          )
        end)

      assert log =~ "[Clementine] Rollout stopped"
      assert log =~ "status=success"
      assert log =~ "iterations=2"
    end

    test "rollout exception without an iteration count logs the raise" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :rollout, :exception],
            %{duration: System.convert_time_unit(10, :millisecond, :native)},
            %{
              model: :claude_sonnet,
              kind: :error,
              reason: %RuntimeError{message: "boom"},
              stacktrace: []
            }
          )
        end)

      assert log =~ "[Clementine] Rollout failed"
      assert log =~ "kind=error"
      assert log =~ "boom"
      refute log =~ "iterations="
    end

    test "llm stop logs duration, tokens, and stop_reason" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :llm, :stop],
            %{
              duration: System.convert_time_unit(500, :millisecond, :native),
              input_tokens: 850,
              output_tokens: 120
            },
            %{model: :claude_sonnet, iteration: 1, stop_reason: "tool_use", streaming: true}
          )
        end)

      assert log =~ "[Clementine] LLM call completed"
      assert log =~ "input_tokens=850"
      assert log =~ "output_tokens=120"
      assert log =~ "stop_reason=tool_use"
    end

    test "tool stop logs tool summary with duration and status" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :tool, :stop],
            %{duration: System.convert_time_unit(12, :millisecond, :native)},
            %{
              tool: "read_file",
              tool_call_id: "toolu_1",
              iteration: 1,
              result: :ok,
              tool_module: Clementine.Tools.ReadFile,
              args: %{path: "lib/foo.ex"}
            }
          )
        end)

      assert log =~ "[Clementine] Tool completed"
      assert log =~ "read_file(lib/foo.ex)"
      assert log =~ "status=ok"
    end

    test "tool start logs tool summary from summarize callback" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :tool, :start],
            %{system_time: System.system_time()},
            %{
              tool: "bash",
              tool_call_id: "toolu_1",
              iteration: 1,
              tool_module: Clementine.Tools.Bash,
              args: %{command: "mix test --only wip"}
            }
          )
        end)

      assert log =~ "[Clementine] Tool executing"
      assert log =~ "bash(mix test --only wip)"
    end

    test "tool exception logs tool summary with kind and reason" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :tool, :exception],
            %{duration: System.convert_time_unit(5, :millisecond, :native)},
            %{
              tool: "bash",
              tool_call_id: "toolu_2",
              iteration: 1,
              kind: :error,
              reason: %RuntimeError{message: "boom"},
              tool_module: Clementine.Tools.Bash,
              args: %{command: "rm -rf /"}
            }
          )
        end)

      assert log =~ "[Clementine] Tool crashed"
      assert log =~ "bash(rm -rf /)"
      assert log =~ "kind=error"
      assert log =~ "boom"
    end

    test "tool log falls back to tool name when tool_module is missing" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :tool, :start],
            %{system_time: System.system_time()},
            %{tool: "custom_tool", tool_call_id: "toolu_1", iteration: 1}
          )
        end)

      assert log =~ "[Clementine] Tool executing"
      assert log =~ "custom_tool"
    end

    test "run claimed logs run, epoch, and executor" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :run, :claimed],
            %{epoch: 3},
            %{run_ref: "run-42", executor_id: "oban:17:node@host"}
          )
        end)

      assert log =~ "[Clementine] Run claimed"
      assert log =~ ~s(run="run-42")
      assert log =~ "epoch=3"
      assert log =~ "executor=oban:17:node@host"
    end

    test "run finished logs terminal, duration, and usage" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :run, :finished],
            %{duration: System.convert_time_unit(2500, :millisecond, :native)},
            %{
              run_ref: "run-42",
              epoch: 1,
              terminal: :completed,
              usage: %Usage{input_tokens: 12, output_tokens: 5}
            }
          )
        end)

      assert log =~ "[Clementine] Run finished"
      assert log =~ "terminal=completed"
      assert log =~ "duration=2500ms"
      assert log =~ "input_tokens=12"
      assert log =~ "output_tokens=5"
    end

    test "run suspended and resumed log at the configured level" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :run, :suspended],
            %{},
            %{run_ref: "run-42", epoch: 1, reason_type: :approval}
          )

          :telemetry.execute(
            [:clementine, :run, :resumed],
            %{},
            %{run_ref: "run-42", epoch: 1}
          )
        end)

      assert log =~ "[Clementine] Run suspended"
      assert log =~ "reason_type=approval"
      assert log =~ "[Clementine] Run resumed"
    end

    test "lease loss and reaps log as warnings" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :run, :lease_lost],
            %{},
            %{run_ref: "run-42", epoch: 1}
          )

          :telemetry.execute(
            [:clementine, :run, :reaped],
            %{},
            %{run_ref: "run-42", epoch: 1, code: :lease_expired}
          )
        end)

      assert log =~ "[warning]"
      assert log =~ "[Clementine] Run lease lost"
      assert log =~ "[Clementine] Run reaped"
      assert log =~ "code=:lease_expired"
    end

    test "run requeued logs the reason" do
      TelemetryLogger.install()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :run, :requeued],
            %{},
            %{run_ref: "run-42", epoch: 2, reason: :drain}
          )
        end)

      assert log =~ "[Clementine] Run requeued"
      assert log =~ "reason=:drain"
    end
  end

  describe "custom log level" do
    test "install(level: :debug) uses debug level" do
      TelemetryLogger.install(level: :debug)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:clementine, :rollout, :start],
            %{system_time: System.system_time()},
            %{model: :claude_sonnet, tool_count: 0, max_iterations: 10}
          )
        end)

      assert log =~ "[debug]" or log =~ "[Clementine]"
    end
  end
end
