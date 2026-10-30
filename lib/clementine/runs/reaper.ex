if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Reaper do
    @moduledoc false
    # The periodic sweeps that write what a dead executor could not: two
    # cadences in one process.
    #
    # The rollout sweep, every sweep_interval: a dying node writes nothing
    # on purpose; its runs' heartbeats stop, and every tick here
    # interrupts (or, by policy, requeues) the runs that are no longer
    # alive, a loop's children included, and resumes a run waiting on
    # children that have all ended when no child's end reached it (a
    # node on code from before delegation dropped it). The loop sweep, every
    # loop_sweep_interval over loop rows alone: a loop is a standing
    # entity, so no verdict but the deadline belt ends one. A crashed step
    # requeues, a lost step job is re-inserted, a child's lost completion
    # is synthesized, and a park stranded over pending inputs is woken
    # (LOOP_RFC amendment A3). Sweeps on several nodes need no
    # coordination: every verdict lands as a compare-and-swap on the exact
    # facts the sweep observed. Neither starts while Oban runs in a
    # testing mode, the way Oban's own plugins don't; tests call sweep/1
    # and loop_sweep/1.

    use GenServer

    import Ecto.Query

    require Logger

    alias Clementine.Emissions
    alias Clementine.Lifecycle.Ecto.Codec
    alias Clementine.Lifecycle.Ecto.Oban, as: JobCheck
    alias Clementine.Lifecycle.{Facts, Protocol}
    alias Clementine.Reconciler
    alias Clementine.Runs.{AgentRun, Config, Delegations, Lifecycle, Loops, Worker}
    alias Clementine.Suspension

    @fields Codec.resolve_fields(:id, [])
    @active_statuses ~w(queued running waiting)

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    end

    @impl GenServer
    def init(opts) do
      policy = Keyword.get_lazy(opts, :policy, &Reconciler.Policy.new/0)
      send(self(), :sweep)
      send(self(), :loop_sweep)
      {:ok, %{policy: policy}}
    end

    @impl GenServer
    def handle_info(:sweep, %{policy: policy} = state) do
      report(policy)
      Process.send_after(self(), :sweep, policy.sweep_interval)
      {:noreply, state}
    end

    def handle_info(:loop_sweep, %{policy: policy} = state) do
      report_loops(policy)
      Process.send_after(self(), :loop_sweep, policy.loop_sweep_interval)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}

    defp report(policy) do
      case sweep(policy) do
        %{interrupted: 0, requeued: 0, resumed: 0} ->
          :ok

        %{interrupted: interrupted, requeued: requeued, resumed: resumed} ->
          Logger.info(
            "Agent run sweep interrupted #{interrupted}, requeued #{requeued}, and resumed " <>
              "#{resumed} runs"
          )
      end
    rescue
      e -> Logger.error("Agent run sweep failed: " <> Exception.message(e))
    end

    defp report_loops(policy) do
      case Map.drop(loop_sweep(policy), [:healthy]) do
        verdicts when map_size(verdicts) == 0 -> :ok
        verdicts -> Logger.info("Agent loop sweep verdicts: #{inspect(verdicts)}")
      end
    rescue
      e -> Logger.error("Agent loop sweep failed: " <> Exception.message(e))
    end

    @doc false
    # The loop sweep: loop rows only, each judged on its facts plus, for a
    # parked loop, the evidence its facts cannot carry (its live children
    # against their rows and the inbox, the oldest pending input's age).
    # Counts verdicts by name; every non-healthy verdict also emits
    # [:clementine, :loop, :verdict] at judgment (Clementine.Reconciler).
    @spec loop_sweep(Reconciler.Policy.t()) :: %{optional(atom()) => non_neg_integer()}
    def loop_sweep(policy \\ Reconciler.Policy.new()) do
      %Config{repo: repo} = Config.fetch!()
      now = storage_now!(repo)

      Enum.reduce(active_runs(repo, "loop"), %{}, fn row, acc ->
        facts = Codec.to_facts(row, @fields)
        evidence = if row.status == "waiting", do: Loops.evidence(row)
        verdict = Reconciler.judge_loop(facts, evidence, now, policy)
        apply_loop_verdict(verdict, repo, row, facts)
        Map.update(acc, verdict_name(verdict), 1, &(&1 + 1))
      end)
    end

    defp verdict_name(:healthy), do: :healthy
    defp verdict_name({verdict, _detail}), do: verdict

    # A3a: a crashed step requeues unconditionally, with its step job in
    # the same transaction, as a resume does. A loop's epoch counts its
    # lifetime claims, and the commit is replayable by construction.
    defp apply_loop_verdict({:requeue, reason}, repo, _row, facts) do
      case Emissions.after_commit(fn ->
             repo.transaction(fn -> requeue_loop(repo, facts, reason) end)
           end) do
        {:ok, :ok} -> :ok
        {:error, :stale} -> :ok
        {:error, other} -> log_sweep_error(facts.ref, other, nil)
      end
    end

    # A3b: claim-timeout evidence means the step job is lost, not that the
    # loop should die. Re-insert it; a duplicate no-ops on the claim CAS.
    defp apply_loop_verdict({:reenqueue, _reason}, _repo, _row, facts) do
      Loops.enqueue_step(facts.ref, nil)
    end

    # A3c: a live child ended but its completion never reached the inbox.
    # Synthesize it under the canonical key; a racing real delivery no-ops.
    defp apply_loop_verdict({:reconcile_children, strands}, _repo, row, facts) do
      Enum.each(strands, &reconcile_child(row, facts, &1))
    end

    # A3c: inputs sat past the threshold against a parked loop; the wake
    # was lost. Take it now.
    defp apply_loop_verdict({:wake_pending, _reason}, _repo, _row, facts) do
      Loops.wake(facts.ref)
    end

    # The one terminal verdict a loop keeps: a live-wedged step runner past
    # its deadline and the grace.
    defp apply_loop_verdict({:interrupt, reason}, _repo, _row, facts) do
      case Protocol.interrupt(Lifecycle, facts, reason) do
        {:ok, _facts} -> :ok
        {:error, :stale} -> :ok
        {:error, other} -> log_sweep_error(facts.ref, other, nil)
      end
    end

    defp apply_loop_verdict(:healthy, _repo, _row, _facts), do: :ok

    defp reconcile_child(row, facts, strand) do
      Loops.reconcile_child(row, strand)
    rescue
      e -> log_sweep_error(facts.ref, Exception.message(e), nil)
    end

    defp requeue_loop(repo, facts, reason) do
      case Protocol.requeue(Lifecycle, facts, reason) do
        {:ok, _facts} -> Loops.enqueue_step(facts.ref, nil)
        {:error, reason} -> repo.rollback(reason)
      end
    end

    @doc false
    # One sweep: the query is agent_runs'; the judgment is the library's,
    # status-scoped, with the Oban cross-check for runs the clock alone
    # cannot convict.
    @spec sweep(Reconciler.Policy.t()) :: %{
            interrupted: non_neg_integer(),
            requeued: non_neg_integer(),
            resumed: non_neg_integer()
          }
    def sweep(policy \\ Reconciler.Policy.new()) do
      %Config{repo: repo, oban: oban} = Config.fetch!()
      now = storage_now!(repo)
      rows = active_runs(repo, "rollout")
      jobs = oban_jobs_by_id(repo, oban, rows)

      Enum.reduce(rows, %{interrupted: 0, requeued: 0, resumed: 0}, fn row, acc ->
        facts = Codec.to_facts(row, @fields)

        case judge(facts, jobs[row.oban_job_id], now, policy) do
          :healthy -> reconcile_delegation(facts, acc)
          verdict -> apply_verdict(verdict, repo, facts, acc)
        end
      end)
    end

    # A run waiting on its children is healthy, but if they have all
    # ended and it still waits, their end never reached it: resume it.
    # The cheap read first; the resume re-checks under the run's lock.
    defp reconcile_delegation(
           %Facts{
             status: :waiting,
             ref: run_id,
             suspension: %Suspension{reason: {:external, {:delegation, ids}}}
           },
           acc
         ) do
      if Delegations.all_ended?(ids) and Delegations.reconcile(run_id) == :resumed,
        do: %{acc | resumed: acc.resumed + 1},
        else: acc
    rescue
      e -> log_sweep_error(run_id, Exception.message(e), acc)
    end

    defp reconcile_delegation(_facts, acc), do: acc

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
      # The host hears of the requeue once its transaction commits, and
      # never if it rolls back.
      case Emissions.after_commit(fn ->
             repo.transaction(fn -> requeue(repo, facts, reason) end)
           end) do
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

    defp active_runs(repo, kind) do
      AgentRun
      |> where([r], r.kind == ^kind and r.status in @active_statuses)
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
