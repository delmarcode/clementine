if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs do
    @moduledoc """
    The durable runtime's API: start, resume, cancel, purge, and read agent
    runs.

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

      * one migration calling `Clementine.Migration.up(version: 3)`;
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
    execution. Clementine owns the mechanism:
    claims, lease fencing, heartbeats, suspension and resume, carrying a
    cancel to the node that runs the run, the drain at shutdown, and the
    reaper that finishes runs whose node died. Every lifecycle write is a
    guarded compare-and-swap.

    ## Options of the child spec

    #{Clementine.Runs.Config.docs()}
    """

    # inspect/1 is the loop doctor, by the RFC's name; Kernel's is
    # qualified where this module needs it.
    import Kernel, except: [inspect: 1]
    import Ecto.Query, only: [from: 2]

    alias Clementine.Emissions
    alias Clementine.Lifecycle.Ecto.Codec
    alias Clementine.Lifecycle.{Facts, Protocol}
    alias Clementine.Loop
    alias Clementine.Loop.{Input, Report, StoredInput}
    alias Clementine.Runs.{AgentRun, Config, Lifecycle, Loops, StepSupervisor, StepWorker, Worker}
    alias Clementine.Suspension
    alias Ecto.Multi

    @fields Codec.resolve_fields(:id, [])
    @active_statuses Enum.map(Facts.active_statuses(), &Atom.to_string/1)

    # A loop's insert-or-get rides the lane index, as ON CONFLICT names it.
    @lane_conflict "((CASE WHEN turn THEN '' ELSE agent_key END), subject_type, subject_id) " <>
                     "WHERE status IN ('queued', 'running', 'waiting') AND subject_id IS NOT NULL"

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
           :ok <- agent_only(agent),
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

    # The child spec lists agents and loop controllers in one key
    # namespace: reads filter by either, and only an agent starts as a run.
    defp registered_key(%Config{agents: agents}, module) do
      case Enum.find(agents, fn {_key, listed} -> listed == module end) do
        {key, _listed} -> {:ok, key}
        nil -> {:error, :unknown_agent}
      end
    end

    defp agent_only(module) do
      if Config.agent?(module), do: :ok, else: {:error, :unknown_agent}
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
    Starts a loop of `controller`, a `Clementine.Loop` module listed in
    the child spec's `agents:`, with `args` for its `init/1`, or returns
    the loop already standing. A loop is a run (`kind: "loop"`): its row
    occupies the lane of its controller's key and its subject like any
    run, so a second `start_loop/3` of the same controller on the same
    subject is insert-or-get, `{:ok, :already_exists, run}` with the
    standing loop. The row and its first step's job insert in one
    transaction, and inside the caller's transaction they commit with
    it; `init/1` runs in that first step.

    ## Options

      * `:subject` — `{type, id}`, what the loop stands for (a
        conversation, a case). Required with an id: the lane is the
        loop's identity.
      * `:actor` — `{type, id}`, whose authority its children act with
        unless a child names its own.
      * `:policy` — a JSON map the step runner reads: `"batch_cap"`,
        `"dead_letter_after"`, `"deadline_ms"`.
      * `:metadata` — a map stored on the row as given.

    Returns `{:error, :unknown_controller}` for a module the child spec
    does not list as a loop, and `{:error, :subject_required}` without a
    subject id. `args` and `:policy` must be JSON-safe maps; anything
    else raises, because the row stores them.
    """
    @spec start_loop(module(), map(), keyword()) ::
            {:ok, AgentRun.t()}
            | {:ok, :already_exists, AgentRun.t()}
            | {:error, :unknown_controller | :subject_required | Ecto.Changeset.t() | term()}
    def start_loop(controller, args, opts \\ []) when is_atom(controller) and is_map(args) do
      config = Config.fetch!()
      {subject_type, subject_id} = reference(Keyword.get(opts, :subject))
      {actor_type, actor_id} = reference(Keyword.get(opts, :actor))

      with {:ok, key} <- registered_controller(config, controller),
           :ok <- validate_loop_subject(subject_id) do
        attrs = %{
          kind: "loop",
          agent_key: key,
          turn: false,
          input: Loop.Codec.validate_json_map!(args, "loop args"),
          loop_policy:
            Loop.Codec.validate_json_map!(Keyword.get(opts, :policy, %{}), "loop policy"),
          state_version: controller.__loop__(:state_version),
          subject_type: subject_type,
          subject_id: subject_id,
          actor_type: actor_type,
          actor_id: actor_id,
          metadata: Keyword.get(opts, :metadata, %{})
        }

        insert_or_get_loop(config, attrs, 3)
      end
    end

    defp registered_controller(%Config{agents: agents}, controller) do
      case Enum.find(agents, fn {_key, module} -> module == controller end) do
        {key, _module} ->
          if Config.controller?(controller), do: {:ok, key}, else: {:error, :unknown_controller}

        nil ->
          {:error, :unknown_controller}
      end
    end

    defp validate_loop_subject(nil), do: {:error, :subject_required}
    defp validate_loop_subject(_id), do: :ok

    # The row inserts with ON CONFLICT DO NOTHING on the lane index, so an
    # existing loop never aborts the caller's transaction; the one it hit
    # is then read back. A loop that ended between the two is the race the
    # retry covers.
    defp insert_or_get_loop(%Config{repo: repo} = config, attrs, attempts) do
      result =
        repo.transaction(fn ->
          case insert_loop_row(config, attrs) do
            {:ok, run} ->
              {:created, run}

            :conflict ->
              # The lane's loop ended between the insert and the read.
              # Nothing was written on this path, so it returns rather
              # than rolls back: a caller's transaction stays good for the
              # retry.
              case existing_loop(config, attrs) do
                %AgentRun{} = run -> {:existing, run}
                nil -> :lost_race
              end
          end
        end)

      case result do
        {:ok, {:created, run}} -> {:ok, run}
        {:ok, {:existing, run}} -> {:ok, :already_exists, run}
        {:ok, :lost_race} when attempts > 1 -> insert_or_get_loop(config, attrs, attempts - 1)
        {:ok, :lost_race} -> {:error, :active_run_exists}
        {:error, reason} -> {:error, reason}
      end
    end

    defp insert_loop_row(%Config{repo: repo, oban: oban, queue: queue}, attrs) do
      changeset = AgentRun.queued_changeset(attrs)

      unless changeset.valid?, do: repo.rollback(changeset)

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      row =
        changeset
        |> Ecto.Changeset.apply_changes()
        |> Map.take([
          :kind,
          :agent_key,
          :turn,
          :input,
          :loop_policy,
          :state_version,
          :subject_type,
          :subject_id,
          :actor_type,
          :actor_id,
          :metadata
        ])
        |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})

      case repo.insert_all(AgentRun, [row],
             on_conflict: :nothing,
             conflict_target: {:unsafe_fragment, @lane_conflict},
             returning: true
           ) do
        {1, [run]} ->
          {:ok, job} = Oban.insert(oban, StepWorker.new(%{"run_id" => run.id}, queue: queue))

          {1, _} =
            repo.update_all(from(r in AgentRun, where: r.id == ^run.id),
              set: [oban_job_id: job.id]
            )

          {:ok, %{run | oban_job_id: job.id}}

        {0, _} ->
          :conflict
      end
    end

    defp existing_loop(%Config{repo: repo}, attrs) do
      repo.one(
        from(r in AgentRun,
          where: r.kind == "loop" and r.status in @active_statuses,
          where: r.agent_key == ^attrs.agent_key,
          where: r.subject_type == ^attrs.subject_type and r.subject_id == ^attrs.subject_id,
          limit: 1
        )
      )
    end

    @doc """
    Sends `payload` to the loop `loop_id`: appends it to the loop's inbox
    as a `{:message, payload}` input, wakes the loop if it is parked, and
    enqueues its step, in one transaction. `payload` is a term under the
    controller's `vocabulary:`; one it cannot store raises.

    Outside a transaction, the loop's step then runs at once, in a task
    on this node, and `send/3` returns without waiting for it: the step
    job stays as the backstop and discards when the task's claim won.
    The reply therefore carries no child id; a client learns of the turn
    the step started from `c:Clementine.Host.run_transition/2`
    (`:claimed`), from its events, or from `child/2`. Inside the caller's
    transaction the input and the job commit with it and the job steps
    the loop at the commit, since the append is not visible before; and
    nothing announces the append itself (no `:resumed` to the host, no
    `[:clementine, :loop, :input]` event): either would describe a write
    the caller may yet roll back.

    ## Options

      * `:dedup_key` — a string unique among the loop's live and dead
        inbox rows (a provider's message id, say): a second send with the
        same key returns `{:ok, :duplicate}` and changes nothing.
      * `:if_idle` — `true` refuses the message with `{:error, :busy}`
        unless the loop is idle: no child of its is active (queued,
        running, or waiting), nothing waits in its inbox, and no cancel is
        pending on it. The check runs under the loop row's lock, which
        every append and every step's park take, so a message that races
        a step is either refused or appended whole, and the controller
        never sees a refused one. For a prompt that should start a turn
        only when the thread is quiet.

    Returns `{:ok, :appended}`, `{:ok, :duplicate}`, or
    `{:ok, :dead_lettered}` when the loop has ended and the message was
    kept as evidence, never to be consumed, so the caller knows.
    `{:error, :not_found}` and `{:error, :not_a_loop}` name a missing run
    and a run that is not a loop.
    """
    @spec send(Ecto.UUID.t(), term(), keyword()) ::
            {:ok, :appended | :duplicate | :dead_lettered}
            | {:error, :not_found | :not_a_loop | :busy | term()}
    def send(loop_id, payload, opts \\ []) do
      %Config{repo: repo} = config = Config.fetch!()

      with {:ok, id} <- cast_id(loop_id),
           {:ok, outcome} <-
             Loops.append(id, Input.message(payload), Keyword.get(opts, :dedup_key),
               if_idle: Keyword.get(opts, :if_idle, false)
             ) do
        # The step runs on what the append committed. Inside the caller's
        # transaction nothing has, and a claim here would read past it;
        # the job steps the loop at the commit instead.
        if outcome == :appended and not repo.in_transaction?(),
          do: StepSupervisor.step(config, id)

        {:ok, outcome}
      end
    end

    @doc """
    Resumes a `waiting` run with a decision, `{:approved, meta}` or
    `{:denied, meta}`, and hands it back to a worker. `meta` is a map
    stored with the resume exactly as given; on a denial, `meta[:message]`
    reaches the model.

    `c:Clementine.Host.authorize_resume/2` decides who may resume; its
    refusal comes back as is. Returns `{:error, :not_found}` and
    `{:error, :not_waiting}` for a run that does not exist or is not
    waiting, and `{:error, :loop_run}` for a loop, which waits for its
    inbox rather than a decision. The claim that follows resolves the
    run's subject and actor again, so a run whose actor was refused
    meanwhile is cancelled rather than continued.

    The resume and the new job commit in one transaction. Apart, a sweep
    between them would find a queued run whose only job is the one that
    completed when the run parked (or none, once Oban's pruner removed it)
    and interrupt it, losing the decision.

    Call it outside a transaction; inside one it raises, for the reason
    `cancel/1` gives: `c:Clementine.Host.run_transition/2` hears of the
    resume when resume's own transaction commits.
    """
    @spec resume(Ecto.UUID.t(), Clementine.Host.decision()) ::
            :ok | {:error, :not_found | :not_waiting | :loop_run | term()}
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
           :ok <- refuse_loop(row),
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

    # A parked loop waits for its inbox, not a decision: it wakes through
    # send/3 and its children's ends, never a resume.
    defp refuse_loop(%AgentRun{kind: "loop"}), do: {:error, :loop_run}
    defp refuse_loop(%AgentRun{}), do: :ok

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

    A loop (`start_loop/3`) is flagged (`{:ok, :flagged}`) and woken: its
    next step cancels its live children, absorbs their ends without
    calling the controller, and finishes the loop `cancelled` last, with
    any input left in its inbox kept as evidence. A child of a loop
    cancels like any run; its loop hears the `Cancelled` completion and
    decides.

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
      reason = %{"code" => "cancelled"}

      with {:ok, id} <- cast_id(run_id) do
        case Protocol.request_cancel(Lifecycle, id, reason) do
          {:error, :loop_run} -> Loops.cancel(id, reason)
          other -> other
        end
      end
    end

    @doc """
    Erases every run on `subject` (`{type, id}`): the runs whose subject
    it is, and every descendant of a loop among them whatever its own
    subject (a `{:run, ...}` action may name another), with their inbox
    rows. Returns `{:ok, count}`. Only Clementine writes `agent_runs`, so
    this is how an app erases what a deleted thread's prompts and replies
    left in `input` and `result`.

    It refuses with `{:error, :active}` while any run in that set is
    queued, running or waiting, loops included, and then deletes nothing.
    A thread's loop is active until it is cancelled, so the path is
    `cancel/1` on the loop, then `purge/1` once it has ended (from
    `c:Clementine.Host.run_committed/2` on the loop's end, say). The set
    is locked for the check, so a step or a claim racing the purge waits
    on the row and finds it gone.

    It works inside the caller's transaction, so an app deletes its own
    row in the same unit; the refusal is a return, never a rollback. It
    emits `[:clementine, :runs, :purge]` with the count, for audit: after
    its own transaction commits, or inside the caller's as it returns.
    """
    @spec purge({String.t() | atom(), String.t() | integer() | nil}) ::
            {:ok, non_neg_integer()} | {:error, :active}
    def purge({_type, _id} = subject) do
      %Config{repo: repo} = Config.fetch!()
      {subject_type, subject_id} = reference(subject)

      {:ok, outcome} =
        Emissions.after_commit(fn ->
          repo.transaction(fn ->
            rows = purge_set(repo, subject)

            if Enum.any?(rows, &(&1.status in @active_statuses)) do
              {:error, :active}
            else
              count = delete_children_first(repo, rows)

              Emissions.emit(fn ->
                :telemetry.execute(
                  [:clementine, :runs, :purge],
                  %{count: count},
                  %{subject_type: subject_type, subject_id: subject_id}
                )
              end)

              {:ok, count}
            end
          end)
        end)

      outcome
    end

    # The runs on the subject, then every descendant of any of them, each
    # level locked as it is read.
    defp purge_set(repo, subject) do
      roots =
        repo.all(
          from(r in where_reference(AgentRun, :subject, subject),
            lock: "FOR UPDATE",
            select: %{id: r.id, parent_id: r.parent_id, status: r.status}
          )
        )

      descendants(repo, roots, MapSet.new(roots, & &1.id), roots)
    end

    defp descendants(_repo, [], _seen, acc), do: acc

    defp descendants(repo, parents, seen, acc) do
      parent_ids = Enum.map(parents, & &1.id)

      children =
        repo.all(
          from(r in AgentRun,
            where: r.parent_id in ^parent_ids,
            lock: "FOR UPDATE",
            select: %{id: r.id, parent_id: r.parent_id, status: r.status}
          )
        )
        |> Enum.reject(&MapSet.member?(seen, &1.id))

      seen = Enum.reduce(children, seen, &MapSet.put(&2, &1.id))
      descendants(repo, children, seen, acc ++ children)
    end

    # Children before parents: parent_id restricts the delete, so each
    # pass removes the rows nothing left in the set points at.
    defp delete_children_first(_repo, []), do: 0

    defp delete_children_first(repo, rows) do
      parents = MapSet.new(rows, & &1.parent_id)

      case Enum.split_with(rows, &(not MapSet.member?(parents, &1.id))) do
        {[], _rest} ->
          raise "purge set has no leaf: parent_id forms a cycle among #{inspect(rows)}"

        {leaves, rest} ->
          ids = Enum.map(leaves, & &1.id)
          {count, _} = repo.delete_all(from(r in AgentRun, where: r.id in ^ids))
          count + delete_children_first(repo, rest)
      end
    end

    @doc """
    The live child of the loop `loop_id` under `tag`, or
    `{:error, :no_child}`: a tag has at most one live child, and re-arms
    once that child has ended. A streaming UI attaches to the child this
    way as its turn starts.
    """
    @spec child(Ecto.UUID.t(), Loop.tag()) :: {:ok, AgentRun.t()} | {:error, :no_child}
    def child(loop_id, tag) do
      %Config{repo: repo} = Config.fetch!()
      {kind, id} = Loop.Codec.split_tag(tag)

      with {:ok, loop_id} <- cast_id(loop_id),
           %AgentRun{} = run <-
             repo.one(
               from(r in AgentRun,
                 where: r.parent_id == ^loop_id and r.status in @active_statuses,
                 where: r.tag_kind == ^kind and r.tag_id == ^id,
                 limit: 1
               )
             ) do
        {:ok, run}
      else
        _none -> {:error, :no_child}
      end
    end

    @doc """
    The turns the loop `loop_id` started, newest first:
    `list(parent: loop_id, turn: true)`.
    """
    @spec turns(Ecto.UUID.t()) :: [AgentRun.t()]
    def turns(loop_id), do: list(parent: loop_id, turn: true)

    @doc """
    The loop's raw inbox, oldest first, up to `limit:` (default 50): the
    inputs its next step will drain, as `Clementine.Loop.StoredInput`
    structs. Empty once a step has drained them into the controller's
    state, so not what a thread holds: `Clementine.Thread.waiting/1` is.
    For the doctor, and a controller's own tooling. A run that is not a
    loop has none.
    """
    @spec pending(Ecto.UUID.t(), keyword()) :: [StoredInput.t()]
    def pending(loop_id, opts \\ []) do
      case cast_id(loop_id) do
        {:ok, id} -> Loops.pending(id, Keyword.get(opts, :limit, 50), :any, nil)
        {:error, :not_found} -> []
      end
    end

    @doc """
    The doctor's read of the loop `loop_id`: everything a frozen loop's
    diagnosis needs, as a `Clementine.Loop.Report` (its facts, controller,
    envelope, live children with their statuses, timers, pending inputs
    with ages, dead letters, and the strands it diagnosed).
    `Clementine.Loop.Report.render/1` prints it. Nothing is written.
    """
    @spec inspect(Ecto.UUID.t()) :: {:ok, Report.t()} | {:error, :not_found | :not_a_loop}
    def inspect(loop_id) do
      with {:ok, id} <- cast_id(loop_id) do
        Report.gather(Loops, id, lifecycle: Lifecycle)
      end
    end

    @doc """
    Every loop with pending inputs: its id, how many wait, and the oldest
    one's age in milliseconds on the storage clock. The stuck detector's
    raw data; `emit_inbox_depths/0` emits it.
    """
    @spec inbox_depths() :: [
            %{loop_id: Ecto.UUID.t(), depth: non_neg_integer(), oldest_age_ms: non_neg_integer()}
          ]
    def inbox_depths, do: Loops.inbox_depths()

    @doc """
    Emits one `[:clementine, :loop, :inbox]` event per loop with pending
    inputs (`Clementine.Telemetry`), from one aggregate query: the
    measurement of a `:telemetry_poller` entry.

        {:telemetry_poller,
         measurements: [{Clementine.Runs, :emit_inbox_depths, []}],
         period: :timer.seconds(30)}
    """
    @spec emit_inbox_depths() :: :ok
    def emit_inbox_depths do
      Enum.each(inbox_depths(), fn row ->
        :telemetry.execute(
          [:clementine, :loop, :inbox],
          %{depth: row.depth, oldest_age_ms: row.oldest_age_ms},
          %{loop_ref: row.loop_id}
        )
      end)
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
      * `:parent` — a loop's id, the runs its steps started;
      * `:kind` — `:rollout` (the default) or `:loop`;
      * `:limit` — at most this many.

    A thread's turns are `list(subject: thread, turn: true)`; an audit of
    an account's runs, `list(actor: {"user", id})`; a loop's children,
    `list(parent: loop.id)`.
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

        {:parent, parent_id}, query ->
          case cast_id(parent_id) do
            {:ok, id} -> from(r in query, where: r.parent_id == ^id)
            {:error, :not_found} -> from(r in query, where: false)
          end

        {:kind, _kind}, query ->
          query

        {:limit, _limit}, query ->
          query

        {key, value}, _query ->
          raise ArgumentError, "unknown filter #{Kernel.inspect({key, value})}"
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
          raise ArgumentError,
                "#{Kernel.inspect(agent)} is not an agent or loop controller the child spec lists"
      end
    end
  end
end
