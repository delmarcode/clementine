defmodule Clementine.ToolPolicyTest do
  @moduledoc """
  The tool policy in the engine, through the real runner on the in-memory
  lifecycle. A tool declared `approval: {:policy, term}` asks the
  `authorize_tool:` function about each call: `:allow` runs it with its
  batch, `:require_approval` parks it like `:required`, and
  `{:deny, reason}` settles it as an error the model reads. An approval's
  resume asks once more, and a deny wins over the approval. A function
  that raises, exits, throws, answers anything else, or does not answer
  in time denies the call and logs why, without the run's data; without
  one, the tool gates like `:required`. The function runs in a task of
  its own: a cancel or a drain while it answers unwinds the run at once.
  A skill's tools and deferred tools are checked the same way, engine
  tools never are, and the trace keeps each answer as it is given and
  the verdict each call settled under, beside the approval.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Clementine.{ApprovalRequest, Checkpoint, Pending, Rollout, Run, Runner}
  alias Clementine.{ToolResult, Trace}
  alias Clementine.LLM.Message.{Content, ToolResultMessage}
  alias Clementine.Lifecycle.{Facts, Protocol}
  alias Clementine.Test.MemoryLifecycle
  alias Clementine.Test.Tools.{Echo, GatedDeploy}

  setup :verify_on_exit!

  setup do
    {:ok, store: MemoryLifecycle.start_store(), ref: make_ref()}
  end

  defmodule Refund do
    @moduledoc false
    use Clementine.Tool,
      name: "refund",
      description: "Refunds an order",
      approval: {:policy, :refund},
      retry: :unsafe,
      parameters: [
        order: [type: :string, required: true],
        cents: [type: :integer, required: true]
      ]

    @impl true
    def run(%{order: order, cents: cents} = args, context) do
      send(context.notify, {:refunded, args})
      {:ok, "Refunded #{cents} on #{order}."}
    end
  end

  defmodule Lookup do
    @moduledoc false
    use Clementine.Tool,
      name: "lookup",
      description: "Looks up an order",
      approval: {:policy, :read},
      retry: :safe,
      parameters: [order: [type: :string, required: true]]

    @impl true
    def run(%{order: order}, context) do
      send(context.notify, {:looked_up, order})
      {:ok, "Order #{order} shipped."}
    end
  end

  defmodule Billing do
    @moduledoc false
    use Clementine.Skill,
      name: "billing",
      description: "Handle money. Use for refunds.",
      tools: [Refund]

    @impl true
    def body(_context), do: "Refund only what was charged."
  end

  defmodule Researcher do
    @moduledoc false
    use Clementine.Agent, key: "researcher", model: :claude_sonnet, instructions: "Research."
  end

  @failed "Denied: the tool's policy check failed."

  defp agent(opts) do
    Clementine.Agent.new(
      Keyword.merge(
        [model: :claude_sonnet, instructions: "Help.", tools: [Echo, Refund, Lookup]],
        opts
      )
    )
  end

  defp build_run(ref, agent_opts \\ [], rollout_opts \\ []) do
    rollout =
      Rollout.new(
        Keyword.merge(
          [agent: agent(agent_opts), input: "go", context: %{notify: self()}],
          rollout_opts
        )
      )

    Run.new(ref: ref, rollout: rollout)
  end

  defp execute(run, store, policy) do
    Runner.execute(run,
      lifecycle: MemoryLifecycle,
      ctx: store,
      executor_id: "test:policy",
      heartbeat: false,
      authorize_tool: policy,
      # The runtime that starts a delegate's children says so; this
      # lifecycle stands in for it.
      delegation: true
    )
  end

  # A policy that reports each question to the test and answers with
  # `answer.(request)`.
  defp policy(answer) do
    test = self()

    fn %ApprovalRequest{} = request, term ->
      send(test, {:asked, request, term})
      answer.(request)
    end
  end

  defp expect_gather(events) do
    test = self()

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      send(test, {:gather, messages})
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

  defp refund(id, order, cents), do: {id, "refund", %{"order" => order, "cents" => cents}}

  # The tool results of the last request the model received.
  defp last_results do
    messages = last_gather()

    for %ToolResultMessage{content: blocks} <- messages,
        %Content.ToolResult{} = block <- blocks,
        do: {block.tool_use_id, block.content, block.is_error}
  end

  defp last_gather(messages \\ nil) do
    receive do
      {:gather, messages} -> last_gather(messages)
    after
      0 -> messages
    end
  end

  defp tool_call(store, ref, id) do
    store
    |> MemoryLifecycle.trace(ref)
    |> Enum.find(&(&1.kind == :tool_call and &1.payload["tool_use_id"] == id))
    |> Map.fetch!(:payload)
  end

  # The tool policy's answers, as the trace's :policy entries keep them.
  defp answers(store, ref) do
    for %{kind: :policy} = entry <- MemoryLifecycle.trace(store, ref),
        do: {entry.epoch, entry.payload["tool_use_id"], entry.payload["verdict"]}
  end

  # A policy whose answer the test changes between executions.
  defp switchable(first) do
    {:ok, answer} = Agent.start_link(fn -> first end)
    {answer, policy(fn request -> answer |> Agent.get(& &1) |> then(& &1.(request)) end)}
  end

  defp pending!(store, ref) do
    %Facts{status: :waiting, suspension: %{reason: reason, checkpoint: checkpoint}} =
      MemoryLifecycle.facts!(store, ref)

    {reason, checkpoint}
  end

  describe "the policy's answer" do
    test ":allow runs the call with its batch; the policy is asked with the call's arguments " <>
           "and the tool's term, and only about {:policy, _} tools",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([refund("tu_1", "o-1", 500), {"tu_2", "echo", %{"message" => "hi"}}])
      )

      expect_gather(text_events("Refunded."))

      assert {:finished, %Facts{status: :completed, effects?: true}} =
               execute(build_run(ref), store, policy(fn _ -> :allow end))

      assert_received {:asked,
                       %ApprovalRequest{
                         tool_use_id: "tu_1",
                         tool_name: "refund",
                         args: %{"order" => "o-1", "cents" => 500}
                       }, :refund}

      refute_received {:asked, _, _}
      assert_received {:refunded, %{order: "o-1", cents: 500}}

      assert last_results() == [
               {"tu_1", "Refunded 500 on o-1.", false},
               {"tu_2", "Echo: hi", false}
             ]

      assert %{
               "policy" => %{"verdict" => "allow", "reason" => nil, "failed" => false},
               "approval" => nil
             } = tool_call(store, ref, "tu_1")

      assert %{"policy" => nil} = tool_call(store, ref, "tu_2")
    end

    test ":require_approval parks the call like :required; the approval's resume asks once " <>
           "more and runs it, and the trace keeps every answer and the verdict beside the approval",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 90_000)]))

      run = build_run(ref)
      policy = policy(fn _ -> :require_approval end)
      assert {:suspended, token} = execute(run, store, policy)
      assert_received {:asked, %ApprovalRequest{tool_use_id: "tu_1"}, :refund}
      refute_received {:refunded, _}

      # The answer is on the trace with the park, before any decision.
      assert answers(store, ref) == [{1, "tu_1", "require_approval"}]

      assert {{:approval, %ApprovalRequest{tool_name: "refund", args: args}},
              %Checkpoint{pending: %Pending.ToolApproval{policy: :require_approval}} = checkpoint} =
               pending!(store, ref)

      assert args == %{"order" => "o-1", "cents" => 90_000}

      # The verdict rides in the checkpoint, so it needs version 2.
      assert Checkpoint.version_for(checkpoint) == 2

      assert {:ok, %Checkpoint{pending: %Pending.ToolApproval{policy: :require_approval}}} =
               checkpoint
               |> Checkpoint.encode()
               |> Jason.encode!()
               |> Jason.decode!()
               |> Checkpoint.decode()

      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "u1"}}, store)
      expect_gather(text_events("Refunded."))
      assert {:finished, %Facts{status: :completed}} = execute(run, store, policy)

      assert_received {:asked, %ApprovalRequest{tool_use_id: "tu_1"}, :refund}
      refute_received {:asked, _, _}
      assert_received {:refunded, %{order: "o-1", cents: 90_000}}

      assert answers(store, ref) == [
               {1, "tu_1", "require_approval"},
               {2, "tu_1", "require_approval"}
             ]

      assert %{
               "policy" => %{"verdict" => "require_approval", "failed" => false},
               "approval" => %{"verdict" => "approved", "by" => "u1"},
               "result" => "Refunded 90000 on o-1."
             } = tool_call(store, ref, "tu_1")
    end

    test ":require_approval then an approver's denial: the policy is not asked again, the " <>
           "model reads the denial, and the trace keeps both",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 90_000)]))

      run = build_run(ref)
      policy = policy(fn _ -> :require_approval end)
      assert {:suspended, token} = execute(run, store, policy)
      assert_received {:asked, _, _}

      {:ok, _} =
        Protocol.resume(
          MemoryLifecycle,
          token,
          {:denied, %{by: "u1", message: "Too much."}},
          store
        )

      expect_gather(text_events("Understood."))
      assert {:finished, %Facts{status: :completed}} = execute(run, store, policy)

      refute_received {:asked, _, _}
      refute_received {:refunded, _}
      assert last_results() == [{"tu_1", "Too much.", true}]

      assert %{
               "policy" => %{"verdict" => "require_approval"},
               "approval" => %{"verdict" => "denied", "by" => "u1"}
             } = tool_call(store, ref, "tu_1")
    end

    test "{:deny, reason} settles the call as an error the model reads: nothing runs, and " <>
           "the fence stays down",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 500)]))
      expect_gather(text_events("I cannot refund that."))

      policy = policy(fn _ -> {:deny, "You may not refund orders."} end)

      assert {:finished, %Facts{status: :completed, effects?: false}} =
               execute(build_run(ref), store, policy)

      refute_received {:refunded, _}
      assert last_results() == [{"tu_1", "You may not refund orders.", true}]

      assert %{
               "policy" => %{
                 "verdict" => "deny",
                 "reason" => "You may not refund orders.",
                 "failed" => false
               },
               "approval" => nil,
               "result" => "You may not refund orders.",
               "is_error" => true,
               "duration_ms" => 0
             } = tool_call(store, ref, "tu_1")
    end
  end

  describe "an approval's resume" do
    test "asks once more, and a deny wins: the approved call runs nothing, the model reads " <>
           "the deny, the trace keeps both, and a sibling still waiting is denied too",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(tool_events([refund("tu_1", "o-1", 90_000), refund("tu_2", "o-2", 90_000)]))

      run = build_run(ref)
      {answer, policy} = switchable(fn _ -> :require_approval end)
      assert {:suspended, token} = execute(run, store, policy)

      # Two days later the actor loses refund authority, and a manager,
      # who does not know it, approves.
      Agent.update(answer, fn _ -> fn _ -> {:deny, "The actor lost refund authority."} end end)
      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "manager"}}, store)
      expect_gather(text_events("I cannot refund these."))

      assert {:finished, %Facts{status: :completed, effects?: false}} =
               execute(run, store, policy)

      refute_received {:refunded, _}

      assert last_results() == [
               {"tu_1", "The actor lost refund authority.", true},
               {"tu_2", "The actor lost refund authority.", true}
             ]

      assert %{
               "approval" => %{"verdict" => "approved", "by" => "manager"},
               "policy" => %{"verdict" => "deny", "reason" => "The actor lost refund authority."},
               "result" => "The actor lost refund authority.",
               "is_error" => true
             } = tool_call(store, ref, "tu_1")

      assert %{"approval" => nil, "policy" => %{"verdict" => "deny"}} =
               tool_call(store, ref, "tu_2")

      assert answers(store, ref) == [
               {1, "tu_1", "require_approval"},
               {1, "tu_2", "require_approval"},
               {2, "tu_1", "deny"},
               {2, "tu_2", "deny"}
             ]
    end

    test ":allow on the second ask runs the approved call", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 90_000)]))

      run = build_run(ref)
      {answer, policy} = switchable(fn _ -> :require_approval end)
      assert {:suspended, token} = execute(run, store, policy)

      Agent.update(answer, fn _ -> fn _ -> :allow end end)
      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "u1"}}, store)
      expect_gather(text_events("Refunded."))
      assert {:finished, %Facts{status: :completed}} = execute(run, store, policy)

      assert_received {:refunded, %{order: "o-1"}}

      assert %{"approval" => %{"verdict" => "approved"}, "policy" => %{"verdict" => "allow"}} =
               tool_call(store, ref, "tu_1")
    end

    test "a failure on the second ask denies the approved call", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 90_000)]))

      run = build_run(ref)
      {answer, policy} = switchable(fn _ -> :require_approval end)
      assert {:suspended, token} = execute(run, store, policy)

      Agent.update(answer, fn _ -> fn _ -> raise "policy store down" end end)
      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "u1"}}, store)
      expect_gather(text_events("The check failed."))

      log =
        capture_log(fn ->
          assert {:finished, %Facts{status: :completed}} = execute(run, store, policy)
        end)

      assert log =~ "raised RuntimeError"
      refute_received {:refunded, _}

      assert %{
               "approval" => %{"verdict" => "approved"},
               "policy" => %{"verdict" => "deny", "failed" => true}
             } = tool_call(store, ref, "tu_1")
    end

    test "of a call parked with no policy asks the policy the run has now, and a deny wins",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 90_000)]))

      run = build_run(ref)
      assert {:suspended, token} = execute(run, store, nil)

      assert {_reason, %Checkpoint{pending: %Pending.ToolApproval{policy: nil}} = checkpoint} =
               pending!(store, ref)

      assert Checkpoint.version_for(checkpoint) == 1

      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "u1"}}, store)
      expect_gather(text_events("I cannot."))

      assert {:finished, %Facts{status: :completed}} =
               execute(run, store, policy(fn _ -> {:deny, "Not any more."} end))

      assert_received {:asked, %ApprovalRequest{tool_use_id: "tu_1"}, :refund}
      refute_received {:refunded, _}
      assert last_results() == [{"tu_1", "Not any more.", true}]
    end
  end

  describe "a policy that fails" do
    test "a raise denies the call, logs why, and tells the model only that the check failed",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 500)]))
      expect_gather(text_events("The check failed."))

      policy = policy(fn _ -> raise "accounts service down" end)

      log =
        capture_log(fn ->
          assert {:finished, %Facts{status: :completed}} =
                   execute(build_run(ref), store, policy)
        end)

      assert log =~ ~s[authorize_tool for tool "refund" (call tu_1) raised RuntimeError]
      assert log =~ "test/clementine/tool_policy_test.exs"
      assert log =~ "The call is denied."
      # The message may inspect the run's data, so the log leaves it out.
      refute log =~ "accounts service down"

      refute_received {:refunded, _}
      assert last_results() == [{"tu_1", @failed, true}]

      assert %{"policy" => %{"verdict" => "deny", "reason" => @failed, "failed" => true}} =
               tool_call(store, ref, "tu_1")
    end

    test "an exit or a throw denies the call too" do
      for {logged, answer} <- [
            {"exited with :timeout", fn _ -> exit(:timeout) end},
            {"threw :nope", fn _ -> throw(:nope) end}
          ] do
        store = MemoryLifecycle.start_store()
        ref = make_ref()
        MemoryLifecycle.seed_queued(store, ref)
        expect_gather(tool_events([refund("tu_1", "o-1", 500)]))
        expect_gather(text_events("The check failed."))

        log =
          capture_log(fn ->
            assert {:finished, %Facts{status: :completed}} =
                     execute(build_run(ref), store, policy(answer))
          end)

        assert log =~ ~s[authorize_tool for tool "refund" (call tu_1) #{logged}]
        refute_received {:refunded, _}
        assert last_results() == [{"tu_1", @failed, true}]
        assert %{"policy" => %{"failed" => true}} = tool_call(store, ref, "tu_1")
      end
    end

    test "an answer it may not give denies the call, whatever it looks like" do
      for {answer, shape} <- [
            {:ok, ":ok"},
            {true, "true"},
            {nil, "nil"},
            {{:deny, :forbidden}, "{:deny, :forbidden}"},
            {{:allow, "yes"}, "{:allow, a string}"},
            {{:error, %{reason: "nope"}}, "{:error, a map}"}
          ] do
        store = MemoryLifecycle.start_store()
        ref = make_ref()
        MemoryLifecycle.seed_queued(store, ref)
        expect_gather(tool_events([refund("tu_1", "o-1", 500)]))
        expect_gather(text_events("The check failed."))

        log =
          capture_log(fn ->
            assert {:finished, %Facts{status: :completed}} =
                     execute(build_run(ref), store, policy(fn _ -> answer end))
          end)

        assert log =~ "answered #{shape}, which is not :allow"
        refute_received {:refunded, _}
        assert last_results() == [{"tu_1", @failed, true}]
      end
    end
  end

  describe "a policy's log" do
    @ssn "123-45-6789"

    test "never carries the run's data: not a clause's arguments, an exception's message, an " <>
           "answer's values, or an exit's reason" do
      cases = [
        # A FunctionClauseError's top frame holds the call's arguments.
        fn %ApprovalRequest{tool_name: "not_this_tool"} -> :allow end,
        # A MatchError's message inspects the value.
        fn %ApprovalRequest{args: args} -> %{"order" => "o-1"} = args end,
        fn %ApprovalRequest{args: args} -> {:deny, args} end,
        fn %ApprovalRequest{args: args} -> exit({:shutdown, args["order"]}) end
      ]

      for answer <- cases do
        store = MemoryLifecycle.start_store()
        ref = make_ref()
        MemoryLifecycle.seed_queued(store, ref)
        expect_gather(tool_events([refund("tu_1", @ssn, 500)]))
        expect_gather(text_events("The check failed."))

        log =
          capture_log(fn ->
            assert {:finished, %Facts{status: :completed}} =
                     execute(build_run(ref), store, policy(answer))
          end)

        assert log =~ "The call is denied."
        refute log =~ @ssn
        assert last_results() == [{"tu_1", @failed, true}]
      end
    end
  end

  describe "a policy that takes its time" do
    test "is denied when it does not answer within the run's remaining time, and the run " <>
           "ends at its deadline",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 500)]))

      run = build_run(ref, [], limits: [max_duration: 300])

      log =
        capture_log(fn ->
          assert {:finished, %Facts{status: :failed}} =
                   execute(run, store, policy(fn _ -> Process.sleep(:infinity) end))
        end)

      assert log =~
               ~r/authorize_tool for tool "refund" \(call tu_1\) did not answer within \d+ ms/

      refute_received {:refunded, _}

      assert [{_ref, %Clementine.Result.Failed{error: %{code: :deadline_exceeded}}}] =
               MemoryLifecycle.projections(store)

      assert %{"policy" => %{"verdict" => "deny", "failed" => true}} =
               tool_call(store, ref, "tu_1")
    end

    test "is stopped at once by a cancel that lands while it answers: nothing runs",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 500)]))
      runner = self()

      hang = fn _ ->
        send(runner, {:clementine, :cancel, :stop})
        Process.sleep(:infinity)
      end

      assert {:finished, %Facts{status: :cancelled, effects?: false}} =
               execute(build_run(ref), store, policy(hang))

      refute_received {:refunded, _}
      assert answers(store, ref) == []
    end

    test "runs in a task that carries the run's $callers, for an Ecto sandbox allowance",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 500)]))
      expect_gather(text_events("Done."))
      test = self()

      answer = fn _ ->
        send(test, {:callers, self(), Process.get(:"$callers")})
        :allow
      end

      assert {:finished, %Facts{status: :completed}} =
               execute(build_run(ref), store, policy(answer))

      assert_received {:callers, task, callers}
      assert task != test
      assert test in callers
    end
  end

  describe "without a policy" do
    test "a {:policy, _} tool gates like :required, its checkpoint stays version 1, and its " <>
           "trace names no verdict",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 500)]))

      run = build_run(ref)
      assert {:suspended, token} = execute(run, store, nil)
      refute_received {:refunded, _}

      assert {{:approval, %ApprovalRequest{tool_name: "refund"}},
              %Checkpoint{pending: %Pending.ToolApproval{policy: nil}} = checkpoint} =
               pending!(store, ref)

      assert Checkpoint.version_for(checkpoint) == 1
      refute Map.has_key?(Checkpoint.encode(checkpoint)["pending"], "policy")

      {:ok, _} = Protocol.resume(MemoryLifecycle, token, {:approved, %{by: "u1"}}, store)
      expect_gather(text_events("Refunded."))
      assert {:finished, %Facts{status: :completed}} = execute(run, store, nil)

      assert_received {:refunded, _}

      assert %{"policy" => nil, "approval" => %{"verdict" => "approved"}} =
               tool_call(store, ref, "tu_1")
    end
  end

  describe "what the policy covers" do
    test "tools without {:policy, _} never ask it: :required parks undecided, :never runs",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "gated_deploy", %{"env" => "prod"}},
          {"tu_2", "echo", %{"message" => "hi"}}
        ])
      )

      run = build_run(ref, tools: [Echo, GatedDeploy])
      assert {:suspended, _token} = execute(run, store, policy(fn _ -> :allow end))

      refute_received {:asked, _, _}
      refute_received {:deployed, _}

      assert {_reason,
              %Checkpoint{
                pending: %Pending.ToolApproval{
                  tool_name: "gated_deploy",
                  policy: nil,
                  completed_results: %{"tu_2" => %ToolResult{content: "Echo: hi"}}
                }
              }} = pending!(store, ref)
    end

    test "a skill's policy tool is checked, even beside the use_skill call that adds it, and " <>
           "use_skill is not",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "use_skill", %{"name" => "billing"}},
          refund("tu_2", "o-1", 500)
        ])
      )

      expect_gather(tool_events([refund("tu_3", "o-2", 700)]))
      expect_gather(text_events("Done."))

      run = build_run(ref, tools: [Echo], skills: [Billing])

      answer = fn
        %ApprovalRequest{args: %{"order" => "o-1"}} -> {:deny, "Not that one."}
        %ApprovalRequest{} -> :allow
      end

      assert {:finished, %Facts{status: :completed}} = execute(run, store, policy(answer))

      assert_received {:asked, %ApprovalRequest{tool_use_id: "tu_2", tool_name: "refund"},
                       :refund}

      assert_received {:asked, %ApprovalRequest{tool_use_id: "tu_3", tool_name: "refund"},
                       :refund}

      refute_received {:asked, _, _}

      assert_received {:refunded, %{order: "o-2"}}
      refute_received {:refunded, _}

      assert %{"policy" => %{"verdict" => "deny"}} = tool_call(store, ref, "tu_2")
      assert %{"policy" => %{"verdict" => "allow"}} = tool_call(store, ref, "tu_3")
      assert %{"name" => "use_skill", "policy" => nil} = tool_call(store, ref, "tu_1")
    end

    test "a deferred policy tool is checked like any other", %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 500)]))
      expect_gather(text_events("Done."))

      run = build_run(ref, tools: [Echo], deferred: [Refund])

      assert {:finished, %Facts{status: :completed}} =
               execute(run, store, policy(fn _ -> {:deny, "No refunds today."} end))

      assert_received {:asked, %ApprovalRequest{tool_name: "refund"}, :refund}
      refute_received {:refunded, _}
      assert last_results() == [{"tu_1", "No refunds today.", true}]
    end

    test "a delegate call never asks it, and a denial beside one settles before the run parks " <>
           "for the child",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "delegate", %{"agent" => "researcher", "prompt" => "Look."}},
          refund("tu_2", "o-1", 500)
        ])
      )

      run = build_run(ref, delegates: [Researcher])

      assert {:suspended, _token} =
               execute(run, store, policy(fn _ -> {:deny, "Ask first."} end))

      assert_received {:asked, %ApprovalRequest{tool_use_id: "tu_2"}, :refund}
      refute_received {:asked, _, _}

      assert {{:external, {:delegation, _}},
              %Checkpoint{
                pending: %Pending.Delegation{
                  children: %{"tu_1" => %{agent: "researcher"}},
                  completed_results: %{
                    "tu_2" => %ToolResult{content: "Ask first.", is_error: true}
                  }
                }
              }} = pending!(store, ref)
    end

    test ":require_approval beside a delegate call parks for the decision first, then for " <>
           "the child",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "delegate", %{"agent" => "researcher", "prompt" => "Look."}},
          refund("tu_2", "o-1", 90_000)
        ])
      )

      run = build_run(ref, delegates: [Researcher])
      policy = policy(fn _ -> :require_approval end)

      assert {:suspended, approval} = execute(run, store, policy)

      assert {{:approval, %ApprovalRequest{tool_use_id: "tu_2"}},
              %Checkpoint{pending: %Pending.ToolApproval{policy: :require_approval}}} =
               pending!(store, ref)

      {:ok, _} = Protocol.resume(MemoryLifecycle, approval, {:approved, %{by: "u1"}}, store)
      assert {:suspended, delegation} = execute(run, store, policy)
      assert delegation.reason_type == :external
      assert_received {:refunded, %{order: "o-1"}}

      assert {_reason,
              %Checkpoint{
                pending: %Pending.Delegation{
                  completed_results: %{"tu_2" => %ToolResult{content: "Refunded 90000 on o-1."}}
                }
              }} = pending!(store, ref)
    end
  end

  describe "a batch" do
    test "each call gets its own answer: the allowed run, the denied settle, the first gated " <>
           "parks, and a call still waiting is asked again on the resume",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)

      expect_gather(
        tool_events([
          {"tu_1", "lookup", %{"order" => "o-1"}},
          refund("tu_2", "o-1", 100),
          refund("tu_3", "o-2", 90_000),
          refund("tu_4", "o-3", 90_000)
        ])
      )

      answer = fn
        %ApprovalRequest{tool_name: "lookup"} -> :allow
        %ApprovalRequest{args: %{"cents" => 100}} -> {:deny, "Too small to refund."}
        %ApprovalRequest{} -> :require_approval
      end

      run = build_run(ref)
      policy = policy(answer)
      assert {:suspended, first} = execute(run, store, policy)

      for id <- ["tu_1", "tu_2", "tu_3", "tu_4"] do
        assert_received {:asked, %ApprovalRequest{tool_use_id: ^id}, _term}
      end

      assert_received {:looked_up, "o-1"}
      refute_received {:refunded, _}

      assert {_reason,
              %Checkpoint{
                pending: %Pending.ToolApproval{
                  tool_use_id: "tu_3",
                  completed_results: %{
                    "tu_1" => %ToolResult{content: "Order o-1 shipped.", is_error: false},
                    "tu_2" => %ToolResult{content: "Too small to refund.", is_error: true}
                  }
                }
              }} = pending!(store, ref)

      {:ok, _} = Protocol.resume(MemoryLifecycle, first, {:approved, %{by: "u1"}}, store)
      assert {:suspended, second} = execute(run, store, policy)
      assert_received {:refunded, %{order: "o-2"}}

      # The approved call is asked once more, and the call still waiting
      # is asked again, in batch order.
      assert_received {:asked, %ApprovalRequest{tool_use_id: "tu_3"}, :refund}
      assert_received {:asked, %ApprovalRequest{tool_use_id: "tu_4"}, :refund}
      refute_received {:asked, _, _}

      assert {_reason, %Checkpoint{pending: %Pending.ToolApproval{tool_use_id: "tu_4"}}} =
               pending!(store, ref)

      {:ok, _} = Protocol.resume(MemoryLifecycle, second, {:approved, %{by: "u2"}}, store)
      expect_gather(text_events("Done."))
      assert {:finished, %Facts{status: :completed}} = execute(run, store, policy)
      assert_received {:asked, %ApprovalRequest{tool_use_id: "tu_4"}, :refund}
      refute_received {:asked, _, _}
      assert_received {:refunded, %{order: "o-3"}}

      # Two calls that each needed approval: 2 * (2 + 3) / 2 = 5 asks of
      # them, beside one each for the allowed and the denied call.
      assert answers(store, ref) == [
               {1, "tu_1", "allow"},
               {1, "tu_2", "deny"},
               {1, "tu_3", "require_approval"},
               {1, "tu_4", "require_approval"},
               {2, "tu_3", "require_approval"},
               {2, "tu_4", "require_approval"},
               {3, "tu_4", "require_approval"}
             ]

      assert last_results() == [
               {"tu_1", "Order o-1 shipped.", false},
               {"tu_2", "Too small to refund.", true},
               {"tu_3", "Refunded 90000 on o-2.", false},
               {"tu_4", "Refunded 90000 on o-3.", false}
             ]

      assert [_ | _] = trace = MemoryLifecycle.trace(store, ref)

      assert for(
               %{kind: :tool_call, payload: payload} <- trace,
               do: {payload["tool_use_id"], payload["policy"]["verdict"]}
             ) == [
               {"tu_2", "deny"},
               {"tu_1", "allow"},
               {"tu_3", "require_approval"},
               {"tu_4", "require_approval"}
             ]
    end

    test "a drain that lands while the policy answers is honored before anything runs, and " <>
           "the answers already given stay on the trace",
         %{store: store, ref: ref} do
      MemoryLifecycle.seed_queued(store, ref)
      expect_gather(tool_events([refund("tu_1", "o-1", 500), refund("tu_2", "o-2", 500)]))
      runner = self()

      # The runner delivers the drain to the run's process while the
      # policy answers for the second call.
      answer = fn
        %ApprovalRequest{tool_use_id: "tu_1"} ->
          :allow

        %ApprovalRequest{} ->
          send(runner, {:clementine, :drain})
          Process.sleep(:infinity)
      end

      assert {:finished, %Facts{status: :queued, effects?: false}} =
               execute(build_run(ref), store, policy(answer))

      refute_received {:refunded, _}
      assert answers(store, ref) == [{1, "tu_1", "allow"}]
    end
  end

  describe "the trace" do
    test "keeps the verdict under :facts, which drops the deny's result but not its reason" do
      payload =
        Trace.payload(
          :tool_call,
          Trace.tool_call(%{
            iteration: 1,
            tool_use_id: "tu_1",
            name: "refund",
            args: %{"order" => "o-1"},
            result: "No.",
            is_error: true,
            duration_ms: 0,
            policy: {:deny, "No."}
          }),
          :facts
        )

      refute Map.has_key?(payload, "result")
      assert payload["policy"] == %{"verdict" => "deny", "reason" => "No.", "failed" => false}
      assert payload["approval"] == nil
    end
  end
end
