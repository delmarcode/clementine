if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Clementine.Migration do
    @moduledoc """
    The `agent_runs` table the durable runtime (`Clementine.Runs`) runs on,
    as numbered versions, the way `Oban.Migration` ships `oban_jobs`. The
    host keeps one migration per version it adopts:

        defmodule MyApp.Repo.Migrations.AddClementine do
          use Ecto.Migration

          def up, do: Clementine.Migration.up(version: 4)
          def down, do: Clementine.Migration.down(version: 4)
        end

    Each version's DDL is frozen here: a migration that says `version: 1`
    builds the same table under every later Clementine. A host on an
    earlier version adopts a later one in a new migration with
    `up(from: 3, version: 4)`.

    ## The version stamp

    Every version ends by stamping its number on the table
    (`comment on table agent_runs is '3'`), and `migrated_version/1` reads
    it. The runtime checks the stamp as it starts and refuses to start
    against a table behind the code's version, naming the migration to
    write, so the table and the code that writes it move together. A
    table with no stamp was built before stamps, or by hand to match
    version 1; the check takes it for version 1. A table ahead of the code
    (the code rolled back after a migration) starts.

    ## Version 4

    The run's trace (`Clementine.Runs.trace/1`), a table of its own that
    only Clementine writes:

        agent_run_trace
          id           bigserial primary key
          run_id       uuid, not null, references agent_runs(id) on delete cascade
          epoch        integer, not null   the execution that recorded the entry
          seq          integer, not null   its number within that execution
          kind         text, not null      execution | model_call | tool_call
          payload      jsonb, not null
          inserted_at  timestamptz, not null, default now()
          index agent_run_trace_run_index on (run_id, id)

    The cascade erases a run's trace with the run, so `Clementine.Runs.purge/1`
    takes it. `up(from: 3, version: 4)` creates the table and touches no
    row of `agent_runs`.

    ## Version 3

    Loops are runs (`Clementine.Runs.start_loop/3`): a loop's row has
    `kind = 'loop'`, its controller's key in `agent_key`, its args in
    `input`, and three columns of its own; a run a loop's step started
    points at its parent and carries its tag; and the loop's inbox is a
    table of its own.

        loop_policy    jsonb     batch cap, dead-letter threshold, deadline_ms
        envelope       jsonb     the controller's state as it last committed it
        state_version  integer   the controller's declared state version then
        parent_id      uuid      references agent_runs(id) on delete restrict
        tag_kind       text      the child's tag, in two halves
        tag_id         text
        check agent_runs_tag_whole    ((tag_kind is null) = (tag_id is null))
        check agent_runs_child_tagged ((parent_id is null) = (tag_kind is null))
        check agent_runs_loop_shape   (kind <> 'loop' or (turn = false and parent_id is null))
        unique index agent_runs_child_tag_index on (parent_id, tag_kind, tag_id)
          where status in ('queued', 'running', 'waiting') and parent_id is not null
        index agent_runs_parent_index on (parent_id) where parent_id is not null

        agent_run_inbox
          id           bigserial primary key
          run_id       uuid, not null, references agent_runs(id) on delete cascade
          kind         text, not null        message | completed | elapsed | input_failed
          payload      jsonb, not null
          dedup_key    text
          attempts     integer, not null, default 0
          inserted_at  timestamptz, not null, default now()
          dead_at      timestamptz
          dead_reason  text
          index agent_run_inbox_pending_index on (run_id, id) where dead_at is null
          unique index agent_run_inbox_dedup_index on (run_id, dedup_key) where dedup_key is not null

    A loop occupies the lane like any run: `kind = 'loop'`, `turn = false`,
    `agent_key = "thread"`, `subject = ("conversation", id)` gives lane
    `("thread", "conversation", id)`, which is what makes `start_loop/3`
    insert-or-get. Its turns, `turn = true` on the same subject, sit in
    lane `('', "conversation", id)`, and a task of another agent in its
    own; none collide. The child tag index is the other half of one live
    child per tag: a tag re-arms once its child is terminal.

    ## Version 2

    Adds the actor, the turn flag, and the lane:

        actor_type    text               whose authority the run acts with
        actor_id      text               (`Clementine.Runs.start/3`, `actor:`)
        turn          boolean, not null  a run on a thread; false by default
        check agent_runs_agent_key_present (agent_key <> '')
        check agent_runs_turn_has_subject  (not turn or subject_id is not null)
        check agent_runs_subject_typed     (subject_id is null or subject_type is not null)
        check agent_runs_actor_typed       (actor_id is null or actor_type is not null)
        unique index agent_runs_lane_index on
          ((case when turn then '' else agent_key end), subject_type, subject_id)
          where status in ('queued', 'running', 'waiting') and subject_id is not null

    in place of version 1's `agent_runs_single_active_run_index`.

    The index states lane exclusivity: every active run (queued, running,
    or waiting) with a subject occupies one lane, and a lane holds at most
    one active run. A turn's lane is its thread, `('', type, id)`,
    whichever agent it belongs to, so two turns of different agents on one
    thread collide. A task's lane is `(agent_key, type, id)`, so tasks of
    different agents on one subject never collide, and neither do a turn
    and a task. The first check keeps the two sets apart (a key is never
    `''`), and three columns rather than one joined string keep ids that
    contain colons from aliasing. A run with no subject id has no lane and
    blocks nothing: NULLs are distinct in a unique index, and the
    predicate says so besides. The other three checks keep a row from
    slipping out of its lane through a NULL: a turn always has a subject
    id, and a subject or actor id always has a type. The predicate has no
    `kind` term: a loop (version 3) occupies its lane like any run.

    `up(from: 1, version: 2)` adds `turn` as `false` on every existing
    row and backfills nothing: which keys belong to turn agents is the
    host's code, not the table's. A host whose version 1 table holds
    rows sets `turn` for its turn agents' rows in the same migration,
    right after the upgrade, so the index swap and the backfill commit
    together and an active turn keeps its thread:

        Clementine.Migration.up(from: 1, version: 2)
        execute "UPDATE agent_runs SET turn = true WHERE agent_key IN ('chat')"

    ## Version 1

    `agent_runs`, keyed by UUID:

        agent_key     text, not null     the agent's key (Clementine.Agent)
        subject_type  text               what the run is about; at most one
        subject_id    text               active run per agent and subject
        input         jsonb              %{"prompt" => ...}
        result        jsonb              %{"output" => ...} once completed
        oban_job_id   bigint             the run's current job
        metadata      jsonb              the app's, stored as given
        inserted_at, updated_at

    plus the lifecycle columns of the column recipe
    (version 1) and its
    single-active index on `(agent_key, subject_type, subject_id)`, which
    counts queued, running, and waiting rollout runs as active.
    """

    import Ecto.Migration

    @table :agent_runs
    @inbox :agent_run_inbox
    @trace :agent_run_trace
    @current_version 4

    @doc "The newest version `up/1` can apply."
    @spec current_version() :: pos_integer()
    def current_version, do: @current_version

    @doc """
    Migrates `agent_runs` from version `:from` (default `0`, no table)
    through `:version`. `:version` is required, so a migration always names
    the DDL it was written against.
    """
    @spec up(keyword()) :: :ok
    def up(opts) do
      {from, version} = range!(opts, :from)

      for step <- (from + 1)..version//1, do: step_up(step)
      :ok
    end

    @doc """
    Reverses `up/1`: removes versions `:version` down through `:to` + 1
    (default `0`, dropping the table).
    """
    @spec down(keyword()) :: :ok
    def down(opts) do
      {to, version} = range!(opts, :to)

      for step <- version..(to + 1)//-1, do: step_down(step)
      :ok
    end

    @doc """
    The version stamped on `repo`'s `agent_runs` table: `:missing` when
    there is no table, `:unstamped` when it carries no stamp (built before
    stamps, or by hand), else the number.
    """
    @spec migrated_version(module()) :: pos_integer() | :unstamped | :missing
    def migrated_version(repo) do
      %{rows: [[table, comment]]} =
        repo.query!(
          "SELECT to_regclass('agent_runs')::text, " <>
            "obj_description(to_regclass('agent_runs'), 'pg_class')"
        )

      # A comment that is not a bare number is some earlier description of
      # the table, not a stamp.
      case {table, comment && Integer.parse(comment)} do
        {nil, _comment} -> :missing
        {_table, {version, ""}} when version > 0 -> version
        {_table, _other} -> :unstamped
      end
    end

    @doc """
    Raises unless `repo`'s `agent_runs` is at `current_version/0` or past
    it, naming the migration to write. The runtime calls it as it starts.
    """
    @spec check!(module()) :: :ok
    def check!(repo) do
      case migrated_version(repo) do
        version when is_integer(version) and version >= @current_version ->
          :ok

        :missing ->
          raise RuntimeError,
                "Clementine's durable runtime needs the agent_runs table at version " <>
                  "#{@current_version}, and #{inspect(repo)} has none: add a migration " <>
                  "calling Clementine.Migration.up(version: #{@current_version})"

        behind ->
          {from, found} =
            case behind do
              :unstamped -> {1, "with no version stamp (version 1)"}
              version -> {version, "at version #{version}"}
            end

          raise RuntimeError,
                "Clementine's durable runtime needs the agent_runs table at version " <>
                  "#{@current_version}, and #{inspect(repo)} has it #{found}: add a " <>
                  "migration calling Clementine.Migration.up(from: #{from}, " <>
                  "version: #{@current_version})"
      end
    end

    defp range!(opts, floor_key) do
      version = Keyword.fetch!(opts, :version)
      floor = Keyword.get(opts, floor_key, 0)

      unless version in 1..@current_version//1 and floor in 0..version//1 do
        raise ArgumentError,
              "Clementine.Migration versions run 1..#{@current_version}; got " <>
                "#{floor_key}: #{inspect(floor)}, version: #{inspect(version)}"
      end

      {floor, version}
    end

    # Frozen: a version's DDL never changes, and a new version is a new
    # pair of clauses. The stamp is not DDL (stamp/1), which is how version
    # 1 came to end with one.
    defp step_up(1) do
      create table(@table, primary_key: false) do
        add(:id, :binary_id, primary_key: true)
        add(:agent_key, :text, null: false)
        add(:subject_type, :text)
        add(:subject_id, :text)
        add(:input, :map, null: false, default: %{})
        add(:result, :map)
        add(:oban_job_id, :bigint)
        add(:metadata, :map, null: false, default: %{})

        timestamps(type: :utc_datetime_usec)
      end

      Clementine.Lifecycle.Ecto.Migration.up(@table,
        version: 1,
        scope: [:agent_key, :subject_type, :subject_id]
      )

      create(index(@table, [:kind, :status]))
      create(index(@table, [:agent_key]))
      create(index(@table, [:subject_type, :subject_id]))
      create(index(@table, [:oban_job_id]))
      stamp(1)
    end

    defp step_up(2) do
      alter table(@table) do
        add(:actor_type, :text)
        add(:actor_id, :text)
        add(:turn, :boolean, null: false, default: false)
      end

      create(constraint(@table, :agent_runs_agent_key_present, check: "agent_key <> ''"))

      # The lane is a tuple of three columns: a NULL in any of them would
      # take a row out of the index, so a turn always has a subject id,
      # and an id always has a type.
      create(
        constraint(@table, :agent_runs_turn_has_subject,
          check: "NOT turn OR subject_id IS NOT NULL"
        )
      )

      create(
        constraint(@table, :agent_runs_subject_typed,
          check: "subject_id IS NULL OR subject_type IS NOT NULL"
        )
      )

      create(
        constraint(@table, :agent_runs_actor_typed,
          check: "actor_id IS NULL OR actor_type IS NOT NULL"
        )
      )

      drop(index(@table, [], name: :agent_runs_single_active_run_index))

      create(
        unique_index(
          @table,
          ["(CASE WHEN turn THEN '' ELSE agent_key END)", :subject_type, :subject_id],
          name: :agent_runs_lane_index,
          where: "status IN ('queued', 'running', 'waiting') AND subject_id IS NOT NULL"
        )
      )

      stamp(2)
    end

    defp step_up(3) do
      alter table(@table) do
        add(:loop_policy, :map)
        add(:envelope, :map)
        add(:state_version, :integer)
        add(:parent_id, references(@table, type: :binary_id, on_delete: :restrict))
        add(:tag_kind, :text)
        add(:tag_id, :text)
      end

      create(
        constraint(@table, :agent_runs_tag_whole, check: "(tag_kind IS NULL) = (tag_id IS NULL)")
      )

      create(
        constraint(@table, :agent_runs_child_tagged,
          check: "(parent_id IS NULL) = (tag_kind IS NULL)"
        )
      )

      create(
        constraint(@table, :agent_runs_loop_shape,
          check: "kind <> 'loop' OR (turn = false AND parent_id IS NULL)"
        )
      )

      create(
        unique_index(@table, [:parent_id, :tag_kind, :tag_id],
          name: :agent_runs_child_tag_index,
          where: "status IN ('queued', 'running', 'waiting') AND parent_id IS NOT NULL"
        )
      )

      create(
        index(@table, [:parent_id],
          name: :agent_runs_parent_index,
          where: "parent_id IS NOT NULL"
        )
      )

      create table(@inbox) do
        add(:run_id, references(@table, type: :binary_id, on_delete: :delete_all), null: false)
        add(:kind, :text, null: false)
        add(:payload, :map, null: false)
        add(:dedup_key, :text)
        add(:attempts, :integer, null: false, default: 0)
        add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
        add(:dead_at, :timestamptz)
        add(:dead_reason, :text)
      end

      create(
        index(@inbox, [:run_id, :id],
          name: :agent_run_inbox_pending_index,
          where: "dead_at IS NULL"
        )
      )

      create(
        unique_index(@inbox, [:run_id, :dedup_key],
          name: :agent_run_inbox_dedup_index,
          where: "dedup_key IS NOT NULL"
        )
      )

      stamp(3)
    end

    defp step_up(4) do
      create table(@trace) do
        add(:run_id, references(@table, type: :binary_id, on_delete: :delete_all), null: false)
        add(:epoch, :integer, null: false)
        add(:seq, :integer, null: false)
        add(:kind, :text, null: false)
        add(:payload, :map, null: false)
        add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
      end

      create(index(@trace, [:run_id, :id], name: :agent_run_trace_run_index))
      stamp(4)
    end

    defp step_down(4) do
      drop(table(@trace))
      stamp(3)
    end

    defp step_down(3) do
      drop(table(@inbox))
      drop(index(@table, [], name: :agent_runs_parent_index))
      drop(index(@table, [], name: :agent_runs_child_tag_index))
      drop(constraint(@table, :agent_runs_loop_shape))
      drop(constraint(@table, :agent_runs_child_tagged))
      drop(constraint(@table, :agent_runs_tag_whole))

      alter table(@table) do
        remove(:tag_id)
        remove(:tag_kind)
        remove(:parent_id)
        remove(:state_version)
        remove(:envelope)
        remove(:loop_policy)
      end

      stamp(2)
    end

    defp step_down(2) do
      drop(index(@table, [], name: :agent_runs_lane_index))

      create(
        unique_index(@table, [:agent_key, :subject_type, :subject_id],
          name: :agent_runs_single_active_run_index,
          where: "status IN ('queued', 'running', 'waiting') AND kind = 'rollout'"
        )
      )

      drop(constraint(@table, :agent_runs_actor_typed))
      drop(constraint(@table, :agent_runs_subject_typed))
      drop(constraint(@table, :agent_runs_turn_has_subject))
      drop(constraint(@table, :agent_runs_agent_key_present))

      alter table(@table) do
        remove(:turn)
        remove(:actor_id)
        remove(:actor_type)
      end

      stamp(1)
    end

    defp step_down(1) do
      drop(table(@table))
    end

    # The table's version, as obj_description reads it. Version 1 stamps
    # too: the stamp is part of every version, so a down from 2 lands on a
    # stamped 1, and a version 1 table built before stamps reads as
    # :unstamped, which the check takes for 1.
    defp stamp(version) do
      execute("COMMENT ON TABLE #{@table} IS '#{version}'")
    end
  end
end
