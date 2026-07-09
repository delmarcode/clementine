if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Clementine.Loop.Ecto.Migration do
    @moduledoc """
    The loop recipe additions (LOOP_RFC amendment A6) — like the lifecycle
    recipe, functions the host calls inside its own migrations, on its own
    tables. A host adopting loops on a table that already carries
    `Clementine.Lifecycle.Ecto.Migration.run_columns/0`:

        def change do
          alter table(:conversation_runs) do
            Clementine.Loop.Ecto.Migration.loop_columns()
            Clementine.Loop.Ecto.Migration.child_columns()
          end

          Clementine.Loop.Ecto.Migration.loop_scope_index(:conversation_runs)
          Clementine.Loop.Ecto.Migration.child_dedup_index(:conversation_runs)
          Clementine.Loop.Ecto.Migration.create_inbox(:conversation_loop_inbox)
        end

    (`kind` itself ships with `run_columns/0` — amendment A1; see that
    module's backfill note for tables migrated before it existed.)

    These helpers follow the append-only stability policy stated in
    `Clementine.Lifecycle.Ecto.Migration` (Helper stability): emitted DDL
    never changes under an existing name and arguments, so shipped host
    migrations replay identically on fresh databases across library
    upgrades.

    ## Loop columns

        loop_module    text     the behaviour module, persisted as string
        loop_args      jsonb    init/1's argument, JSON-safe
        loop_policy    jsonb    batch cap, dead-letter threshold, deadlines
        envelope       jsonb    Clementine.Loop.Envelope.encode/1 output
        state_version  integer  the app state version recorded per commit
        loop_scope     text     creation's idempotency key

    `loop_scope_index/2` makes the scope key unique where present —
    `Clementine.Loop.Protocol.create/3`'s insert-or-get grain. Rollout
    rows carry NULL and never collide.

    ## Child columns

        loop_ref   the parent loop's run row (same type as the table's pk)
        tag_key    Clementine.Loop.Codec.key/2 canonical form

    `child_dedup_index/2` is a **dedup** index, NOT single-active: unique
    on `(loop_ref, tag_key)` only *while the child is active*, so a crash
    replay's re-dispatch no-ops instead of duplicating a live child, while
    fan-out stays unconstrained by the machinery (five run actions, five
    children — one-at-a-time is `handle/2` logic, where it belongs). A
    terminal child frees its tag: live-key lifetime, the watcher's
    re-armed `:poll`.

    ## The inbox

    `create_inbox/2` creates the per-loop FIFO (host table, library
    semantics): ordered id, `kind`, codec-encoded `payload`, `dedup_key`
    unique per loop where present (the effectively-once grain for webhook
    retries, completions, elapses, and sends), `attempts` for the
    head-blame rule, and `dead_at`/`dead_reason` for retained dead-letter
    evidence. Consumed rows delete; dead letters are always retained —
    TTL/GC (and the GDPR answer) belong to the host, which owns the rows.

    ## Billing

    Every token a loop's children spend is recorded twice on this table
    by design: once on each child run row (its own terminal usage, the
    shipped rollout grain) and once again in the parent loop's aggregate —
    the step machinery folds completions' usage into the envelope and
    keeps the loop row's `usage` column current commit by commit (LOOP_RFC
    §Children). Billing queries must therefore discriminate on `kind`
    (amendment A1) and exclude loop-kind rows, or they will count every
    token twice:

        SELECT sum((usage->>'input_tokens')::bigint)
        FROM conversation_runs
        WHERE kind = 'rollout'

    The loop rows' aggregate is the *reporting* surface — per-agent
    spend in one read, no join — never the billing one.
    """

    import Ecto.Migration

    alias Clementine.Lifecycle.Facts

    @doc """
    Adds the loop-side columns. Call inside an `alter table(...)` (or
    `create table(...)`) block, alongside or after `run_columns/0`.
    """
    @spec loop_columns() :: :ok
    def loop_columns do
      add(:loop_module, :text)
      add(:loop_args, :map)
      add(:loop_policy, :map)
      add(:envelope, :map)
      add(:state_version, :integer)
      add(:loop_scope, :text)
      :ok
    end

    @doc """
    Adds the child-side columns. Call inside an `alter table(...)` block.

    Options:

      * `:type` — the `loop_ref` column type; must match the run table's
        primary key. Defaults to `:bigint`.
    """
    @spec child_columns(keyword()) :: :ok
    def child_columns(opts \\ []) do
      add(:loop_ref, Keyword.get(opts, :type, :bigint))
      add(:tag_key, :text)
      :ok
    end

    @doc """
    Creates the unique scope-key index creation's insert-or-get rides.
    Call at the migration's top level, after the columns exist.

    Options:

      * `:scope_column` — defaults to `:loop_scope`; override to match a
        `fields:` override on the adapter.
      * `:name` — index name; defaults to `<table>_loop_scope_index`.
    """
    @spec loop_scope_index(atom() | String.t(), keyword()) :: term()
    def loop_scope_index(table, opts \\ []) do
      scope_column = Keyword.get(opts, :scope_column, :loop_scope)
      name = Keyword.get(opts, :name, "#{table}_loop_scope_index")

      create(
        index(table, [scope_column],
          unique: true,
          name: name,
          where: "#{scope_column} IS NOT NULL"
        )
      )
    end

    @doc """
    Creates the `(loop_ref, tag_key)` dedup index — unique where active,
    NOT single-active (see the moduledoc). Call at the migration's top
    level, after the columns exist.

    Options:

      * `:loop_ref_column` / `:tag_key_column` / `:status_column` —
        default to `:loop_ref` / `:tag_key` / `:status`; override to match
        `fields:` overrides on the adapter.
      * `:name` — index name; defaults to `<table>_loop_child_dedup_index`.
    """
    @spec child_dedup_index(atom() | String.t(), keyword()) :: term()
    def child_dedup_index(table, opts \\ []) do
      loop_ref_column = Keyword.get(opts, :loop_ref_column, :loop_ref)
      tag_key_column = Keyword.get(opts, :tag_key_column, :tag_key)
      status_column = Keyword.get(opts, :status_column, :status)
      name = Keyword.get(opts, :name, "#{table}_loop_child_dedup_index")

      active = Enum.map_join(Facts.active_statuses(), ", ", &"'#{&1}'")

      create(
        index(table, [loop_ref_column, tag_key_column],
          unique: true,
          name: name,
          where: "#{status_column} IN (#{active})"
        )
      )
    end

    @doc """
    Creates the inbox table: the durable per-loop FIFO. Call at the
    migration's top level.

    Options:

      * `:loop_ref_type` — must match the run table's primary key type.
        Defaults to `:bigint`.

    Two indexes ship with the table: the pending-scan index
    (`(loop_ref, id) where dead_at IS NULL` — the FIFO window and the
    park re-check read it) and the dedup index (`(loop_ref, dedup_key)`
    unique where present).
    """
    @spec create_inbox(atom() | String.t(), keyword()) :: :ok
    def create_inbox(table, opts \\ []) do
      loop_ref_type = Keyword.get(opts, :loop_ref_type, :bigint)

      create table(table) do
        add(:loop_ref, loop_ref_type, null: false)
        add(:kind, :text, null: false)
        add(:payload, :map, null: false)
        add(:dedup_key, :text)
        add(:attempts, :integer, null: false, default: 0)
        add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
        add(:dead_at, :timestamptz)
        add(:dead_reason, :text)
      end

      create(
        index(table, [:loop_ref, :id],
          name: "#{table}_pending_index",
          where: "dead_at IS NULL"
        )
      )

      create(
        index(table, [:loop_ref, :dedup_key],
          unique: true,
          name: "#{table}_dedup_index",
          where: "dedup_key IS NOT NULL"
        )
      )

      :ok
    end
  end
end
