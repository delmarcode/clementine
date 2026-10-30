defmodule Clementine.DelegationTest do
  use ExUnit.Case, async: true

  alias Clementine.{Delegation, Error, EngineTool, InterruptReason, Result}

  defmodule Researcher do
    @moduledoc false
    use Clementine.Agent, key: "researcher", model: :claude_sonnet, instructions: "Research."
  end

  defmodule AlsoResearcher do
    @moduledoc false
    use Clementine.Agent, key: "researcher", model: :claude_sonnet, instructions: "Research."
  end

  describe "tool/1" do
    test "is a parking engine tool named delegate, its agent an enum of the keys" do
      tool = Delegation.tool([Researcher])
      assert %EngineTool{kind: :delegate, name: "delegate"} = tool
      assert EngineTool.parks?(tool)
      refute EngineTool.parks?(Clementine.Skill.use_skill_tool([skill()]))

      assert tool.description =~ "Agents: researcher"
      assert tool.parameters[:agent][:enum] == ["researcher"]
    end

    test "refuses a module that is not an agent, and two agents sharing a key" do
      assert_raise ArgumentError, ~r/agent modules/, fn -> Delegation.tool([String]) end

      assert_raise ArgumentError, ~r/keyed \["researcher"\]/, fn ->
        Delegation.tool([Researcher, AlsoResearcher])
      end
    end
  end

  describe "call/2" do
    test "asks for the child it names, among the offered agents only" do
      assert {:ok, %{agent: "researcher", prompt: "Look.", run_id: nil}} =
               Delegation.call([Researcher], %{"agent" => "researcher", "prompt" => "Look."})

      assert {:error, "delegate needs the agent to ask: one of researcher."} =
               Delegation.call([Researcher], %{"prompt" => "Look."})

      assert {:error, "delegate needs a prompt" <> _} =
               Delegation.call([Researcher], %{"agent" => "researcher"})
    end
  end

  describe "outcome/2" do
    test "passes a completed child's text as is, and JSON-encodes anything else" do
      assert Delegation.outcome("a", Result.completed(output: "Plain.")) ==
               %{"status" => "completed", "content" => "Plain.", "is_error" => false}

      assert %{"content" => json, "is_error" => false} =
               Delegation.outcome("a", Result.completed(output: %{"tier" => "high", "n" => 2}))

      assert Jason.decode!(json) == %{"tier" => "high", "n" => 2}
      assert %{"content" => "[1,2]"} = Delegation.outcome("a", Result.completed(output: [1, 2]))
      assert %{"content" => ""} = Delegation.outcome("a", Result.completed(output: nil))
      assert %{"content" => "{1, 2}"} = Delegation.outcome("a", Result.completed(output: {1, 2}))
    end

    test "settles a failed, cancelled, or interrupted child as an error naming what happened" do
      assert Delegation.outcome("a", Result.failed(%Error{message: "boom"})) ==
               %{"status" => "failed", "content" => "The a run failed: boom", "is_error" => true}

      assert %{"status" => "cancelled", "is_error" => true, "content" => cancelled} =
               Delegation.outcome("a", Result.cancelled(%{"code" => "cancelled"}))

      assert cancelled == "The a run was cancelled before it answered."

      assert %{
               "status" => "interrupted",
               "content" => "The a run was interrupted (lease_expired)" <> _
             } =
               Delegation.outcome("a", Result.interrupted(:lease_expired))

      assert %{"content" => "The a run was interrupted (:reconciled)" <> _} =
               Delegation.outcome(
                 "a",
                 Result.interrupted(InterruptReason.new({:app, :reconciled}))
               )
    end
  end

  defp skill do
    Clementine.Skill.new(name: "notes", description: "Notes.", body: "Short.")
  end
end
