defmodule Clementine.SkillsExecutionTest do
  @moduledoc """
  Skills in the engine, through the real runner on the in-memory
  lifecycle: the `use_skill` engine tool offered beside the agent's tools,
  a load that adds the skill's tools for the next model call, the answers
  to a repeated or unknown name, a skill's gated tool parking the run and
  the resume that rebuilds the toolset from checkpoint version 2, a
  version-1 checkpoint that still resumes, a skill the agent stopped
  offering, and what the trace records.
  """

  use ExUnit.Case, async: true

  import Mox

  alias Clementine.{Checkpoint, Error, Result, Rollout, Run, Runner, Skill, Tool, Trace}
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}
  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.Test.MemoryLifecycle
  alias Clementine.Test.Tools.{Echo, GatedDeploy, SafeEcho, SafePush, UnsafeSlow}
  alias Clementine.Trace.Entry

  setup :verify_on_exit!

  setup do
    {:ok, store: MemoryLifecycle.start_store(), ref: make_ref()}
  end

  defmodule Deploys do
    @moduledoc false
    use Clementine.Skill,
      name: "deploys",
      description: "Ship a release. Use when asked to deploy.",
      tools: [SafeEcho, GatedDeploy]

    @impl true
    def body(context), do: "Deploy only to #{context[:env] || "staging"} first."
  end

  defmodule Verdict do
    @moduledoc false
    use Clementine.Tool,
      name: "record_verdict",
      description: "Records a verdict",
      retry: :safe,
      parameters: [
        tier: [type: :string, required: true],
        summary: [type: :string, required: true]
      ]

    @impl true
    def run(args, context) do
      send(context.notify, {:verdict, args})
      {:ok, "recorded"}
    end
  end

  defmodule Triage do
    @moduledoc false
    use Clementine.Skill,
      name: "triage",
      description: "Grade a case.",
      tools: [Verdict, GatedDeploy]

    @impl true
    def body(_context), do: "Grade it."
  end

  defmodule Notes do
    @moduledoc false
    use Clementine.Skill, name: "notes", description: "Take notes.", tools: [Echo]

    @impl true
    def body(_context), do: "Keep notes short."
  end

  defmodule OtherEcho do
    @moduledoc false
    use Clementine.Tool, name: "echo", description: "Another tool named echo", parameters: []

    @impl true
    def run(_args, _context), do: {:ok, "other"}
  end

  defmodule UseSkillTool do
    @moduledoc false
    use Clementine.Tool, name: "use_skill", description: "A tool of the app's own", parameters: []

    @impl true
    def run(_args, _context), do: {:ok, "mine"}
  end

  @instructions "Help with releases."

  defp agent(opts) do
    Clementine.Agent.new(
      Keyword.merge([model: :claude_sonnet, instructions: @instructions, tools: [Echo]], opts)
    )
  end

  defp build_run(ref, agent_opts, rollout_opts \\ []) do
    rollout =
      Rollout.new(
        Keyword.merge(
          [agent: agent(Keyword.put_new(agent_opts, :skills, [Deploys, Notes])), input: "go"],
          rollout_opts
        )
      )

    Run.new(ref: ref, rollout: rollout)
  end

  defp execute(run, store) do
    Runner.execute(run,
      lifecycle: MemoryLifecycle,
      ctx: store,
      executor_id: "test:skills",
      heartbeat: false
    )
  end

  # Scripts one model call, reporting what the request offered: the
  # system prompt, and the names of the tools.
  defp expect_gather(events) do
    test = self()

    expect(Clementine.LLM.MockClient, :stream, fn _model, system, messages, tools, _opts ->
      send(test, {:gather, system, Enum.map(tools, &Tool.to_schema(&1).name), messages})
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

  defp tool_results(messages) do
    for %ToolResultMessage{content: blocks} <- messages,
        %Content.ToolResult{} = block <- blocks,
        do: {block.tool_use_id, block.content, block.is_error}
  end

  defp kinds(entries), do: Enum.map(entries, &{&1.epoch, &1.seq, &1.kind})

  # A skill whose body, which runs in the run's own process, delivers
  # `signal` to it, as the runner would while the body runs.
  defp signaller(signal) do
    Skill.new(
      name: "signaller",
      description: "Loads while a signal arrives.",
      body: fn _context ->
        send(self(), signal)
        "Loaded."
      end
    )
  end

  describe "a load" do
    test "offers use_skill from the start, and the skill's tools from the next call on, " <>
           "which the model then calls",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([{"tu_1", "use_skill", %{"name" => "deploys"}}]))
      expect_gather(tool_events([{"tu_2", "safe_echo", %{"message" => "release notes"}}]))
      expect_gather(text_events("Done."))

      run = build_run(ref, [], context: %{env: "canary"})
      assert {:finished, %Facts{status: :completed}} = execute(run, store)

      assert_received {:gather, @instructions, ["echo", "use_skill"], _}

      assert_received {:gather, @instructions, ["echo", "safe_echo", "gated_deploy", "use_skill"],
                       _}

      assert_received {:gather, @instructions, offered, messages}
      assert offered == ["echo", "safe_echo", "gated_deploy", "use_skill"]

      assert [
               {"tu_1", load, false},
               {"tu_2", "Echo: release notes", false}
             ] = tool_results(messages)

      assert load ==
               "Deploy only to canary first.\n\nIts tools are available: safe_echo, gated_deploy."

      assert [{^ref, %Result.Completed{output: "Done."}}] = MemoryLifecycle.projections(store)
    end

    test "settles first in its batch, so a call beside it may use the tools it adds",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "safe_echo", %{"message" => "eager"}},
          {"tu_2", "use_skill", %{"name" => "deploys"}}
        ])
      )

      expect_gather(text_events("Done."))

      assert {:finished, %Facts{status: :completed}} = execute(build_run(ref, []), store)

      assert_received {:gather, _, _, _}
      assert_received {:gather, _, _, messages}

      # Results go back in the order the model called them.
      assert [{"tu_1", "Echo: eager", false}, {"tu_2", _body, false}] = tool_results(messages)
    end

    test "repairs a garbled call beside it to a tool it adds, as it repairs any other",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "use_skill", %{"name" => "triage"}},
          {"tu_2", "record_verdict",
           %{"tier" => "high</tier>\n<parameter name=\"summary\">Same day"}}
        ])
      )

      expect_gather(text_events("Graded."))

      run = build_run(ref, [skills: [Triage]], context: %{notify: self()})
      assert {:finished, %Facts{status: :completed}} = execute(run, store)

      assert_received {:verdict, %{tier: "high", summary: "Same day"}}
    end

    test "repairs a garbled gated call beside it before parking on it",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "use_skill", %{"name" => "triage"}},
          {"tu_2", "gated_deploy", %{"env" => "prod</env>\n</invoke>"}}
        ])
      )

      assert {:suspended, _token} = execute(build_run(ref, skills: [Triage]), store)

      # The approver sees, and approves, exactly the arguments that will run.
      assert %Facts{suspension: %{checkpoint: %Checkpoint{pending: pending}}} =
               MemoryLifecycle.facts!(store, ref)

      assert pending.args == %{"env" => "prod"}
    end

    test "of a skill already loaded answers so and changes nothing",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([{"tu_1", "use_skill", %{"name" => "notes"}}]))
      expect_gather(tool_events([{"tu_2", "use_skill", %{"name" => "notes"}}]))
      expect_gather(text_events("Done."))

      assert {:finished, %Facts{status: :completed}} = execute(build_run(ref, []), store)

      assert_received {:gather, _, ["echo", "use_skill"], _}
      assert_received {:gather, _, ["echo", "use_skill"], _}
      assert_received {:gather, _, ["echo", "use_skill"], messages}

      assert [{"tu_1", "Keep notes short." <> _, false}, {"tu_2", again, false}] =
               tool_results(messages)

      assert again == ~s(The skill "notes" is already loaded. Its tools are available: echo.)

      # One load, one entry.
      assert [%Entry{payload: %{"name" => "notes"}}] =
               store |> MemoryLifecycle.trace(ref) |> Enum.filter(&(&1.kind == :skill_load))
    end

    test "of a name the agent does not offer is an error the model sees, and loads nothing",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([{"tu_1", "use_skill", %{"name" => "Elixir.System"}}]))
      expect_gather(text_events("Sorry."))

      assert {:finished, %Facts{status: :completed}} = execute(build_run(ref, []), store)

      assert_received {:gather, _, _, _}
      assert_received {:gather, _, ["echo", "use_skill"], messages}

      assert [{"tu_1", unknown, true}] = tool_results(messages)

      assert unknown ==
               ~s(There is no skill named "Elixir.System". The skills are: deploys, notes.)

      refute Enum.any?(MemoryLifecycle.trace(store, ref), &(&1.kind == :skill_load))
    end

    test "whose body exits is an error the model sees, and the run goes on",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([{"tu_1", "use_skill", %{"name" => "flaky"}}]))
      expect_gather(text_events("I could not load it."))

      flaky =
        Skill.new(
          name: "flaky",
          description: "Reads its body from a server that times out.",
          body: fn _ -> GenServer.call(spawn(fn -> :ok end), :read, 10) end
        )

      run = build_run(ref, skills: [flaky])
      assert {:finished, %Facts{status: :completed}} = execute(run, store)

      assert_received {:gather, _, _, _}
      assert_received {:gather, _, ["echo", "use_skill"], messages}
      assert [{"tu_1", error, true}] = tool_results(messages)
      assert error =~ ~s(The skill "flaky" could not be loaded: exit)
      refute Enum.any?(MemoryLifecycle.trace(store, ref), &(&1.kind == :skill_load))
    end

    test "leaves the effect fence down: loading a skill acts on nothing outside the run" do
      test = self()
      expect_gather(tool_events([{"tu_1", "use_skill", %{"name" => "notes"}}]))
      expect_gather(text_events("Done."))

      rollout = Rollout.new(agent: agent(skills: [Notes]), input: "go")

      assert {:ok, %Result.Completed{}} =
               Rollout.execute(rollout, mark_effects: fn -> send(test, :fence) && :ok end)

      refute_received :fence
    end
  end

  describe "an agent whose skills were set without Agent.new/1" do
    # What an agent/1 that does %{super(run) | skills: ...} returns.
    defp set_skills(agent_opts, skills) do
      %{agent(Keyword.put(agent_opts, :skills, [])) | skills: skills}
    end

    defp run_with(ref, agent) do
      Run.new(ref: ref, rollout: Rollout.new(agent: agent, input: "go"))
    end

    test "has a raw skill module checked and offered", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([{"tu_1", "use_skill", %{"name" => "notes"}}]))
      expect_gather(text_events("Done."))

      run = run_with(ref, set_skills([], [Notes]))
      assert {:finished, %Facts{status: :completed}} = execute(run, store)

      assert_received {:gather, _, ["echo", "use_skill"], _}
      assert_received {:gather, _, _, messages}
      assert [{"tu_1", "Keep notes short." <> _, false}] = tool_results(messages)
    end

    test "fails as :invalid_skills, before the model is called, on what Agent.new/1 refuses",
         %{store: store} do
      clash = Skill.new(name: "clash", description: "Clashes.", body: "", tools: [OtherEcho])

      for {agent, message} <- [
            {set_skills([], [clash]), ~s(share the name "echo")},
            {set_skills([tools: [UseSkillTool]], [Notes]), ~s(named "use_skill")},
            {set_skills([], [Notes, Notes]), ~s(more than one skill named ["notes"])},
            {set_skills([], [Echo]), "does not use Clementine.Skill"}
          ] do
        ref = make_ref()
        MemoryLifecycle.seed_queued(store, ref)

        assert {:finished, %Facts{status: :failed} = facts} = execute(run_with(ref, agent), store)

        assert %Error{code: :invalid_skills, retryable?: false} = facts.error
        assert facts.error.message =~ message

        # The execution offered the agent's own tools and nothing more.
        assert [%Entry{kind: :execution, payload: %{"skills" => [], "tools" => tools}}] =
                 MemoryLifecycle.trace(store, ref)

        assert tools == Enum.map(agent.tools, & &1.__name__())
      end
    end
  end

  describe "beside deferred: and output_schema:" do
    @answer_schema %{
      "type" => "object",
      "properties" => %{"verdict" => %{"type" => "string"}},
      "required" => ["verdict"],
      "additionalProperties" => false
    }

    test "loads and uses a skill, keeps the deferred tools deferred, and decodes only the " <>
           "final answer" do
      test = self()

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, tools, opts ->
        send(test, {:offered, Enum.map(tools, &Tool.to_schema(&1).name), opts})
        tool_events([{"tu_1", "use_skill", %{"name" => "notes"}}])
      end)

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, tools, opts ->
        send(test, {:offered, Enum.map(tools, &Tool.to_schema(&1).name), opts})
        tool_events([{"tu_2", "echo", %{"message" => "noted"}}])
      end)

      expect_gather(text_events(~s({"verdict": "pass"})))

      agent =
        agent(
          tools: [SafeEcho],
          deferred: [GatedDeploy],
          skills: [Notes],
          output_schema: @answer_schema
        )

      assert {:ok, %Result.Completed{output: %{"verdict" => "pass"}}} =
               Rollout.execute(Rollout.new(agent: agent, input: "go"))

      assert_received {:offered, ["safe_echo", "gated_deploy", "use_skill"], opts}
      assert opts[:deferred] == [GatedDeploy]
      assert opts[:output_schema] == @answer_schema

      # The skill's tool joins in full; the deferred tool stays deferred.
      assert_received {:offered, ["safe_echo", "gated_deploy", "echo", "use_skill"], opts}
      assert opts[:deferred] == [GatedDeploy]
    end

    test "a skill may not bring a deferred tool, nor one named like a deferred tool",
         %{store: store} do
      for {skill_tools, message} <- [
            {[GatedDeploy], "brings a tool the agent lists in deferred"},
            {[OtherEcho], ~s(share the name "echo")}
          ] do
        skill = Skill.new(name: "clash", description: "Clashes.", body: "", tools: skill_tools)

        assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn ->
          agent(tools: [SafeEcho], deferred: [Echo, GatedDeploy], skills: [skill])
        end

        # The same agent built past Agent.new/1 fails its run.
        ref = make_ref()
        MemoryLifecycle.seed_queued(store, ref)

        built = %{
          agent(tools: [SafeEcho], deferred: [Echo, GatedDeploy], skills: [])
          | skills: [skill]
        }

        run = Run.new(ref: ref, rollout: Rollout.new(agent: built, input: "go"))
        assert {:finished, %Facts{status: :failed} = facts} = execute(run, store)
        assert %Error{code: :invalid_skills} = facts.error
        assert facts.error.message =~ message
      end
    end

    test "the trace names the skills and the deferred tools, and the fingerprint covers both",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(text_events(~s({"verdict": "pass"})))

      agent =
        agent(
          tools: [SafeEcho],
          deferred: [GatedDeploy],
          skills: [Notes],
          output_schema: @answer_schema
        )

      run = Run.new(ref: ref, rollout: Rollout.new(agent: agent, input: "go"))
      assert {:finished, %Facts{status: :completed}} = execute(run, store)

      assert [%Entry{kind: :execution, payload: payload} | _] = MemoryLifecycle.trace(store, ref)

      assert %{
               "tools" => ["safe_echo", "gated_deploy", "use_skill"],
               "deferred" => ["gated_deploy"],
               "skills" => ["notes"],
               "agent_fingerprint" => fingerprint
             } = payload

      assert fingerprint ==
               Trace.fingerprint(:claude_sonnet, @instructions, [SafeEcho, GatedDeploy],
                 deferred: [GatedDeploy],
                 output_schema: @answer_schema,
                 skills: [Notes.__skill__()]
               )

      refute fingerprint ==
               Trace.fingerprint(:claude_sonnet, @instructions, [SafeEcho, GatedDeploy],
                 deferred: [GatedDeploy],
                 output_schema: @answer_schema
               )
    end
  end

  describe "a skill's gated tool" do
    test "parks the run with the loaded skills in the checkpoint, and the resume after " <>
           "approval offers them again and runs the call",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([{"tu_1", "use_skill", %{"name" => "deploys"}}]))
      expect_gather(tool_events([{"tu_2", "gated_deploy", %{"env" => "prod"}}]))

      run = build_run(ref, [], context: %{notify: self()})
      assert {:suspended, token} = execute(run, store)
      refute_received {:deployed, _}

      assert %Facts{suspension: %{checkpoint: %Checkpoint{version: 2, skills: ["deploys"]}}} =
               MemoryLifecycle.facts!(store, ref)

      {:ok, _facts} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "u1"}}, store)
      expect_gather(text_events("Deployed."))

      assert {:finished, %Facts{status: :completed, epoch: 2}} = execute(run, store)
      assert_received {:deployed, %{env: "prod"}}

      flush_gathers(2)
      assert_received {:gather, _, ["echo", "safe_echo", "gated_deploy", "use_skill"], messages}
      assert {"tu_2", "deployed prod", false} in tool_results(messages)

      # The resumed execution began with the skill's tools.
      assert %Entry{payload: %{"resumed" => true, "tools" => tools}} =
               store
               |> MemoryLifecycle.trace(ref)
               |> Enum.find(&(&1.kind == :execution and &1.epoch == 2))

      assert tools == ["echo", "safe_echo", "gated_deploy", "use_skill"]
    end

    test "loaded in the batch that calls it parks once, with the skill recorded",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "use_skill", %{"name" => "deploys"}},
          {"tu_2", "gated_deploy", %{"env" => "prod"}}
        ])
      )

      run = build_run(ref, [], context: %{notify: self()})
      assert {:suspended, token} = execute(run, store)

      assert %Facts{suspension: %{checkpoint: checkpoint}} = MemoryLifecycle.facts!(store, ref)
      assert checkpoint.skills == ["deploys"]
      assert Map.keys(checkpoint.pending.completed_results) == ["tu_1"]

      {:ok, _facts} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "u1"}}, store)
      expect_gather(text_events("Deployed."))

      assert {:finished, %Facts{status: :completed}} = execute(run, store)
      assert_received {:deployed, %{env: "prod"}}
    end

    test "parked by an agent that no longer offers the skill fails the resume as " <>
           ":incompatible_checkpoint",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([{"tu_1", "use_skill", %{"name" => "deploys"}}]))
      expect_gather(tool_events([{"tu_2", "gated_deploy", %{"env" => "prod"}}]))

      assert {:suspended, token} = execute(build_run(ref, []), store)
      {:ok, _facts} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "u1"}}, store)

      # A deploy between park and resume dropped the skill.
      redeployed = build_run(ref, skills: [Notes])

      assert {:finished, %Facts{status: :failed} = facts} = execute(redeployed, store)

      assert %Error{code: :incompatible_checkpoint, retryable?: false, message: message} =
               facts.error

      assert message =~ ~s(skill "deploys", which the agent no longer offers)
      refute_received {:deployed, _}
    end
  end

  defp flush_gathers(0), do: :ok

  defp flush_gathers(n) do
    assert_received {:gather, _, _, _}
    flush_gathers(n - 1)
  end

  describe "a version-1 checkpoint" do
    test "resumes, with no skills loaded" do
      checkpoint =
        %Checkpoint{
          rollout_id: "r1",
          iteration: 1,
          messages: [
            UserMessage.new("go"),
            AssistantMessage.new([Content.tool_use("tu_1", "gated_deploy", %{"env" => "qa"})])
          ],
          pending: %Clementine.Pending.ToolApproval{
            tool_use_id: "tu_1",
            tool_name: "gated_deploy",
            args: %{"env" => "qa"}
          }
        }
        |> Checkpoint.encode()
        |> Map.delete("skills")
        |> Map.put("version", 1)
        |> Jason.encode!()
        |> Jason.decode!()

      expect_gather(text_events("Deployed."))

      rollout =
        Rollout.new(
          agent: agent(tools: [Echo, GatedDeploy], skills: [Notes]),
          input: "go",
          context: %{notify: self()}
        )

      assert {:ok, %Result.Completed{output: "Deployed."}} =
               Rollout.execute(rollout, resume: {checkpoint, {:approved, %{by: "u1"}}})

      assert_received {:deployed, %{env: "qa"}}
      assert_received {:gather, _, ["echo", "gated_deploy", "use_skill"], _}
    end
  end

  describe "the trace" do
    test "records each load as a :skill_load just before its use_skill call",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([{"tu_1", "use_skill", %{"name" => "deploys"}}]))
      expect_gather(text_events("Done."))

      assert {:finished, %Facts{status: :completed}} = execute(build_run(ref, []), store)

      assert [execution, _call, load, use_skill, _final] =
               trace = MemoryLifecycle.trace(store, ref)

      assert kinds(trace) == [
               {1, 1, :execution},
               {1, 2, :model_call},
               {1, 3, :skill_load},
               {1, 4, :tool_call},
               {1, 5, :model_call}
             ]

      assert %{
               "tools" => ["echo", "use_skill"],
               "skills" => ["deploys", "notes"],
               "agent_fingerprint" => fingerprint
             } = execution.payload

      assert fingerprint ==
               Trace.fingerprint(:claude_sonnet, @instructions, [Echo],
                 skills: [Deploys.__skill__(), Notes.__skill__()]
               )

      assert load.payload == %{
               "iteration" => 1,
               "tool_use_id" => "tu_1",
               "name" => "deploys",
               "tools" => ["safe_echo", "gated_deploy"],
               "body_sha256" =>
                 Base.encode16(:crypto.hash(:sha256, "Deploy only to staging first."),
                   case: :lower
                 )
             }

      assert %{
               "name" => "use_skill",
               "args" => %{"name" => "deploys"},
               "result" => "Deploy only to staging first." <> _,
               "is_error" => false,
               "approval" => nil
             } = use_skill.payload
    end

    test "keeps the load and drops the body under trace: :facts", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([{"tu_1", "use_skill", %{"name" => "notes"}}]))
      expect_gather(text_events("Done."))

      assert {:finished, %Facts{status: :completed}} =
               execute(build_run(ref, trace: :facts), store)

      trace = MemoryLifecycle.trace(store, ref)

      # Which body the model read stays on the record as a hash.
      assert %Entry{payload: %{"name" => "notes", "body_sha256" => sha}} =
               Enum.find(trace, &(&1.kind == :skill_load))

      assert sha == Base.encode16(:crypto.hash(:sha256, "Keep notes short."), case: :lower)

      assert %Entry{payload: use_skill} = Enum.find(trace, &(&1.kind == :tool_call))
      refute Map.has_key?(use_skill, "result")
    end
  end

  describe "a batch a signal cuts off" do
    test "by a drain keeps the load and the use_skill call, numbered in order, beside the " <>
           "call it killed",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      runner = self()

      # The load settles first; the drain lands while the unsafe call works.
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        spawn(fn ->
          Process.sleep(200)
          send(runner, {:clementine, :drain})
        end)

        tool_events([
          {"tu_1", "use_skill", %{"name" => "notes"}},
          {"tu_2", "unsafe_slow", %{"delay_ms" => 5_000}}
        ])
      end)

      run = build_run(ref, tools: [Echo, UnsafeSlow])
      assert {:finished, %Facts{status: :interrupted}} = execute(run, store)

      assert [_execution, _call, load, use_skill, cut] = trace = MemoryLifecycle.trace(store, ref)

      assert kinds(trace) == [
               {1, 1, :execution},
               {1, 2, :model_call},
               {1, 3, :skill_load},
               {1, 4, :tool_call},
               {1, 5, :tool_call}
             ]

      assert %{"name" => "notes", "tool_use_id" => "tu_1"} = load.payload

      assert %{
               "name" => "use_skill",
               "result" => "Keep notes short." <> _,
               "is_error" => false,
               "killed" => false
             } = use_skill.payload

      assert %{"name" => "unsafe_slow", "killed" => true, "result" => nil} = cut.payload
    end

    test "by a cancel the batch's own tool pushes keeps the load beside the killed call",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "use_skill", %{"name" => "notes"}},
          {"tu_2", "safe_push", %{}}
        ])
      )

      run = build_run(ref, [tools: [Echo, SafePush]], context: %{push_to: self()})
      assert {:finished, %Facts{status: :cancelled}} = execute(run, store)

      assert kinds(MemoryLifecycle.trace(store, ref)) == [
               {1, 1, :execution},
               {1, 2, :model_call},
               {1, 3, :skill_load},
               {1, 4, :tool_call},
               {1, 5, :tool_call}
             ]

      assert [%{payload: %{"name" => "use_skill", "killed" => false}}, %{payload: killed}] =
               store |> MemoryLifecycle.trace(ref) |> Enum.filter(&(&1.kind == :tool_call))

      assert %{"name" => "safe_push", "killed" => true} = killed
    end

    test "by a drain that arrives while a skill's body runs requeues the run before any tool " <>
           "starts",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "use_skill", %{"name" => "signaller"}},
          {"tu_2", "unsafe_slow", %{"delay_ms" => 10}}
        ])
      )

      run =
        build_run(ref, [tools: [UnsafeSlow], skills: [signaller({:clementine, :drain})]],
          context: %{notify: self()}
        )

      # No fence went up, so the drain requeues rather than interrupts.
      assert {:finished, %Facts{status: :queued, effects?: false}} = execute(run, store)
      refute_received {:unsafe_done, _}

      assert kinds(MemoryLifecycle.trace(store, ref)) == [
               {1, 1, :execution},
               {1, 2, :model_call},
               {1, 3, :skill_load},
               {1, 4, :tool_call}
             ]
    end

    test "by a cancel that arrives while a skill's body runs stops the run before any tool " <>
           "starts",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "use_skill", %{"name" => "signaller"}},
          {"tu_2", "unsafe_slow", %{"delay_ms" => 10}}
        ])
      )

      run =
        build_run(ref, [tools: [UnsafeSlow], skills: [signaller({:clementine, :cancel, :stop})]],
          context: %{notify: self()}
        )

      assert {:finished, %Facts{status: :cancelled, effects?: false}} = execute(run, store)
      refute_received {:unsafe_done, _}
    end

    test "by a cancel that arrived during the model call loads nothing", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      runner = self()

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        send(runner, {:clementine, :cancel, :stop})
        tool_events([{"tu_1", "use_skill", %{"name" => "notes"}}])
      end)

      assert {:finished, %Facts{status: :cancelled}} = execute(build_run(ref, []), store)

      assert kinds(MemoryLifecycle.trace(store, ref)) ==
               [{1, 1, :execution}, {1, 2, :model_call}]
    end
  end

  describe "the fingerprint" do
    test "covers each skill's name, description, and tools, and is unchanged for an agent " <>
           "offering none" do
      base = Trace.fingerprint(:claude_sonnet, @instructions, [Echo])

      assert base == Trace.fingerprint(:claude_sonnet, @instructions, [Echo], skills: [])

      %Skill{} = notes = Notes.__skill__()
      with_notes = Trace.fingerprint(:claude_sonnet, @instructions, [Echo], skills: [notes])
      refute with_notes == base

      reworded = %{notes | description: "Take longer notes."}

      refute with_notes ==
               Trace.fingerprint(:claude_sonnet, @instructions, [Echo], skills: [reworded])

      retooled = %{notes | tools: [SafeEcho]}

      refute with_notes ==
               Trace.fingerprint(:claude_sonnet, @instructions, [Echo], skills: [retooled])

      # The body is read at load, per run: it is not the agent's identity.
      rebodied = %{notes | body: "Anything."}

      assert with_notes ==
               Trace.fingerprint(:claude_sonnet, @instructions, [Echo], skills: [rebodied])
    end
  end
end
