defmodule Clementine.LoopTest do
  use ExUnit.Case, async: true
  import Mox

  alias Clementine.Loop
  alias Clementine.LLM.Message.{AssistantMessage, Content, UserMessage}
  alias Clementine.LLM.Response

  # Set up Mox
  setup :verify_on_exit!

  setup do
    # The TaskSupervisor is started by the application
    :ok
  end

  # Test tools
  defmodule EchoTool do
    use Clementine.Tool,
      name: "echo",
      description: "Echoes input",
      parameters: [message: [type: :string, required: true]]

    @impl true
    def run(%{message: msg}, _ctx), do: {:ok, "Echo: #{msg}"}
  end

  # Test verifiers
  defmodule PassingVerifier do
    use Clementine.Verifier
    @impl true
    def verify(_result, _ctx), do: :ok
  end

  defmodule FailOnceVerifier do
    use Clementine.Verifier

    @impl true
    def verify(_result, ctx) do
      count = Map.get(ctx, :verify_count, 0)

      if count > 0 do
        :ok
      else
        {:retry, "First attempt failed"}
      end
    end
  end

  describe "run/2 with text response" do
    test "returns text when model responds without tools" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Hello world!")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      config = [
        model: :claude_sonnet,
        system: "You are helpful.",
        tools: []
      ]

      assert {:ok, "Hello world!", messages} = Loop.run(config, "Hi")
      assert length(messages) == 2  # user + assistant
    end
  end

  describe "run/2 with tool use" do
    test "executes tools and continues loop" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, messages, _tools, _opts ->
        # First call: model wants to use echo tool
        if length(messages) == 1 do
          {:ok,
           %Response{
             content: [
               Content.tool_use("toolu_1", "echo", %{"message" => "test"})
             ],
             stop_reason: "tool_use",
             usage: %{}
           }}
        else
          # Second call: model returns final text
          {:ok,
           %Response{
             content: [Content.text("Done!")],
             stop_reason: "end_turn",
             usage: %{}
           }}
        end
      end)
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Done!")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      config = [
        model: :claude_sonnet,
        tools: [EchoTool]
      ]

      assert {:ok, "Done!", messages} = Loop.run(config, "Echo test")

      # Should have: user, assistant (tool use), user (tool result), assistant (final)
      assert length(messages) == 4
    end
  end

  describe "run/2 with verification" do
    test "runs verifiers on final response" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Hello")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      config = [
        model: :claude_sonnet,
        verifiers: [PassingVerifier]
      ]

      assert {:ok, "Hello", _messages} = Loop.run(config, "Hi")
    end
  end

  describe "run/2 with max iterations" do
    test "returns error when max iterations reached" do
      # Model keeps wanting to use tools
      Clementine.LLM.MockClient
      |> stub(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [
             Content.tool_use("toolu_1", "echo", %{"message" => "loop"})
           ],
           stop_reason: "tool_use",
           usage: %{}
         }}
      end)

      config = [
        model: :claude_sonnet,
        tools: [EchoTool],
        max_iterations: 3
      ]

      assert {:error, :max_iterations_reached} = Loop.run(config, "Loop forever")
    end
  end

  describe "run/2 with LLM errors" do
    test "returns error when LLM call fails" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:error, {:api_error, 500, "Internal server error"}}
      end)

      config = [model: :claude_sonnet]

      assert {:error, {:api_error, 500, _}} = Loop.run(config, "Hi")
    end
  end

  describe "events" do
    test "emits events via callback" do
      agent = self()

      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{
           content: [Content.text("Hello")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      config = [
        model: :claude_sonnet,
        on_event: fn event -> send(agent, {:event, event}) end
      ]

      {:ok, _, _} = Loop.run(config, "Hi")

      # Check we received events
      assert_receive {:event, {:loop_start, "Hi"}}
      assert_receive {:event, {:iteration_start, 1}}
      assert_receive {:event, :llm_call_start}
      assert_receive {:event, {:llm_call_end, {:ok, _}}}
      assert_receive {:event, {:final_text, "Hello"}}
      assert_receive {:event, {:loop_end, :success}}
    end
  end

  describe "continue/3" do
    test "continues from existing message history" do
      initial_messages = [
        UserMessage.new("Hello"),
        AssistantMessage.new([Content.text("Hi there!")])
      ]

      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, messages, _tools, _opts ->
        # Should have 3 messages: 2 initial + 1 new user message
        assert length(messages) == 3

        {:ok,
         %Response{
           content: [Content.text("Continuing conversation")],
           stop_reason: "end_turn",
           usage: %{}
         }}
      end)

      config = [model: :claude_sonnet]

      {:ok, result, messages} = Loop.continue(config, initial_messages, "Follow up")

      assert result == "Continuing conversation"
      assert length(messages) == 4  # 2 initial + user + assistant
    end
  end

  describe "run_stream/3" do
    test "streams text deltas to callback" do
      test_pid = self()

      # Mock stream returns an enumerable of events
      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:content_block_start, 0, :text},
          {:text_delta, "Hello "},
          {:text_delta, "world!"},
          {:content_block_stop, 0},
          {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
          {:message_stop}
        ]
      end)

      config = [model: :claude_sonnet, tools: []]

      callback = fn event -> send(test_pid, {:stream_event, event}) end

      assert {:ok, "Hello world!", _messages} = Loop.run_stream(config, "Hi", callback)

      # Verify we received text deltas
      assert_receive {:stream_event, {:text_delta, "Hello "}}
      assert_receive {:stream_event, {:text_delta, "world!"}}
    end

    test "streams tool use events" do
      test_pid = self()

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, messages, _tools, _opts ->
        if length(messages) == 1 do
          # First call: tool use
          [
            {:message_start, %{"id" => "msg_1"}},
            {:content_block_start, 0, :tool_use},
            {:tool_use_start, "toolu_1", "echo"},
            {:input_json_delta, "toolu_1", "{\"message\":"},
            {:input_json_delta, "toolu_1", "\"test\"}"},
            {:content_block_stop, 0},
            {:message_delta, %{"stop_reason" => "tool_use"}, %{}},
            {:message_stop}
          ]
        else
          # Second call: final response
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

      callback = fn event -> send(test_pid, {:stream_event, event}) end

      assert {:ok, "Done!", _messages} = Loop.run_stream(config, "Echo test", callback)

      # Verify tool use events
      assert_receive {:stream_event, {:tool_use_start, "toolu_1", "echo"}}
      assert_receive {:stream_event, {:input_json_delta, "toolu_1", "{\"message\":"}}
      assert_receive {:stream_event, {:tool_result, "toolu_1", _result}}
      assert_receive {:stream_event, {:text_delta, "Done!"}}
    end

    test "emits loop events wrapped in :loop_event tuple" do
      test_pid = self()

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:text_delta, "Hi"},
          {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
          {:message_stop}
        ]
      end)

      config = [model: :claude_sonnet]

      callback = fn event -> send(test_pid, {:stream_event, event}) end

      {:ok, _, _} = Loop.run_stream(config, "Hello", callback)

      # Loop events come wrapped
      assert_receive {:stream_event, {:loop_event, {:loop_start, "Hello"}}}
      assert_receive {:stream_event, {:loop_event, {:iteration_start, 1}}}
      assert_receive {:stream_event, {:loop_event, :llm_call_start}}
    end

    test "stream error returns {:error, reason} and forwards error to callback" do
      test_pid = self()

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:content_block_start, 0, :text},
          {:text_delta, "partial"},
          {:error, %{"type" => "overloaded_error", "message" => "Overloaded"}}
        ]
      end)

      config = [model: :claude_sonnet, tools: []]

      callback = fn event -> send(test_pid, {:stream_event, event}) end

      assert {:error, %{"type" => "overloaded_error"}} =
               Loop.run_stream(config, "Hi", callback)

      # Error was forwarded to the callback
      assert_receive {:stream_event, {:error, %{"type" => "overloaded_error"}}}
      # Text delta before the error was also forwarded
      assert_receive {:stream_event, {:text_delta, "partial"}}
    end

    test "stream error emits correct {:llm_call_end, {:error, ...}} loop event" do
      test_pid = self()

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:error, %{"type" => "api_error", "message" => "Server error"}}
        ]
      end)

      config = [model: :claude_sonnet, tools: []]

      callback = fn event -> send(test_pid, {:stream_event, event}) end

      {:error, _} = Loop.run_stream(config, "Hi", callback)

      assert_receive {:stream_event, {:loop_event, {:llm_call_end, {:error, %{"type" => "api_error"}}}}}
    end

    test "stream error does not cause further iterations" do
      Clementine.LLM.MockClient
      |> expect(:stream, 1, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:error, %{"type" => "overloaded_error", "message" => "Overloaded"}}
        ]
      end)

      config = [model: :claude_sonnet, tools: [EchoTool]]

      assert {:error, _} = Loop.run_stream(config, "Hi", fn _ -> :ok end)

      # Mox's expect with count 1 verifies no additional stream calls were made
    end

    test "handles max iterations in streaming mode" do
      Clementine.LLM.MockClient
      |> stub(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:content_block_start, 0, :tool_use},
          {:tool_use_start, "toolu_1", "echo"},
          {:input_json_delta, "toolu_1", "{\"message\":\"loop\"}"},
          {:content_block_stop, 0},
          {:message_delta, %{"stop_reason" => "tool_use"}, %{}},
          {:message_stop}
        ]
      end)

      config = [model: :claude_sonnet, tools: [EchoTool], max_iterations: 2]

      assert {:error, :max_iterations_reached} =
               Loop.run_stream(config, "Loop", fn _ -> :ok end)
    end
  end
end
