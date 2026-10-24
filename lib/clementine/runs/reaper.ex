if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Reaper do
    @moduledoc false
    # The periodic sweep that writes the terminal a dead executor could not.
    #
    # A dying node writes nothing on purpose; its runs' heartbeats stop, and
    # every tick here interrupts (or, by policy, requeues) the runs that are
    # no longer alive. Sweeps on several nodes need no coordination: every
    # verdict lands as a compare-and-swap on the exact facts the sweep
    # observed. It does not start while Oban runs in a testing mode, the
    # way Oban's own plugins don't; tests call sweep/1.

    use GenServer

    import Ecto.Query

    require Logger

    alias Clementine.Lifecycle.Ecto.Codec
    alias Clementine.Lifecycle.Ecto.Oban, as: JobCheck
    alias Clementine.Lifecycle.{Facts, Protocol}
    alias Clementine.Reconciler
    alias Clementine.Runs.{AgentRun, Config, Lifecycle, Worker}

    @fields Codec.resolve_fields(:id, [])
    @active_statuses ~w(queued running waiting)

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    end

    @impl GenServer
    def init(opts) do
      policy = Keyword.get_lazy(opts, :policy, &Reconciler.Policy.new/0)
      send(self(), :sweep)
      {:ok, %{policy: policy}}
    end

    @impl GenServer
    def handle_info(:sweep, %{policy: policy} = state) do
      report(policy)
      Process.send_after(self(), :sweep, policy.sweep_interval)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}

    defp report(policy) do
      case sweep(policy) do
        %{interrupted: 0, requeued: 0} ->
          :ok

        %{interrupted: interrupted, requeued: requeued} ->
          Logger.info("Agent run sweep interrupted #{interrupted} and requeued #{requeued} runs")
      end
    rescue
      e -> Logger.error("Agent run sweep failed: " <> Exception.message(e))
    end

    @doc false
    # One sweep: the query is agent_runs'; the judgment is the library's,
    # status-scoped, with the Oban cross-check for runs the clock alone
    # cannot convict.
    @spec sweep(Reconciler.Policy.t()) :: %{
            interrupted: non_neg_integer(),
            requeued: non_neg_integer()
          }
    def sweep(policy \\ Reconciler.Policy.new()) do
      %Config{repo: repo, oban: oban} = Config.fetch!()
      now = storage_now!(repo)
      rows = active_runs(repo)
      jobs = oban_jobs_by_id(repo, oban, rows)

      Enum.reduce(rows, %{interrupted: 0, requeued: 0}, fn row, acc ->
        facts = Codec.to_facts(row, @fields)

        facts
        |> judge(jobs[row.oban_job_id], now, policy)
        |> apply_verdict(repo, facts, acc)
      end)
    end

    # The storage clock, the same source that stamped the facts. A
    # node-local DateTime.utc_now/0 would bring back the two-clock problem
    # the protocol's symbolic timestamps remove.
    defp storage_now!(repo) do
      %{rows: [[now]]} = repo.query!("SELECT now()")
      now
    end

    # Library judgment first (heartbeat, deadline, queue age, wait ceiling),
    # then the Oban cross-check. A waiting run judges healthy by
    # construction: its job completed on purpose when it suspended.
    defp judge(facts, job, now, policy) do
      case Reconciler.judge(claim_clock(facts, job, now), now, policy) do
        :healthy -> JobCheck.judge_job(facts, job)
        verdict -> verdict
      end
    end

    # The claim timeout catches a worker that died or wedged before it
    # claimed its run. A job still waiting in Oban's queue has no worker
    # yet: that is backlog, and a burst bigger than the queue's limit would
    # otherwise interrupt runs that were never given a chance to start. So
    # a queued run's claim clock starts when its job starts executing, not
    # when the run was queued.
    @waiting_job_states ~w(available scheduled retryable)

    defp claim_clock(%Facts{status: :queued} = facts, %{state: state}, now)
         when state in @waiting_job_states,
         do: %{facts | queued_at: now}

    defp claim_clock(
           %Facts{status: :queued, queued_at: %DateTime{} = queued} = facts,
           %{attempted_at: %DateTime{} = started},
           _now
         ) do
      if DateTime.compare(started, queued) == :gt, do: %{facts | queued_at: started}, else: facts
    end

    defp claim_clock(facts, _job, _now), do: facts

    defp apply_verdict({:interrupt, reason}, _repo, facts, acc) do
      case Protocol.interrupt(Lifecycle, facts, reason) do
        {:ok, _facts} -> %{acc | interrupted: acc.interrupted + 1}
        # A racing finish, or another reaper, won: the guard working.
        {:error, :stale} -> acc
        {:error, other} -> log_sweep_error(facts.ref, other, acc)
      end
    end

    defp apply_verdict({:requeue, reason}, repo, facts, acc) do
      case repo.transaction(fn -> requeue(repo, facts, reason) end) do
        {:ok, :ok} -> %{acc | requeued: acc.requeued + 1}
        {:error, reason} when reason in [:stale, :effects_present] -> acc
        {:error, other} -> log_sweep_error(facts.ref, other, acc)
      end
    end

    defp apply_verdict(_healthy, _repo, _facts, acc), do: acc

    # The requeue and its new job commit together, for the reason
    # Clementine.Runs.resume/2 gives: apart, another node's sweep could
    # interrupt the queued run before its job exists.
    defp requeue(repo, facts, reason) do
      case Protocol.requeue(Lifecycle, facts, reason) do
        {:ok, _facts} -> Worker.re_enqueue!(facts.ref)
        {:error, reason} -> repo.rollback(reason)
      end
    end

    defp active_runs(repo) do
      AgentRun
      |> where([r], r.kind == "rollout" and r.status in @active_statuses)
      |> repo.all()
    end

    defp oban_jobs_by_id(repo, oban, rows) do
      ids = rows |> Enum.map(& &1.oban_job_id) |> Enum.reject(&is_nil/1)

      from(j in Oban.Job, where: j.id in ^ids)
      |> repo.all(prefix: Oban.config(oban).prefix)
      |> Map.new(&{&1.id, &1})
    end

    defp log_sweep_error(run_id, reason, acc) do
      Logger.warning("Agent run sweep could not write run #{run_id}: #{inspect(reason)}")
      acc
    end
  end
end
