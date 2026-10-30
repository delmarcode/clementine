defmodule Clementine.DelegationExecutionTest do
  @moduledoc """
  Delegation in the engine, through the real runner on the in-memory
  lifecycle, which starts no children: the `delegate` engine tool offered
  beside the agent's tools, the park on a batch's delegate calls with its
  siblings' results, the refusals the engine makes at the call, a batch
  holding a gated call (the approval first, then the delegation), the
  resume that settles each call with its child's outcome, a drain or a
  cancel that lands before the park, malformed resumes, and the trace.
  """

  use ExUnit.Case, async: true

  import Mox

  alias Clementine.{Checkpoint, Delegation, Error, Pending, Result, Rollout, Run, Runner, Tool}
  alias Clementine.{ToolResult, Trace}
  alias Clementine.LLM.Message.{Content, ToolResultMessage}
  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.Test.MemoryLifecycle
  alias Clementine.Test.Tools.{Echo, GatedDeploy}
  alias Clementine.Trace.Entry

  setup :verify_on_exit!

  setup do
    {:ok, store: MemoryLifecycle.start_store(), ref: make_ref()}
  end

  defmodule Researcher do
    @moduledoc false
    use Clementine.Agent,
      key: "researcher",
      description: "Finds and cites facts.",
      model: :claude_sonnet,
      instructions: "Research."
  end

  defmodule Writer do
    @moduledoc false
    use Clementine.Agent, key: "writer", model: :claude_sonnet, instructions: "Write."
  end

  defmodule Chatter do
    @moduledoc false
    use Clementine.Agent, key: "chatter", turn: true, model: :claude_sonnet, instructions: "Chat."

    @impl true
    def history(_run), do: []
  end

  defmodule Notes do
    @moduledoc false
    use Clementine.Skill, name: "notes", description: "Take notes.", tools: []

    # The body runs between the engine calls of its batch, in a task: it
    # delivers a signal to the run's process (`run`) after the batch was
    # acted on.
    @impl true
    def body(%{signal: signal, run: run}) do
      send(run, signal)
      "Keep notes short."
    end
  end

  @instructions "Plan the work."

  defp agent(opts \\ []) do
    Clementine.Agent.new(
      Keyword.merge(
        [
          model: :claude_sonnet,
          instructions: @instructions,
          tools: [Echo, GatedDeploy],
          delegates: [Researcher, Writer, Chatter]
        ],
        opts
      )
    )
  end

  defp build_run(ref, agent_opts \\ [], rollout_opts \\ []) do
    rollout = Rollout.new(Keyword.merge([agent: agent(agent_opts), input: "go"], rollout_opts))
    Run.new(ref: ref, rollout: rollout)
  end

  defp execute(run, store) do
    Runner.execute(run,
      lifecycle: MemoryLifecycle,
      ctx: store,
      executor_id: "test:delegation",
      heartbeat: false,
      # The runtime that starts the children says so; this lifecycle
      # stands in for it.
      delegation: true
    )
  end

  defp expect_gather(events) do
    test = self()

    expect(Clementine.LLM.MockClient, :stream, fn _model, system, messages, tools, _opts ->
      send(test, {:gather, system, tools, messages})
      events
    end)
  end

  defp text_events(text) do
    [
      {:text_delta, text},
      {:message_delta, %{"stop_reason" => "end_turn"},
       %{"input_tokens" => 7, "output_tokens" => 3}}
    ]
  end

  defp tool_events(calls) do
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
         %{"input_tokens" => 5, "output_tokens" => 2}}
      ]
  end

  defp ask(id, agent, prompt), do: {id, "delegate", %{"agent" => agent, "prompt" => prompt}}

  defp tool_results(messages) do
    for %ToolResultMessage{content: blocks} <- messages,
        %Content.ToolResult{} = block <- blocks,
        do: {block.tool_use_id, block.content, block.is_error}
  end

  defp pending!(store, ref) do
    %Facts{status: :waiting, suspension: %{reason: reason, checkpoint: checkpoint}} =
      MemoryLifecycle.facts!(store, ref)

    {reason, checkpoint}
  end

  defp completed(content),
    do: %{"status" => "completed", "content" => content, "is_error" => false}

  describe "the delegate tool" do
    test "is offered beside the agent's tools, its agent an enum of the delegates' keys, " <>
           "each listed with its description" do
      expect_gather(text_events("Nothing to ask."))

      assert {:ok, %Result.Completed{}} =
               Rollout.execute(Rollout.new(agent: agent(), input: "go"), delegation: true)

      assert_received {:gather, @instructions, tools, _messages}
      assert Enum.map(tools, &Tool.to_schema(&1).name) == ["echo", "gated_deploy", "delegate"]

      %{input_schema: schema, description: description} = Tool.to_schema(List.last(tools))
      assert schema["properties"]["agent"]["enum"] == ["researcher", "writer", "chatter"]
      assert schema["required"] |> Enum.sort() == ["agent", "prompt"]

      assert description =~
               "Agents:\n- researcher: Finds and cites facts.\n- writer\n- chatter"
    end

    test "is not offered off a runtime that starts children: the run goes on without it" do
      expect_gather(text_events("On my own, then."))

      assert {:ok, %Result.Completed{output: "On my own, then."}} =
               Clementine.run(agent(), "go")

      assert_received {:gather, _, tools, _}
      assert Enum.map(tools, &Tool.to_schema(&1).name) == ["echo", "gated_deploy"]
    end

    test "is not offered by an agent with no delegates" do
      expect_gather(text_events("Hi."))

      assert {:ok, %Result.Completed{}} =
               Rollout.execute(Rollout.new(agent: agent(delegates: []), input: "go"))

      assert_received {:gather, _, tools, _}
      assert Enum.map(tools, &Tool.to_schema(&1).name) == ["echo", "gated_deploy"]
    end
  end

  describe "a batch of delegate calls" do
    test "parks the run once, after the batch's other calls, with every child and the " <>
           "siblings' results in the checkpoint",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          ask("tu_1", "researcher", "Find the facts."),
          {"tu_2", "echo", %{"message" => "noted"}},
          ask("tu_3", "writer", "Draft it.")
        ])
      )

      assert {:suspended, token} = execute(build_run(ref), store)
      assert token.reason_type == :external

      assert {{:external, {:delegation, []}}, %Checkpoint{version: 2, pending: pending}} =
               pending!(store, ref)

      assert %Pending.Delegation{
               children: %{
                 "tu_1" => %{agent: "researcher", prompt: "Find the facts.", run_id: nil},
                 "tu_3" => %{agent: "writer", prompt: "Draft it.", run_id: nil}
               },
               completed_results: %{
                 "tu_2" => %ToolResult{content: "Echo: noted", is_error: false}
               }
             } = pending

      # The sibling ran, and is on the record; the delegate calls settle later.
      names =
        for %Entry{kind: :tool_call, payload: p} <- MemoryLifecycle.trace(store, ref),
            do: p["name"]

      assert names == ["echo"]
    end

    test "resumes with every child's outcome, settling each call, and the model reads them " <>
           "in the order it called them",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          ask("tu_1", "researcher", "Find the facts."),
          {"tu_2", "echo", %{"message" => "noted"}},
          ask("tu_3", "writer", "Draft it.")
        ])
      )

      run = build_run(ref)
      assert {:suspended, token} = execute(run, store)

      outcomes = %{
        "tu_1" => completed("The facts."),
        "tu_3" => Delegation.outcome("writer", Result.cancelled(%{"code" => "cancelled"}))
      }

      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:delegated, outcomes}, store)
      expect_gather(text_events("Done."))

      assert {:finished, %Facts{status: :completed, epoch: 2}} = execute(run, store)

      assert_received {:gather, _, _, _}
      assert_received {:gather, _, _, messages}

      assert tool_results(messages) == [
               {"tu_1", "The facts.", false},
               {"tu_2", "Echo: noted", false},
               {"tu_3", "The writer run was cancelled before it answered.", true}
             ]

      # The resumed execution records each child, then its call.
      resumed =
        for %Entry{epoch: 2, kind: kind, payload: payload} <- MemoryLifecycle.trace(store, ref),
            kind in [:delegate, :tool_call],
            do: {kind, payload["tool_use_id"], payload["agent"] || payload["name"]}

      assert resumed == [
               {:delegate, "tu_1", "researcher"},
               {:tool_call, "tu_1", "delegate"},
               {:delegate, "tu_3", "writer"},
               {:tool_call, "tu_3", "delegate"}
             ]

      assert %Entry{payload: %{"status" => "cancelled", "iteration" => 1}} =
               store
               |> MemoryLifecycle.trace(ref)
               |> Enum.find(&(&1.kind == :delegate and &1.payload["agent"] == "writer"))
    end
  end

  describe "a delegate call the engine refuses" do
    test "settles at once as an error the model reads, and parks nothing: a turn agent, " <>
           "an agent not offered, a blank prompt",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          ask("tu_1", "chatter", "Talk to them."),
          ask("tu_2", "Elixir.System", "Halt."),
          ask("tu_3", "writer", "  ")
        ])
      )

      expect_gather(text_events("Understood."))

      assert {:finished, %Facts{status: :completed}} = execute(build_run(ref), store)

      assert_received {:gather, _, _, _}
      assert_received {:gather, _, _, messages}

      assert [{"tu_1", turn, true}, {"tu_2", unknown, true}, {"tu_3", blank, true}] =
               tool_results(messages)

      assert turn =~ "it takes turns on a conversation"

      assert unknown ==
               ~s(There is no agent "Elixir.System" to ask. The agents are: researcher, writer, chatter.)

      assert blank =~ "delegate needs a prompt"

      # Each is on the record as a call that answered with an error.
      assert [true, true, true] =
               for(
                 %Entry{kind: :tool_call, payload: p} <- MemoryLifecycle.trace(store, ref),
                 do: p["is_error"]
               )
    end

    test "beside one it accepts leaves only the accepted one waiting",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([ask("tu_1", "chatter", "Talk."), ask("tu_2", "researcher", "Look.")])
      )

      assert {:suspended, _token} = execute(build_run(ref), store)

      assert {_reason, %Checkpoint{pending: %Pending.Delegation{children: children} = pending}} =
               pending!(store, ref)

      assert Map.keys(children) == ["tu_2"]
      assert %{"tu_1" => %ToolResult{is_error: true}} = pending.completed_results
    end
  end

  describe "a batch holding a gated call and a delegate call" do
    test "parks for the approval first, then for the children, and the model reads every " <>
           "result together",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          ask("tu_1", "researcher", "Look."),
          {"tu_2", "gated_deploy", %{"env" => "prod"}}
        ])
      )

      run = build_run(ref, [], context: %{notify: self()})
      assert {:suspended, approval} = execute(run, store)
      assert approval.reason_type == :approval

      assert {{:approval, _},
              %Checkpoint{pending: %Pending.ToolApproval{tool_use_id: "tu_2"} = gated}} =
               pending!(store, ref)

      # The delegate call waits for its own park: nothing settled it yet.
      refute Map.has_key?(gated.completed_results, "tu_1")

      {:ok, _} = Protocol.resume(MemoryLifecycle, approval, {:approved, %{by: "u1"}}, store)
      assert {:suspended, delegation} = execute(run, store)
      assert_received {:deployed, %{env: "prod"}}
      assert delegation.reason_type == :external

      assert {{:external, {:delegation, []}},
              %Checkpoint{pending: %Pending.Delegation{children: %{"tu_1" => _}} = waiting}} =
               pending!(store, ref)

      assert %{"tu_2" => %ToolResult{content: "deployed prod"}} = waiting.completed_results

      {:ok, _} =
        Protocol.resume(
          MemoryLifecycle,
          delegation,
          {:delegated, %{"tu_1" => completed("Looked.")}},
          store
        )

      expect_gather(text_events("All done."))
      assert {:finished, %Facts{status: :completed, epoch: 3}} = execute(run, store)

      assert_received {:gather, _, _, _}
      assert_received {:gather, _, _, messages}

      assert tool_results(messages) == [
               {"tu_1", "Looked.", false},
               {"tu_2", "deployed prod", false}
             ]
    end
  end

  describe "the park" do
    test "honors a drain that lands after the batch was acted on: nothing parks, and the " <>
           "run requeues",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "use_skill", %{"name" => "notes"}},
          ask("tu_2", "researcher", "Look.")
        ])
      )

      run =
        build_run(ref, [skills: [Notes]], context: %{signal: {:clementine, :drain}, run: self()})

      assert {:finished, %Facts{status: :queued, suspension: nil}} = execute(run, store)
    end

    test "honors a cancel flagged before it: the run ends cancelled, waiting on nothing",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        assert {:ok, :flagged} =
                 Protocol.request_cancel(MemoryLifecycle, ref, %{"code" => "cancelled"}, store)

        tool_events([ask("tu_1", "researcher", "Look.")])
      end)

      assert {:finished, %Facts{status: :cancelled, suspension: nil}} =
               execute(build_run(ref), store)
    end
  end

  describe "a resume" do
    setup %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([ask("tu_1", "researcher", "Look."), ask("tu_2", "writer", "Write.")])
      )

      run = build_run(ref)
      {:suspended, token} = execute(run, store)
      {:ok, run: run, token: token}
    end

    test "missing a child's outcome fails the run, never a crash",
         %{store: store, ref: ref, run: run, token: token} do
      {:ok, _} =
        Protocol.resume(MemoryLifecycle, token, {:delegated, %{"tu_1" => completed("x")}}, store)

      assert {:finished, %Facts{status: :failed, error: %Error{code: :invalid_resume_payload}}} =
               execute(run, store)

      assert {:delegated, _} = MemoryLifecycle.facts!(store, ref).resume.payload
    end

    test "with a decision instead of outcomes fails the run as an invalid payload",
         %{store: store, run: run, token: token} do
      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:approved, %{}}, store)

      assert {:finished, %Facts{status: :failed, error: %Error{code: :invalid_resume_payload}}} =
               execute(run, store)
    end

    test "whose checkpoint lost the calls it waits on fails as an incompatible checkpoint",
         %{store: store, ref: ref, run: run, token: token} do
      facts = MemoryLifecycle.facts!(store, ref)
      %{checkpoint: checkpoint} = suspension = facts.suspension
      checkpoint = %{checkpoint | messages: Enum.drop(checkpoint.messages, -1)}
      MemoryLifecycle.seed(store, %{facts | suspension: %{suspension | checkpoint: checkpoint}})

      outcomes = %{"tu_1" => completed("a"), "tu_2" => completed("b")}
      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:delegated, outcomes}, store)

      assert {:finished, %Facts{status: :failed, error: %Error{code: :incompatible_checkpoint}}} =
               execute(run, store)
    end
  end

  describe "the checkpoint" do
    test "carries a pending delegation through its JSON encoding" do
      pending = %Pending.Delegation{
        children: %{
          "tu_1" => %{agent: "researcher", prompt: "Look.", run_id: "c-1"},
          "tu_2" => %{agent: "writer", prompt: "Write.", run_id: nil}
        },
        completed_results: %{"tu_2" => %ToolResult{content: "Refused.", is_error: true}}
      }

      checkpoint = %Checkpoint{rollout_id: "r", pending: pending}

      assert {:ok, %Checkpoint{version: 2, pending: ^pending}} =
               checkpoint
               |> Checkpoint.encode()
               |> Jason.encode!()
               |> Jason.decode!()
               |> Checkpoint.decode()
    end
  end

  describe "the agent" do
    test "refuses delegates that are not a list of modules, or list one twice" do
      assert_raise ArgumentError, ~r/takes a list/, fn -> agent(delegates: Researcher) end
      assert_raise ArgumentError, ~r/agent modules/, fn -> agent(delegates: ["researcher"]) end
      assert_raise ArgumentError, ~r/more than once/, fn -> agent(delegates: [Writer, Writer]) end
    end

    test "set directly to something a run cannot offer fails the run before it executes",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      bad = %{agent(delegates: []) | delegates: [Researcher, String]}
      run = Run.new(ref: ref, rollout: Rollout.new(agent: bad, input: "go"))

      assert {:finished, %Facts{status: :failed, error: %Error{code: :invalid_delegates} = error}} =
               execute(run, store)

      assert error.message =~ "agent modules"

      # It is on the record as an execution that offered no delegate.
      assert %Entry{payload: %{"delegates" => [], "tools" => ["echo", "gated_deploy"]}} =
               store |> MemoryLifecycle.trace(ref) |> Enum.find(&(&1.kind == :execution))
    end

    test "refuses a tool named delegate beside delegates" do
      defmodule Shadow do
        @moduledoc false
        use Clementine.Tool, name: "delegate", description: "Shadows.", parameters: []
        @impl true
        def run(_args, _context), do: {:ok, "no"}
      end

      assert_raise ArgumentError, ~r/is named "delegate"/, fn -> agent(tools: [Shadow]) end
      assert %Clementine.Agent{} = agent(tools: [Shadow], delegates: [])
    end

    test "fingerprints the delegates by key and description, and records their keys on the " <>
           "execution entry",
         %{store: store, ref: ref} do
      base = Trace.fingerprint(:claude_sonnet, "x", [Echo])
      assert Trace.fingerprint(:claude_sonnet, "x", [Echo], delegates: []) == base
      keyed = Trace.fingerprint(:claude_sonnet, "x", [Echo], delegates: ["writer"])
      refute keyed == base

      # A delegate with no description fingerprints by its key alone; one
      # with a description, by both.
      assert Trace.fingerprint(:claude_sonnet, "x", [Echo], delegates: [{"writer", nil}]) == keyed

      refute Trace.fingerprint(:claude_sonnet, "x", [Echo], delegates: [{"writer", "Writes."}]) ==
               keyed

      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(text_events("Hi."))
      assert {:finished, _} = execute(build_run(ref), store)

      assert %Entry{
               payload: %{"delegates" => ["researcher", "writer", "chatter"], "tools" => tools}
             } =
               store |> MemoryLifecycle.trace(ref) |> Enum.find(&(&1.kind == :execution))

      assert List.last(tools) == "delegate"
    end
  end
end
