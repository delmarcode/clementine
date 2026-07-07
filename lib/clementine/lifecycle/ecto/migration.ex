if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Clementine.Lifecycle.Ecto.Migration do
    @moduledoc """
    The column recipe — not a managed table. The host calls these helpers
    inside its own migration, on its own table, and keeps the table name,
    foreign keys, product columns, and migration history:

        def change do
          alter table(:conversation_runs) do
            Clementine.Lifecycle.Ecto.Migration.run_columns()
          end

          Clementine.Lifecycle.Ecto.Migration.single_active_index(
            :conversation_runs, scope: :conversation_id
          )
        end

    The recipe adds exactly the columns `Clementine.Lifecycle.Facts`
    demands, so `fetch` round-trips facts exactly:

        kind          text default 'rollout'   status       text
        lease_epoch   bigint default 0         executor_id  text
        heartbeat_at  timestamptz              deadline     timestamptz
        queued_at     timestamptz
        cancel        jsonb   (reason, requested_at)
        suspension    jsonb   (reason, checkpoint, token)
        resume        jsonb   (payload, resumed_at)
        effects       boolean default false    usage        jsonb
        error         jsonb   (normalized Error, :failed runs)
        interrupt     jsonb   (InterruptReason, :interrupted runs)
        finished_at   timestamptz

    `queued_at` defaults to `now()` so enqueue-time inserts stamp it for
    free — the reaper's claim-timeout check counts from it. Apps wanting an
    indexable denormalization (an `error_code` text column, say) add their
    own generated column; the recipe's columns are the contract.

    ## Backfill for existing adopters

    `kind` arrived with LOOP_RFC amendment A1; tables migrated before it
    add the column in one line, and the default *is* the backfill — every
    pre-loop row is a rollout run:

        alter table(:conversation_runs) do
          add(:kind, :text, null: false, default: "rollout")
        end

    (On Postgres 11+ a constant default backfills without a table
    rewrite.) The reaper's rollout sweep, billing queries, and any scoped
    index should discriminate on the column from then on — see
    `Clementine.Reconciler` for the sweep exclusion, and recreate a
    single-active index built before the column existed with
    `single_active_index/2` so its predicate gains the kind
    discrimination.

    Write-load note: steady state is one small `UPDATE` per active run per
    heartbeat interval — HOT-update friendly, since the recipe keeps hot
    columns small and the heartbeat never rewrites the large jsonb columns.
    The `suspension` write happens once per suspension and is bounded by
    context-window size; if your checkpoints run large, move the value to a
    side table behind your `apply` (see the adapter moduledoc's escape
    hatch).

    ## The single-active index, and its product consequence

    `single_active_index/2` enforces one active *rollout* run per scope —
    the single-flight guard (failure matrix row 6: a double-send's second
    run is uninsertable at enqueue). By default "active" means
    `queued`, `running`, **and `waiting`** — and that default is a product
    decision made deliberately: a run parked in `waiting` for days blocks
    new runs in its scope. A product that wants "chat continues while an
    approval is parked" passes `statuses: [:queued, :running]` and owns the
    resulting concurrency (two runs of the same conversation may then
    interleave when the parked one resumes).

    The predicate covers rollout-kind rows only (amendment A1: scoped
    indexes discriminate on `kind`): a loop is permanently active by
    design, so an undiscriminated index would let one loop block every
    rollout insert in its scope forever. Loop-kind dedup is its own
    mechanism — the `(loop_ref, tag_key)` index, amendment A6.
    """

    import Ecto.Migration

    alias Clementine.Lifecycle.Facts

    @doc """
    Adds the recipe columns. Call inside an `alter table(...)` (or
    `create table(...)`) block.
    """
    @spec run_columns() :: :ok
    def run_columns do
      add(:kind, :text, null: false, default: "rollout")
      add(:status, :text, null: false, default: "queued")
      add(:lease_epoch, :bigint, null: false, default: 0)
      add(:executor_id, :text)
      add(:heartbeat_at, :timestamptz)
      add(:deadline, :timestamptz)
      add(:queued_at, :timestamptz, default: fragment("now()"))
      add(:cancel, :map)
      add(:suspension, :map)
      add(:resume, :map)
      add(:effects, :boolean, null: false, default: false)
      add(:usage, :map)
      add(:error, :map)
      add(:interrupt, :map)
      add(:finished_at, :timestamptz)
      :ok
    end

    @doc """
    Creates the partial unique index enforcing one active rollout run per
    scope. Call at the migration's top level, after the columns exist
    (the predicate reads both the status and the kind column).

    Options:

      * `:scope` (required) — the scoping column (or list of columns), e.g.
        `:conversation_id`.
      * `:statuses` — which statuses count as active. Defaults to
        `[:queued, :running, :waiting]`; see the moduledoc for the product
        consequence before narrowing it.
      * `:status_column` — defaults to `:status`; override to match a
        `fields:` override on the adapter.
      * `:kind_column` — defaults to `:kind`; override to match a
        `fields:` override on the adapter.
      * `:name` — index name; defaults to
        `<table>_single_active_run_index`.
    """
    @spec single_active_index(atom() | String.t(), keyword()) :: term()
    def single_active_index(table, opts) do
      scope = opts |> Keyword.fetch!(:scope) |> List.wrap()
      statuses = Keyword.get(opts, :statuses, [:queued, :running, :waiting])
      status_column = Keyword.get(opts, :status_column, :status)
      kind_column = Keyword.get(opts, :kind_column, :kind)
      name = Keyword.get(opts, :name, "#{table}_single_active_run_index")

      case statuses -- Facts.active_statuses() do
        [] ->
          :ok

        invalid ->
          raise ArgumentError,
                "single_active_index statuses must be active statuses, got: #{inspect(invalid)}"
      end

      in_list = Enum.map_join(statuses, ", ", &"'#{&1}'")

      create(
        index(table, scope,
          unique: true,
          name: name,
          where: "#{status_column} IN (#{in_list}) AND #{kind_column} = 'rollout'"
        )
      )
    end
  end
end
