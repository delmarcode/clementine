if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Lifecycle do
    @moduledoc false
    # The storage contract between the durable-execution protocol and
    # agent_runs: the Ecto adapter's guarded compare-and-swap writes, with
    # the repo the child spec named. The projection runs inside the
    # transaction that makes a run terminal: it stores a completed run's
    # output, queues the host's run_committed/2 for after the commit, and
    # hands the result to the host's run_finished/2. Every other committed
    # change reaches the host's run_transition/2, after its commit, and a
    # committed cancel flag goes on to the run's runner (CancelRelay).

    @behaviour Clementine.Lifecycle
    @behaviour Clementine.Lifecycle.Ecto

    import Ecto.Query, only: [from: 2]

    require Logger

    alias Clementine.{Emissions, Lease, Result}
    alias Clementine.Lifecycle.Ecto, as: EctoLifecycle
    alias Clementine.Lifecycle.Ecto.Codec
    alias Clementine.Lifecycle.{Facts, Transition}
    alias Clementine.Runs.{AgentRun, CancelRelay, Config, Courier, Loops}

    # Liveness, the trace, and the effects fence are the runtime's
    # bookkeeping.
    @quiet_ops [:heartbeat, :record_trace, :mark_effects]

    @trace "agent_run_trace"

    # What the host's run_transition/2 hears for each other write that
    # leaves a run unfinished.
    @transitions %{
      claim: :claimed,
      suspend: :suspended,
      resume: :resumed,
      requeue: :requeued,
      cancel_request: :cancel_requested
    }

    @fields Codec.resolve_fields(:id, [])

    @doc false
    def __clementine_config__, do: Config.fetch!().lifecycle

    @impl Clementine.Lifecycle
    def fetch(run_ref, ctx), do: EctoLifecycle.fetch(__MODULE__, run_ref, ctx)

    @impl Clementine.Lifecycle
    def apply(transition, ctx) do
      flush_events(transition, ctx)
      EctoLifecycle.apply_transition(__MODULE__, transition, ctx)
    end

    # The runner subscribes once it holds the run: a cancel flag committed
    # from then on reaches it at once, from any node.
    @impl Clementine.Lifecycle
    def subscribe_cancel(%Lease{run_ref: run_id, epoch: epoch}),
      do: CancelRelay.subscribe(run_id, epoch)

    # Before the run's own process writes a transition, every event it
    # emitted has reached the host's run_event/2, so the host hears of the
    # transition after the events that led to it. Heartbeats come from
    # another process, and neither they nor the effects fence reach the
    # host.
    defp flush_events(%Transition{op: op}, %{courier: %Courier{} = courier})
         when op not in @quiet_ops,
         do: Courier.flush(courier)

    defp flush_events(_transition, _ctx), do: :ok

    # A write's trace entries go to agent_run_trace in its transaction, so
    # they commit with the write and the projection below sees them.
    # inserted_at is the storage clock's, as the column's default. An
    # entry is (run, epoch, seq), unique in the table: entries a write
    # carries again after an earlier one committed unheard (a dropped
    # connection at COMMIT, then the end carrying them as pending) are
    # already there and insert nothing.
    @impl Clementine.Lifecycle.Ecto
    def record_trace(entries, %AgentRun{id: run_id}, _ctx) do
      %Config{repo: repo} = Config.fetch!()
      id = Ecto.UUID.dump!(run_id)

      rows =
        Enum.map(entries, fn entry ->
          %{
            run_id: id,
            epoch: entry.epoch,
            seq: entry.seq,
            kind: to_string(entry.kind),
            payload: entry.payload
          }
        end)

      {_count, _} = repo.insert_all(@trace, rows, on_conflict: :nothing)
      :ok
    end

    @impl Clementine.Lifecycle.Ecto
    def project(result, %AgentRun{} = run, _ctx) do
      %Config{repo: repo, host: host} = Config.fetch!()
      run = store_output(repo, result, run)

      # A loop's child tells its loop inside this same transaction: the
      # completion is exactly-once at source, because a terminal is a
      # dead end (LOOP_RFC L12).
      if run.parent_id, do: Loops.append_completion(run, result)

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
    # reaches the host through run_committed/2 instead, with its result;
    # a child's end also wakes its loop, best-effort, the completion
    # being durable already.
    #
    # A cancel flag reaches the host before its runner, so the host never
    # hears of the flag after the end it causes.
    @impl Clementine.Lifecycle.Ecto
    def after_transition(%Facts{} = facts, %Transition{op: op}, ctx)
        when op not in @quiet_ops do
      %Config{repo: repo, oban: oban} = config = Config.fetch!()

      if Facts.terminal?(facts) do
        with %AgentRun{parent_id: parent_id} = run when is_binary(parent_id) <-
               transition_run(repo, facts, ctx) do
          Loops.wake_parent(run)
        end
      else
        with {:ok, transition} <- Map.fetch(@transitions, op) do
          hear(config, facts, transition, ctx)
          if transition == :cancel_requested, do: CancelRelay.push(facts, oban)
        end
      end

      :ok
    end

    def after_transition(_facts, _transition, _ctx), do: :ok

    @doc false
    # A change the loop machinery wrote outside the protocol (a wake, a
    # loop's cancel flag), for the host's run_transition/2. Called after
    # the write commits, or deferred until it does.
    @spec notify_transition(Facts.t(), Clementine.Host.transition()) :: :ok
    def notify_transition(%Facts{} = facts, transition) do
      hear(Config.fetch!(), facts, transition, nil)
      :ok
    end

    # The host's run_transition/2 hears of the change, and after a claim
    # the run's courier carries the claimed run to run_event/2.
    defp hear(%Config{repo: repo, host: host}, facts, transition, ctx) do
      courier = if transition == :claimed, do: courier(ctx)
      host? = exports?(host, :run_transition)

      if host? or courier do
        with %AgentRun{} = run <- transition_run(repo, facts, ctx) do
          if courier, do: Courier.put_run(courier, run)
          if host?, do: run_transition(host, run, transition)
        end
      end
    end

    defp courier(%{courier: %Courier{} = courier}), do: courier
    defp courier(_ctx), do: nil

    # The run as this transition committed it. The worker's own writes
    # carry its row in their ctx, as read before the claim; the control
    # plane's and the reaper's read it after the commit, when a later write
    # may already have landed. Either way the lifecycle columns come from
    # the facts this transition committed.
    defp transition_run(repo, %Facts{} = facts, ctx) do
      run =
        case ctx do
          %{run: %AgentRun{} = run} -> run
          _other -> repo.get(AgentRun, facts.ref)
        end

      run && put_facts(run, facts)
    end

    defp put_facts(run, facts) do
      Enum.reduce(@fields, run, fn
        {:ref, _column}, run -> run
        {key, column}, run -> Map.put(run, column, column_value(key, Map.fetch!(facts, key)))
      end)
    end

    # A value as its column loads it: the encoding the write stores, with a
    # jsonb column's map in the shape its JSON round trip gives back.
    defp column_value(key, value) do
      case Codec.encode_value(key, value) do
        %{} = map when not is_struct(map) -> map |> Jason.encode!() |> Jason.decode!()
        encoded -> encoded
      end
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
