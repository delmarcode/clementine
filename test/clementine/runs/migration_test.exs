defmodule Clementine.MigrationTest do
  @moduledoc """
  `Clementine.Migration`'s versions are frozen: a host migration that says
  `version: 4` must build these exact tables under every later
  Clementine, and the upgrade path (`up(from: 1, version: 2)` on a version
  1 table, then `up(from: 2, version: 3)`, then `up(from: 3, version: 4)`)
  must build the same tables as `up(version: 4)` from scratch. If a
  snapshot here fails, a change reached a version's DDL; it belongs in a
  new version instead.

  The suite's own `agent_runs` came up by the upgrade path
  (`test_helper.exs`). The from-scratch and down paths run here inside
  the test's sandbox transaction, which Postgres's transactional DDL
  rolls back with it, so the suite's table is untouched.
  """

  # DDL on the suite's table: one test at a time, after every async one.
  use Clementine.EctoCase, async: false

  alias Clementine.Migration

  @v3_columns [
    {"id", "uuid", "NO", nil},
    {"agent_key", "text", "NO", nil},
    {"subject_type", "text", "YES", nil},
    {"subject_id", "text", "YES", nil},
    {"input", "jsonb", "NO", "'{}'::jsonb"},
    {"result", "jsonb", "YES", nil},
    {"oban_job_id", "bigint", "YES", nil},
    {"metadata", "jsonb", "NO", "'{}'::jsonb"},
    {"inserted_at", "timestamp without time zone", "NO", nil},
    {"updated_at", "timestamp without time zone", "NO", nil},
    {"kind", "text", "NO", "'rollout'::text"},
    {"status", "text", "NO", "'queued'::text"},
    {"lease_epoch", "bigint", "NO", "0"},
    {"executor_id", "text", "YES", nil},
    {"heartbeat_at", "timestamp with time zone", "YES", nil},
    {"deadline", "timestamp with time zone", "YES", nil},
    {"queued_at", "timestamp with time zone", "YES", "now()"},
    {"cancel", "jsonb", "YES", nil},
    {"suspension", "jsonb", "YES", nil},
    {"resume", "jsonb", "YES", nil},
    {"effects", "boolean", "NO", "false"},
    {"usage", "jsonb", "YES", nil},
    {"error", "jsonb", "YES", nil},
    {"interrupt", "jsonb", "YES", nil},
    {"finished_at", "timestamp with time zone", "YES", nil},
    {"actor_type", "text", "YES", nil},
    {"actor_id", "text", "YES", nil},
    {"turn", "boolean", "NO", "false"},
    {"loop_policy", "jsonb", "YES", nil},
    {"envelope", "jsonb", "YES", nil},
    {"state_version", "integer", "YES", nil},
    {"parent_id", "uuid", "YES", nil},
    {"tag_kind", "text", "YES", nil},
    {"tag_id", "text", "YES", nil}
  ]

  @v2_columns Enum.take(@v3_columns, 28)
  @v1_columns Enum.take(@v3_columns, 25)

  @inbox_columns [
    {"id", "bigint", "NO", "nextval('agent_run_inbox_id_seq'::regclass)"},
    {"run_id", "uuid", "NO", nil},
    {"kind", "text", "NO", nil},
    {"payload", "jsonb", "NO", nil},
    {"dedup_key", "text", "YES", nil},
    {"attempts", "integer", "NO", "0"},
    {"inserted_at", "timestamp with time zone", "NO", "now()"},
    {"dead_at", "timestamp with time zone", "YES", nil},
    {"dead_reason", "text", "YES", nil}
  ]

  @lane_index "CREATE UNIQUE INDEX agent_runs_lane_index ON public.agent_runs USING btree ((\n" <>
                "CASE\n    WHEN turn THEN ''::text\n    ELSE agent_key\nEND), subject_type, " <>
                "subject_id) WHERE ((status = ANY (ARRAY['queued'::text, 'running'::text, " <>
                "'waiting'::text])) AND (subject_id IS NOT NULL))"

  @single_active_index "CREATE UNIQUE INDEX agent_runs_single_active_run_index ON " <>
                         "public.agent_runs USING btree (agent_key, subject_type, subject_id) " <>
                         "WHERE ((status = ANY (ARRAY['queued'::text, 'running'::text, " <>
                         "'waiting'::text])) AND (kind = 'rollout'::text))"

  @child_tag_index "CREATE UNIQUE INDEX agent_runs_child_tag_index ON public.agent_runs " <>
                     "USING btree (parent_id, tag_kind, tag_id) WHERE ((status = ANY " <>
                     "(ARRAY['queued'::text, 'running'::text, 'waiting'::text])) AND " <>
                     "(parent_id IS NOT NULL))"

  @parent_index "CREATE INDEX agent_runs_parent_index ON public.agent_runs USING btree " <>
                  "(parent_id) WHERE (parent_id IS NOT NULL)"

  @plain_indexes [
    {"agent_runs_agent_key_index",
     "CREATE INDEX agent_runs_agent_key_index ON public.agent_runs USING btree (agent_key)"},
    {"agent_runs_kind_status_index",
     "CREATE INDEX agent_runs_kind_status_index ON public.agent_runs USING btree (kind, status)"},
    {"agent_runs_oban_job_id_index",
     "CREATE INDEX agent_runs_oban_job_id_index ON public.agent_runs USING btree (oban_job_id)"},
    {"agent_runs_pkey",
     "CREATE UNIQUE INDEX agent_runs_pkey ON public.agent_runs USING btree (id)"},
    {"agent_runs_subject_type_subject_id_index",
     "CREATE INDEX agent_runs_subject_type_subject_id_index ON public.agent_runs USING btree " <>
       "(subject_type, subject_id)"}
  ]

  @v1_indexes Enum.sort([
                {"agent_runs_single_active_run_index", @single_active_index} | @plain_indexes
              ])
  @v2_indexes Enum.sort([{"agent_runs_lane_index", @lane_index} | @plain_indexes])
  @trace_columns [
    {"id", "bigint", "NO", "nextval('agent_run_trace_id_seq'::regclass)"},
    {"run_id", "uuid", "NO", nil},
    {"epoch", "integer", "NO", nil},
    {"seq", "integer", "NO", nil},
    {"kind", "text", "NO", nil},
    {"payload", "jsonb", "NO", nil},
    {"inserted_at", "timestamp with time zone", "NO", "now()"}
  ]

  @trace_indexes [
    {"agent_run_trace_entry_index",
     "CREATE UNIQUE INDEX agent_run_trace_entry_index ON public.agent_run_trace USING btree " <>
       "(run_id, epoch, seq)"},
    {"agent_run_trace_pkey",
     "CREATE UNIQUE INDEX agent_run_trace_pkey ON public.agent_run_trace USING btree (id)"},
    {"agent_run_trace_run_index",
     "CREATE INDEX agent_run_trace_run_index ON public.agent_run_trace USING btree (run_id, id)"}
  ]

  @trace_constraints [
    {"agent_run_trace_pkey", "PRIMARY KEY (id)"},
    {"agent_run_trace_run_id_fkey",
     "FOREIGN KEY (run_id) REFERENCES agent_runs(id) ON DELETE CASCADE"}
  ]

  @v3_indexes Enum.sort([
                {"agent_runs_child_tag_index", @child_tag_index},
                {"agent_runs_parent_index", @parent_index} | @v2_indexes
              ])

  @inbox_indexes [
    {"agent_run_inbox_dedup_index",
     "CREATE UNIQUE INDEX agent_run_inbox_dedup_index ON public.agent_run_inbox USING btree " <>
       "(run_id, dedup_key) WHERE (dedup_key IS NOT NULL)"},
    {"agent_run_inbox_pending_index",
     "CREATE INDEX agent_run_inbox_pending_index ON public.agent_run_inbox USING btree " <>
       "(run_id, id) WHERE (dead_at IS NULL)"},
    {"agent_run_inbox_pkey",
     "CREATE UNIQUE INDEX agent_run_inbox_pkey ON public.agent_run_inbox USING btree (id)"}
  ]

  @v1_constraints [{"agent_runs_pkey", "PRIMARY KEY (id)"}]

  @v2_constraints [
    {"agent_runs_actor_typed", "CHECK (((actor_id IS NULL) OR (actor_type IS NOT NULL)))"},
    {"agent_runs_agent_key_present", "CHECK ((agent_key <> ''::text))"},
    {"agent_runs_pkey", "PRIMARY KEY (id)"},
    {"agent_runs_subject_typed", "CHECK (((subject_id IS NULL) OR (subject_type IS NOT NULL)))"},
    {"agent_runs_turn_has_subject", "CHECK (((NOT turn) OR (subject_id IS NOT NULL)))"}
  ]

  @v3_constraints Enum.sort([
                    {"agent_runs_child_tagged",
                     "CHECK (((parent_id IS NULL) = (tag_kind IS NULL)))"},
                    {"agent_runs_loop_shape",
                     "CHECK (((kind <> 'loop'::text) OR ((turn = false) AND (parent_id IS NULL))))"},
                    {"agent_runs_parent_id_fkey",
                     "FOREIGN KEY (parent_id) REFERENCES agent_runs(id) ON DELETE RESTRICT"},
                    {"agent_runs_tag_whole", "CHECK (((tag_kind IS NULL) = (tag_id IS NULL)))"}
                    | @v2_constraints
                  ])

  @inbox_constraints [
    {"agent_run_inbox_pkey", "PRIMARY KEY (id)"},
    {"agent_run_inbox_run_id_fkey",
     "FOREIGN KEY (run_id) REFERENCES agent_runs(id) ON DELETE CASCADE"}
  ]

  defmodule FromScratch do
    use Ecto.Migration
    def up, do: Clementine.Migration.up(version: 4)
    def down, do: Clementine.Migration.down(version: 4)
  end

  defmodule Version3 do
    use Ecto.Migration
    def up, do: Clementine.Migration.up(version: 3)
    def down, do: Clementine.Migration.down(version: 3)
  end

  defmodule Version1 do
    use Ecto.Migration
    def up, do: Clementine.Migration.up(version: 1)
    def down, do: Clementine.Migration.down(version: 1)
  end

  defmodule Version2 do
    use Ecto.Migration
    def up, do: Clementine.Migration.up(version: 2)
    def down, do: Clementine.Migration.down(version: 2)
  end

  defmodule UpgradeTo2 do
    use Ecto.Migration
    def up, do: Clementine.Migration.up(from: 1, version: 2)
    def down, do: Clementine.Migration.down(to: 1, version: 2)
  end

  defmodule UpgradeTo3 do
    use Ecto.Migration
    def up, do: Clementine.Migration.up(from: 2, version: 3)
    def down, do: Clementine.Migration.down(to: 2, version: 3)
  end

  defmodule UpgradeTo4 do
    use Ecto.Migration
    def up, do: Clementine.Migration.up(from: 3, version: 4)
    def down, do: Clementine.Migration.down(to: 3, version: 4)
  end

  test "the upgrade path built the frozen version 4 schema" do
    assert_version_4!()
  end

  test "up(version: 4) from scratch builds the same schema" do
    drop_table!()
    migrate!(:up, FromScratch)

    assert_version_4!()
  end

  test "up(version: 3) from scratch builds the frozen version 3 schema" do
    drop_table!()
    migrate!(:up, Version3)

    assert_version_3!()
  end

  test "up(version: 2) from scratch builds the frozen version 2 schema" do
    drop_table!()
    migrate!(:up, Version2)

    assert_version_2!()
  end

  test "the upgrades bring a hand-rolled version 1 table through 2 to the same schema" do
    drop_table!()
    migrate!(:up, Version1)
    # A table built by hand to match version 1 carries no stamp.
    TestRepo.query!("COMMENT ON TABLE agent_runs IS NULL")

    assert columns("agent_runs") == @v1_columns
    assert indexes("agent_runs") == @v1_indexes
    assert constraints("agent_runs") == @v1_constraints
    assert Migration.migrated_version(TestRepo) == :unstamped

    migrate!(:up, UpgradeTo2)
    assert_version_2!()

    migrate!(:up, UpgradeTo3)
    assert_version_3!()

    migrate!(:up, UpgradeTo4)
    assert_version_4!()
  end

  test "down(to: 3, version: 4) restores version 3, and down(version: 4) drops every table" do
    # The suite's own upgrade migration, as the host would roll it back.
    Ecto.Migrator.down(
      TestRepo,
      20_261_029_000_001,
      Clementine.Test.Ecto.UpgradeAgentRunsToVersion4,
      log: false,
      log_migrator_sql: false,
      migration_lock: false
    )

    assert_version_3!()
    assert columns("agent_run_trace") == []

    version = migrate!(:up, UpgradeTo4)
    assert_version_4!()

    migrate!(:down, UpgradeTo4, version)
    assert_version_3!()

    drop_table!()
    version = migrate!(:up, FromScratch)
    assert_version_4!()

    migrate!(:down, FromScratch, version)
    assert columns("agent_runs") == []
    assert columns("agent_run_inbox") == []
    assert columns("agent_run_trace") == []
    assert Migration.migrated_version(TestRepo) == :missing
  end

  test "down(to: 2, version: 3) restores version 2" do
    drop_table!()
    migrate!(:up, Version2)
    version = migrate!(:up, UpgradeTo3)
    assert_version_3!()

    migrate!(:down, UpgradeTo3, version)
    assert_version_2!()
    assert columns("agent_run_inbox") == []
  end

  test "the version stamp reads back, and the check names the migration to write" do
    assert Migration.migrated_version(TestRepo) == 4
    assert Migration.check!(TestRepo) == :ok

    TestRepo.query!("COMMENT ON TABLE agent_runs IS '3'")
    assert Migration.migrated_version(TestRepo) == 3

    assert_raise RuntimeError, ~r/at version 3: .*up\(from: 3, version: 4\)/, fn ->
      Migration.check!(TestRepo)
    end

    TestRepo.query!("COMMENT ON TABLE agent_runs IS NULL")
    assert Migration.migrated_version(TestRepo) == :unstamped

    assert_raise RuntimeError,
                 ~r/no version stamp \(version 1\): .*up\(from: 1, version: 4\)/,
                 fn ->
                   Migration.check!(TestRepo)
                 end

    # The code rolled back after a migration: the table is ahead, and
    # starts.
    TestRepo.query!("COMMENT ON TABLE agent_runs IS '5'")
    assert Migration.migrated_version(TestRepo) == 5
    assert Migration.check!(TestRepo) == :ok

    drop_table!()
    assert Migration.migrated_version(TestRepo) == :missing

    assert_raise RuntimeError, ~r/has none: .*up\(version: 4\)/, fn ->
      Migration.check!(TestRepo)
    end
  end

  defp assert_version_4! do
    assert columns("agent_runs") == @v3_columns
    assert indexes("agent_runs") == @v3_indexes
    assert constraints("agent_runs") == @v3_constraints
    assert columns("agent_run_inbox") == @inbox_columns
    assert indexes("agent_run_inbox") == @inbox_indexes
    assert constraints("agent_run_inbox") == @inbox_constraints
    assert columns("agent_run_trace") == @trace_columns
    assert indexes("agent_run_trace") == @trace_indexes
    assert constraints("agent_run_trace") == @trace_constraints
    assert Migration.migrated_version(TestRepo) == 4
  end

  defp assert_version_3! do
    assert columns("agent_runs") == @v3_columns
    assert indexes("agent_runs") == @v3_indexes
    assert constraints("agent_runs") == @v3_constraints
    assert columns("agent_run_inbox") == @inbox_columns
    assert indexes("agent_run_inbox") == @inbox_indexes
    assert constraints("agent_run_inbox") == @inbox_constraints
    assert columns("agent_run_trace") == []
    assert Migration.migrated_version(TestRepo) == 3
  end

  defp assert_version_2! do
    assert columns("agent_runs") == @v2_columns
    assert indexes("agent_runs") == @v2_indexes
    assert constraints("agent_runs") == @v2_constraints
    assert Migration.migrated_version(TestRepo) == 2
  end

  # The inbox and the trace reference agent_runs, so they go first.
  defp drop_table! do
    TestRepo.query!("DROP TABLE IF EXISTS agent_run_trace")
    TestRepo.query!("DROP TABLE IF EXISTS agent_run_inbox")
    TestRepo.query!("DROP TABLE agent_runs")
  end

  # The sandbox's connection carries the migration, so its DDL rolls back
  # with the test, and so does the migrator's record of the version. An up
  # registers a fresh version, later than the suite's own; a down must name
  # the version its up registered, or the migrator finds nothing to undo.
  defp migrate!(direction, module, version \\ nil) do
    version = version || 20_261_029_000_001 + System.unique_integer([:positive, :monotonic])

    apply(Ecto.Migrator, direction, [
      TestRepo,
      version,
      module,
      [log: false, log_migrator_sql: false, migration_lock: false]
    ])

    version
  end

  defp columns(table) do
    TestRepo.query!(
      """
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_name = $1
      ORDER BY ordinal_position
      """,
      [table]
    ).rows
    |> Enum.map(&List.to_tuple/1)
  end

  defp indexes(table) do
    TestRepo.query!(
      "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = $1 ORDER BY indexname",
      [table]
    ).rows
    |> Enum.map(&List.to_tuple/1)
  end

  defp constraints(table) do
    TestRepo.query!(
      """
      SELECT conname, pg_get_constraintdef(oid)
      FROM pg_constraint WHERE conrelid = to_regclass($1) ORDER BY conname
      """,
      [table]
    ).rows
    |> Enum.map(&List.to_tuple/1)
  end
end
