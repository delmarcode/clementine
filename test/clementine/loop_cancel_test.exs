defmodule Clementine.LoopCancelTest do
  use ExUnit.Case, async: true
  import Mox

  alias Clementine.{CancelToken, Loop}
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

  describe "run/2 cancellation" do
    test "pre-tripped token returns {:error, :cancelled} without calling the LLM" do
      # No expectation set on :call. verify_on_exit! ensures it is never called.
      token = CancelToken.new()
      CancelToken.cancel(token)

      config = [model: :claude_sonnet, cancel_token: token]

      assert {:error, :cancelled} = Loop.run(config, "Hi")
    end

    test "token tripped during the first turn stops before the next LLM call" do
      token = CancelToken.new()

      # The model asks for a tool on the first turn; the mock trips the token
      # while producing that response, so after the tool runs the loop should
      # stop at the next iteration boundary instead of calling :call again.
      Clementine.LLM.MockClient
      |> expect(:call, 1, fn _model, _system, _messages, _tools, _opts ->
        CancelToken.cancel(token)

        {:ok,
         %Response{
           content: [Content.tool_use("toolu_1", "echo", %{"message" => "test"})],
           stop_reason: "tool_use",
           usage: %{}
         }}
      end)

      config = [model: :claude_sonnet, tools: [EchoTool], cancel_token: token]

      assert {:error, :cancelled} = Loop.run(config, "Echo test")
      # Mox count of 1 verifies no second :call happened.
    end

    test "emits a {:loop_end, :cancelled} event on cancel" do
      test_pid = self()
      token = CancelToken.new()
      CancelToken.cancel(token)

      config = [
        model: :claude_sonnet,
        cancel_token: token,
        on_event: fn event -> send(test_pid, {:event, event}) end
      ]

      assert {:error, :cancelled} = Loop.run(config, "Hi")
      assert_receive {:event, {:loop_end, :cancelled}}
    end
  end

  describe "run/2 control (no token / untripped)" do
    test "no token behaves exactly as before" do
      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok,
         %Response{content: [Content.text("Hello world!")], stop_reason: "end_turn", usage: %{}}}
      end)

      config = [model: :claude_sonnet]

      assert {:ok, "Hello world!", _messages} = Loop.run(config, "Hi")
    end

    test "untripped token behaves exactly as before" do
      token = CancelToken.new()

      Clementine.LLM.MockClient
      |> expect(:call, fn _model, _system, _messages, _tools, _opts ->
        {:ok, %Response{content: [Content.text("Hello!")], stop_reason: "end_turn", usage: %{}}}
      end)

      config = [model: :claude_sonnet, cancel_token: token]

      assert {:ok, "Hello!", _messages} = Loop.run(config, "Hi")
    end
  end

  describe "run_stream/3 cancellation" do
    test "pre-tripped token returns {:error, :cancelled} without streaming" do
      token = CancelToken.new()
      CancelToken.cancel(token)

      config = [model: :claude_sonnet, cancel_token: token]

      assert {:error, :cancelled} = Loop.run_stream(config, "Hi", fn _ -> :ok end)
    end

    test "token tripped mid-stream halts and does not run further iterations" do
      token = CancelToken.new()

      # A lazy stream that trips the token as it is consumed. The first event
      # passes through; by the time the next event is pulled the token is
      # cancelled, so reduce_while halts and the run returns {:error, :cancelled}
      # without a second stream call.
      Clementine.LLM.MockClient
      |> expect(:stream, 1, fn _model, _system, _messages, _tools, _opts ->
        Stream.map(
          [
            {:message_start, %{"id" => "msg_1"}},
            {:text_delta, "partial"},
            {:text_delta, "more"},
            {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
            {:message_stop}
          ],
          fn
            {:text_delta, "partial"} = e ->
              CancelToken.cancel(token)
              e

            other ->
              other
          end
        )
      end)

      config = [model: :claude_sonnet, tools: [EchoTool], cancel_token: token]

      assert {:error, :cancelled} = Loop.run_stream(config, "Hi", fn _ -> :ok end)
      # Mox count of 1 verifies no further stream iterations occurred.
    end

    test "mid-stream cancel emits a single clean {:loop_end, :cancelled}, not an error loop_end" do
      test_pid = self()
      token = CancelToken.new()

      Clementine.LLM.MockClient
      |> expect(:stream, 1, fn _model, _system, _messages, _tools, _opts ->
        Stream.map(
          [
            {:message_start, %{"id" => "msg_1"}},
            {:text_delta, "partial"},
            {:text_delta, "more"},
            {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
            {:message_stop}
          ],
          fn
            {:text_delta, "partial"} = e ->
              CancelToken.cancel(token)
              e

            other ->
              other
          end
        )
      end)

      config = [model: :claude_sonnet, cancel_token: token]
      callback = fn event -> send(test_pid, {:ev, event}) end

      assert {:error, :cancelled} = Loop.run_stream(config, "Hi", callback)

      # Streaming wraps loop events as {:loop_event, _}; run_stream wraps every
      # forwarded event as {seq, _}. Cancel must surface as a clean :cancelled
      # loop end, never the generic {:error, :cancelled} error loop end.
      assert_receive {:ev, {_seq, {:loop_event, {:loop_end, :cancelled}}}}
      refute_received {:ev, {_s, {:loop_event, {:loop_end, {:error, :cancelled}}}}}
    end

    test "untripped token streams normally" do
      token = CancelToken.new()

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:message_start, %{"id" => "msg_1"}},
          {:content_block_start, 0, :text},
          {:text_delta, "Hello world!"},
          {:content_block_stop, 0},
          {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
          {:message_stop}
        ]
      end)

      config = [model: :claude_sonnet, cancel_token: token]

      assert {:ok, "Hello world!", _messages} = Loop.run_stream(config, "Hi", fn _ -> :ok end)
    end
  end
end
