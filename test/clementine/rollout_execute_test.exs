defmodule Clementine.RolloutExecuteTest do
  use ExUnit.Case, async: true

  import Mox

  alias Clementine.{
    ApprovalRequest,
    Checkpoint,
    Error,
    Event,
    Lease,
    Pending,
    Result,
    Rollout,
    Suspension,
    ToolResult,
    Usage
  }

  alias Clementine.Events.Stamper
  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}
  alias Clementine.Test.CollectingSink

  alias Clementine.Test.Tools.{
    Echo,
    GatedDeploy,
    PolicyGated,
    SafeEcho,
    SafeGatedLookup,
    SafePush,
    Slow,
    UnsafeSlow
  }

  setup :verify_on_exit!

  defmodule NotifyingEcho do
    @moduledoc false
    use Clementine.Tool,
      name: "echo",
      description: "Echoes and notifies the test",
      parameters: [message: [type: :string, required: true]]

    @impl true
    def run(%{message: message}, context) do
      send(context.notify, {:mark, :tool})
      {:ok, message}
    end
  end

  defp rollout(opts \\ []) do
    agent =
      Clementine.Agent.new(
        model: :claude_sonnet,
        instructions: "test",
        tools: Keyword.get(opts, :tools, [])
      )

    Rollout.new(
      agent: agent,
      input: Keyword.get(opts, :input, "go"),
      messages: Keyword.get(opts, :messages, []),
      context: Keyword.get(opts, :context, %{}),
      limits: Keyword.get(opts, :limits, [])
    )
  end

  defp expect_stream(events) do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      events
    end)
  end

  defp text_events(text, usage \\ %{"input_tokens" => 7, "output_tokens" => 3}) do
    [{:text_delta, text}, {:message_delta, %{"stop_reason" => "end_turn"}, usage}]
  end

  defp tool_events(id, name, input) do
    [
      {:tool_use_start, id, name},
      {:input_json_delta, id, Jason.encode!(input)},
      {:content_block_stop, 0},
      {:message_delta, %{"stop_reason" => "tool_use"},
       %{"input_tokens" => 5, "output_tokens" => 2}}
    ]
  end

  defp batch_events(calls) do
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

  # A parked run's checkpoint: history + the assistant turn that issued
  # the batch, with the first call pending unless overridden.
  defp approval_checkpoint(opts \\ []) do
    batch = Keyword.get(opts, :batch, [{"tu_1", "gated_deploy", %{"env" => "prod"}}])
    {pending_id, pending_name, pending_args} = Keyword.get(opts, :pending, hd(batch))

    %Checkpoint{
      rollout_id: "r1",
      iteration: Keyword.get(opts, :iteration, 1),
      messages: [
        UserMessage.new("go"),
        %AssistantMessage{
          content:
            Enum.map(batch, fn {id, name, input} ->
              %Content.ToolUse{id: id, name: name, input: input}
            end)
        }
      ],
      pending: %Pending.ToolApproval{
        tool_use_id: pending_id,
        tool_name: pending_name,
        args: pending_args,
        completed_results: Keyword.get(opts, :completed, %{})
      },
      usage: %Usage{input_tokens: 10, output_tokens: 5}
    }
  end

  defp stamper do
    lease = %Lease{
      run_ref: :unit_test_run,
      epoch: 1,
      executor_id: "test:unit",
      lifecycle: Clementine.Test.MemoryLifecycle
    }

    Stamper.new(CollectingSink, lease)
  end

  defp collect_events(acc \\ []) do
    receive do
      {:clementine_event, %Event{} = event} -> collect_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count_received(message, acc \\ 0) do
    receive do
      ^message -> count_received(message, acc + 1)
    after
      0 -> acc
    end
  end

  describe "completed" do
    test "separates generated messages from history and input" do
      history = [UserMessage.new("before"), UserMessage.new("context")]
      expect_stream(text_events("Answer"))

      assert {:ok, %Result.Completed{} = result} =
               Rollout.execute(rollout(messages: history, input: "question"))

      assert result.output == "Answer"
      assert result.input_message == UserMessage.new("question")
      # history ++ [input_message] ++ messages is the full transcript
      assert [%{content: _}] = result.messages
      assert result.usage == %Usage{input_tokens: 7, output_tokens: 3}
    end

    test "a tool loop's generated messages ride in the result" do
      expect_stream(tool_events("tu_1", "echo", %{"message" => "test"}))
      expect_stream(text_events("Done!"))

      assert {:ok, %Result.Completed{} = result} = Rollout.execute(rollout(tools: [Echo]))

      assert result.output == "Done!"
      # assistant (tool use), tool results, assistant (final) — the input
      # rides separately in input_message.
      assert [%AssistantMessage{}, %ToolResultMessage{}, %AssistantMessage{}] = result.messages
    end
  end

  describe "limits" do
    test "max_iterations returns a normalized error, never a bare atom" do
      expect_stream(tool_events("tu_1", "echo", %{"message" => "loop"}))

      assert {:error, %Error{kind: :rollout, code: :max_iterations, retryable?: false}} =
               Rollout.execute(rollout(tools: [Echo], limits: [max_iterations: 1]))
    end

    test "the engine default caps iterations at 10 when no limit is set" do
      test = self()

      stub(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        send(test, :gather)
        tool_events("tu_1", "echo", %{"message" => "loop"})
      end)

      assert {:error, %Error{code: :max_iterations}} = Rollout.execute(rollout(tools: [Echo]))

      assert count_received(:gather) == 10
    end

    test "an expired deadline fails at the boundary before any provider call" do
      deadline = DateTime.add(DateTime.utc_now(), -1, :second)

      assert {:error, %Error{kind: :rollout, code: :deadline_exceeded, retryable?: false}} =
               Rollout.execute(rollout(), deadline: deadline)
    end
  end

  describe "cancellation poll" do
    test "a requested cancel unwinds before the next gather" do
      assert {:cancelled, :user_stop} =
               Rollout.execute(rollout(), cancel?: fn -> {:requested, :user_stop} end)
    end

    test "a poll that discovers lease loss unwinds without a result" do
      assert :lost_lease =
               Rollout.execute(rollout(), cancel?: fn -> {:error, :lost_lease} end)
    end

    test "a transient poll failure does not kill a healthy run" do
      expect_stream(text_events("Fine"))

      assert {:ok, %Result.Completed{output: "Fine"}} =
               Rollout.execute(rollout(), cancel?: fn -> {:error, :db_down} end)
    end
  end

  describe "signals" do
    test "a mailboxed drain unwinds at the boundary" do
      send(self(), {:clementine, :drain})
      assert :drained = Rollout.execute(rollout())
    end

    test "a mailboxed lease-lost unwinds at the boundary" do
      send(self(), {:clementine, :lease_lost, :fake_lease})
      assert :lost_lease = Rollout.execute(rollout())
    end

    test "a mailboxed cancel push unwinds at the boundary" do
      send(self(), {:clementine, :cancel, :now_please})
      assert {:cancelled, :now_please} = Rollout.execute(rollout())
    end

    test "a signal surfaced mid-stream aborts the gather" do
      # ProviderStream translates a mailboxed runner signal into a {:signal, _}
      # stream event and halts; the engine unwinds on that event shape.
      expect_stream([{:text_delta, "par"}, {:signal, {:clementine, :drain}}])

      assert :drained = Rollout.execute(rollout())
    end

    test "matrix row 4: a cancel push mid token stream aborts the provider stream" do
      # The push flavor: ProviderStream kills the in-flight request and
      # surfaces the signal; the loop unwinds without finishing the gather —
      # no poll, no waiting for the model to stop talking.
      expect_stream([{:text_delta, "par"}, {:signal, {:clementine, :cancel, :user_stop}}])

      assert {:cancelled, :user_stop} = Rollout.execute(rollout())
    end

    test "a drain queued during the gather unwinds before the fence rises" do
      test = self()

      # The signal lands in the mailbox after the stream completed but
      # before act: it must be honored before the fence write and before
      # any tool task spawns — a pending drain must not forfeit requeue
      # eligibility.
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        send(self(), {:clementine, :drain})
        tool_events("tu_1", "echo", %{"message" => "never"})
      end)

      assert :drained =
               Rollout.execute(rollout(tools: [NotifyingEcho], context: %{notify: test}),
                 mark_effects: fn ->
                   send(test, {:mark, :fence})
                   :ok
                 end
               )

      refute_received {:mark, :fence}
      refute_received {:mark, :tool}
    end

    test "a cancel queued during the gather skips the batch entirely" do
      test = self()

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        send(self(), {:clementine, :cancel, :queued_stop})
        tool_events("tu_1", "echo", %{"message" => "never"})
      end)

      assert {:cancelled, :queued_stop} =
               Rollout.execute(rollout(tools: [NotifyingEcho], context: %{notify: test}))

      refute_received {:mark, :tool}
    end
  end

  describe "tool-batch cancellation (matrix row 5)" do
    test "matrix row 5: cancel during an unsafe tool kills safe siblings, unsafe runs out" do
      expect_stream([
        {:tool_use_start, "tu_1", "safe_push"},
        {:input_json_delta, "tu_1", "{}"},
        {:content_block_stop, 0},
        {:tool_use_start, "tu_2", "unsafe_slow"},
        {:input_json_delta, "tu_2", Jason.encode!(%{"delay_ms" => 80})},
        {:content_block_stop, 1},
        {:message_delta, %{"stop_reason" => "tool_use"},
         %{"input_tokens" => 5, "output_tokens" => 2}}
      ])

      started = System.monotonic_time(:millisecond)

      # SafePush delivers the cancel the moment it starts, then sleeps
      # forever — only the kill policy can settle this batch.
      assert {:cancelled, :mid_batch_stop} =
               Rollout.execute(
                 rollout(
                   tools: [SafePush, UnsafeSlow],
                   context: %{push_to: self(), notify: self()}
                 )
               )

      # The unsafe tool's effect settled coherently before the stop.
      assert_received {:unsafe_done, 80}
      # One provider call only (Mox verifies): the loop stopped before the
      # next gather, well under the safe tool's infinite sleep.
      assert System.monotonic_time(:millisecond) - started < 2_000
    end
  end

  describe "resume" do
    test "restores messages, iteration, and usage from a compatible checkpoint" do
      checkpoint = %Checkpoint{
        rollout_id: "r1",
        iteration: 2,
        messages: [UserMessage.new("go"), UserMessage.new("prior turn")],
        usage: %Usage{input_tokens: 10, output_tokens: 5}
      }

      expect_stream(text_events("Resumed answer"))

      assert {:ok, %Result.Completed{} = result} =
               Rollout.execute(rollout(), resume: {checkpoint, {:approved, %{}}})

      # rollout.messages is [] so only the input prefix is dropped; the
      # checkpoint's later messages count as generated.
      assert [%UserMessage{content: "prior turn"}, %{content: _}] = result.messages
      assert result.usage == %Usage{input_tokens: 17, output_tokens: 8}
    end

    test "preserves the iteration counter across the suspension" do
      checkpoint = %Checkpoint{rollout_id: "r1", iteration: 3, messages: []}

      assert {:error, %Error{code: :max_iterations}} =
               Rollout.execute(rollout(limits: [max_iterations: 3]),
                 resume: {checkpoint, :elapsed}
               )
    end

    test "matrix row 8: a checkpoint struct from another version is incompatible" do
      checkpoint = %Checkpoint{version: 2, rollout_id: "r1"}

      assert {:error, %Error{code: :incompatible_checkpoint, retryable?: false}} =
               Rollout.execute(rollout(), resume: {checkpoint, :elapsed})
    end

    test "matrix row 8: an encoded envelope with an unknown version is incompatible" do
      assert {:error, %Error{code: :incompatible_checkpoint}} =
               Rollout.execute(rollout(), resume: {%{"version" => 42}, :elapsed})
    end

    test "matrix row 8: checkpoint garbage decodes to the same clean error" do
      assert {:error, %Error{code: :incompatible_checkpoint}} =
               Rollout.execute(rollout(), resume: {:corrupted, :elapsed})
    end
  end

  describe "effect fence" do
    test "mark_effects fires once, before the first tool executes" do
      test = self()

      mark_effects = fn ->
        send(test, {:mark, :fence})
        :ok
      end

      expect_stream(tool_events("tu_1", "echo", %{"message" => "one"}))
      expect_stream(tool_events("tu_2", "echo", %{"message" => "two"}))
      expect_stream(text_events("Done"))

      context = %{notify: test}

      assert {:ok, %Result.Completed{}} =
               Rollout.execute(rollout(tools: [NotifyingEcho], context: context),
                 mark_effects: mark_effects
               )

      assert_received {:mark, :fence}
      assert_received {:mark, :tool}
      assert_received {:mark, :tool}
      # Exactly one fence write across both batches.
      refute_received {:mark, :fence}
    end

    test "a fence write that discovers lease loss unwinds before the batch runs" do
      test = self()
      expect_stream(tool_events("tu_1", "echo", %{"message" => "never"}))

      assert :lost_lease =
               Rollout.execute(rollout(tools: [NotifyingEcho], context: %{notify: test}),
                 mark_effects: fn -> {:error, :lost_lease} end
               )

      refute_received {:mark, :tool}
    end

    test "a fence write that fails transiently fails the run closed" do
      expect_stream(tool_events("tu_1", "echo", %{"message" => "never"}))

      assert {:error, %Error{}} =
               Rollout.execute(rollout(tools: [Echo]),
                 mark_effects: fn -> {:error, :db_down} end
               )
    end

    test "a batch of only retry: :safe tools leaves the fence down" do
      test = self()

      expect_stream(tool_events("tu_1", "safe_echo", %{"message" => "read-only"}))
      expect_stream(text_events("Done"))

      assert {:ok, %Result.Completed{}} =
               Rollout.execute(rollout(tools: [SafeEcho]),
                 mark_effects: fn ->
                   send(test, {:mark, :fence})
                   :ok
                 end
               )

      # The whole run stayed effect-free: still requeue-eligible.
      refute_received {:mark, :fence}
    end

    test "the fence rises at the first batch containing a non-:safe tool" do
      test = self()

      # Iteration 1: safe-only batch, no fence. Iteration 2: Echo declares
      # nothing, :unknown is :unsafe — the fence rises before it runs.
      expect_stream(tool_events("tu_1", "safe_echo", %{"message" => "look"}))
      expect_stream(tool_events("tu_2", "echo", %{"message" => "touch"}))
      expect_stream(text_events("Done"))

      assert {:ok, %Result.Completed{}} =
               Rollout.execute(rollout(tools: [SafeEcho, Echo]),
                 mark_effects: fn ->
                   send(test, {:mark, :fence})
                   :ok
                 end
               )

      assert_received {:mark, :fence}
      refute_received {:mark, :fence}
    end

    test "an unresolvable tool name cannot produce an effect and does not fence" do
      test = self()

      expect_stream(tool_events("tu_1", "ghost", %{}))
      expect_stream(text_events("Done"))

      assert {:ok, %Result.Completed{}} =
               Rollout.execute(rollout(tools: []),
                 mark_effects: fn ->
                   send(test, {:mark, :fence})
                   :ok
                 end
               )

      refute_received {:mark, :fence}
    end
  end

  describe "approval gate (act phase)" do
    test "a gated tool call suspends with the rollout's own loop state in the request" do
      expect_stream(tool_events("tu_1", "gated_deploy", %{"env" => "prod"}))

      assert {:suspend, %Suspension.Request{} = request} =
               Rollout.execute(rollout(tools: [GatedDeploy], context: %{notify: self()}))

      assert request.reason ==
               {:approval,
                %ApprovalRequest{
                  tool_use_id: "tu_1",
                  tool_name: "gated_deploy",
                  args: %{"env" => "prod"}
                }}

      assert request.pending == %Pending.ToolApproval{
               tool_use_id: "tu_1",
               tool_name: "gated_deploy",
               args: %{"env" => "prod"},
               completed_results: %{}
             }

      assert request.iteration == 1
      assert request.usage == %Usage{input_tokens: 5, output_tokens: 2}

      # The full transcript rides in the request, ending with the
      # assistant turn that issued the gated call.
      assert [%UserMessage{content: "go"}, %AssistantMessage{} = assistant] = request.messages

      assert [%Content.ToolUse{id: "tu_1", name: "gated_deploy"}] =
               AssistantMessage.get_tool_uses(assistant)

      # The gated call itself never ran.
      refute_received {:deployed, _args}
    end

    test "ungated siblings execute and ride in the checkpoint; only the gated call is pending" do
      expect_stream(
        batch_events([
          {"tu_1", "gated_deploy", %{"env" => "prod"}},
          {"tu_2", "echo", %{"message" => "hi"}}
        ])
      )

      assert {:suspend, %Suspension.Request{pending: pending}} =
               Rollout.execute(
                 rollout(tools: [GatedDeploy, Echo], context: %{notify: self()}),
                 emit: stamper()
               )

      assert pending.tool_use_id == "tu_1"

      assert pending.completed_results == %{
               "tu_2" => %ToolResult{content: "Echo: hi", is_error: false}
             }

      refute_received {:deployed, _args}

      # The sibling's execution is observable; the approval event itself is
      # the runner's to emit, only after the suspend commits.
      events = collect_events()
      assert Enum.any?(events, &(&1.type == :tool_result and &1.payload.tool_use_id == "tu_2"))
      refute Enum.any?(events, &(&1.type == :approval_requested))
    end

    test "a batch of only gated calls parks on the first with nothing settled" do
      expect_stream(
        batch_events([
          {"tu_1", "gated_deploy", %{"env" => "a"}},
          {"tu_2", "gated_deploy", %{"env" => "b"}}
        ])
      )

      assert {:suspend, %Suspension.Request{pending: pending}} =
               Rollout.execute(rollout(tools: [GatedDeploy], context: %{notify: self()}))

      assert pending.tool_use_id == "tu_1"
      assert pending.completed_results == %{}
      refute_received {:deployed, _args}
    end

    test "the fence keys to what executes now: a lone gated call leaves it down" do
      test = self()
      expect_stream(tool_events("tu_1", "gated_deploy", %{}))

      assert {:suspend, _request} =
               Rollout.execute(rollout(tools: [GatedDeploy]),
                 mark_effects: fn ->
                   send(test, {:mark, :fence})
                   :ok
                 end
               )

      # Nothing executed, so nothing may forfeit requeue eligibility.
      refute_received {:mark, :fence}
    end

    test "the fence rises for a non-safe sibling before the batch executes" do
      test = self()

      expect_stream(
        batch_events([
          {"tu_1", "gated_deploy", %{}},
          {"tu_2", "echo", %{"message" => "touch"}}
        ])
      )

      assert {:suspend, _request} =
               Rollout.execute(rollout(tools: [GatedDeploy, Echo]),
                 mark_effects: fn ->
                   send(test, {:mark, :fence})
                   :ok
                 end
               )

      assert_received {:mark, :fence}
    end

    test "safe-only siblings settle without raising the fence" do
      test = self()

      expect_stream(
        batch_events([
          {"tu_1", "gated_deploy", %{}},
          {"tu_2", "safe_echo", %{"message" => "read"}}
        ])
      )

      assert {:suspend, %Suspension.Request{pending: pending}} =
               Rollout.execute(rollout(tools: [GatedDeploy, SafeEcho]),
                 mark_effects: fn ->
                   send(test, {:mark, :fence})
                   :ok
                 end
               )

      assert %{"tu_2" => %ToolResult{content: "Echo: read"}} = pending.completed_results
      refute_received {:mark, :fence}
    end

    test "a {:policy, _} declaration gates exactly like :required" do
      expect_stream(tool_events("tu_1", "policy_gated", %{}))

      assert {:suspend, %Suspension.Request{pending: pending}} =
               Rollout.execute(rollout(tools: [PolicyGated], context: %{notify: self()}))

      assert pending.tool_name == "policy_gated"
      refute_received :policy_ran
    end

    test "a queued drain beats a gated batch: nothing executes, nothing parks" do
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        send(self(), {:clementine, :drain})
        tool_events("tu_1", "gated_deploy", %{})
      end)

      assert :drained =
               Rollout.execute(rollout(tools: [GatedDeploy], context: %{notify: self()}))

      refute_received {:deployed, _args}
    end
  end

  describe "resume (pending approval)" do
    test "an approved resume executes the pending call and the loop continues" do
      checkpoint = approval_checkpoint()
      expect_stream(text_events("Shipped!"))

      assert {:ok, %Result.Completed{} = result} =
               Rollout.execute(
                 rollout(tools: [GatedDeploy], context: %{notify: self()}),
                 resume: {checkpoint, {:approved, %{by: "u1"}}}
               )

      assert result.output == "Shipped!"
      assert_received {:deployed, %{env: "prod"}}

      # Generated messages: the checkpointed assistant turn, the settled
      # batch, the final answer — the input rides separately.
      assert [%AssistantMessage{}, %ToolResultMessage{content: [tool_result]}, _final] =
               result.messages

      assert %Content.ToolResult{tool_use_id: "tu_1", content: "deployed prod", is_error: false} =
               tool_result

      # Checkpointed usage plus the final gather.
      assert result.usage == %Usage{input_tokens: 17, output_tokens: 8}
    end

    test "an approved resume merges checkpointed sibling results in tool-use order" do
      checkpoint =
        approval_checkpoint(
          batch: [
            {"tu_1", "gated_deploy", %{"env" => "prod"}},
            {"tu_2", "echo", %{"message" => "hi"}}
          ],
          completed: %{"tu_2" => %ToolResult{content: "Echo: earlier", is_error: false}}
        )

      expect_stream(text_events("Done"))

      assert {:ok, %Result.Completed{} = result} =
               Rollout.execute(
                 rollout(tools: [GatedDeploy, Echo], context: %{notify: self()}),
                 resume: {checkpoint, {:approved, %{by: "u1"}}}
               )

      assert [_assistant, %ToolResultMessage{content: [first, second]}, _final] = result.messages
      assert %Content.ToolResult{tool_use_id: "tu_1", content: "deployed prod"} = first
      # The checkpointed content — not "Echo: hi" — proves the sibling did
      # not re-execute on resume.
      assert %Content.ToolResult{tool_use_id: "tu_2", content: "Echo: earlier"} = second
    end

    test "the fence rises before the approved call executes" do
      test = self()
      checkpoint = approval_checkpoint()
      expect_stream(text_events("Done"))

      assert {:ok, %Result.Completed{}} =
               Rollout.execute(
                 rollout(tools: [GatedDeploy], context: %{notify: test}),
                 resume: {checkpoint, {:approved, %{}}},
                 mark_effects: fn ->
                   send(test, {:mark, :fence})
                   :ok
                 end
               )

      # Strict mailbox order: the fence write precedes the effect.
      assert {:mark, :fence} =
               (receive do
                  message -> message
                after
                  0 -> flunk("expected the fence write")
                end)

      assert {:deployed, _args} =
               (receive do
                  message -> message
                after
                  0 -> flunk("expected the deploy")
                end)
    end

    test "an approved call declared retry: :safe leaves the fence down" do
      test = self()

      checkpoint = approval_checkpoint(batch: [{"tu_1", "safe_gated_lookup", %{}}])
      expect_stream(text_events("Done"))

      assert {:ok, %Result.Completed{} = result} =
               Rollout.execute(
                 rollout(tools: [SafeGatedLookup]),
                 resume: {checkpoint, {:approved, %{}}},
                 mark_effects: fn ->
                   send(test, {:mark, :fence})
                   :ok
                 end
               )

      assert [_assistant, %ToolResultMessage{content: [%Content.ToolResult{content: "42"}]}, _] =
               result.messages

      refute_received {:mark, :fence}
    end

    test "a denied resume synthesizes the approver's message; the tool never runs" do
      checkpoint = approval_checkpoint()
      expect_stream(text_events("Understood."))

      assert {:ok, %Result.Completed{} = result} =
               Rollout.execute(
                 rollout(tools: [GatedDeploy], context: %{notify: self()}),
                 resume: {checkpoint, {:denied, %{by: "u2", message: "not in prod"}}},
                 emit: stamper()
               )

      refute_received {:deployed, _args}

      assert [_assistant, %ToolResultMessage{content: [denial]}, _final] = result.messages

      assert %Content.ToolResult{tool_use_id: "tu_1", content: "not in prod", is_error: true} =
               denial

      # The synthesized result is observable exactly like an executed one.
      assert Enum.any?(
               collect_events(),
               &(&1.type == :tool_result and
                   &1.payload == %{
                     tool_use_id: "tu_1",
                     result: "not in prod",
                     is_error: true
                   })
             )
    end

    test "a denial without a message defaults to \"Denied by approver.\"" do
      checkpoint = approval_checkpoint()
      expect_stream(text_events("Okay."))

      assert {:ok, %Result.Completed{} = result} =
               Rollout.execute(
                 rollout(tools: [GatedDeploy], context: %{notify: self()}),
                 resume: {checkpoint, {:denied, %{by: "u2"}}}
               )

      assert [_assistant, %ToolResultMessage{content: [denial]}, _final] = result.messages

      assert %Content.ToolResult{content: "Denied by approver.", is_error: true} = denial
      refute_received {:deployed, _args}
    end

    test "matrix row 8: a pending tool absent from this rollout's toolset is incompatible" do
      checkpoint = approval_checkpoint()

      assert {:error, %Error{code: :incompatible_checkpoint, message: message}} =
               Rollout.execute(rollout(tools: []), resume: {checkpoint, {:approved, %{}}})

      assert message =~ "does not resolve"
    end

    test "a checkpoint that cannot support its own pending call is incompatible" do
      checkpoint = %Checkpoint{approval_checkpoint() | messages: [UserMessage.new("go")]}

      assert {:error, %Error{code: :incompatible_checkpoint, message: message}} =
               Rollout.execute(
                 rollout(tools: [GatedDeploy]),
                 resume: {checkpoint, {:approved, %{}}}
               )

      assert message =~ "last assistant message"
    end

    test "an unrecognized payload for a pending approval fails cleanly, never crashes" do
      checkpoint = approval_checkpoint()

      assert {:error, %Error{code: :invalid_resume_payload, retryable?: false}} =
               Rollout.execute(
                 rollout(tools: [GatedDeploy], context: %{notify: self()}),
                 resume: {checkpoint, :elapsed}
               )

      refute_received {:deployed, _args}
    end

    test "a second gated call parks the batch again with the first decision settled" do
      checkpoint =
        approval_checkpoint(
          batch: [
            {"tu_1", "gated_deploy", %{"env" => "a"}},
            {"tu_2", "gated_deploy", %{"env" => "b"}}
          ]
        )

      assert {:suspend, %Suspension.Request{pending: pending}} =
               Rollout.execute(
                 rollout(tools: [GatedDeploy], context: %{notify: self()}),
                 resume: {checkpoint, {:approved, %{by: "u1"}}}
               )

      # The first decision executed its call; the batch parked again on
      # the second, carrying the settled result — one decision at a time.
      assert_received {:deployed, %{env: "a"}}
      assert pending.tool_use_id == "tu_2"
      assert %{"tu_1" => %ToolResult{content: "deployed a"}} = pending.completed_results
      refute_received {:deployed, _args}
    end

    test "a signal queued at resume is honored before the approved call executes" do
      send(self(), {:clementine, :drain})
      checkpoint = approval_checkpoint()

      assert :drained =
               Rollout.execute(
                 rollout(tools: [GatedDeploy], context: %{notify: self()}),
                 resume: {checkpoint, {:approved, %{}}}
               )

      refute_received {:deployed, _args}
    end
  end

  describe "deadline caps" do
    test "the deadline caps the provider receive timeout to the remaining budget" do
      test = self()
      deadline = DateTime.add(DateTime.utc_now(), 60, :second)

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, opts ->
        send(test, {:stream_opts, opts})
        text_events("Fine")
      end)

      assert {:ok, %Result.Completed{}} = Rollout.execute(rollout(), deadline: deadline)

      assert_received {:stream_opts, opts}
      assert_in_delta Keyword.fetch!(opts, :receive_timeout), 60_000, 1_000
    end

    test "a distant deadline never extends the provider timeout past its default" do
      test = self()
      deadline = DateTime.add(DateTime.utc_now(), 3600, :second)

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, opts ->
        send(test, {:stream_opts, opts})
        text_events("Fine")
      end)

      assert {:ok, %Result.Completed{}} = Rollout.execute(rollout(), deadline: deadline)

      assert_received {:stream_opts, opts}
      assert Keyword.fetch!(opts, :receive_timeout) == :timer.minutes(5)
    end

    test "no deadline leaves the provider timeout to the client" do
      test = self()

      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, opts ->
        send(test, {:stream_opts, opts})
        text_events("Fine")
      end)

      assert {:ok, %Result.Completed{}} = Rollout.execute(rollout())

      assert_received {:stream_opts, opts}
      refute Keyword.has_key?(opts, :receive_timeout)
    end

    test "the deadline caps per-tool timeouts to the remaining budget" do
      deadline = DateTime.add(DateTime.utc_now(), 200, :millisecond)
      expect_stream(tool_events("tu_1", "slow", %{"delay_ms" => 10_000}))

      started = System.monotonic_time(:millisecond)

      # The capped tool times out around the deadline instant; the next
      # boundary converts that into the deadline failure — total run time
      # is bounded by the budget, not by the tool's own duration.
      assert {:error, %Error{code: :deadline_exceeded, retryable?: false}} =
               Rollout.execute(rollout(tools: [Slow]), deadline: deadline)

      assert System.monotonic_time(:millisecond) - started < 2_000
    end
  end

  describe "events" do
    test "the full loop emits stamped, gapless execution events" do
      expect_stream(tool_events("tu_1", "echo", %{"message" => "hi"}))
      expect_stream(text_events("Bye"))

      assert {:ok, %Result.Completed{}} =
               Rollout.execute(rollout(tools: [Echo]), emit: stamper())

      events = collect_events()

      assert Enum.map(events, & &1.type) == [
               :iteration_start,
               :tool_use_start,
               :tool_input_delta,
               :usage_delta,
               :tool_result,
               :iteration_start,
               :text_delta,
               :usage_delta
             ]

      assert Enum.map(events, & &1.seq) == Enum.to_list(1..8)
      assert Enum.all?(events, &(&1.epoch == 1))

      assert %Event{payload: %{tool_use_id: "tu_1", is_error: false}} =
               Enum.find(events, &(&1.type == :tool_result))
    end

    test "a failing gather emits a normalized error event last" do
      expect_stream([{:error, {:api_error, 500, "boom"}}])

      assert {:error, %Error{code: :provider_unavailable, retryable?: true} = error} =
               Rollout.execute(rollout(), emit: stamper())

      assert List.last(collect_events()) == %Event{
               run_ref: :unit_test_run,
               epoch: 1,
               seq: 2,
               type: :error,
               payload: %{error: error}
             }
    end
  end
end
