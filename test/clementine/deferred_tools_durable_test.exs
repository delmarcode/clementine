defmodule Clementine.DeferredToolsDurableTest do
  @moduledoc """
  A deferred tool on the durable runtime: the model finds it with the
  provider's tool search, it needs approval, the run parks with its
  checkpoint in Postgres, and the approved resume replays the search.
  """
  use Clementine.RunsCase

  alias Clementine.LLM.Anthropic
  alias Clementine.LLM.Message.{AssistantMessage, Content}
  alias Clementine.LLM.StreamParser

  defmodule Refunds do
    @moduledoc false

    defmodule IssueRefund do
      @moduledoc false
      use Clementine.Tool,
        name: "issue_refund",
        description: "Refunds an order.",
        approval: :required,
        retry: :unsafe,
        parameters: [order: [type: :string, required: true]]

      @impl true
      def run(%{order: order}, _context), do: {:ok, "Refunded #{order}."}
    end

    use Clementine.Agent,
      key: "test_deferred_refunds",
      model: :claude_sonnet,
      instructions: "Help with orders.",
      tools: [Clementine.RunsCase.Context],
      deferred: [IssueRefund]
  end

  @moduletag runtime: false

  setup do
    start_supervised!(
      {Clementine, repo: TestRepo, agents: [Refunds], host: Clementine.RunsCase.Host}
    )

    :ok
  end

  test "a deferred tool found by search parks for approval, and the resume replays the search" do
    {:ok, run} = Runs.start(Refunds, "Refund order A1")

    sse =
      Clementine.Test.Fixtures.sse_tool_search_stream(
        tool_name: "issue_refund",
        tool_input: %{"order" => "A1"}
      )

    {search_turn, _state} = StreamParser.parse(StreamParser.new(), sse)

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, tools, opts ->
      assert tools == [Clementine.RunsCase.Context, Refunds.IssueRefund]
      assert opts[:deferred] == [Refunds.IssueRefund]
      search_turn
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "waiting"} = Runs.get(run.id)

    assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, opts ->
      assert opts[:deferred] == [Refunds.IssueRefund]

      # The checkpoint came back from Postgres with the search in place.
      assert [_prompt, %AssistantMessage{content: content}, results] = messages

      assert [
               %Content.Text{},
               %Content.ServerToolUse{id: "srvtoolu_01ABC123", input: %{"pattern" => "weather"}},
               %Content.ServerToolResult{
                 tool_use_id: "srvtoolu_01ABC123",
                 block_type: "tool_search_tool_result"
               },
               %Content.Text{},
               %Content.ToolUse{id: "toolu_01XYZ789", name: "issue_refund"}
             ] = content

      assert %{content: [%Content.ToolResult{content: "Refunded A1.", is_error: false}]} =
               results

      # And it goes back to the API as the API sent it.
      assert [_, %{"content" => [_, search, references, _, _]}, _] =
               Anthropic.Messages.encode_all(messages)

      assert search == %{
               "type" => "server_tool_use",
               "id" => "srvtoolu_01ABC123",
               "name" => "tool_search_tool_regex",
               "input" => %{"pattern" => "weather"}
             }

      assert references == %{
               "type" => "tool_search_tool_result",
               "tool_use_id" => "srvtoolu_01ABC123",
               "content" => %{
                 "type" => "tool_search_tool_search_result",
                 "tool_references" => [
                   %{"type" => "tool_reference", "tool_name" => "issue_refund"}
                 ]
               }
             }

      text_events("Refunded.")
    end)

    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert %AgentRun{status: "completed", result: %{"output" => "Refunded."}} =
             Runs.get(run.id)
  end
end
