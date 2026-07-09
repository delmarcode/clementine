defmodule Clementine.Loop.LocalTest.FanOutLoop do
  @moduledoc false
  use Clementine.Loop, state_version: 1, vocabulary: [:fan]

  alias Clementine.Result

  def init(_args) do
    {:ok, %{"got" => []},
     [{:run, {:fan, 1}, %{"prompt" => "a"}}, {:run, {:fan, 2}, %{"prompt" => "b"}}]}
  end

  def handle({:completed, {:fan, i}, %Result.Completed{output: out}}, state) do
    got = state["got"] ++ ["#{i}:#{out}"]

    if length(got) == 2 do
      {:halt, Result.completed(output: Enum.join(got, ",")), %{state | "got" => got}}
    else
      {:ok, %{state | "got" => got}, []}
    end
  end
end

defmodule Clementine.Loop.LocalTest.TimerOrderLoop do
  @moduledoc false
  use Clementine.Loop, state_version: 1, vocabulary: [:tick]

  alias Clementine.Result

  # Slow armed first: fire order must follow deadlines, not arm order.
  def init(_args) do
    {:ok, %{"log" => []},
     [{:timer, {:tick, "slow"}, :timer.hours(1)}, {:timer, {:tick, "fast"}, :timer.minutes(1)}]}
  end

  def handle({:elapsed, {:tick, name}}, state) do
    log = state["log"] ++ [name]

    if length(log) == 2 do
      {:halt, Result.completed(output: Enum.join(log, ",")), %{state | "log" => log}}
    else
      {:ok, %{state | "log" => log}, []}
    end
  end
end

defmodule Clementine.Loop.LocalTest.TimerChildLoop do
  @moduledoc false
  use Clementine.Loop, state_version: 1, vocabulary: [:wait, :job]

  alias Clementine.Result

  def init(_args), do: {:ok, %{}, [{:timer, :wait, :timer.hours(1)}]}

  def handle({:elapsed, :wait}, state), do: {:ok, state, [{:run, {:job, 1}, %{}}]}

  def handle({:completed, {:job, 1}, result}, state) do
    output =
      case result do
        %Result.Completed{} -> "completed"
        %Result.Failed{error: error} -> "failed:#{error.code}"
      end

    {:halt, Result.completed(output: output), state}
  end
end

defmodule Clementine.Loop.LocalTest.SequenceLoop do
  @moduledoc false
  use Clementine.Loop, state_version: 1

  alias Clementine.Result

  def init(_args), do: {:ok, %{"log" => []}, []}

  def handle({:message, %{"halt" => true}}, state) do
    {:halt, Result.completed(output: Enum.join(state["log"], ",")), state}
  end

  def handle({:message, %{"id" => id}}, state) do
    {:ok, Map.update!(state, "log", &(&1 ++ ["#{id}"])), []}
  end
end

defmodule Clementine.Loop.LocalTest.CascadeLoop do
  @moduledoc false
  use Clementine.Loop, state_version: 1, vocabulary: [:fan]

  alias Clementine.Result

  def init(_args), do: {:ok, %{}, [{:run, {:fan, 1}, %{"prompt" => "x"}}]}

  def handle({:message, %{"halt" => output}}, state) do
    {:halt, Result.completed(output: output), state}
  end
end

defmodule Clementine.Loop.LocalTest.PoisonLoop do
  @moduledoc false
  use Clementine.Loop, state_version: 1

  alias Clementine.Result

  def init(_args), do: {:ok, %{"log" => []}, []}

  def handle({:message, %{"boom" => true}}, _state), do: raise("kaboom")

  def handle({:message, %{"id" => id}}, state) do
    {:ok, Map.update!(state, "log", &(&1 ++ ["#{id}"])), []}
  end

  def handle({:input_failed, _ref, error}, state) do
    log = state["log"] ++ ["input_failed:#{error.code}"]
    {:halt, Result.completed(output: Enum.join(log, ",")), %{state | "log" => log}}
  end
end

defmodule Clementine.Loop.LocalTest.SelfSendLoop do
  @moduledoc false
  use Clementine.Loop, state_version: 1

  alias Clementine.Result

  # run_local mints refs deterministically; the loop row is always ref 1.
  def init(_args), do: {:ok, %{}, [{:send, 1, %{"ping" => true}}]}

  def handle({:message, %{"ping" => true}}, state) do
    {:halt, Result.completed(output: "ponged"), state}
  end
end

defmodule Clementine.Loop.LocalTest.LostSendLoop do
  @moduledoc false
  use Clementine.Loop, state_version: 1

  def init(_args), do: {:ok, %{}, [{:send, 999, %{"hi" => true}}]}
  def handle(_input, state), do: {:ok, state, []}
end

defmodule Clementine.Loop.LocalTest do
  use ExUnit.Case, async: true

  import Mox

  alias Clementine.Lifecycle.Facts
  alias Clementine.Loop
  alias Clementine.Loop.Ecto.Codec, as: InboxCodec
  alias Clementine.Loop.Input
  alias Clementine.Loop.Runner, as: LoopRunner
  alias Clementine.Test.{JudgeLoop, MemoryLoopHost, ScriptedLoop}
  alias Clementine.{Result, Rollout, Run, Runner, Usage}

  alias Clementine.Loop.LocalTest.{
    CascadeLoop,
    FanOutLoop,
    LostSendLoop,
    PoisonLoop,
    SelfSendLoop,
    SequenceLoop,
    TimerChildLoop,
    TimerOrderLoop
  }

  @moduletag capture_log: true

  setup :verify_on_exit!

  describe "the judge loop (acceptance)" do
    test "runs deterministically, retry timer included" do
      attach_steps!()

      for _ <- 1..2 do
        expect_child("judged: fail")
        expect_child("judged: pass")
      end

      [first, second] =
        for _ <- 1..2 do
          {:ok, result} =
            Loop.run_local(JudgeLoop, %{"prompt" => "2 + 2?"}, build_child: judge_builder())

          {result, collect_steps()}
        end

      {result, steps} = first

      assert %Result.Completed{output: "spawn:1,fail:1,spawn:2,pass:2"} = result
      assert result.usage == %Usage{input_tokens: 14, output_tokens: 6}

      # One step per wake — spawn, judge-fail, retry-elapse, judge-pass —
      # each completion and elapse a separate drain: the hop is modeled.
      assert steps == [
               {:parked, :normal, 0},
               {:parked, :normal, 1},
               {:parked, :normal, 1},
               {:finished, :normal, 1}
             ]

      assert second == first
    end

    test "halts Failed when attempts exhaust — the halt result returns whatever variant" do
      for _ <- 1..3, do: expect_child("judged: fail")

      assert {:ok, %Result.Failed{} = result} =
               Loop.run_local(JudgeLoop, %{"prompt" => "2 + 2?"}, build_child: judge_builder())

      assert result.error.code == :attempts_exhausted

      assert result.error.message ==
               "spawn:1,fail:1,spawn:2,fail:2,spawn:3,fail:3,exhausted:3"

      assert result.usage == %Usage{input_tokens: 21, output_tokens: 9}
    end

    test "ordering matches a production trace for the same input script" do
      # The same script, twice: once through run_local, once through the
      # conformant in-memory production pairing — steps and children in
      # job order, the retry timer fired only at idle. The halt output
      # carries the loop's full decision trace, so equality here is
      # equality of consumption order, decisions, and the usage fold.
      expect_child("judged: fail")
      expect_child("judged: pass")

      {:ok, local_result} =
        Loop.run_local(JudgeLoop, %{"prompt" => "2 + 2?"}, build_child: judge_builder())

      expect_child("judged: fail")
      expect_child("judged: pass")

      production_result = drive_production!(%{"prompt" => "2 + 2?"})

      assert local_result == production_result
    end
  end

  describe "the modeled hop" do
    test "fan-out children execute in spawn order; completions drain as inputs, batched" do
      attach_steps!()
      expect_child("one")
      expect_child("two")

      assert {:ok, %Result.Completed{output: "1:one,2:two"}} =
               Loop.run_local(FanOutLoop, %{}, build_child: prompt_builder())

      # Both completions arrived through the inbox and folded in one
      # later drain — never handed to handle/2 inline at child finish.
      assert collect_steps() == [{:parked, :normal, 0}, {:finished, :normal, 2}]
    end

    test "a queued child is cancelled by the cascade before its job runs" do
      attach_steps!()

      # No :build_child: success proves the halt's cascade terminalized
      # the child inside the commit, so its job was skipped, never built.
      assert {:ok, %Result.Completed{output: "stopped", usage: %Usage{input_tokens: 0}}} =
               Loop.run_local(CascadeLoop, %{}, messages: [%{"halt" => "stopped"}])

      assert collect_steps() == [{:continued, :normal, 1}, {:finished, :cascade, 1}]
    end
  end

  describe "the virtual clock" do
    test "timers fire in deadline order, not arm order, jumping when idle" do
      # An hour of virtual time; wall time is milliseconds.
      assert {:ok, %Result.Completed{output: "fast,slow"}} =
               Loop.run_local(TimerOrderLoop, %{})
    end

    test "a cancelled timer never fires" do
      messages = [
        %{"id" => 1, "actions" => [{:timer, :poll, :timer.minutes(1)}]},
        %{"id" => 2, "actions" => [{:cancel_timer, :poll}]}
      ]

      assert {:error, {:parked, %Facts{status: :waiting}}} =
               Loop.run_local(ScriptedLoop, %{},
                 messages: messages,
                 policy: %{"batch_cap" => 1}
               )
    end

    test "a virtual jump does not slacken a child's max_duration belt" do
      # The child spawns after an hour-long virtual jump. Its 50ms
      # deadline is enforced by the rollout engine against wall time, so
      # the boundary check after a 100ms first Gather must trip — a
      # deadline minted off the virtual clock would sit an hour slack.
      expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        Process.sleep(100)

        [
          {:tool_use_start, "tu_1", "echo"},
          {:input_json_delta, "tu_1", Jason.encode!(%{"message" => "hi"})},
          {:content_block_stop, 0},
          {:message_delta, %{"stop_reason" => "tool_use"},
           %{"input_tokens" => 5, "output_tokens" => 2}}
        ]
      end)

      build = fn {:job, 1}, _args ->
        agent =
          Clementine.Agent.new(
            model: :claude_sonnet,
            instructions: "answer",
            tools: [Clementine.Test.Tools.Echo]
          )

        {:ok, Rollout.new(agent: agent, input: "go", limits: [max_duration: 50])}
      end

      assert {:ok, %Result.Completed{output: "failed:deadline_exceeded"}} =
               Loop.run_local(TimerChildLoop, %{}, build_child: build)
    end

    test "a self-re-arming watcher is bounded by :max_steps" do
      messages = [%{"id" => 1, "actions" => [{:timer, :poll, :timer.minutes(1)}]}]

      assert {:error, {:max_steps, 5}} =
               Loop.run_local(ScriptedLoop, %{}, messages: messages, max_steps: 5)
    end
  end

  describe "the inbox" do
    test "script messages consume in FIFO order" do
      assert {:ok, %Result.Completed{output: "1,2"}} =
               Loop.run_local(SequenceLoop, %{},
                 messages: [%{"id" => 1}, %{"id" => 2}, %{"halt" => true}]
               )
    end

    test "a payload outside the declared vocabulary raises at append, as against real storage" do
      assert_raise ArgumentError, ~r/vocabulary/, fn ->
        Loop.run_local(SequenceLoop, %{}, messages: [%{"bad" => :undeclared}])
      end
    end

    test "poison input dead-letters at the threshold and the loop survives it" do
      assert {:ok, %Result.Completed{output: "2,input_failed:input_dead_lettered"}} =
               Loop.run_local(PoisonLoop, %{},
                 messages: [%{"boom" => true}, %{"id" => 2}],
                 policy: %{"dead_letter_after" => 2}
               )
    end
  end

  describe "sends" do
    test "a self-send delivers through the inbox and the park re-check sees it" do
      attach_steps!()

      assert {:ok, %Result.Completed{output: "ponged"}} = Loop.run_local(SelfSendLoop, %{})

      # :continued, not :parked — the self-sent row was visible inside
      # the commit's own re-check and downgraded the park.
      assert collect_steps() == [{:continued, :normal, 0}, {:finished, :normal, 1}]
    end

    test "a send to a target that does not exist locally fails the step" do
      assert {:error, {:send_target_not_found, 999}} = Loop.run_local(LostSendLoop, %{})
    end
  end

  describe "the script surface" do
    test "a loop that parks with nothing in flight and no timers returns {:parked, facts}" do
      assert {:error, {:parked, %Facts{status: :waiting, kind: :loop}}} =
               Loop.run_local(SequenceLoop, %{}, messages: [%{"id" => 1}])
    end

    test "a module without the loop contract is refused" do
      assert {:error, {:incompatible_spec, %{reason: :not_a_loop}}} =
               Loop.run_local(Enum, %{})
    end

    test "a {:run, ...} action without :build_child raises with guidance" do
      assert_raise ArgumentError, ~r/build_child/, fn ->
        Loop.run_local(CascadeLoop, %{})
      end
    end
  end

  ## The production-shaped drive: the conformant in-memory host pairing,
  ## jobs processed in ledger order, children as real runs, the timer
  ## fired only when nothing else is runnable — one legal production
  ## trace for the same script.

  defp drive_production!(args) do
    store = MemoryLoopHost.start_store()

    {:ok, %Facts{ref: loop_ref}} =
      Loop.Protocol.create(
        MemoryLoopHost,
        %{module: JudgeLoop, scope: "judge-production", args: args},
        ctx: store
      )

    drive_production!(store, loop_ref, MapSet.new())
  end

  defp drive_production!(store, loop_ref, processed) do
    jobs = store |> MemoryLoopHost.jobs!() |> Enum.with_index()
    runnable = Enum.find(jobs, fn {job, i} -> i not in processed and job.kind != "timer" end)

    case runnable do
      {%{kind: "step"}, i} ->
        outcome =
          LoopRunner.step(loop_ref,
            host: MemoryLoopHost,
            lifecycle: MemoryLoopHost,
            executor_id: "production:step",
            ctx: store
          )

        case outcome do
          {:finished, %Facts{}} ->
            {^loop_ref, result} =
              store |> MemoryLoopHost.projections() |> Enum.find(&(elem(&1, 0) == loop_ref))

            result

          _continue_or_park ->
            drive_production!(store, loop_ref, MapSet.put(processed, i))
        end

      {%{kind: "child", run_ref: child_ref}, i} ->
        run = Run.new(ref: child_ref, rollout: build_rollout("2 + 2?"))

        {:finished, %Facts{}} =
          Runner.execute(run,
            lifecycle: MemoryLoopHost,
            ctx: store,
            executor_id: "production:child",
            heartbeat: false
          )

        drive_production!(store, loop_ref, MapSet.put(processed, i))

      nil ->
        {%{args: %{"tag_key" => tag_key}}, i} =
          Enum.find(jobs, fn {job, i} -> i not in processed and job.kind == "timer" end) ||
            flunk("production drive stuck: no runnable job and no timer to fire")

        tag = InboxCodec.decode_tag(tag_key, vocabulary: JudgeLoop.__loop__(:vocabulary))

        {:ok, :appended} =
          MemoryLoopHost.append(
            loop_ref,
            Input.elapsed(tag),
            InboxCodec.elapsed_dedup_key(tag_key, i),
            store
          )

        drive_production!(store, loop_ref, MapSet.put(processed, i))
    end
  end

  ## Children

  defp judge_builder do
    fn {:attempt, _n}, args -> {:ok, build_rollout(args["prompt"])} end
  end

  defp prompt_builder do
    fn _tag, args -> {:ok, build_rollout(args["prompt"])} end
  end

  defp build_rollout(input) do
    agent = Clementine.Agent.new(model: :claude_sonnet, instructions: "answer briefly")
    Rollout.new(agent: agent, input: input)
  end

  defp expect_child(text) do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      [
        {:text_delta, text},
        {:message_delta, %{"stop_reason" => "end_turn"},
         %{"input_tokens" => 7, "output_tokens" => 3}}
      ]
    end)
  end

  ## Step observation — handler filtered to this process, so parallel
  ## tests' loops (every run_local loop is ref 1 in its own store) stay
  ## out of each other's mailboxes.

  defp attach_steps! do
    pid = self()
    handler = "loop-local-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:clementine, :loop, :step],
      fn _event, _measurements, meta, _config ->
        if self() == pid, do: send(pid, {:step, meta.outcome, meta.mode, meta.batch})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp collect_steps(acc \\ []) do
    receive do
      {:step, outcome, mode, batch} -> collect_steps(acc ++ [{outcome, mode, batch}])
    after
      0 -> acc
    end
  end
end
