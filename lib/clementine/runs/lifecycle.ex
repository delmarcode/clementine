if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Lifecycle do
    @moduledoc false
    # The storage contract between the durable-execution protocol and
    # agent_runs: the Ecto adapter's guarded compare-and-swap writes, with
    # the repo the child spec named. The projection runs inside the
    # transaction that makes a run terminal: it stores a completed run's
    # output, queues the host's run_committed/2 for after the commit, and
    # hands the result to the host's run_finished/2. Every other committed
    # change reaches the host's run_transition/2, after its commit.

    @behaviour Clementine.Lifecycle
    @behaviour Clementine.Lifecycle.Ecto

    import Ecto.Query, only: [from: 2]

    require Logger

    alias Clementine.Emissions
    alias Clementine.Lifecycle.Ecto, as: EctoLifecycle
    alias Clementine.Lifecycle.Ecto.Codec
    alias Clementine.Lifecycle.{Facts, Transition}
    alias Clementine.Result
    alias Clementine.Runs.{AgentRun, Config, Courier}

    # Liveness and the effects fence are the runtime's bookkeeping.
    @quiet_ops [:heartbeat, :mark_effects]

    # What the host's run_transition/2 hears for each other write that
    # leaves a run unfinished.
    @transitions %{
      claim: :claimed,
      suspend: :suspended,
      resume: :resumed,
      requeue: :requeued,
      cancel_request: :cancel_requested
    }

    @doc false
    def __clementine_config__, do: Config.fetch!().lifecycle

    @impl Clementine.Lifecycle
    def fetch(run_ref, ctx), do: EctoLifecycle.fetch(__MODULE__, run_ref, ctx)

    @impl Clementine.Lifecycle
    def apply(transition, ctx) do
      flush_events(transition, ctx)
      EctoLifecycle.apply_transition(__MODULE__, transition, ctx)
    end

    # Before the run's own process writes a transition, every event it
    # emitted has reached the host's run_event/2, so the host hears of the
    # transition after the events that led to it. Heartbeats come from
    # another process, and neither they nor the effects fence reach the
    # host.
    defp flush_events(%Transition{op: op}, %{courier: %Courier{} = courier})
         when op not in @quiet_ops,
         do: Courier.flush(courier)

    defp flush_events(_transition, _ctx), do: :ok

    @impl Clementine.Lifecycle.Ecto
    def project(result, %AgentRun{} = run, _ctx) do
      %Config{repo: repo, host: host} = Config.fetch!()
      run = store_output(repo, result, run)

      # The adapter brackets this transaction for emissions: this one
      # fires once the transaction commits and is dropped if it rolls
      # back, including when run_finished/2 raises below.
      if exports?(host, :run_committed) do
        Emissions.emit(fn -> run_committed(host, run, result) end)
      end

      if exports?(host, :run_finished), do: host.run_finished(run, result)

      :ok
    end

    # The adapter calls this once the transition's transaction commits
    # (the outermost one, while Clementine.Emissions brackets it). An end
    # reaches the host through run_committed/2 instead, with its result.
    @impl Clementine.Lifecycle.Ecto
    def after_transition(%Facts{} = facts, %Transition{op: op}, ctx)
        when op not in @quiet_ops do
      %Config{repo: repo, host: host} = Config.fetch!()

      with true <- exports?(host, :run_transition),
           false <- Facts.terminal?(facts),
           {:ok, transition} <- Map.fetch(@transitions, op),
           %AgentRun{} = run <- transition_run(repo, facts, ctx) do
        run_transition(host, run, transition)
      end

      :ok
    end

    def after_transition(_facts, _transition, _ctx), do: :ok

    # The worker's own writes carry the run in their ctx; the control
    # plane's and the reaper's read it. Either way, its status is the one
    # this transition committed.
    defp transition_run(repo, %Facts{} = facts, ctx) do
      run =
        case ctx do
          %{run: %AgentRun{} = run} -> run
          _other -> repo.get(AgentRun, facts.ref)
        end

      run && %{run | status: Codec.encode_status(facts.status)}
    end

    defp store_output(repo, %Result.Completed{output: output}, run) do
      result = %{"output" => output}
      {1, _} = repo.update_all(from(r in AgentRun, where: r.id == ^run.id), set: [result: result])
      %{run | result: result}
    end

    defp store_output(_repo, _result, run), do: run

    defp exports?(nil, _callback), do: false
    defp exports?(host, callback), do: function_exported?(host, callback, 2)

    # The write is committed: a failing notification is logged and goes no
    # further, or it would fail (and retry) a write that already happened.
    defp run_committed(host, run, result) do
      host.run_committed(run, result)
    rescue
      e ->
        Logger.error(
          "#{inspect(host)}.run_committed/2 raised: #{Exception.message(e)} (run: #{run.id})"
        )
    catch
      kind, reason ->
        Logger.error(
          "#{inspect(host)}.run_committed/2 #{kind}: #{inspect(reason)} (run: #{run.id})"
        )
    end

    defp run_transition(host, run, transition) do
      host.run_transition(run, transition)
    rescue
      e ->
        Logger.error(
          "#{inspect(host)}.run_transition/2 raised: #{Exception.message(e)} " <>
            "(run: #{run.id}, transition: #{transition})"
        )
    catch
      kind, reason ->
        Logger.error(
          "#{inspect(host)}.run_transition/2 #{kind}: #{inspect(reason)} " <>
            "(run: #{run.id}, transition: #{transition})"
        )
    end
  end
end
