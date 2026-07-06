defmodule Clementine.Lifecycle.EctoApprovalRoundTripTest do
  @moduledoc """
  The full approval round trip of RFC §The Resume Flow against the Ecto
  adapter: the real engine parks the run, the suspension — checkpoint,
  pending call, settled siblings, token — survives the recipe's jsonb
  columns, the app reads the token from its own storage and resumes, and
  the next claim hands the checkpoint back for the rollout to finish.
  """
  use Clementine.EctoCase, async: false

  import Mox

  alias Clementine.{Event, Pending, Result, Rollout, Run, Runner, Suspension, ToolResult, Usage}
  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.LLM.Message.{Content, ToolResultMessage}
  alias Clementine.Test.CollectingSink
  alias Clementine.Test.Ecto.Lifecycle
  alias Clementine.Test.Tools.{GatedDeploy, SafeEcho}

  setup :verify_on_exit!

  defp build_run(run_row) do
    agent =
      Clementine.Agent.new(
        model: :claude_sonnet,
        instructions: "test agent",
        tools: [GatedDeploy, SafeEcho]
      )

    rollout =
      Rollout.new(agent: agent, input: "ship it", context: %{notify: self()})

    Run.new(ref: run_row.id, rollout: rollout)
  end

  defp execute(run, opts \\ []) do
    Runner.execute(
      run,
      Keyword.merge(
        [lifecycle: Lifecycle, ctx: self(), executor_id: "test:approval", heartbeat: false],
        opts
      )
    )
  end

  defp expect_stream(events) do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      events
    end)
  end

  defp gated_batch_events do
    [
      {:tool_use_start, "tu_1", "gated_deploy"},
      {:input_json_delta, "tu_1", Jason.encode!(%{"env" => "prod"})},
      {:content_block_stop, 0},
      {:tool_use_start, "tu_2", "safe_echo"},
      {:input_json_delta, "tu_2", Jason.encode!(%{"message" => "staged"})},
      {:content_block_stop, 1},
      {:message_delta, %{"stop_reason" => "tool_use"},
       %{"input_tokens" => 5, "output_tokens" => 2}}
    ]
  end

  defp text_events(text) do
    [
      {:text_delta, text},
      {:message_delta, %{"stop_reason" => "end_turn"},
       %{"input_tokens" => 7, "output_tokens" => 3}}
    ]
  end

  defp fetch!(run_id) do
    {:ok, facts} = Lifecycle.fetch(run_id, self())
    facts
  end

  test "full approval round trip: park, approve, resume, complete" do
    run_row = insert_run!()
    run = build_run(run_row)

    expect_stream(gated_batch_events())

    assert {:suspended, token} = execute(run, events: CollectingSink)

    # The suspension round-tripped through the recipe's jsonb columns:
    # pending call, settled sibling, and the token, all exactly.
    facts = fetch!(run_row.id)
    assert facts.status == :waiting
    assert %Suspension{token: stored_token, checkpoint: checkpoint} = facts.suspension
    assert stored_token == token

    assert %Pending.ToolApproval{
             tool_use_id: "tu_1",
             tool_name: "gated_deploy",
             args: %{"env" => "prod"},
             completed_results: %{"tu_2" => %ToolResult{content: "Echo: staged"}}
           } = checkpoint.pending

    assert checkpoint.iteration == 1
    assert checkpoint.usage == %Usage{input_tokens: 5, output_tokens: 2}
    refute_received {:deployed, _args}

    # The advisory approval event followed the durable park, token-free —
    # the approval surface reads the token from stored facts instead.
    assert_received {:clementine_event, %Event{type: :approval_requested} = event}
    assert event.payload == %{tool_use_id: "tu_1", name: "gated_deploy", args: %{"env" => "prod"}}

    # The app authorizes its caller, then resumes with the stored token.
    assert {:ok, %Facts{status: :queued}} =
             Protocol.resume(Lifecycle, stored_token, {:approved, %{by: 42}}, self())

    # matrix row 7: the token fires exactly once — a replayed approval
    # dies precisely, and the run is untouched.
    assert {:error, :already_resumed} =
             Protocol.resume(Lifecycle, stored_token, {:approved, %{by: 42}}, self())

    # Re-enqueue is a second execute; the claim hands the checkpoint back.
    expect_stream(text_events("Shipped."))

    assert {:finished, %Facts{status: :completed, epoch: 2}} = execute(run)

    # The gated call finally executed, exactly once.
    assert_received {:deployed, %{env: "prod"}}
    refute_received {:deployed, _args}

    # The projection committed with the terminal: the settled batch rides
    # in tool-use order, the sibling's checkpointed result un-re-executed.
    assert_received {:projected, %Result.Completed{output: "Shipped."} = result, _row}

    assert [_assistant, %ToolResultMessage{content: [first, second]}, _final] = result.messages

    assert %Content.ToolResult{tool_use_id: "tu_1", content: "deployed prod", is_error: false} =
             first

    assert %Content.ToolResult{tool_use_id: "tu_2", content: "Echo: staged"} = second
    assert result.usage == %Usage{input_tokens: 12, output_tokens: 5}
  end

  test "denied round trip: the model reacts to the approver's message" do
    run_row = insert_run!()
    run = build_run(run_row)

    expect_stream(gated_batch_events())
    assert {:suspended, _token} = execute(run)

    # The approval surface reads the token from the app's own storage.
    %Facts{suspension: %Suspension{token: token}} = fetch!(run_row.id)

    assert {:ok, %Facts{status: :queued}} =
             Protocol.resume(
               Lifecycle,
               token,
               {:denied, %{by: 42, message: "not in prod"}},
               self()
             )

    expect_stream(text_events("Understood, standing down."))

    assert {:finished, %Facts{status: :completed}} = execute(run)

    # The gated tool never ran; the model saw the denial as an error tool
    # result and reacted.
    refute_received {:deployed, _args}
    assert_received {:projected, %Result.Completed{messages: messages}, _row}
    assert [_assistant, %ToolResultMessage{content: [denial, _sibling]}, _final] = messages

    assert %Content.ToolResult{tool_use_id: "tu_1", content: "not in prod", is_error: true} =
             denial
  end
end
