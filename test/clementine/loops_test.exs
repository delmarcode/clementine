defmodule Clementine.LoopsTest do
  # async: false + global Mox because the agent runs the LLM client from its
  # own process (and fan_out runs several agents across Task processes).
  use ExUnit.Case, async: false
  import Mox

  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Response

  setup :set_mox_global
  setup :verify_on_exit!

  defmodule TestAgent do
    use Clementine.Agent,
      name: "loops_test_agent",
      model: :claude_sonnet,
      tools: [],
      system: "You are a test assistant."
  end

  # A bare text response from the model — the outer loop never uses tools here,
  # so each Clementine.run/2 is exactly one mocked :call.
  defp text(body) do
    {:ok, %Response{content: [Content.text(body)], stop_reason: "end_turn", usage: %{}}}
  end

  describe "drive/3" do
    test "runs a single turn when :decide returns :done immediately" do
      Clementine.LLM.MockClient
      |> expect(:call, 1, fn _model, _system, _messages, _tools, _opts -> text("all set") end)

      {:ok, agent} = TestAgent.start_link()

      assert {:ok, "all set", 1} =
               Clementine.Loops.drive(agent, "do the thing",
                 decide: fn _output, _turn -> :done end
               )

      GenServer.stop(agent)
    end

    test "re-prompts until :decide returns :done, counting turns" do
      # Three outer turns => three inner runs => three :call invocations.
      Clementine.LLM.MockClient
      |> expect(:call, 3, fn _model, _system, _messages, _tools, _opts -> text("working") end)

      {:ok, agent} = TestAgent.start_link()

      decide = fn _output, turn ->
        if turn >= 3, do: :done, else: {:continue, "keep going (was turn #{turn})"}
      end

      assert {:ok, "working", 3} = Clementine.Loops.drive(agent, "start", decide: decide)

      GenServer.stop(agent)
    end

    test "stops at :max_turns and returns the last output" do
      Clementine.LLM.MockClient
      |> expect(:call, 2, fn _model, _system, _messages, _tools, _opts -> text("still going") end)

      {:ok, agent} = TestAgent.start_link()

      assert {:error, {:max_turns_reached, "still going"}} =
               Clementine.Loops.drive(agent, "start",
                 max_turns: 2,
                 decide: fn _output, _turn -> {:continue, "again"} end
               )

      GenServer.stop(agent)
    end

    test "invokes the :on_turn callback once per turn" do
      Clementine.LLM.MockClient
      |> expect(:call, 2, fn _model, _system, _messages, _tools, _opts -> text("tick") end)

      {:ok, agent} = TestAgent.start_link()
      test_pid = self()

      decide = fn _output, turn -> if turn >= 2, do: :done, else: {:continue, "more"} end

      Clementine.Loops.drive(agent, "start",
        decide: decide,
        on_turn: fn info -> send(test_pid, {:turn, info.turn}) end
      )

      assert_received {:turn, 1}
      assert_received {:turn, 2}

      GenServer.stop(agent)
    end

    test "propagates an error from Clementine.run/2" do
      Clementine.LLM.MockClient
      |> expect(:call, 1, fn _model, _system, _messages, _tools, _opts -> {:error, :boom} end)

      {:ok, agent} = TestAgent.start_link()

      assert {:error, :boom} = Clementine.Loops.drive(agent, "start")

      GenServer.stop(agent)
    end
  end

  describe "until_verified/4" do
    test "stops as soon as the check passes" do
      Clementine.LLM.MockClient
      |> expect(:call, 2, fn _model, _system, _messages, _tools, _opts -> text("attempt") end)

      {:ok, agent} = TestAgent.start_link()

      # External check fails the first time, passes the second.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      check = fn _output ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if n == 0, do: {:retry, "not yet"}, else: :ok
      end

      assert {:ok, "attempt", 2} = Clementine.Loops.until_verified(agent, "make it pass", check)

      GenServer.stop(agent)
    end

    test "gives up at :max_turns if the check never passes" do
      Clementine.LLM.MockClient
      |> expect(:call, 3, fn _model, _system, _messages, _tools, _opts -> text("nope") end)

      {:ok, agent} = TestAgent.start_link()

      assert {:error, {:max_turns_reached, "nope"}} =
               Clementine.Loops.until_verified(
                 agent,
                 "make it pass",
                 fn _ -> {:retry, "still red"} end,
                 max_turns: 3
               )

      GenServer.stop(agent)
    end
  end

  describe "fan_out/3" do
    test "runs work across many agents in parallel and preserves order" do
      Clementine.LLM.MockClient
      |> stub(:call, fn _model, _system, _messages, _tools, _opts -> text("reviewed") end)

      results =
        Clementine.Loops.fan_out([:a, :b, :c], fn item ->
          {:ok, agent} = TestAgent.start_link()
          {:ok, output} = Clementine.run(agent, "review #{item}")
          GenServer.stop(agent)
          {item, output}
        end)

      assert results == [
               {:ok, {:a, "reviewed"}},
               {:ok, {:b, "reviewed"}},
               {:ok, {:c, "reviewed"}}
             ]
    end

    test "isolates a crash in one item without failing the rest" do
      Clementine.LLM.MockClient
      |> stub(:call, fn _model, _system, _messages, _tools, _opts -> text("ok") end)

      results =
        Clementine.Loops.fan_out([:good, :bad], fn
          :bad ->
            raise "kaboom"

          item ->
            {:ok, agent} = TestAgent.start_link()
            {:ok, output} = Clementine.run(agent, "go #{item}")
            GenServer.stop(agent)
            {item, output}
        end)

      assert [{:ok, {:good, "ok"}}, {:error, _reason}] = results
    end
  end
end
