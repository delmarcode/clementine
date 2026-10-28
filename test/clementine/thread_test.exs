defmodule Clementine.ThreadTest do
  @moduledoc """
  `Clementine.Thread` on the script path (`Clementine.Loop.run_local/3`):
  queue, interrupt, surface, retry, retry-interrupted, and poison, each
  observed through the children the thread asked for and the model calls
  they made; then the decision table on its own, where the script path
  cannot reach (a turn interrupted twice, a stale fire, bad args).
  """

  use ExUnit.Case, async: true

  import Mox

  alias Clementine.Lifecycle.Facts
  alias Clementine.{Error, Loop, Result, Rollout, Thread}

  @moduletag capture_log: true

  setup :verify_on_exit!

  defmodule DrainTool do
    @moduledoc false
    # An effectful tool that tells the run's process to drain, mid-run:
    # the one way a script-path child ends Interrupted (the runner's
    # drain-with-effects path), since no reaper runs here.
    use Clementine.Tool,
      name: "drain",
      description: "Drains the node.",
      retry: :unsafe,
      parameters: []

    @impl true
    def run(_args, _context) do
      send(Process.whereis(:clementine_thread_test), {:clementine, :drain})
      {:ok, "draining"}
    end
  end

  describe "run_local: queue" do
    test "two messages are two turns, in order, the second started once the first ended" do
      expect_answer("first answer")
      expect_answer("second answer")

      assert {:error, {:parked, %Facts{status: :waiting}}} =
               run_thread(%{"agent" => "chat"}, [message("m1", "one"), message("m2", "two")])

      assert spawns() == [{{:turn, "m1"}, "one"}, {{:turn, "m2"}, "two"}]
      assert prompts_seen() == ["one", "two"]
    end

    test "a message carries its metadata and actor to the turn; one without an id is counted" do
      expect_answer("ok")
      expect_answer("ok")

      run_thread(%{"agent" => "chat"}, [
        %{"prompt" => "a", "metadata" => %{"message_id" => 9}, "actor" => ["user", "u-2"]},
        %{"prompt" => "b"}
      ])

      assert_received {:spawn, {:turn, 1},
                       %{
                         "agent" => "chat",
                         "prompt" => "a",
                         "metadata" => %{"message_id" => 9},
                         "actor" => ["user", "u-2"]
                       } = first}

      refute Map.has_key?(first, "subject")
      assert_received {:spawn, {:turn, 2}, %{"prompt" => "b", "metadata" => %{}} = second}
      refute Map.has_key?(second, "actor")
    end
  end

  describe "run_local: interrupt" do
    test "a message behind another in one step cancels the turn before it exists: only the newer one runs" do
      expect_answer("answer to two")

      assert {:error, {:parked, %Facts{status: :waiting}}} =
               run_thread(%{"agent" => "chat", "busy" => "interrupt"}, [
                 message("m1", "one"),
                 message("m2", "two")
               ])

      assert spawns() == [{{:turn, "m2"}, "two"}]
      assert prompts_seen() == ["two"]
    end

    test "a message arriving while a committed turn stands cancels it and takes its place" do
      # batch_cap 1 commits the first turn before the second message is
      # read; the script path runs the child before the next step, so the
      # cancel finds it ended and the thread goes on to the newer message.
      expect_answer("answer to one")
      expect_answer("answer to two")

      run_thread(
        %{"agent" => "chat", "busy" => "interrupt"},
        [message("m1", "one"), message("m2", "two")],
        policy: %{"batch_cap" => 1}
      )

      assert spawns() == [{{:turn, "m1"}, "one"}, {{:turn, "m2"}, "two"}]
    end
  end

  describe "run_local: on_failure" do
    test "surface: a failed turn is over; the next message is answered" do
      expect_failure()
      expect_answer("two")

      run_thread(%{"agent" => "chat"}, [message("m1", "one"), message("m2", "two")])

      assert spawns() == [{{:turn, "m1"}, "one"}, {{:turn, "m2"}, "two"}]
    end

    test "retry: a failed turn runs again under the same tag after the delay, then the queue moves" do
      expect_failure()
      expect_answer("one, retried")
      expect_answer("two")

      run_thread(
        %{"agent" => "chat", "on_failure" => "retry", "retry_after_ms" => :timer.minutes(5)},
        [message("m1", "one"), message("m2", "two")]
      )

      assert spawns() == [{{:turn, "m1"}, "one"}, {{:turn, "m1"}, "one"}, {{:turn, "m2"}, "two"}]
    end

    test "retry: the retry fails too; the turn is over" do
      expect_failure()
      expect_failure()
      expect_answer("two")

      run_thread(%{"agent" => "chat", "on_failure" => "retry", "retry_after_ms" => 1_000}, [
        message("m1", "one"),
        message("m2", "two")
      ])

      assert spawns() == [{{:turn, "m1"}, "one"}, {{:turn, "m1"}, "one"}, {{:turn, "m2"}, "two"}]
    end
  end

  describe "run_local: retry_interrupted" do
    setup do
      Process.register(self(), :clementine_thread_test)
      :ok
    end

    test "an interrupted turn runs again at once, under the same tag" do
      expect_drain()
      expect_answer("one, after the restart")

      run_thread(%{"agent" => "chat"}, [message("m1", "one")], tools: [DrainTool])

      assert spawns() == [{{:turn, "m1"}, "one"}, {{:turn, "m1"}, "one"}]
    end

    test "retry_interrupted false: the interrupted turn is over" do
      expect_drain()
      expect_answer("two")

      run_thread(
        %{"agent" => "chat", "retry_interrupted" => false},
        [message("m1", "one"), message("m2", "two")],
        tools: [DrainTool]
      )

      assert spawns() == [{{:turn, "m1"}, "one"}, {{:turn, "m2"}, "two"}]
    end
  end

  describe "run_local: poison" do
    test "a message without a prompt dead-letters at the threshold; the thread answers the rest" do
      expect_answer("one")
      expect_answer("two")

      assert {:error, {:parked, %Facts{status: :waiting}}} =
               run_thread(%{"agent" => "chat"}, [
                 message("m1", "one"),
                 %{"nope" => true},
                 message("m2", "two")
               ])

      assert spawns() == [{{:turn, "m1"}, "one"}, {{:turn, "m2"}, "two"}]
    end
  end

  describe "init/1" do
    test "defaults: queue, surface, five minutes, retry interrupted" do
      assert {:ok, state, []} = Thread.init(%{"agent" => "chat"})

      assert state == %{
               "agent" => "chat",
               "busy" => "queue",
               "on_failure" => "surface",
               "retry_after_ms" => 300_000,
               "retry_interrupted" => true,
               "turn" => nil,
               "queue" => [],
               "seq" => 0
             }
    end

    test "args outside the contract halt the loop failed, naming the problem" do
      for {args, message} <- [
            {%{}, ~r/needs an "agent"/},
            {%{"agent" => ""}, ~r/needs an "agent"/},
            {%{"agent" => "chat", "busy" => "drop"}, ~r/"busy" must be one of/},
            {%{"agent" => "chat", "on_failure" => "crash"}, ~r/"on_failure" must be one of/},
            {%{"agent" => "chat", "retry_after_ms" => -1}, ~r/"retry_after_ms"/},
            {%{"agent" => "chat", "retry_interrupted" => "yes"}, ~r/"retry_interrupted"/},
            {%{"agent" => "chat", "retry_on_failure" => true}, ~r/unknown thread args/}
          ] do
        assert {:halt, %Result.Failed{error: %Error{code: :invalid_args, message: text}}} =
                 Thread.init(args)

        assert text =~ message
      end
    end
  end

  describe "handle/2" do
    test "a turn whose node died runs again once; a second interruption ends it" do
      {:ok, state, [{:run, {:turn, "m1"}, _}]} =
        Thread.handle({:message, message("m1", "one")}, idle())

      assert {:ok, state, [{:run, {:turn, "m1"}, %{"prompt" => "one"}}]} =
               Thread.handle(
                 {:completed, {:turn, "m1"}, Result.interrupted(:lease_expired)},
                 state
               )

      assert state["turn"]["retried"] == true

      assert {:ok, %{"turn" => nil}, []} =
               Thread.handle(
                 {:completed, {:turn, "m1"}, Result.interrupted(:lease_expired)},
                 state
               )
    end

    test "a retried turn that fails is not retried again, whatever the policy" do
      state = idle(%{"on_failure" => "retry"})
      {:ok, state, _} = Thread.handle({:message, message("m1", "one")}, state)

      {:ok, state, _} =
        Thread.handle({:completed, {:turn, "m1"}, Result.interrupted(:lease_expired)}, state)

      assert {:ok, %{"turn" => nil}, []} =
               Thread.handle({:completed, {:turn, "m1"}, Result.failed(:boom)}, state)
    end

    test "interrupt during a retry wait drops the retry and runs the new message now" do
      state = idle(%{"busy" => "interrupt", "on_failure" => "retry"})
      {:ok, state, _} = Thread.handle({:message, message("m1", "one")}, state)

      {:ok, state, [{:timer, {:retry, "m1"}, 300_000}]} =
        Thread.handle({:completed, {:turn, "m1"}, Result.failed(:boom)}, state)

      assert {:ok, state,
              [{:cancel_timer, {:retry, "m1"}}, {:run, {:turn, "m2"}, %{"prompt" => "two"}}]} =
               Thread.handle({:message, message("m2", "two")}, state)

      assert state["turn"]["id"] == "m2"
      assert state["queue"] == []

      # The fire that lost the race is nothing to decide on.
      assert {:ok, ^state, []} = Thread.handle({:elapsed, {:retry, "m1"}}, state)
    end

    test "a turn cancelled for an interrupt ends however it ends: no retry, the queue moves" do
      state = idle(%{"busy" => "interrupt", "on_failure" => "retry"})
      {:ok, state, _} = Thread.handle({:message, message("m1", "one")}, state)

      assert {:ok, state, [{:cancel, {:turn, "m1"}}]} =
               Thread.handle({:message, message("m2", "two")}, state)

      assert state["turn"]["phase"] == "interrupting"

      # A third message while the cancel is in flight waits its turn.
      assert {:ok, state, []} = Thread.handle({:message, message("m3", "three")}, state)
      assert Enum.map(state["queue"], & &1["id"]) == ["m2", "m3"]

      # The turn failed before the flag landed: still no retry.
      assert {:ok, state, [{:run, {:turn, "m2"}, _}]} =
               Thread.handle({:completed, {:turn, "m1"}, Result.failed(:boom)}, state)

      assert {:ok, state, [{:run, {:turn, "m3"}, _}]} =
               Thread.handle({:completed, {:turn, "m2"}, Result.completed(output: "ok")}, state)

      assert {:ok, %{"turn" => nil, "queue" => []}, []} =
               Thread.handle({:completed, {:turn, "m3"}, Result.completed(output: "ok")}, state)
    end

    test "a completion for a turn the thread no longer tracks changes nothing" do
      {:ok, state, _} = Thread.handle({:message, message("m1", "one")}, idle())

      assert {:ok, ^state, []} =
               Thread.handle({:completed, {:turn, "ghost"}, Result.completed()}, state)
    end

    test "poison evidence is acknowledged and ignored" do
      state = idle()
      error = %Error{code: :input_dead_lettered}
      assert {:ok, ^state, []} = Thread.handle({:input_failed, 7, error}, state)
    end

    test "a message outside the contract raises, toward the poison path" do
      for bad <- [
            "a string",
            %{},
            %{"prompt" => "  "},
            %{"prompt" => "x", "id" => 1.5},
            %{"prompt" => "x", "id" => " "},
            %{"prompt" => "x", "metadata" => "no"},
            %{"prompt" => "x", "metadata" => %{"extra" => {:turn, 1}}},
            %{"prompt" => "x", "actor" => "user"},
            %{"prompt" => "x", "actor" => ["", "u-1"]},
            %{"prompt" => "x", "actor" => ["user", ""]},
            %{"prompt" => "x", "actor" => ["user", nil]}
          ] do
        assert_raise ArgumentError, fn -> Thread.handle({:message, bad}, idle()) end
      end
    end

    test "a queued message the turn's row would refuse is blamed at the message, never at the running turn's completion" do
      # The inbox codec round-trips the loop's vocabulary and Ecto's cast
      # turns "" into NULL, so each of these reaches handle/2 whole and
      # would be refused only at the row's insert. Accepted into the queue,
      # it would fail at its own {:run, ...}, in the drain that folds the
      # running turn's completion, blaming that innocent input and wedging
      # the thread behind a dead-lettered completion.
      {:ok, running, [_spawn]} = Thread.handle({:message, %{"prompt" => "a"}}, idle())

      for bad <- [
            %{"prompt" => "b", "metadata" => %{"extra" => {:turn, 1}}},
            %{"prompt" => "b", "id" => ""},
            %{"prompt" => "b", "actor" => ["", "u-1"]}
          ] do
        assert_raise ArgumentError, fn -> Thread.handle({:message, bad}, running) end
      end
    end
  end

  ## The script

  defp run_thread(args, messages, opts \\ []) do
    test = self()
    tools = Keyword.get(opts, :tools, [])

    build = fn tag, child ->
      send(test, {:spawn, tag, child})
      agent = Clementine.Agent.new(model: :claude_sonnet, instructions: "Answer.", tools: tools)
      {:ok, Rollout.new(agent: agent, input: child["prompt"])}
    end

    Loop.run_local(
      Thread,
      args,
      Keyword.merge([messages: messages, build_child: build], Keyword.drop(opts, [:tools]))
    )
  end

  defp message(id, prompt), do: %{"id" => id, "prompt" => prompt}

  defp idle(overrides \\ %{}) do
    {:ok, state, []} = Thread.init(Map.merge(%{"agent" => "chat"}, overrides))
    state
  end

  defp spawns(acc \\ []) do
    receive do
      {:spawn, tag, child} -> spawns([{tag, child["prompt"]} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp prompts_seen(acc \\ []) do
    receive do
      {:prompt, prompt} -> prompts_seen([prompt | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  ## The model

  defp expect_answer(text) do
    test = self()

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      send(test, {:prompt, List.last(messages).content})

      [
        {:text_delta, text},
        {:message_delta, %{"stop_reason" => "end_turn"},
         %{"input_tokens" => 7, "output_tokens" => 3}}
      ]
    end)
  end

  # A provider client bug: the engine's rescue tier ends the child Failed.
  defp expect_failure do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      [{:text_delta, :not_a_binary}]
    end)
  end

  # The model calls the drain tool, whose effect is the drain signal; the
  # boundary after it finds the signal, and the effects already marked
  # make the drain an Interrupted end rather than a requeue.
  defp expect_drain do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      [
        {:tool_use_start, "tu_drain", "drain"},
        {:input_json_delta, "tu_drain", "{}"},
        {:content_block_stop, 0},
        {:message_delta, %{"stop_reason" => "tool_use"},
         %{"input_tokens" => 5, "output_tokens" => 2}}
      ]
    end)
  end
end
