defmodule Clementine.Runs.DelegationTest do
  @moduledoc """
  Delegation on the durable runtime: a parent's `delegate` calls start
  its children in the transaction that parks it, each child's end
  reaches the parent, and the last one resumes it with every outcome.
  Both lane refusals, cancel in both directions, the reaper's two paths,
  a resumed parent requeued by a drain, and the trace.
  """

  use Clementine.RunsCase

  alias Clementine.{Checkpoint, Error, Pending, Result, ToolResult}
  alias Clementine.Lifecycle.Ecto.Codec
  alias Clementine.Lifecycle.Protocol
  alias Clementine.LLM.Message.{Content, ToolResultMessage}
  alias Clementine.Runs.{Lifecycle, Reaper}
  alias Clementine.Trace.Entry

  import Ecto.Query, only: [from: 2]

  @fields Codec.resolve_fields(:id, [])

  defmodule Grader do
    @moduledoc false
    use Clementine.Agent,
      key: "test_delegate_grader",
      model: :claude_sonnet,
      instructions: "Grade the essay.",
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "verdict" => %{"type" => "string", "enum" => ["pass", "fail"]},
          "reasons" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["verdict", "reasons"],
        "additionalProperties" => false
      }
  end

  defmodule Concierge do
    @moduledoc false
    use Clementine.Agent,
      key: "test_concierge",
      turn: true,
      model: :claude_sonnet,
      instructions: "Help travellers.",
      delegates: [Clementine.RunsCase.Echo]

    @impl true
    def history(_run), do: []
  end

  defmodule Ping do
    @moduledoc false
    use Clementine.Agent,
      key: "test_ping",
      model: :claude_sonnet,
      instructions: "Serve.",
      delegates: [Clementine.Runs.DelegationTest.Pong]
  end

  defmodule Pong do
    @moduledoc false
    use Clementine.Agent,
      key: "test_pong",
      model: :claude_sonnet,
      instructions: "Return.",
      delegates: [Clementine.Runs.DelegationTest.Ping]
  end

  defmodule Narcissus do
    @moduledoc false
    use Clementine.Agent,
      key: "test_narcissus",
      model: :claude_sonnet,
      instructions: "Ask yourself.",
      delegates: [Clementine.Runs.DelegationTest.Narcissus]
  end

  defmodule Head do
    @moduledoc false
    use Clementine.Agent,
      key: "test_delegate_head",
      model: :claude_sonnet,
      instructions: "Have essays graded.",
      delegates: [Grader]
  end

  setup do
    Process.register(self(), :clementine_runs_test)
    :ok
  end

  defp calls(calls) do
    blocks =
      calls
      |> Enum.with_index()
      |> Enum.flat_map(fn {{id, name, input}, index} ->
        [
          {:tool_use_start, id, name},
          {:input_json_delta, id, Jason.encode!(input)},
          {:content_block_stop, index}
        ]
      end)

    blocks ++
      [
        {:message_delta, %{"stop_reason" => "tool_use"},
         %{"input_tokens" => 10, "output_tokens" => 5}}
      ]
  end

  defp ask(id, agent, prompt), do: {id, "delegate", %{"agent" => agent, "prompt" => prompt}}

  # The model's next turn answers `text`, and reports the tool results it read.
  defp expect_reply(text) do
    test = self()

    Mox.expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      send(test, {:read, tool_results(messages)})
      text_events(text)
    end)
  end

  defp tool_results(messages) do
    for %ToolResultMessage{content: blocks} <- messages,
        %Content.ToolResult{} = block <- blocks,
        do: {block.tool_use_id, block.content, block.is_error}
  end

  defp facts(id), do: id |> Runs.get() |> Codec.to_facts(@fields)

  defp children(parent_id) do
    parent_id |> then(&Runs.list(parent: &1)) |> Enum.sort_by(& &1.tag_id)
  end

  defp perform!(%AgentRun{id: id}), do: perform!(id)
  defp perform!(id) when is_binary(id), do: perform_job(Worker, %{"run_id" => id})

  # A parent parked on the calls the model makes in its first turn.
  defp park!(calls, opts \\ []) do
    {:ok, parent} = Runs.start(Planner, "Plan the launch", opts)
    expect_turn(calls(calls))
    assert :ok = perform!(parent)
    parent.id
  end

  describe "a batch of delegate calls" do
    test "starts every child with the parent's subject and actor, in the transaction that " <>
           "parks the parent" do
      parent_id =
        park!(
          [ask("tu_1", "test_echo", "Say the plan."), ask("tu_2", "test_lookup", "Find dates.")],
          subject: {"ticket", "t-1"},
          actor: {"user", "u-1"}
        )

      assert [echo, lookup] = children(parent_id)

      for {child, tag_id, key, prompt} <- [
            {echo, "tu_1", "test_echo", "Say the plan."},
            {lookup, "tu_2", "test_lookup", "Find dates."}
          ] do
        assert %AgentRun{
                 status: "queued",
                 parent_id: ^parent_id,
                 tag_kind: "delegate",
                 tag_id: ^tag_id,
                 agent_key: ^key,
                 turn: false,
                 subject_type: "ticket",
                 subject_id: "t-1",
                 actor_type: "user",
                 actor_id: "u-1",
                 input: %{"prompt" => ^prompt},
                 metadata: %{"delegated_by" => "test_planner"}
               } = child

        assert_enqueued(worker: Worker, args: %{"run_id" => child.id})
      end

      assert %{
               status: :waiting,
               suspension: %{
                 reason: {:external, {:delegation, ids}},
                 checkpoint: %Checkpoint{version: 2, pending: %Pending.Delegation{} = pending}
               }
             } = facts(parent_id)

      assert ids == [echo.id, lookup.id]

      assert %{
               "tu_1" => %{agent: "test_echo", run_id: echo_id},
               "tu_2" => %{agent: "test_lookup", run_id: lookup_id}
             } = pending.children

      assert {echo_id, lookup_id} == {echo.id, lookup.id}
      assert_received {:run_transition, %AgentRun{id: ^parent_id}, :suspended, false}
    end

    test "resumes the parent with every child's answer once the last ends, on a new job, " <>
           "and the trace records each child" do
      parent_id =
        park!([ask("tu_1", "test_echo", "Say A."), ask("tu_2", "test_lookup", "Find B.")],
          subject: {"ticket", "t-2"}
        )

      parked_job = Runs.get(parent_id).oban_job_id
      [echo, lookup] = children(parent_id)

      expect_turn(text_events("A."))
      assert :ok = perform!(echo)
      assert %AgentRun{status: "waiting"} = Runs.get(parent_id)

      expect_turn(text_events("B, found."))
      assert :ok = perform!(lookup)

      assert %{status: :queued, resume: %{payload: {:delegated, outcomes}}} = facts(parent_id)

      assert outcomes == %{
               "tu_1" => %{"status" => "completed", "content" => "A.", "is_error" => false},
               "tu_2" => %{"status" => "completed", "content" => "B, found.", "is_error" => false}
             }

      resumed = Runs.get(parent_id)
      assert resumed.oban_job_id != parked_job
      assert_enqueued(worker: Worker, args: %{"run_id" => parent_id}, state: "available")
      assert_received {:run_transition, %AgentRun{id: ^parent_id}, :resumed, false}

      expect_reply("The plan is A and B.")
      assert :ok = perform!(parent_id)
      assert_received {:read, [{"tu_1", "A.", false}, {"tu_2", "B, found.", false}]}

      assert %AgentRun{status: "completed", result: %{"output" => "The plan is A and B."}} =
               Runs.get(parent_id)

      delegated =
        for %Entry{kind: :delegate, payload: payload} <- Runs.trace(parent_id), do: payload

      assert [
               %{"tool_use_id" => "tu_1", "agent" => "test_echo", "child_id" => echo_id},
               %{"tool_use_id" => "tu_2", "agent" => "test_lookup", "child_id" => lookup_id}
             ] = delegated

      assert {echo_id, lookup_id} == {echo.id, lookup.id}
      assert Enum.all?(delegated, &(&1["status"] == "completed"))

      # Each child's own trace is a read away.
      assert [%Entry{kind: :execution} | _] = Runs.trace(echo_id)
    end

    test "settles a child's map output as JSON, and a failed child as an error" do
      parent_id =
        park!([ask("tu_1", "test_echo", "Grade it."), ask("tu_2", "test_lookup", "Look.")])

      [echo, lookup] = children(parent_id)
      verdict = %{"tier" => "high", "score" => 3}

      {:ok, lease} = Protocol.claim(Lifecycle, echo.id, executor: "test")
      {:ok, _} = Protocol.finish(lease, Result.completed(output: verdict))

      {:ok, lease} = Protocol.claim(Lifecycle, lookup.id, executor: "test")
      {:ok, _} = Protocol.finish(lease, Result.failed(%Error{message: "the index is down"}))

      assert %{resume: %{payload: {:delegated, outcomes}}} = facts(parent_id)
      assert %{"tu_1" => %{"content" => json, "is_error" => false}} = outcomes
      assert Jason.decode!(json) == verdict

      assert outcomes["tu_2"] == %{
               "status" => "failed",
               "content" => "The test_lookup run failed: the index is down",
               "is_error" => true
             }
    end

    @tag runtime: false
    test "settles a structured answer as its JSON" do
      start_supervised!(
        {Clementine, repo: TestRepo, agents: [Grader, Head], host: Clementine.RunsCase.Host}
      )

      {:ok, parent} = Runs.start(Head, "Grade the essay")
      expect_turn(calls([ask("tu_1", "test_delegate_grader", "Grade: An essay.")]))
      assert :ok = perform!(parent)

      [child] = children(parent.id)
      expect_turn(text_events(~s({"verdict": "pass", "reasons": ["argued"]})))
      assert :ok = perform!(child)

      verdict = %{"verdict" => "pass", "reasons" => ["argued"]}
      assert %AgentRun{result: %{"output" => ^verdict}} = Runs.get(child.id)

      expect_reply("It passed.")
      assert :ok = perform!(parent.id)
      assert_received {:read, [{"tu_1", json, false}]}
      assert Jason.decode!(json) == verdict
    end

    test "of a parent with no subject starts two children of one agent: no lane holds them" do
      parent_id = park!([ask("tu_1", "test_echo", "One."), ask("tu_2", "test_echo", "Two.")])

      assert [%AgentRun{agent_key: "test_echo"}, %AgentRun{agent_key: "test_echo"}] =
               children(parent_id)
    end
  end

  describe "lanes" do
    test "a turn agent is refused at the call: the model reads why, and nothing parks" do
      {:ok, parent} = Runs.start(Planner, "Plan", subject: {"ticket", "t-3"})
      expect_turn(calls([ask("tu_1", "test_chat", "Tell the customer.")]))
      expect_reply("I will tell them myself.")

      assert :ok = perform!(parent)
      assert_received {:read, [{"tu_1", refusal, true}]}
      assert refusal =~ "it takes turns on a conversation"

      assert %AgentRun{status: "completed"} = Runs.get(parent.id)
      assert children(parent.id) == []
    end

    test "an agent at work on the subject is refused at the park, and so is a second call " <>
           "to an agent the batch already asked; the others start" do
      {:ok, busy} = Runs.start(Echo, "Already busy", subject: {"ticket", "t-4"})

      parent_id =
        park!(
          [
            ask("tu_1", "test_echo", "Say it."),
            ask("tu_2", "test_lookup", "Look once."),
            ask("tu_3", "test_lookup", "Look twice.")
          ],
          subject: {"ticket", "t-4"}
        )

      assert [%AgentRun{tag_id: "tu_2"} = lookup] = children(parent_id)

      assert %{
               suspension: %{
                 reason: {:external, {:delegation, [lookup_id]}},
                 checkpoint: %Checkpoint{pending: pending}
               }
             } = facts(parent_id)

      assert lookup_id == lookup.id
      assert %{"tu_1" => %{run_id: nil}, "tu_3" => %{run_id: nil}} = pending.children

      assert %{
               "tu_1" => %ToolResult{is_error: true, content: busy_refusal},
               "tu_3" => %ToolResult{is_error: true, content: sibling_refusal}
             } = pending.completed_results

      assert busy_refusal =~ ~s(Cannot ask "test_echo": it is already at work on this subject)
      assert sibling_refusal =~ ~s(Cannot ask "test_lookup": it is already at work)

      expect_turn(text_events("Looked."))
      assert :ok = perform!(lookup)

      expect_reply("Done.")
      assert :ok = perform!(parent_id)

      assert_received {:read,
                       [
                         {"tu_1", ^busy_refusal, true},
                         {"tu_2", "Looked.", false},
                         {"tu_3", ^sibling_refusal, true}
                       ]}

      # The refused calls are on the trace as calls; only the child that ran is a delegate.
      assert [%{"tool_use_id" => "tu_2"}] =
               for(%Entry{kind: :delegate, payload: p} <- Runs.trace(parent_id), do: p)

      assert %AgentRun{status: "queued"} = Runs.get(busy.id)
    end

    test "a batch whose every child is refused at the park resumes the parent once its " <>
           "execution is over" do
      {:ok, _busy} = Runs.start(Echo, "Already busy", subject: {"ticket", "t-5"})
      parent_id = park!([ask("tu_1", "test_echo", "Say it.")], subject: {"ticket", "t-5"})

      # after_execution/2 ran with the run still parked: nothing could
      # claim its next execution before it let go.
      assert_received {:after_execution, ^parent_id, "waiting"}

      assert children(parent_id) == []

      assert %{status: :queued, resume: %{payload: {:delegated, outcomes}}} = facts(parent_id)
      assert outcomes == %{}
      assert_enqueued(worker: Worker, args: %{"run_id" => parent_id}, state: "available")

      expect_reply("Later, then.")
      assert :ok = perform!(parent_id)
      assert_received {:read, [{"tu_1", refusal, true}]}
      assert refusal =~ "already at work on this subject"
      assert %AgentRun{status: "completed"} = Runs.get(parent_id)
    end
  end

  describe "cycles" do
    @describetag runtime: false

    setup do
      start_supervised!(
        {Clementine,
         repo: TestRepo, agents: [Ping, Pong, Narcissus], host: Clementine.RunsCase.Host}
      )

      :ok
    end

    test "an agent may not ask itself, subject or not" do
      {:ok, parent} = Runs.start(Narcissus, "Look inward")
      expect_turn(calls([ask("tu_1", "test_narcissus", "Again.")]))
      assert :ok = perform!(parent)

      assert children(parent.id) == []
      assert %{status: :queued} = facts(parent.id)

      expect_reply("Alone, then.")
      assert :ok = perform!(parent.id)
      assert_received {:read, [{"tu_1", refusal, true}]}
      assert refusal =~ ~s(Cannot ask "test_narcissus": it is among the agents)
    end

    test "nor an agent whose request led here: two agents cannot ask each other in a circle" do
      {:ok, ping} = Runs.start(Ping, "Serve")
      expect_turn(calls([ask("tu_1", "test_pong", "Return it.")]))
      assert :ok = perform!(ping)
      [pong] = children(ping.id)

      # Pong asks Ping back: Ping is above it, so nothing starts.
      expect_turn(calls([ask("tu_2", "test_ping", "Serve again.")]))
      assert :ok = perform!(pong)
      assert children(pong.id) == []

      expect_reply("Out.")
      assert :ok = perform!(pong.id)
      assert_received {:read, [{"tu_2", refusal, true}]}
      assert refusal =~ ~s(Cannot ask "test_ping": it is among the agents)
    end
  end

  describe "a thread's erasure" do
    @describetag runtime: false

    setup do
      start_supervised!(
        {Clementine,
         repo: TestRepo,
         agents: [Concierge, Echo, Clementine.Thread],
         host: Clementine.RunsCase.Host}
      )

      :ok
    end

    test "cancelling the loop ends the turn after its delegates, and the loop after the " <>
           "turn, so the thread purges from the loop's end" do
      subject = {"conversation", "erase-me"}

      {:ok, loop} =
        Runs.start_loop(Clementine.Thread, %{"agent" => "test_concierge"}, subject: subject)

      assert {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "Plan my trip", "id" => "m1"})
      assert :ok = perform_job(Clementine.Runs.StepWorker, %{"run_id" => loop.id})
      assert {:ok, turn} = Runs.child(loop.id, {:turn, "m1"})

      # The turn asks a delegate, which starts running.
      expect_turn(calls([ask("tu_1", "test_echo", "Find flights.")]))
      assert :ok = perform!(turn)
      [echo] = children(turn.id)
      {:ok, lease} = Protocol.claim(Lifecycle, echo.id, executor: "test")

      # The user deletes the conversation: cancel the loop. Its step
      # cancels the turn, which flags its running delegate and waits.
      assert {:ok, :flagged} = Runs.cancel(loop.id)
      assert :ok = perform_job(Clementine.Runs.StepWorker, %{"run_id" => loop.id})

      assert %{status: :waiting, cancel: %{}} = facts(turn.id)
      assert %{status: :running, cancel: %{}} = facts(echo.id)
      assert %AgentRun{status: status} = Runs.get(loop.id)
      assert status in ["waiting", "queued"]
      assert {:error, :active} = Runs.purge(subject)

      # Bottom up: the delegate ends, the turn resumes and ends cancelled,
      # and the loop's next step finishes it.
      {:ok, _} = Protocol.finish(lease, Result.cancelled(%{"code" => "parent_cancelled"}))
      assert :ok = perform!(turn.id)
      assert %AgentRun{status: "cancelled"} = Runs.get(turn.id)
      assert :ok = perform_job(Clementine.Runs.StepWorker, %{"run_id" => loop.id})

      loop_id = loop.id

      assert_received {:run_committed, %AgentRun{id: ^loop_id, status: "cancelled"}, _result,
                       false}

      assert {:ok, 3} = Runs.purge(subject)
    end
  end

  describe "a batch holding a gated call and a delegate call" do
    test "waits for the decision first, then starts the child, and the model reads both" do
      parent_id =
        park!([
          {"tu_1", "send_note", %{"text" => "kickoff"}},
          ask("tu_2", "test_echo", "Summarize.")
        ])

      assert %{suspension: %{reason: {:approval, _}}} = facts(parent_id)
      assert children(parent_id) == []

      assert :ok = Runs.resume(parent_id, {:approved, %{by: "u-1"}})
      assert :ok = perform!(parent_id)

      assert [echo] = children(parent_id)
      assert %{suspension: %{reason: {:external, {:delegation, [echo_id]}}}} = facts(parent_id)
      assert echo_id == echo.id

      expect_turn(text_events("Summary."))
      assert :ok = perform!(echo)

      expect_reply("Sent, and summarized.")
      assert :ok = perform!(parent_id)

      assert_received {:read, [{"tu_1", "Sent kickoff.", false}, {"tu_2", "Summary.", false}]}
    end
  end

  describe "a parent waiting on its children" do
    test "takes no decision: resume/2 refuses it" do
      parent_id = park!([ask("tu_1", "test_echo", "Say it.")])
      assert {:error, :delegating} = Runs.resume(parent_id, {:approved, %{by: "u-1"}})
      assert %AgentRun{status: "waiting"} = Runs.get(parent_id)
    end

    test "cancelled, is flagged and cancels its live children in the same transaction; it " <>
           "ends after the last of them, so its subject purges from its end" do
      parent_id =
        park!(
          [ask("tu_1", "test_echo", "Say it."), ask("tu_2", "test_lookup", "Look.")],
          subject: {"ticket", "erase-me"}
        )

      [echo, lookup] = children(parent_id)
      {:ok, lease} = Protocol.claim(Lifecycle, lookup.id, executor: "test")

      assert {:ok, :flagged} = Runs.cancel(parent_id)

      reason = %{"code" => "parent_cancelled", "parent_id" => parent_id}
      assert %{status: :waiting, cancel: %{reason: %{"code" => "cancelled"}}} = facts(parent_id)
      assert %{status: :cancelled, cancel: %{reason: ^reason}} = facts(echo.id)
      assert %{status: :running, cancel: %{reason: ^reason}} = facts(lookup.id)

      # A child still runs: nothing on the subject may be erased yet.
      assert {:error, :active} = Runs.purge({"ticket", "erase-me"})
      refute_received {:run_committed, %AgentRun{id: ^parent_id}, _result, _in_transaction?}

      # The running child honors its flag, and its end resumes the parent,
      # whose next execution honors its own before anything else.
      {:ok, _} = Protocol.finish(lease, Result.cancelled(reason))
      assert %{status: :queued, resume: %{payload: {:delegated, _}}} = facts(parent_id)
      assert :ok = perform!(parent_id)

      assert_received {:run_committed, %AgentRun{id: ^parent_id, status: "cancelled"},
                       %Result.Cancelled{reason: %{"code" => "cancelled"}}, false}

      # The recipe: purge once the run that was cancelled has ended.
      assert {:ok, 3} = Runs.purge({"ticket", "erase-me"})
    end

    test "cancelled with only queued children, ends with them" do
      parent_id = park!([ask("tu_1", "test_echo", "Say it.")])
      [echo] = children(parent_id)

      assert {:ok, :flagged} = Runs.cancel(parent_id)
      assert %AgentRun{status: "cancelled"} = Runs.get(echo.id)
      assert %{status: :queued, cancel: %{}} = facts(parent_id)

      assert :ok = perform!(parent_id)
      assert %AgentRun{status: "cancelled"} = Runs.get(parent_id)
    end

    test "flagged before it parks starts no child, and ends cancelled" do
      {:ok, parent} = Runs.start(Planner, "Plan")

      Mox.expect(Clementine.LLM.MockClient, :stream, fn _model,
                                                        _system,
                                                        _messages,
                                                        _tools,
                                                        _opts ->
        assert {:ok, :flagged} = Runs.cancel(parent.id)
        calls([ask("tu_1", "test_echo", "Say it.")])
      end)

      assert :ok = perform!(parent)
      assert %AgentRun{status: "cancelled"} = Runs.get(parent.id)
      assert children(parent.id) == []
    end

    test "flagged after its batch was checked but before the park, starts no child: the " <>
           "park resolves as a cancel" do
      {:ok, parent} = Runs.start(Planner, "Plan")
      {:ok, lease} = Protocol.claim(Lifecycle, parent.id, executor: "test")
      assert {:ok, :flagged} = Runs.cancel(parent.id)

      assert {:cancelled, %{status: :cancelled}} =
               Protocol.suspend(lease, delegation_request("tu_1", "test_echo"))

      assert children(parent.id) == []
    end

    test "that moved on as its write waited answers stale, and leaves an enclosing unit usable" do
      parent_id = park!([ask("tu_1", "test_echo", "Say it.")])
      %{epoch: epoch} = facts(parent_id)
      [echo] = children(parent_id)

      # The last child ends, and the parent resumes, between a canceller's
      # read (waiting) and its write.
      expect_turn(text_events("Said."))
      assert :ok = perform!(echo)
      assert %AgentRun{status: "queued"} = Runs.get(parent_id)

      flag = %Clementine.Lifecycle.Transition{
        op: :cancel_request,
        run_ref: parent_id,
        expect: %{status: :waiting, epoch: epoch},
        set: %{cancel: %{reason: %{"code" => "cancelled"}, requested_at: :now}}
      }

      # As a loop's step cancelling its turn would: inside its own unit,
      # which goes on after the stale answer.
      assert {:ok, :went_on} =
               TestRepo.transaction(fn ->
                 assert {:error, :stale} = Lifecycle.apply(flag, nil)
                 assert %AgentRun{status: "queued"} = TestRepo.get(AgentRun, parent_id)
                 :went_on
               end)

      assert {:ok, :finished} = Runs.cancel(parent_id)
    end

    test "resumes with a cancelled result for a child cancelled on its own" do
      parent_id =
        park!([ask("tu_1", "test_echo", "Say it."), ask("tu_2", "test_lookup", "Look.")])

      [echo, lookup] = children(parent_id)

      assert {:ok, :finished} = Runs.cancel(echo.id)
      assert %AgentRun{status: "waiting"} = Runs.get(parent_id)

      expect_turn(text_events("Looked."))
      assert :ok = perform!(lookup)

      expect_reply("Half done.")
      assert :ok = perform!(parent_id)

      assert_received {:read,
                       [
                         {"tu_1", "The test_echo run was cancelled before it answered.", true},
                         {"tu_2", "Looked.", false}
                       ]}
    end
  end

  describe "the reaper" do
    test "interrupting a child whose node died resumes the parent with the interrupt" do
      parent_id = park!([ask("tu_1", "test_echo", "Say it.")])
      [echo] = children(parent_id)
      dead_executor!(echo)

      assert %{interrupted: 1} = Reaper.sweep()
      assert %AgentRun{status: "interrupted"} = Runs.get(echo.id)

      assert %{status: :queued, resume: %{payload: {:delegated, %{"tu_1" => outcome}}}} =
               facts(parent_id)

      assert %{"status" => "interrupted", "is_error" => true, "content" => content} = outcome
      assert content =~ "The test_echo run was interrupted ("
    end

    test "interrupting a child never claimed resumes the parent too" do
      parent_id = park!([ask("tu_1", "test_echo", "Say it.")])
      [echo] = children(parent_id)
      backdate!(echo, 16, job_state: "executing")

      assert %{interrupted: 1} = Reaper.sweep()

      assert %{resume: %{payload: {:delegated, %{"tu_1" => %{"status" => "interrupted"}}}}} =
               facts(parent_id)

      expect_reply("It never started.")
      assert :ok = perform!(parent_id)
      assert_received {:read, [{"tu_1", content, true}]}
      assert content =~ "claim_timeout"
    end

    test "resumes a waiting parent whose children ended without its hearing, once the " <>
           "last end is a sweep interval old" do
      parent_id = park!([ask("tu_1", "test_echo", "Say it.")])
      [echo] = children(parent_id)

      # The child's end written by code that dropped it for a rollout parent.
      {1, _} =
        TestRepo.update_all(from(r in AgentRun, where: r.id == ^echo.id),
          set: [status: "completed", result: %{"output" => "Said."}, finished_at: db_now!()]
        )

      # Too fresh: the paths that resume at once get their turn first.
      assert %{resumed: 0} = Reaper.sweep()
      assert %AgentRun{status: "waiting"} = Runs.get(parent_id)

      age!(parent_id, :queued_at, 2)
      age!(echo.id, :finished_at, 2)
      assert %{resumed: 1, interrupted: 0} = Reaper.sweep()

      assert %{status: :queued, resume: %{payload: {:delegated, %{"tu_1" => outcome}}}} =
               facts(parent_id)

      assert outcome["content"] == "Said."
      assert %{resumed: 0} = Reaper.sweep()
    end

    test "waits a sweep interval before resuming a park that started no child, so the " <>
           "worker's resume after after_execution/2 comes first" do
      {:ok, _busy} = Runs.start(Echo, "Already busy", subject: {"ticket", "t-grace"})
      {:ok, parent} = Runs.start(Planner, "Plan", subject: {"ticket", "t-grace"})

      # The park, by the runner, without the worker that would resume it
      # once the execution is over.
      {:ok, lease} = Protocol.claim(Lifecycle, parent.id, executor: "test")
      assert {:ok, _token} = Protocol.suspend(lease, delegation_request("tu_1", "test_echo"))

      assert %{status: :waiting, suspension: %{reason: {:external, {:delegation, []}}}} =
               facts(parent.id)

      assert %{resumed: 0} = Reaper.sweep()
      assert %AgentRun{status: "waiting"} = Runs.get(parent.id)

      age!(parent.id, :queued_at, 2)
      assert %{resumed: 1} = Reaper.sweep()
      assert %{status: :queued, resume: %{payload: {:delegated, %{}}}} = facts(parent.id)
    end

    test "leaves the waiting parent alone" do
      parent_id = park!([ask("tu_1", "test_echo", "Say it.")])
      assert %{interrupted: 0} = Reaper.sweep()
      assert %AgentRun{status: "waiting"} = Runs.get(parent_id)
    end
  end

  describe "a resumed parent" do
    test "drained before its effects requeues, and resumes again with the same answers" do
      parent_id = park!([ask("tu_1", "test_echo", "Say it.")])
      [echo] = children(parent_id)
      expect_turn(text_events("Said."))
      assert :ok = perform!(echo)

      # The deploy: the resumed parent is draining as the model answers.
      Mox.expect(Clementine.LLM.MockClient, :stream, fn _model,
                                                        _system,
                                                        _messages,
                                                        _tools,
                                                        _opts ->
        send(self(), {:clementine, :drain})
        calls([ask("tu_9", "test_echo", "Again.")])
      end)

      assert :ok = perform!(parent_id)

      # Requeued, not ended: the suspension and the answers stay for the next claim.
      assert %{status: :queued, epoch: 2, resume: %{payload: {:delegated, _}}, suspension: %{}} =
               facts(parent_id)

      assert [_echo] = children(parent_id)

      # The next node resumes it from the same checkpoint.
      expect_reply("Said it.")
      assert :ok = perform!(parent_id)
      assert_received {:read, [{"tu_1", "Said.", false}]}
      assert %AgentRun{status: "completed", lease_epoch: 3} = Runs.get(parent_id)
    end
  end

  # The suspension body the engine parks on for one delegate call.
  defp delegation_request(tool_use_id, agent) do
    call = %Clementine.LLM.Message.Content.ToolUse{
      id: tool_use_id,
      name: "delegate",
      input: %{"agent" => agent, "prompt" => "Say it."}
    }

    %Clementine.Suspension.Request{
      reason: {:external, {:delegation, []}},
      pending: %Pending.Delegation{
        children: %{tool_use_id => %{agent: agent, prompt: "Say it.", run_id: nil}}
      },
      messages: [
        Clementine.LLM.Message.UserMessage.new("Plan"),
        %Clementine.LLM.Message.AssistantMessage{content: [call]}
      ]
    }
  end

  # Moves one of a run's timestamps `minutes` into the past.
  defp age!(run_id, column, minutes) do
    then = DateTime.add(db_now!(), -minutes, :minute)

    {1, _} =
      TestRepo.update_all(from(r in AgentRun, where: r.id == ^run_id), set: [{column, then}])

    :ok
  end

  # A claimed run whose node died: running, its heartbeat two hours old,
  # its job gone with the node.
  defp dead_executor!(run) do
    long_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

    {1, _} =
      TestRepo.update_all(from(r in AgentRun, where: r.id == ^run.id),
        set: [
          status: "running",
          lease_epoch: 1,
          executor_id: "oban:1:dead@node",
          heartbeat_at: long_ago,
          deadline: DateTime.add(DateTime.utc_now(), 1, :hour)
        ]
      )

    {1, _} =
      TestRepo.update_all(from(j in Oban.Job, where: j.id == ^run.oban_job_id),
        set: [state: "executing", attempted_at: long_ago]
      )

    :ok
  end
end
