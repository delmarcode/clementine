defmodule Clementine.DeferredToolsTest do
  @moduledoc """
  `deferred:` on an agent: the tools the model loads through the
  provider's tool search instead of seeing up front. The model turns here
  are the Messages API's own stream (`sse_tool_search_stream/1`) run
  through the real parser, so the engine sees what Anthropic sends.
  """
  use ExUnit.Case, async: true

  import Mox

  alias Clementine.{Checkpoint, Pending, Result, Rollout, Suspension}
  alias Clementine.LLM.Anthropic
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}
  alias Clementine.LLM.StreamParser
  alias Clementine.Test.Fixtures
  alias Clementine.Test.Tools.{Add, Echo, GatedDeploy}

  setup :verify_on_exit!

  defmodule Support do
    @moduledoc false
    use Clementine.Agent,
      key: "deferred_support",
      model: :claude_sonnet,
      instructions: "Help.",
      tools: [Clementine.Test.Tools.Echo],
      deferred: [Clementine.Test.Tools.GatedDeploy]
  end

  describe "the agent" do
    test "takes deferred: in both forms" do
      assert %Clementine.Agent{tools: [Echo], deferred: [GatedDeploy]} = Support.agent(nil)

      assert %Clementine.Agent{deferred: [Add]} =
               Clementine.Agent.new(model: :claude_sonnet, tools: [Echo], deferred: [Add])

      assert %Clementine.Agent{deferred: []} = Clementine.Agent.new(model: :claude_sonnet)
    end

    test "refuses a tool in both tools: and deferred:" do
      assert_raise ArgumentError, ~r/tools: or deferred:, not both.*Echo/, fn ->
        Clementine.Agent.new(model: :claude_sonnet, tools: [Echo, Add], deferred: [Echo])
      end
    end
  end

  describe "the request" do
    test "carries every tool, and names the deferred ones for the client" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, tools, opts ->
        assert tools == [Echo, Add, GatedDeploy]
        assert opts[:deferred] == [Add, GatedDeploy]
        text_events("Done.")
      end)

      assert {:ok, %Result.Completed{}} =
               Rollout.execute(rollout(tools: [Echo], deferred: [Add, GatedDeploy]))
    end

    test "an agent without deferred tools sends no deferred: option" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, tools, opts ->
        assert tools == [Echo]
        refute Keyword.has_key?(opts, :deferred)
        text_events("Done.")
      end)

      assert {:ok, %Result.Completed{}} = Rollout.execute(rollout(tools: [Echo]))
    end
  end

  describe "a deferred tool the model finds" do
    test "runs and settles like any tool, and the search stays in the transcript in place" do
      expect_turn(search_turn("echo", %{"message" => "hi"}))

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
        assert [
                 %UserMessage{},
                 %AssistantMessage{} = searched,
                 %ToolResultMessage{content: [result]}
               ] = messages

        assert_search_turn(searched, "echo")
        assert %Content.ToolResult{tool_use_id: "toolu_01XYZ789", content: "Echo: hi"} = result
        text_events("Said hi.")
      end)

      assert {:ok, %Result.Completed{output: "Said hi."} = result} =
               Rollout.execute(rollout(tools: [Add], deferred: [Echo]))

      assert [%AssistantMessage{} = searched, %ToolResultMessage{}, %AssistantMessage{}] =
               result.messages

      assert_search_turn(searched, "echo")
    end

    test "is gated by approval: the run parks, and an approved resume runs it" do
      expect_turn(search_turn("gated_deploy", %{"env" => "prod"}))

      assert {:suspend, %Suspension.Request{} = request} =
               Rollout.execute(
                 rollout(tools: [Echo], deferred: [GatedDeploy], context: %{notify: self()})
               )

      assert %Pending.ToolApproval{tool_use_id: "toolu_01XYZ789", tool_name: "gated_deploy"} =
               request.pending

      refute_received {:deployed, _args}

      # Park: the checkpoint goes to storage as JSON and comes back.
      checkpoint = request |> park() |> Jason.encode!() |> Jason.decode!()

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, opts ->
        assert opts[:deferred] == [GatedDeploy]
        assert [%UserMessage{}, %AssistantMessage{} = searched, %ToolResultMessage{}] = messages
        assert_search_turn(searched, "gated_deploy")

        # And the resumed request replays the search to the API as it
        # first arrived: call, references, then the call it led to.
        assert [_user, %{"role" => "assistant", "content" => content}, _results] =
                 Anthropic.Messages.encode_all(messages)

        assert [
                 %{"type" => "text"},
                 %{
                   "type" => "server_tool_use",
                   "id" => "srvtoolu_01ABC123",
                   "name" => "tool_search_tool_regex",
                   "input" => %{"pattern" => "weather"}
                 },
                 %{
                   "type" => "tool_search_tool_result",
                   "tool_use_id" => "srvtoolu_01ABC123",
                   "content" => %{
                     "type" => "tool_search_tool_search_result",
                     "tool_references" => [
                       %{"type" => "tool_reference", "tool_name" => "gated_deploy"}
                     ]
                   }
                 },
                 %{"type" => "text"},
                 %{"type" => "tool_use", "id" => "toolu_01XYZ789", "name" => "gated_deploy"}
               ] = content

        text_events("Deployed.")
      end)

      assert {:ok, %Result.Completed{output: "Deployed."}} =
               Rollout.execute(
                 rollout(tools: [Echo], deferred: [GatedDeploy], context: %{notify: self()}),
                 resume: {checkpoint, {:approved, %{by: "u1"}}}
               )

      assert_received {:deployed, %{env: "prod"}}
    end
  end

  describe "a turn the provider paused" do
    test "goes back as it stands, and the provider's next answer finishes it" do
      paused = [
        {:content_block_start, 0, :server_tool_use},
        {:server_tool_use_start, "srvtoolu_1", "tool_search_tool_regex"},
        {:server_tool_input_delta, "srvtoolu_1", ~s({"pattern":"deploy"})},
        {:content_block_stop, 0},
        {:message_delta, %{"stop_reason" => "pause_turn"},
         %{"input_tokens" => 5, "output_tokens" => 2}}
      ]

      expect_turn(paused)

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
        # No "continue" message: the paused turn ends the history.
        assert [%UserMessage{}, %AssistantMessage{content: [%Content.ServerToolUse{}]}] =
                 messages

        text_events("Nothing to deploy.")
      end)

      assert {:ok, %Result.Completed{output: "Nothing to deploy."} = result} =
               Rollout.execute(rollout(tools: [Echo], deferred: [GatedDeploy]))

      assert [%AssistantMessage{}, %AssistantMessage{}] = result.messages
    end

    test "counts against the iteration cap" do
      paused = [{:message_delta, %{"stop_reason" => "pause_turn"}, %{}}]
      expect_turn(paused)
      expect_turn(paused)

      assert {:error, %Clementine.Error{code: :max_iterations}} =
               Rollout.execute(
                 rollout(tools: [Echo], deferred: [GatedDeploy], limits: [max_iterations: 2])
               )
    end
  end

  defp rollout(opts) do
    agent =
      Clementine.Agent.new(
        model: :claude_sonnet,
        instructions: "test",
        tools: Keyword.fetch!(opts, :tools),
        deferred: Keyword.get(opts, :deferred, [])
      )

    Rollout.new(
      agent: agent,
      input: "go",
      context: Keyword.get(opts, :context, %{}),
      limits: Keyword.get(opts, :limits, [])
    )
  end

  defp expect_turn(events) do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      events
    end)
  end

  # The Messages API's stream of a turn that searches for `tool_name` and
  # calls it, parsed the way the Anthropic client parses it.
  defp search_turn(tool_name, input) do
    sse = Fixtures.sse_tool_search_stream(tool_name: tool_name, tool_input: input)
    {events, _state} = StreamParser.parse(StreamParser.new(), sse)
    events
  end

  defp assert_search_turn(%AssistantMessage{content: content}, tool_name) do
    assert [
             %Content.Text{text: "I'll search for a tool."},
             %Content.ServerToolUse{
               id: "srvtoolu_01ABC123",
               name: "tool_search_tool_regex",
               input: %{"pattern" => "weather"}
             },
             %Content.ServerToolResult{
               tool_use_id: "srvtoolu_01ABC123",
               block_type: "tool_search_tool_result",
               content: %{
                 "tool_references" => [%{"type" => "tool_reference", "tool_name" => ^tool_name}]
               }
             },
             %Content.Text{text: "Found one."},
             %Content.ToolUse{id: "toolu_01XYZ789", name: ^tool_name}
           ] = content
  end

  # What a lifecycle stores when the run parks (Protocol.suspend/3).
  defp park(%Suspension.Request{} = request) do
    Checkpoint.encode(%Checkpoint{
      rollout_id: "r1",
      iteration: request.iteration,
      messages: request.messages,
      pending: request.pending,
      usage: request.usage
    })
  end

  defp text_events(text) do
    [
      {:text_delta, text},
      {:message_delta, %{"stop_reason" => "end_turn"},
       %{"input_tokens" => 7, "output_tokens" => 3}}
    ]
  end
end
