defmodule Clementine.Runs.StopsDurableTest do
  @moduledoc """
  A durable run's end on its final turn's stop reason, scripted through
  `Clementine.LLM.Anthropic.Fake`: a refusal and a final answer cut off
  at `max_tokens` each end the row `failed`, with the error's code, the
  host's `run_finished/2` hears the `Result.Failed`, the trace's last
  model call names the stop reason, and the run's telemetry says failed;
  a whole answer stores its stop reason beside its output.
  """

  use Clementine.RunsCase

  alias Clementine.{Error, Result}
  alias Clementine.LLM.Anthropic.Fake
  alias Clementine.Runs.Lifecycle
  alias Clementine.Trace.Entry

  @moduletag runtime: false

  setup do
    Process.register(self(), :clementine_runs_test)

    start_supervised!(
      {Clementine, repo: TestRepo, agents: [Echo], host: Clementine.RunsCase.Host}
    )

    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [
        [:clementine, :rollout, :stop],
        [:clementine, :rollout, :exception],
        [:clementine, :run, :finished]
      ],
      fn event, _measurements, metadata, _config -> send(test, {:telemetry, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp claude_turn(script, fake_opts) do
    expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
      Fake.stream(model, system, messages, tools, opts, script, fake_opts)
    end)
  end

  defp last_model_call(run_id) do
    run_id |> Runs.trace() |> Enum.filter(&(&1.kind == :model_call)) |> List.last()
  end

  for {stop_reason, code} <- [{"refusal", :refused}, {"max_tokens", :truncated}] do
    test "a final turn ending #{stop_reason} fails the run #{code}, on the row, the host, the trace, and telemetry" do
      stop_reason = unquote(stop_reason)
      code = unquote(code)
      code_string = Atom.to_string(code)

      {:ok, run} = Runs.start(Echo, "Answer this.")
      claude_turn([{:text, "The answer is"}], stop_reason: stop_reason)
      assert :ok = perform_job(Worker, %{"run_id" => run.id})

      run_id = run.id

      assert_received {:run_finished, %AgentRun{id: ^run_id},
                       %Result.Failed{error: %Error{code: ^code}}}

      assert %AgentRun{status: "failed", result: nil, error: %{"code" => ^code_string} = error} =
               Runs.get(run.id)

      assert error["kind"] == "rollout"

      assert %Result.Failed{error: %Error{code: ^code, raw: %{"stop_reason" => ^stop_reason}}} =
               Lifecycle.terminal_result(Runs.get(run.id))

      assert %Entry{payload: %{"stop_reason" => ^stop_reason}} = last_model_call(run.id)

      assert_received {:telemetry, [:clementine, :rollout, :exception],
                       %{error_code: ^code, agent_key: "test_echo"}}

      refute_received {:telemetry, [:clementine, :rollout, :stop], _metadata}
      assert_received {:telemetry, [:clementine, :run, :finished], %{terminal: :failed}}
    end
  end

  test "a cut inside a tool call fails the run :truncated, and the trace keeps the stop reason" do
    {:ok, run} = Runs.start(Echo, "Answer this.")
    claude_turn([{:unfinished_tool_use, "toolu_1", "echo", ~s({"message": "hal)}], [])
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert %AgentRun{status: "failed", error: %{"code" => "truncated"}} = Runs.get(run.id)

    assert %Result.Failed{
             error: %Error{raw: %{"unfinished_call" => %{"tool_use_id" => "toolu_1"}}}
           } =
             Lifecycle.terminal_result(Runs.get(run.id))

    assert %Entry{payload: %{"stop_reason" => "max_tokens"}} = last_model_call(run.id)
  end

  test "a run that writes nothing and calls no tools fails :empty" do
    {:ok, run} = Runs.start(Echo, "Answer this.")
    claude_turn([], [])
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert %AgentRun{status: "failed", error: %{"code" => "empty", "kind" => "rollout"}} =
             Runs.get(run.id)

    assert_received {:telemetry, [:clementine, :rollout, :exception], %{error_code: :empty}}
  end

  test "a whole answer stores its stop reason beside its output, and reads back with it" do
    {:ok, run} = Runs.start(Echo, "Answer this.")
    claude_turn([{:text, "Done."}], stop_reason: "stop_sequence")
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    run_id = run.id

    assert_received {:run_finished, %AgentRun{id: ^run_id},
                     %Result.Completed{output: "Done.", stop_reason: "stop_sequence"}}

    assert %AgentRun{
             status: "completed",
             result: %{"output" => "Done.", "stop_reason" => "stop_sequence"}
           } = Runs.get(run.id)

    assert %Result.Completed{output: "Done.", stop_reason: "stop_sequence"} =
             Lifecycle.terminal_result(Runs.get(run.id))

    assert_received {:telemetry, [:clementine, :rollout, :stop], %{status: :success}}
  end
end
