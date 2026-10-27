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

      * one migration calling `Clementine.Migration.up(version: 2)`;
      * `use Clementine.Agent` modules, listed in `agents:`.

    The optional `host:` module implements `Clementine.Host`: who may
    resume a run, what commits with a run's end and what hears of it
    after, what hears of its events and its other transitions, and how a
    subject and an actor resolve. An agent that converses supplies its
    history with `c:Clementine.Agent.history/1`. Nothing else is
    configurable. Coding agents: the rules are in
    [`usage-rules.md`](usage-rules.md).

    ## Subject, actor, turn, lane

    A run carries up to two references the host resolves at every claim:
    its **subject**, what it is about (`subject: {"ticket", id}`), and its
    **actor**, whose authority it acts with (`actor: {"user", id}`). Either
    refusal cancels the run as unstartable. The agent declares whether its
    runs are **turns**, runs on a thread that read it as history
    (`use Clementine.Agent, turn: true`), and `start/3` copies that to the
    row.

    Those decide the run's **lane**, the key under which active runs
    (queued, running, or waiting) are exclusive; the `agent_runs_lane_index`
    holds it. A turn's lane is its thread, whichever agent it belongs to:
    at most one active turn per thread. A task's lane is its agent and
    subject: tasks of different agents on one subject, and a turn and a
    task, run side by side. A run with no subject has no lane and blocks
    nothing. Refusal is the only policy here: a second start in a busy
    lane returns `{:error, :active_run_exists}`, and a caller who wants
    queueing gives the thread a loop.

    Runs live in `agent_runs` and execute on Oban's `queue`, one job per
    execution (`Clementine.Runs.Worker`). Clementine owns the mechanism:
    claims, lease fencing, heartbeats, suspension and resume, carrying a
    cancel to the node that runs the run, the drain at shutdown, and the
    reaper that finishes runs whose node died. Every lifecycle write is a
    guarded compare-and-swap.

    ## Options of the child spec

    #{Clementine.Runs.Config.docs()}
    """

    import Ecto.Query, only: [from: 2]

    alias Clementine.Emissions
    alias Clementine.Lifecycle.Ecto.Codec
    alias Clementine.Lifecycle.{Facts, Protocol}
    alias Clementine.Runs.{AgentRun, Config, Lifecycle, Worker}
    alias Clementine.Suspension
    alias Ecto.Multi

    @fields Codec.resolve_fields(:id, [])
    @active_statuses Enum.map(Facts.active_statuses(), &Atom.to_string/1)

    @typedoc "A subject as `start/3` takes it: `{type, id}`, stored as text."
    @type subject :: {String.t() | atom(), String.t() | integer() | nil}

    @typedoc "An actor as `start/3` takes it: `{type, id}`, stored as text."
    @type actor :: subject()

    @doc """
    Starts a run of `agent`, a `Clementine.Agent` module listed in the child
    spec, with `prompt`. The run row and its Oban job insert in one
    transaction, so neither exists without the other, and inside the
    caller's transaction they commit with it.

    ## Options

      * `:subject` — `{type, id}`, what the run is about, stored as text.
        A turn agent's run needs one; a task's is optional.
      * `:actor` — `{type, id}`, whose authority the run acts with, stored
        as text and resolved at every claim
        (`c:Clementine.Host.resolve_actor/2`). Leave it out for a run of
        the system's.
      * `:metadata` — a map stored on the row as given.

    Returns `{:error, :unknown_agent}` for a module the child spec does not
    list, `{:error, :blank_prompt}` for an empty prompt,
    `{:error, :subject_required}` for a turn without a subject id, and
    `{:error, :active_run_exists}` when the run's lane holds an active run:
    a turn's lane is its thread (a turn of any agent on the subject), a
    task's its agent and subject.
    """
    @spec start(module(), String.t(), keyword()) ::
            {:ok, AgentRun.t()}
            | {:error,
               :unknown_agent
               | :blank_prompt
               | :subject_required
               | :active_run_exists
               | Ecto.Changeset.t()}
    def start(agent, prompt, opts \\ []) when is_atom(agent) and is_binary(prompt) do
      config = Config.fetch!()

      with {:ok, attrs} <- queued_attrs(config, agent, prompt, opts) do
        insert_queued(config, attrs)
      end
    end

    @doc false
    # What `start/3` inserts, checked the way `start/3` checks it: the
    # agent's key and turn, the prompt, and the subject and actor as text.
    # A loop's step commit builds a child's attrs here, adds its parent
    # and tag, and inserts through insert_queued/2.
    @spec queued_attrs(Config.t(), module(), String.t(), keyword()) ::
            {:ok, map()} | {:error, :unknown_agent | :blank_prompt | :subject_required}
    def queued_attrs(%Config{} = config, agent, prompt, opts)
        when is_atom(agent) and is_binary(prompt) do
      {subject_type, subject_id} = reference(Keyword.get(opts, :subject))
      {actor_type, actor_id} = reference(Keyword.get(opts, :actor))

      with {:ok, key} <- registered_key(config, agent),
           :ok <- validate_prompt(prompt),
           turn = agent.turn(),
           :ok <- validate_lane(turn, subject_id) do
        {:ok,
         %{
           agent_key: key,
           turn: turn,
           input: %{"prompt" => prompt},
           subject_type: subject_type,
           subject_id: subject_id,
           actor_type: actor_type,
           actor_id: actor_id,
           metadata: Keyword.get(opts, :metadata, %{})
         }}
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

    # A turn is a run on a thread, and the thread is its lane: without a
    # subject id there is no thread to be a turn on.
    defp validate_lane(true, nil), do: {:error, :subject_required}
    defp validate_lane(_turn, _subject_id), do: :ok

    # A reference with no id stores NULL, so such runs never block each
    # other.
    defp reference(nil), do: {nil, nil}
    defp reference({type, nil}), do: {to_string(type), nil}
    defp reference({type, id}), do: {to_string(type), to_string(id)}

    @doc false
    # The one insert of a queued run: the row and its Oban job in one
    # transaction, linked from the row. `start/3` is its public face; a
    # loop's step commit inserts children through it too.
    @spec insert_queued(Config.t(), map()) ::
            {:ok, AgentRun.t()} | {:error, :active_run_exists | Ecto.Changeset.t() | term()}
    def insert_queued(%Config{repo: repo, oban: oban, queue: queue}, attrs) do
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
    waiting. The claim that follows resolves the run's subject and actor
    again, so a run whose actor was refused meanwhile is cancelled rather
    than continued.

    The resume and the new job commit in one transaction. Apart, a sweep
    between them would find a queued run whose only job is the one that
    completed when the run parked (or none, once Oban's pruner removed it)
    and interrupt it, losing the decision.

    Call it outside a transaction; inside one it raises, for the reason
    `cancel/1` gives: `c:Clementine.Host.run_transition/2` hears of the
    resume when resume's own transaction commits.
    """
    @spec resume(Ecto.UUID.t(), Clementine.Host.decision()) ::
            :ok | {:error, :not_found | :not_waiting | term()}
    def resume(run_id, {verdict, meta} = decision)
        when verdict in [:approved, :denied] and is_map(meta) do
      %Config{repo: repo} = config = Config.fetch!()
      refuse_transaction!(repo, "resume/2")

      # The host hears of the resume once this transaction commits.
      with {:ok, id} <- cast_id(run_id),
           {:ok, :ok} <-
             Emissions.after_commit(fn ->
               repo.transaction(fn -> resume_locked(config, id, decision) end)
             end) do
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
    Cancels a run. A queued or waiting run finishes `cancelled` at once
    (`{:ok, :finished}`). A running run gets the cooperative flag
    (`{:ok, :flagged}`), and the flag goes on to the process running it,
    on whichever node: the model call in flight is aborted, and the run
    finishes `cancelled` within moments, mid-response. A run that was
    already writing its end when the flag landed keeps that end. Should
    the flag not reach the runner (another node behind a notifier that
    cannot listen, say), the runner finds it at its next step.

    The end reaches the host as a `Clementine.Result.Cancelled` whose
    `reason` is `%{"code" => "cancelled"}`.

    Who may cancel which run is the app's decision: check it before
    calling. A cancel of a run that has ended returns
    `{:error, :already_terminal}` and changes nothing.

    Call it outside a transaction; inside one it raises. The host hears of
    what it wrote (`c:Clementine.Host.run_committed/2` for an end,
    `c:Clementine.Host.run_transition/2` for a flag) when its own write
    commits, and inside the caller's transaction that write has not
    committed yet.
    """
    @spec cancel(Ecto.UUID.t()) ::
            {:ok, :flagged | :finished} | {:error, :already_terminal | :not_found | term()}
    def cancel(run_id) do
      %Config{repo: repo} = Config.fetch!()

      refuse_transaction!(repo, "cancel/1")

      with {:ok, id} <- cast_id(run_id) do
        Protocol.request_cancel(Lifecycle, id, %{"code" => "cancelled"})
      end
    end

    defp refuse_transaction!(repo, function) do
      if repo.in_transaction?() do
        raise RuntimeError,
              "Clementine.Runs.#{function} was called inside a transaction; call it after " <>
                "the transaction commits, so the host never hears of a change that rolls back"
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

    @doc """
    Whether `agent` has an active run (queued, running, or waiting) on
    `subject`: a task's lane. A subject with a `nil` id has no lane, so
    the answer is `false`. For a thread's active turn, whichever agent's,
    see `active/1`.

    Takes `kind:` like `list/1`.
    """
    @spec active?(module(), subject(), keyword()) :: boolean()
    def active?(agent, subject, opts \\ []) when is_atom(agent) do
      %Config{repo: repo} = config = Config.fetch!()

      case reference(subject) do
        {_type, nil} ->
          false

        {type, id} ->
          repo.exists?(
            from(r in active_query(opts),
              where: r.agent_key == ^agent_key!(config, agent),
              where: r.subject_type == ^type and r.subject_id == ^id
            )
          )
      end
    end

    @doc """
    The active turn on the thread `subject`, of whichever agent, or `nil`:
    the thread's lane holds at most one. A subject with a `nil` id has no
    lane.

    With `kind: :loop`, the subject's active loop instead: a loop is never
    a turn, so the turn filter applies to rollouts alone. Where
    controllers of several keys may each hold a loop on one subject,
    `list/1` with `agent:` tells them apart.
    """
    @spec active(subject(), keyword()) :: AgentRun.t() | nil
    def active(subject, opts \\ []) do
      %Config{repo: repo} = Config.fetch!()

      case reference(subject) do
        {_type, nil} ->
          nil

        {type, id} ->
          from(r in active_query(opts),
            where: r.subject_type == ^type and r.subject_id == ^id,
            limit: 1
          )
          |> turns_only(Keyword.get(opts, :kind, :rollout))
          |> repo.one()
      end
    end

    # A turn is a rollout; a loop occupies its lane with `turn = false`.
    defp turns_only(query, :rollout), do: from(r in query, where: r.turn)
    defp turns_only(query, _kind), do: query

    @doc """
    The newest run on `subject`, active or ended, or `nil`. Takes the
    filters of `list/1` (`turn: true` for the thread's latest turn,
    `agent:` for an agent's latest run on it).
    """
    @spec latest(subject(), keyword()) :: AgentRun.t() | nil
    def latest(subject, opts \\ []) do
      %Config{repo: repo} = config = Config.fetch!()

      repo.one(
        from(r in filtered_query(config, Keyword.put(opts, :subject, subject)),
          order_by: [desc: r.inserted_at],
          limit: 1
        )
      )
    end

    @doc """
    Runs, newest first, by any of:

      * `:subject` — `{type, id}`; a `nil` id matches runs of that type
        with no id;
      * `:agent` — a `Clementine.Agent` module the child spec lists;
      * `:turn` — `true` for turns, `false` for tasks;
      * `:actor` — `{type, id}`, every run acting with that authority;
      * `:kind` — `:rollout` (the default) or `:loop`;
      * `:limit` — at most this many.

    A thread's turns are `list(subject: thread, turn: true)`; an audit of
    an account's runs, `list(actor: {"user", id})`.
    """
    @spec list(keyword()) :: [AgentRun.t()]
    def list(opts \\ []) do
      %Config{repo: repo} = config = Config.fetch!()

      from(r in filtered_query(config, opts), order_by: [desc: r.inserted_at])
      |> limit_query(Keyword.get(opts, :limit))
      |> repo.all()
    end

    defp limit_query(query, nil), do: query
    defp limit_query(query, limit) when is_integer(limit), do: from(r in query, limit: ^limit)

    defp active_query(opts) do
      from(r in kind_query(opts), where: r.status in @active_statuses)
    end

    # Loop rows (version 3) share the table; a thread's loop is never its
    # latest run, so every query takes rollouts unless told otherwise.
    defp kind_query(opts) do
      kind = opts |> Keyword.get(:kind, :rollout) |> Atom.to_string()
      from(r in AgentRun, where: r.kind == ^kind)
    end

    defp filtered_query(config, opts) do
      Enum.reduce(opts, kind_query(opts), fn
        {:subject, subject}, query ->
          where_reference(query, :subject, subject)

        {:actor, actor}, query ->
          where_reference(query, :actor, actor)

        {:agent, agent}, query ->
          from(r in query, where: r.agent_key == ^agent_key!(config, agent))

        {:turn, turn}, query when is_boolean(turn) ->
          from(r in query, where: r.turn == ^turn)

        {:kind, _kind}, query ->
          query

        {:limit, _limit}, query ->
          query

        {key, value}, _query ->
          raise ArgumentError, "unknown filter #{inspect({key, value})}"
      end)
    end

    defp where_reference(query, :subject, subject) do
      case reference(subject) do
        {type, nil} -> from(r in query, where: r.subject_type == ^type and is_nil(r.subject_id))
        {type, id} -> from(r in query, where: r.subject_type == ^type and r.subject_id == ^id)
      end
    end

    defp where_reference(query, :actor, actor) do
      case reference(actor) do
        {type, nil} -> from(r in query, where: r.actor_type == ^type and is_nil(r.actor_id))
        {type, id} -> from(r in query, where: r.actor_type == ^type and r.actor_id == ^id)
      end
    end

    defp agent_key!(config, agent) when is_atom(agent) do
      case registered_key(config, agent) do
        {:ok, key} ->
          key

        {:error, :unknown_agent} ->
          raise ArgumentError, "#{inspect(agent)} is not an agent the child spec lists"
      end
    end
  end
end
