if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs do
    @moduledoc """
    The durable runtime's API: start, resume, cancel, and read agent runs.

    A host app runs agents durably with three pieces of glue
    (`mix clementine.install` writes the first two, and
    `mix clementine.gen.agent` the third):

      * a child after Oban in its supervision tree:

            {Clementine,
             repo: MyApp.Repo,
             oban: Oban,
             queue: :agents,
             agents: [MyApp.Agents.Weather],
             host: MyApp.Agents.Host}

      * one migration calling `Clementine.Migration.up(version: 1)`;
      * `use Clementine.Agent` modules, listed in `agents:`.

    The optional `host:` module implements `Clementine.Host`: who may
    resume a run, what commits with a run's end and what hears of it
    after, and how a subject resolves. Nothing else is configurable.
    Coding agents: the rules are in [`usage-rules.md`](usage-rules.md).

    Runs live in `agent_runs` and execute on Oban's `queue`, one job per
    execution (`Clementine.Runs.Worker`). Clementine owns the mechanism:
    claims, lease fencing, heartbeats, suspension and resume, the drain at
    shutdown, and the reaper that finishes runs whose node died. Every
    lifecycle write is a guarded compare-and-swap.

    ## Options of the child spec

    #{Clementine.Runs.Config.docs()}
    """

    import Ecto.Query, only: [from: 2]

    alias Clementine.Lifecycle.Ecto.Codec
    alias Clementine.Lifecycle.{Facts, Protocol}
    alias Clementine.Runs.{AgentRun, Config, Lifecycle, Worker}
    alias Clementine.Suspension
    alias Ecto.Multi

    @fields Codec.resolve_fields(:id, [])

    @doc """
    Starts a run of `agent`, a `Clementine.Agent` module listed in the child
    spec, with `prompt`. The run row and its Oban job insert in one
    transaction, so neither exists without the other.

    ## Options

      * `:subject` — `{type, id}`, what the run is about, stored as text.
        Each agent has at most one active run (queued, running, or
        waiting) per subject, and different agents never block each
        other; a subject with a `nil` id never blocks another.
      * `:metadata` — a map stored on the row as given.

    Returns `{:error, :unknown_agent}` for a module the child spec does not
    list, `{:error, :blank_prompt}` for an empty prompt, and
    `{:error, :active_run_exists}` when this agent already has an active
    run for the subject.
    """
    @spec start(module(), String.t(), keyword()) ::
            {:ok, AgentRun.t()}
            | {:error, :unknown_agent | :blank_prompt | :active_run_exists | Ecto.Changeset.t()}
    def start(agent, prompt, opts \\ []) when is_atom(agent) and is_binary(prompt) do
      config = Config.fetch!()

      with {:ok, key} <- registered_key(config, agent),
           :ok <- validate_prompt(prompt) do
        {subject_type, subject_id} = subject(Keyword.get(opts, :subject))

        insert_run(config, %{
          agent_key: key,
          input: %{"prompt" => prompt},
          subject_type: subject_type,
          subject_id: subject_id,
          metadata: Keyword.get(opts, :metadata, %{})
        })
      end
    end

    defp registered_key(%Config{agents: agents}, agent) do
      case Enum.find(agents, fn {_key, module} -> module == agent end) do
        {key, _module} -> {:ok, key}
        nil -> {:error, :unknown_agent}
      end
    end

    defp validate_prompt(prompt) do
      if String.trim(prompt) == "", do: {:error, :blank_prompt}, else: :ok
    end

    # A subject with no id stores NULL, so such runs never block each other.
    defp subject(nil), do: {nil, nil}
    defp subject({type, nil}), do: {to_string(type), nil}
    defp subject({type, id}), do: {to_string(type), to_string(id)}

    defp insert_run(%Config{repo: repo, oban: oban, queue: queue}, attrs) do
      Multi.new()
      |> Multi.insert(:run, AgentRun.queued_changeset(attrs))
      |> then(fn multi ->
        Oban.insert(oban, multi, :job, fn %{run: run} ->
          Worker.new(%{"run_id" => run.id}, queue: queue)
        end)
      end)
      |> Multi.update(:linked, fn %{run: run, job: job} ->
        Ecto.Changeset.change(run, oban_job_id: job.id)
      end)
      |> repo.transaction()
      |> case do
        {:ok, %{linked: run}} ->
          {:ok, run}

        {:error, :run, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, insert_error(changeset)}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end

    defp insert_error(changeset) do
      if AgentRun.active_run_conflict?(changeset), do: :active_run_exists, else: changeset
    end

    @doc """
    Resumes a `waiting` run with a decision, `{:approved, meta}` or
    `{:denied, meta}`, and hands it back to a worker. `meta` is a map
    stored with the resume exactly as given; on a denial, `meta[:message]`
    reaches the model.

    `c:Clementine.Host.authorize_resume/2` decides who may resume; its
    refusal comes back as is. Returns `{:error, :not_found}` and
    `{:error, :not_waiting}` for a run that does not exist or is not
    waiting.

    The resume and the new job commit in one transaction. Apart, a sweep
    between them would find a queued run whose only job is the one that
    completed when the run parked (or none, once Oban's pruner removed it)
    and interrupt it, losing the decision.
    """
    @spec resume(Ecto.UUID.t(), Clementine.Host.decision()) ::
            :ok | {:error, :not_found | :not_waiting | term()}
    def resume(run_id, {verdict, meta} = decision)
        when verdict in [:approved, :denied] and is_map(meta) do
      %Config{repo: repo} = config = Config.fetch!()

      with {:ok, id} <- cast_id(run_id),
           {:ok, :ok} <- repo.transaction(fn -> resume_locked(config, id, decision) end) do
        :ok
      end
    end

    # The row lock keeps a concurrent cancel or second decision from
    # writing between the read and the resume, so the resume cannot go
    # stale inside this transaction; the other writer waits, then finds the
    # run queued.
    defp resume_locked(%Config{repo: repo, host: host}, id, decision) do
      with {:ok, row} <- lock_run(repo, id),
           {:ok, token} <- waiting_token(row),
           :ok <- authorize_resume(host, row, decision),
           {:ok, _facts} <- Protocol.resume(Lifecycle, token, decision) do
        Worker.re_enqueue!(id)
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end

    defp lock_run(repo, id) do
      case repo.one(from(r in AgentRun, where: r.id == ^id, lock: "FOR UPDATE")) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end

    defp waiting_token(row) do
      case Codec.to_facts(row, @fields) do
        %Facts{status: :waiting, suspension: %Suspension{token: token}} -> {:ok, token}
        %Facts{} -> {:error, :not_waiting}
      end
    end

    defp authorize_resume(host, row, decision) do
      if host && function_exported?(host, :authorize_resume, 2) do
        host.authorize_resume(row, decision)
      else
        :ok
      end
    end

    @doc """
    Cancels a run. A running run gets the cooperative flag, which the
    runner honors at its next boundary (`{:ok, :flagged}`); a queued or
    waiting run finishes `cancelled` at once (`{:ok, :finished}`). Who may
    cancel which run is the app's decision: check it before calling.

    Call it outside a transaction; inside one it raises. A run it ends
    calls `c:Clementine.Host.run_committed/2` when its own write commits,
    and inside the caller's transaction that write has not committed yet.
    """
    @spec cancel(Ecto.UUID.t()) ::
            {:ok, :flagged | :finished} | {:error, :already_terminal | :not_found | term()}
    def cancel(run_id) do
      %Config{repo: repo} = Config.fetch!()

      if repo.in_transaction?() do
        raise RuntimeError,
              "Clementine.Runs.cancel/1 was called inside a transaction; call it after " <>
                "the transaction commits, so the host's run_committed/2 never hears of " <>
                "an end that rolls back"
      end

      with {:ok, id} <- cast_id(run_id) do
        Protocol.request_cancel(Lifecycle, id, %{"code" => "cancelled"})
      end
    end

    @doc "The run with `id`, or `nil`."
    @spec get(Ecto.UUID.t()) :: AgentRun.t() | nil
    def get(run_id) do
      %Config{repo: repo} = Config.fetch!()

      case cast_id(run_id) do
        {:ok, id} -> repo.get(AgentRun, id)
        {:error, :not_found} -> nil
      end
    end

    defp cast_id(run_id) do
      case Ecto.UUID.cast(run_id) do
        {:ok, id} -> {:ok, id}
        :error -> {:error, :not_found}
      end
    end
  end
end
