defmodule Clementine.LoopTest do
  use ExUnit.Case, async: true
  import Mox

  alias Clementine.Loop

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
         %{
           content: [%{type: :text, text: "Hello world!"}],
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
           %{
             content: [
               %{type: :tool_use, id: "toolu_1", name: "echo", input: %{"message" => "test"}}
             ],
             stop_reason: "tool_use",
             usage: %{}
           }}
        else
          # Second call: model returns final text
          {:ok,
           %{
             content: [%{type: :text, text: "Done!"}],
             stop_reason: "end_turn",
             usage: %{}
           }}
        end
      end)
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %{
           content: [%{type: :text, text: "Done!"}],
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
         %{
           content: [%{type: :text, text: "Hello"}],
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
         %{
           content: [
             %{type: :tool_use, id: "toolu_1", name: "echo", input: %{"message" => "loop"}}
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
         %{
           content: [%{type: :text, text: "Hello"}],
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
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: [%{type: :text, text: "Hi there!"}]}
      ]

      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, messages, _tools, _opts ->
        # Should have 3 messages: 2 initial + 1 new user message
        assert length(messages) == 3

        {:ok,
         %{
           content: [%{type: :text, text: "Continuing conversation"}],
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
end
