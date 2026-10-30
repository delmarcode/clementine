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

    test "a batch whose every child is refused at the park resumes the parent at once" do
      {:ok, _busy} = Runs.start(Echo, "Already busy", subject: {"ticket", "t-5"})
      parent_id = park!([ask("tu_1", "test_echo", "Say it.")], subject: {"ticket", "t-5"})

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

    test "cancelled, cancels its live children in the same transaction: a queued one ends, " <>
           "a running one is flagged, and its end resumes nothing" do
      parent_id =
        park!([ask("tu_1", "test_echo", "Say it."), ask("tu_2", "test_lookup", "Look.")])

      [echo, lookup] = children(parent_id)
      {:ok, lease} = Protocol.claim(Lifecycle, lookup.id, executor: "test")

      assert {:ok, :finished} = Runs.cancel(parent_id)
      assert %AgentRun{status: "cancelled"} = Runs.get(parent_id)

      reason = %{"code" => "parent_ended", "parent_id" => parent_id}
      assert %{status: :cancelled, cancel: %{reason: ^reason}} = facts(echo.id)
      assert %{status: :running, cancel: %{reason: ^reason}} = facts(lookup.id)

      # The flagged child writing its end keeps it, and the parent stays ended.
      job = Runs.get(parent_id).oban_job_id
      {:ok, _} = Protocol.finish(lease, Result.completed(output: "late"))
      assert %AgentRun{status: "completed"} = Runs.get(lookup.id)
      assert %AgentRun{status: "cancelled", oban_job_id: ^job} = Runs.get(parent_id)
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
