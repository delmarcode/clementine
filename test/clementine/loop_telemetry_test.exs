defmodule Clementine.LoopTelemetryTest do
  use ExUnit.Case, async: true
  import Mox

  alias Clementine.Loop
  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Response

  setup :verify_on_exit!

  defmodule EchoTool do
    use Clementine.Tool,
      name: "echo",
      description: "Echoes input",
      parameters: [message: [type: :string, required: true]]

    @impl true
    def run(%{message: msg}, _ctx), do: {:ok, "Echo: #{msg}"}
  end

  setup do
    test_pid = self()

    attach_telemetry(test_pid, [:clementine, :loop, :start])
    attach_telemetry(test_pid, [:clementine, :loop, :stop])
    attach_telemetry(test_pid, [:clementine, :loop, :exception])
    attach_telemetry(test_pid, [:clementine, :llm, :start])
    attach_telemetry(test_pid, [:clementine, :llm, :stop])
    attach_telemetry(test_pid, [:clementine, :llm, :exception])
    attach_telemetry(test_pid, [:clementine, :tool, :start])
    attach_telemetry(test_pid, [:clementine, :tool, :stop])
    attach_telemetry(test_pid, [:clementine, :tool, :exception])

    :ok
  end

  defp attach_telemetry(pid, event) do
    handler_id = "test-#{inspect(event)}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn event, measurements, metadata, _config ->
        send(pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "text-only response telemetry" do
    test "emits loop start, llm start/stop, and loop stop" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Hello!")],
           stop_reason: "end_turn",
           usage: %{"input_tokens" => 100, "output_tokens" => 50}
         }}
      end)

      config = [model: :claude_sonnet, tools: []]

      assert {:ok, "Hello!", _messages} = Loop.run(config, "Hi")

      # Loop start
      assert_receive {:telemetry, [:clementine, :loop, :start], %{system_time: _},
                      %{model: :claude_sonnet, tool_count: 0, max_iterations: 10}}

      # LLM start
      assert_receive {:telemetry, [:clementine, :llm, :start], %{system_time: _},
                      %{model: :claude_sonnet, iteration: 1, streaming: false}}

      # LLM stop with token counts
      assert_receive {:telemetry, [:clementine, :llm, :stop],
                      %{duration: duration, input_tokens: 100, output_tokens: 50},
                      %{model: :claude_sonnet, stop_reason: "end_turn", streaming: false}}

      assert is_integer(duration) and duration >= 0

      # Loop stop
      assert_receive {:telemetry, [:clementine, :loop, :stop],
                      %{duration: loop_duration, iterations: 1},
                      %{model: :claude_sonnet, status: :success}}

      assert is_integer(loop_duration) and loop_duration >= 0
    end
  end

  describe "tool use response telemetry" do
    test "emits tool start/stop per tool" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, messages, _tools, _opts ->
        if length(messages) == 1 do
          {:ok,
           %Response{
             content: [Content.tool_use("toolu_1", "echo", %{"message" => "test"})],
             stop_reason: "tool_use",
             usage: %{"input_tokens" => 80, "output_tokens" => 30}
           }}
        else
          {:ok,
           %Response{
             content: [Content.text("Done!")],
             stop_reason: "end_turn",
             usage: %{"input_tokens" => 150, "output_tokens" => 40}
           }}
        end
      end)
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Done!")],
           stop_reason: "end_turn",
           usage: %{"input_tokens" => 150, "output_tokens" => 40}
         }}
      end)

      config = [model: :claude_sonnet, tools: [EchoTool]]

      assert {:ok, "Done!", _} = Loop.run(config, "Echo test")

      # Tool start
      assert_receive {:telemetry, [:clementine, :tool, :start], %{system_time: _},
                      %{tool: "echo", tool_call_id: "toolu_1", iteration: 1}}

      # Tool stop
      assert_receive {:telemetry, [:clementine, :tool, :stop], %{duration: tool_duration},
                      %{tool: "echo", tool_call_id: "toolu_1", result: :ok}}

      assert is_integer(tool_duration) and tool_duration >= 0

      # Two LLM calls
      assert_receive {:telemetry, [:clementine, :llm, :stop], _, %{stop_reason: "tool_use"}}
      assert_receive {:telemetry, [:clementine, :llm, :stop], _, %{stop_reason: "end_turn"}}
    end
  end

  describe "max iterations telemetry" do
    test "emits loop stop with status max_iterations" do
      Clementine.LLM.MockClient
      |> stub(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.tool_use("toolu_1", "echo", %{"message" => "loop"})],
           stop_reason: "tool_use",
           usage: %{}
         }}
      end)

      config = [model: :claude_sonnet, tools: [EchoTool], max_iterations: 2]

      assert {:error, :max_iterations_reached} = Loop.run(config, "Loop forever")

      assert_receive {:telemetry, [:clementine, :loop, :stop], %{duration: _, iterations: 2},
                      %{status: :max_iterations}}
    end
  end

  describe "LLM error telemetry" do
    test "emits llm exception and loop exception" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:error, {:api_error, 500, "Internal server error"}}
      end)

      config = [model: :claude_sonnet]

      assert {:error, {:api_error, 500, _}} = Loop.run(config, "Hi")

      # LLM exception
      assert_receive {:telemetry, [:clementine, :llm, :exception], %{duration: _},
                      %{
                        model: :claude_sonnet,
                        kind: :error,
                        reason: {:api_error, 500, "Internal server error"},
                        streaming: false
                      }}

      # Loop exception
      assert_receive {:telemetry, [:clementine, :loop, :exception], %{duration: _, iterations: 1},
                      %{model: :claude_sonnet, kind: :error}}
    end
  end

  describe "streaming mode telemetry" do
    test "emits the same telemetry events with streaming: true" do
      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:content_block_start, 0, :text},
          {:text_delta, "Hello!"},
          {:content_block_stop, 0},
          {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
          {:message_stop}
        ]
      end)

      config = [model: :claude_sonnet, tools: []]

      assert {:ok, "Hello!", _} = Loop.run_stream(config, "Hi", fn _ -> :ok end)

      assert_receive {:telemetry, [:clementine, :loop, :start], _, %{model: :claude_sonnet}}
      assert_receive {:telemetry, [:clementine, :llm, :start], _, %{streaming: true}}
      assert_receive {:telemetry, [:clementine, :llm, :stop], _, %{streaming: true}}
      assert_receive {:telemetry, [:clementine, :loop, :stop], _, %{status: :success}}
    end

    test "streaming error emits llm exception with streaming: true" do
      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:error, %{"type" => "overloaded_error", "message" => "Overloaded"}}
        ]
      end)

      config = [model: :claude_sonnet, tools: []]

      assert {:error, _} = Loop.run_stream(config, "Hi", fn _ -> :ok end)

      assert_receive {:telemetry, [:clementine, :llm, :exception], %{duration: _},
                      %{streaming: true, kind: :error}}
    end

    test "streaming tool use emits tool telemetry" do
      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, messages, _tools, _opts ->
        if length(messages) == 1 do
          [
            {:message_start, %{"id" => "msg_1"}},
            {:content_block_start, 0, :tool_use},
            {:tool_use_start, "toolu_1", "echo"},
            {:input_json_delta, "toolu_1", "{\"message\":\"test\"}"},
            {:content_block_stop, 0},
            {:message_delta, %{"stop_reason" => "tool_use"}, %{}},
            {:message_stop}
          ]
        else
          [
            {:message_start, %{"id" => "msg_2"}},
            {:content_block_start, 0, :text},
            {:text_delta, "Done!"},
            {:content_block_stop, 0},
            {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
            {:message_stop}
          ]
        end
      end)
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_2"}},
          {:content_block_start, 0, :text},
          {:text_delta, "Done!"},
          {:content_block_stop, 0},
          {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
          {:message_stop}
        ]
      end)

      config = [model: :claude_sonnet, tools: [EchoTool]]

      assert {:ok, "Done!", _} = Loop.run_stream(config, "Echo test", fn _ -> :ok end)

      assert_receive {:telemetry, [:clementine, :tool, :start], _, %{tool: "echo"}}
      assert_receive {:telemetry, [:clementine, :tool, :stop], _, %{tool: "echo", result: :ok}}
    end
  end

  describe "duration measurements" do
    test "all durations are non-negative integers" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Hello!")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      config = [model: :claude_sonnet]

      {:ok, _, _} = Loop.run(config, "Hi")

      assert_receive {:telemetry, [:clementine, :llm, :stop], %{duration: llm_d}, _}
      assert is_integer(llm_d) and llm_d >= 0

      assert_receive {:telemetry, [:clementine, :loop, :stop], %{duration: loop_d}, _}
      assert is_integer(loop_d) and loop_d >= 0
    end
  end

  describe "token counts" do
    test "extracts input_tokens and output_tokens from response.usage" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Hello!")],
           stop_reason: "end_turn",
           usage: %{"input_tokens" => 850, "output_tokens" => 120}
         }}
      end)

      config = [model: :claude_sonnet]

      {:ok, _, _} = Loop.run(config, "Hi")

      assert_receive {:telemetry, [:clementine, :llm, :stop],
                      %{input_tokens: 850, output_tokens: 120}, _}
    end

    test "defaults to 0 when usage is empty" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Hello!")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      config = [model: :claude_sonnet]

      {:ok, _, _} = Loop.run(config, "Hi")

      assert_receive {:telemetry, [:clementine, :llm, :stop],
                      %{input_tokens: 0, output_tokens: 0}, _}
    end
  end
end
