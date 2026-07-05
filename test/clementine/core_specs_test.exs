defmodule Clementine.CoreSpecsTest do
  use ExUnit.Case, async: true

  alias Clementine.{Agent, Event, Lease, ResumeToken, Rollout, Run, Suspension}
  alias Clementine.Pending.ToolApproval

  describe "Agent.new/1" do
    test "builds an inert definition" do
      agent =
        Agent.new(
          id: "agent_1",
          model: :claude_sonnet,
          instructions: "Be helpful.",
          tools: [SomeTool],
          defaults: [max_iterations: 5]
        )

      assert %Agent{model: :claude_sonnet, tools: [SomeTool]} = agent
    end

    test "model is required" do
      assert_raise ArgumentError, fn -> Agent.new(id: "no_model") end
    end
  end

  describe "Rollout.new/1 and to_config/1" do
    test "builds a spec and lowers it to engine config" do
      agent =
        Agent.new(
          model: :claude_sonnet,
          instructions: "sys",
          tools: [ToolA],
          defaults: [max_iterations: 5]
        )

      rollout =
        Rollout.new(
          agent: agent,
          input: "do the thing",
          messages: [:prior],
          context: %{workspace_id: 7}
        )

      config = Rollout.to_config(rollout)

      assert config[:model] == :claude_sonnet
      assert config[:system] == "sys"
      assert config[:tools] == [ToolA]
      assert config[:messages] == [:prior]
      assert config[:context] == %{workspace_id: 7}
      assert config[:max_iterations] == 5
    end

    test "rollout limits win over agent defaults" do
      agent = Agent.new(model: :claude_sonnet, defaults: [max_iterations: 5])
      rollout = Rollout.new(agent: agent, input: "x", limits: [max_iterations: 2])

      assert Rollout.to_config(rollout)[:max_iterations] == 2
    end

    test "max_iterations falls back to the engine default" do
      agent = Agent.new(model: :claude_sonnet)
      rollout = Rollout.new(agent: agent, input: "x")

      assert Rollout.to_config(rollout)[:max_iterations] == 10
    end

    test "agent and input are required" do
      assert_raise ArgumentError, fn -> Rollout.new(input: "orphan") end
    end
  end

  test "Run.new/1 requires ref and rollout" do
    agent = Agent.new(model: :claude_sonnet)
    rollout = Rollout.new(agent: agent, input: "x")

    assert %Run{ref: "run_9", metadata: %{}} = Run.new(ref: "run_9", rollout: rollout)
    assert_raise ArgumentError, fn -> Run.new(ref: "run_9") end
  end

  test "Lease requires identity and the lifecycle handle" do
    assert_raise ArgumentError, fn ->
      struct!(Lease, run_ref: "r", epoch: 1, executor_id: "x")
    end

    lease = struct!(Lease, run_ref: "r", epoch: 1, executor_id: "x", lifecycle: SomeLifecycle)
    assert lease.resume == nil
  end

  describe "Suspension.reason_type/1" do
    test "discriminates every reason shape" do
      approval = {:approval, %Clementine.ApprovalRequest{tool_use_id: "t", tool_name: "n"}}

      request = %Suspension.Request{
        reason: approval,
        pending: %ToolApproval{tool_use_id: "t", tool_name: "n"}
      }

      assert Suspension.reason_type(approval) == :approval
      assert Suspension.reason_type(request) == :approval
      assert Suspension.reason_type({:external, :webhook}) == :external
      assert Suspension.reason_type({:until, ~U[2026-08-01 00:00:00Z]}) == :until
    end
  end

  test "ResumeToken carries exactly run, epoch, and reason type" do
    token = %ResumeToken{run_ref: "run_1", epoch: 4, reason_type: :approval}
    assert %{run_ref: "run_1", epoch: 4, reason_type: :approval} = Map.from_struct(token)
  end

  describe "Event ordering" do
    test "compare/2 is lexicographic on (epoch, seq)" do
      e = fn epoch, seq ->
        %Event{run_ref: "r", epoch: epoch, seq: seq, type: :text_delta}
      end

      assert Event.compare(e.(1, 99), e.(2, 0)) == :lt
      assert Event.compare(e.(2, 5), e.(2, 4)) == :gt
      assert Event.compare(e.(3, 3), e.(3, 3)) == :eq
    end

    test "cursor/1 exposes the (epoch, seq) identity" do
      event = %Event{run_ref: "r", epoch: 2, seq: 57, type: :tool_result}
      assert Event.cursor(event) == {2, 57}
    end
  end
end
