defmodule Clementine.Runs.TraceTest do
  @moduledoc """
  The trace on the durable runtime: `Runs.trace/1` reads what the runner
  wrote to `agent_run_trace`, committed with the run's end or park (so a
  projection already sees it), continued by a resume, cut at the last
  boundary for a reaped run, fenced on the epoch, and erased by
  `Runs.purge/1`. A cancelled run keeps the usage its stream reported
  (C13), and a loop's inbox holds a child's output and usage, never its
  transcript (decision 9).
  """

  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]

  alias Clementine.{InterruptReason, Result, Usage}
  alias Clementine.Lifecycle.Ecto.Codec
  alias Clementine.Lifecycle.Protocol
  alias Clementine.Runs.{Lifecycle, StepWorker}
  alias Clementine.Thread
  alias Clementine.Trace.Entry

  defmodule Host do
    @moduledoc false
    # Reads the run's trace from inside the end's own transaction.
    @behaviour Clementine.Host

    @impl true
    def run_finished(run, result) do
      if pid = Process.whereis(:clementine_runs_test),
        do: send(pid, {:finished_with_trace, run.id, result, Clementine.Runs.trace(run.id)})

      :ok
    end
  end

  @moduletag runtime: false
  @subject {"conversation", "c-1"}

  setup do
    Process.register(self(), :clementine_runs_test)

    start_supervised!(
      {Clementine, repo: TestRepo, agents: [Echo, Lookup, Approval, Chat, Thread], host: Host}
    )

    :ok
  end

  defp kinds(entries), do: Enum.map(entries, &{&1.epoch, &1.seq, &1.kind})

  defp trace_rows(run_id) do
    TestRepo.one(
      from(t in "agent_run_trace",
        where: t.run_id == type(^run_id, Ecto.UUID),
        select: count(t.id)
      )
    )
  end

  test "a completed run's whole trace commits with its end, where the projection sees it" do
    {:ok, run} = Runs.start(Lookup, "Find the forecast", subject: {"ticket", "t-1"})
    expect_turn(tool_events("tu_1", "lookup", %{"query" => "forecast"}))
    expect_turn(text_events("Sunny."))

    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert [execution, _call, tool_call, _final] = trace = Runs.trace(run.id)

    assert kinds(trace) == [
             {1, 1, :execution},
             {1, 2, :model_call},
             {1, 3, :tool_call},
             {1, 4, :model_call}
           ]

    assert Enum.all?(trace, &(&1.run_id == run.id and match?(%DateTime{}, &1.at)))

    assert %{
             "model" => "claude-sonnet-5",
             "tools" => ["lookup", "context"],
             "resumed" => false,
             "instructions" => "Look up nil for nil."
           } = execution.payload

    assert %{
             "name" => "lookup",
             "args" => %{"query" => "forecast"},
             "result" => "Found forecast about nil.",
             "is_error" => false
           } = tool_call.payload

    # The projection ran inside the end's transaction and already read
    # the whole trace.
    run_id = run.id
    assert_received {:finished_with_trace, ^run_id, %Result.Completed{}, ^trace}
  end

  test "a resume after an approval continues the trace under the next epoch" do
    {:ok, run} = Runs.start(Approval, "Tell the team")
    expect_turn(tool_events("tu_1", "send_note", %{"text" => "hi"}))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "waiting"} = Runs.get(run.id)

    # The park committed what the execution had recorded.
    assert kinds(Runs.trace(run.id)) == [{1, 1, :execution}, {1, 2, :model_call}]

    assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
    expect_turn(text_events("Sent."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert [_, _, resumed, approved, _final] = trace = Runs.trace(run.id)

    assert kinds(trace) == [
             {1, 1, :execution},
             {1, 2, :model_call},
             {2, 1, :execution},
             {2, 2, :tool_call},
             {2, 3, :model_call}
           ]

    assert %{"resumed" => true} = resumed.payload

    assert %{
             "name" => "send_note",
             "result" => "Sent hi.",
             "approval" => %{"verdict" => "approved", "by" => "alice"}
           } = approved.payload
  end

  test "a run reaped between iterations keeps its trace up to its last boundary" do
    {:ok, run} = Runs.start(Lookup, "Find it", subject: {"ticket", "t-2"})
    expect_turn(tool_events("tu_1", "lookup", %{"query" => "it"}))

    # The node stalls in the second model call long enough for the reaper.
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      {:ok, facts} = Lifecycle.fetch(run.id, nil)
      {:ok, _} = Protocol.interrupt(Lifecycle, facts, InterruptReason.new(:lease_expired))
      text_events("Too late.")
    end)

    # The executor's end finds the run already ended, and writes nothing.
    assert {:cancel, ":already_terminal"} = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "interrupted"} = Runs.get(run.id)

    assert kinds(Runs.trace(run.id)) ==
             [{1, 1, :execution}, {1, 2, :model_call}, {1, 3, :tool_call}]
  end

  test "the trace write is fenced on the epoch: a superseded executor writes no rows" do
    {:ok, run} = Runs.start(Echo, "Hello")
    {:ok, old} = Protocol.claim(Lifecycle, run.id, executor: "old")
    entry = %Entry{run_id: run.id, epoch: old.epoch, seq: 1, kind: :execution, payload: %{}}

    assert :ok = Protocol.record_trace(old, [entry])
    assert trace_rows(run.id) == 1

    {:ok, facts} = Lifecycle.fetch(run.id, nil)
    {:ok, _} = Protocol.requeue(Lifecycle, facts, :lease_expired)
    {:ok, _new} = Protocol.claim(Lifecycle, run.id, executor: "new")

    late = %Entry{entry | seq: 2, kind: :model_call}
    assert {:error, :lost_lease} = Protocol.record_trace(old, [late])
    assert trace_rows(run.id) == 1
  end

  test "entries a write carries again, after a commit its client never heard of, insert once" do
    {:ok, run} = Runs.start(Echo, "Hello")
    {:ok, lease} = Protocol.claim(Lifecycle, run.id, executor: "test")
    first = %Entry{run_id: run.id, epoch: lease.epoch, seq: 1, kind: :execution, payload: %{}}
    second = %Entry{first | seq: 2, kind: :model_call, payload: %{"iteration" => 1}}

    # The boundary write committed, but its caller saw an error, so the
    # entries stayed pending and the end carries them again.
    assert :ok = Protocol.record_trace(lease, [first])

    assert {:ok, _} =
             Protocol.finish(lease, Result.cancelled(%{"code" => "x"}), trace: [first, second])

    assert [{1, 1, :execution}, {1, 2, :model_call}] = kinds(Runs.trace(run.id))
  end

  test "a resumed run cancelled in its second execution keeps its first's usage on the row" do
    {:ok, run} = Runs.start(Approval, "Tell the team")
    id = run.id
    expect_turn(tool_events("tu_1", "send_note", %{"text" => "hi"}))
    assert :ok = perform_job(Worker, %{"run_id" => id})
    assert :ok = Runs.resume(id, {:approved, %{by: "alice"}})

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      assert {:ok, :flagged} = Runs.cancel(id)

      [
        {:message_start, %{"usage" => %{"input_tokens" => 42, "output_tokens" => 1}}},
        {:signal, {:clementine, :cancel, %{"code" => "cancelled"}}}
      ]
    end)

    assert :ok = perform_job(Worker, %{"run_id" => id})

    # The first execution's 10 in and 5 out, then the cut-off call's.
    assert %AgentRun{status: "cancelled", usage: %{"input_tokens" => 52, "output_tokens" => 6}} =
             Runs.get(id)
  end

  test "a cancelled run keeps the usage its stream reported, on the row and in the trace" do
    {:ok, run} = Runs.start(Echo, "Tell me a long story")
    id = run.id

    # The cancel lands mid-response, after the start event's input count.
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      assert {:ok, :flagged} = Runs.cancel(id)

      [
        {:message_start, %{"usage" => %{"input_tokens" => 42, "output_tokens" => 1}}},
        {:text_delta, "Once upon"},
        {:signal, {:clementine, :cancel, %{"code" => "cancelled"}}}
      ]
    end)

    assert :ok = perform_job(Worker, %{"run_id" => id})

    assert %AgentRun{status: "cancelled", usage: %{"input_tokens" => 42, "output_tokens" => 1}} =
             Runs.get(id)

    assert_received {:finished_with_trace, ^id,
                     %Result.Cancelled{usage: %Usage{input_tokens: 42, output_tokens: 1}}, _trace}

    assert [_execution, %Entry{kind: :model_call, payload: call}] = Runs.trace(id)

    assert %{"stop_reason" => nil, "usage" => %{"input_tokens" => 42, "output_tokens" => 1}} =
             call
  end

  test "purge erases the trace with the run" do
    {:ok, run} = Runs.start(Echo, "Hi", subject: @subject)
    expect_turn(text_events("Hello."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert trace_rows(run.id) == 2

    assert {:ok, 1} = Runs.purge(@subject)
    assert trace_rows(run.id) == 0
    assert Runs.trace(run.id) == []
  end

  describe "the columns" do
    # Text a person, the model, a tool, or the app produced, which only
    # content columns may hold.
    @canary "Kq7canary"

    test "hold no text a person, the model, a tool, or the app produced; content columns do" do
      {:ok, loop} =
        Runs.start_loop(Thread, %{"agent" => "test_chat"},
          subject: @subject,
          metadata: %{"note" => @canary}
        )

      {:ok, :appended} =
        Runs.send(loop.id, %{"prompt" => "Tell the #{@canary} team", "id" => "m1"},
          dedup_key: "<m1.#{@canary}@mail.example.com>"
        )

      # The inbox holds the message until a step drains it.
      refute_canary_in_facts()
      assert {:agent_run_inbox, :payload} in content_canaries()
      assert {:agent_run_inbox, :dedup_key} in content_canaries()

      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
      {:ok, turn} = Runs.child(loop.id, {:turn, "m1"})

      # A tool the agent does not offer, named by the model; then a gated
      # call an approver allows; then the answer.
      expect_turn(tool_events("tu_1", "zzz_#{@canary}", %{"x" => @canary}))
      expect_turn(tool_events("tu_2", "send_note", %{"text" => @canary}))
      assert :ok = perform_job(Worker, %{"run_id" => turn.id})
      assert :ok = Runs.resume(turn.id, {:approved, %{by: "#{@canary}-approver"}})
      expect_turn(text_events("Told the #{@canary} team."))
      assert :ok = perform_job(Worker, %{"run_id" => turn.id})
      assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})

      assert [_, _, unknown, _, _, approved, _] = Runs.trace(turn.id)

      # The name the model asked for reads back as it always did, from the
      # payload, and its tool_name column stays null.
      assert %{
               "name" => "zzz_" <> @canary,
               "unknown" => true,
               "is_error" => true,
               "args" => %{"x" => @canary}
             } = unknown.payload

      assert %{"name" => "send_note", "approval" => %{"by" => "Kq7canary-approver"}} =
               approved.payload

      refute_canary_in_facts()
      hits = content_canaries()

      for column <- [:input, :result, :metadata, :suspension],
          do: assert({:agent_runs, column} in hits)

      assert {:agent_run_trace, :payload} in hits
    end

    test "a model call's provider, model, alias, tokens, cost, duration, and stop reason" do
      {:ok, run} = Runs.start(Lookup, "Find the forecast", subject: {"ticket", "t-1"})
      expect_turn(tool_events("tu_1", "lookup", %{"query" => "forecast"}))
      expect_turn(text_events("Sunny."))
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      assert [execution, call, tool, final] =
               TestRepo.all(
                 from(t in "agent_run_trace",
                   where: t.run_id == type(^run.id, Ecto.UUID),
                   order_by: t.id,
                   select: map(t, ^[:kind, :payload | Clementine.Trace.columns()])
                 )
               )

      assert %{
               kind: "execution",
               provider: "anthropic",
               model: "claude-sonnet-5",
               alias: "claude_sonnet",
               agent_fingerprint: <<_::binary-size(64)>>,
               input_tokens: nil,
               tool_name: nil
             } = execution

      refute Map.has_key?(execution.payload, "model")

      for {model_call, stop_reason} <- [{call, "tool_use"}, {final, "end_turn"}] do
        assert %{
                 kind: "model_call",
                 provider: "anthropic",
                 model: "claude-sonnet-5",
                 alias: "claude_sonnet",
                 input_tokens: 10,
                 output_tokens: 5,
                 cache_read_tokens: 0,
                 cache_write_tokens: 0,
                 cost_micros: nil,
                 currency: nil,
                 duration_ms: duration,
                 stop_reason: ^stop_reason,
                 agent_fingerprint: nil
               } = model_call

        assert is_integer(duration)
        assert Map.keys(model_call.payload) == ["content"]
      end

      assert [1, 2] = [call.iteration, final.iteration]

      assert %{
               kind: "tool_call",
               iteration: 1,
               tool_use_id: "tu_1",
               tool_name: "lookup",
               is_error: false,
               killed: false,
               duration_ms: duration,
               approval_verdict: nil,
               policy_verdict: nil,
               provider: nil
             } = tool

      assert is_integer(duration)

      assert Map.keys(tool.payload) |> Enum.sort() == ["args", "result"]
    end
  end

  defp refute_canary_in_facts do
    for {table, columns} <- Clementine.Migration.fact_columns(), column <- columns do
      assert canaries(table, column) == 0, "#{table}.#{column} holds content"
    end
  end

  defp content_canaries do
    for {table, columns} <- Clementine.Migration.content_columns(),
        column <- columns,
        canaries(table, column) > 0,
        do: {table, column}
  end

  # How many rows of `table` hold the canary in `column`, as text.
  defp canaries(table, column) do
    %{rows: [[count]]} =
      TestRepo.query!(
        "SELECT count(*) FROM #{table} WHERE #{column}::text LIKE $1",
        ["%#{@canary}%"]
      )

    count
  end

  test "trace/1 of a run that does not exist, or by a malformed id, is empty" do
    assert Runs.trace(Ecto.UUID.generate()) == []
    assert Runs.trace("not-a-uuid") == []
  end

  test "a loop's inbox holds a child's output and usage, never its transcript" do
    {:ok, loop} = Runs.start_loop(Thread, %{"agent" => "test_chat"}, subject: @subject)
    {:ok, :appended} = Runs.send(loop.id, %{"prompt" => "hi", "id" => "m1"})
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    {:ok, turn} = Runs.child(loop.id, {:turn, "m1"})

    expect_turn(text_events("Hello there."))
    assert :ok = perform_job(Worker, %{"run_id" => turn.id})

    # The host's projection had the whole result, transcript included.
    turn_id = turn.id

    assert_received {:finished_with_trace, ^turn_id, %Result.Completed{messages: [_ | _]}, _trace}

    assert [%{"result" => stored}] =
             TestRepo.all(
               from(i in "agent_run_inbox",
                 where: i.run_id == type(^loop.id, Ecto.UUID) and i.kind == "completed",
                 select: i.payload
               )
             )

    assert Codec.decode_term(stored) == %Result.Completed{
             output: "Hello there.",
             usage: %Usage{input_tokens: 10, output_tokens: 5},
             messages: [],
             input_message: nil
           }

    # The thread reads it as before and moves on.
    assert :ok = perform_job(StepWorker, %{"run_id" => loop.id})
    assert {:error, :no_child} = Runs.child(loop.id, {:turn, "m1"})
  end
end
