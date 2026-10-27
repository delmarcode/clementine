defmodule Clementine.MigrationTest do
  @moduledoc """
  `Clementine.Migration`'s versions are frozen: a host migration that says
  `version: 2` must build this exact table under every later Clementine,
  and `up(from: 1, version: 2)` on a version 1 table (the library's, which
  a hand-rolled one matches column by column) must build the same table.
  If a snapshot here fails, a change reached a version's DDL; it belongs
  in a new version instead.

  The suite's own `agent_runs` came up by the upgrade path
  (`test_helper.exs`). The from-scratch and down paths run here inside
  the test's sandbox transaction, which Postgres's transactional DDL
  rolls back with it, so the suite's table is untouched.
  """

  # DDL on the suite's table: one test at a time, after every async one.
  use Clementine.EctoCase, async: false

  alias Clementine.Migration

  @v2_columns [
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
    {"turn", "boolean", "NO", "false"}
  ]

  @v1_columns Enum.take(@v2_columns, 25)

  @lane_index "CREATE UNIQUE INDEX agent_runs_lane_index ON public.agent_runs USING btree ((\n" <>
                "CASE\n    WHEN turn THEN ''::text\n    ELSE agent_key\nEND), subject_type, " <>
                "subject_id) WHERE ((status = ANY (ARRAY['queued'::text, 'running'::text, " <>
                "'waiting'::text])) AND (subject_id IS NOT NULL))"

  @single_active_index "CREATE UNIQUE INDEX agent_runs_single_active_run_index ON " <>
                         "public.agent_runs USING btree (agent_key, subject_type, subject_id) " <>
                         "WHERE ((status = ANY (ARRAY['queued'::text, 'running'::text, " <>
                         "'waiting'::text])) AND (kind = 'rollout'::text))"

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

  @v2_indexes Enum.sort([{"agent_runs_lane_index", @lane_index} | @plain_indexes])
  @v1_indexes Enum.sort([
                {"agent_runs_single_active_run_index", @single_active_index} | @plain_indexes
              ])

  @v2_constraints [
    {"agent_runs_agent_key_present", "CHECK ((agent_key <> ''::text))"},
    {"agent_runs_pkey", "PRIMARY KEY (id)"}
  ]

  @v1_constraints [{"agent_runs_pkey", "PRIMARY KEY (id)"}]

  defmodule FromScratch do
    use Ecto.Migration
    def up, do: Clementine.Migration.up(version: 2)
    def down, do: Clementine.Migration.down(version: 2)
  end

  defmodule Version1 do
    use Ecto.Migration
    def up, do: Clementine.Migration.up(version: 1)
    def down, do: Clementine.Migration.down(version: 1)
  end

  defmodule Upgrade do
    use Ecto.Migration
    def up, do: Clementine.Migration.up(from: 1, version: 2)
    def down, do: Clementine.Migration.down(to: 1, version: 2)
  end

  test "the upgrade path built the frozen version 2 schema" do
    assert_version_2!()
  end

  test "up(version: 2) from scratch builds the same schema" do
    drop_table!()
    migrate!(:up, FromScratch)

    assert_version_2!()
  end

  test "up(from: 1, version: 2) brings a hand-rolled version 1 table to the same schema" do
    drop_table!()
    migrate!(:up, Version1)
    # A table built by hand to match version 1 carries no stamp.
    TestRepo.query!("COMMENT ON TABLE agent_runs IS NULL")

    assert columns() == @v1_columns
    assert indexes() == @v1_indexes
    assert constraints() == @v1_constraints
    assert Migration.migrated_version(TestRepo) == :unstamped

    migrate!(:up, Upgrade)

    assert_version_2!()
  end

  test "down(to: 1, version: 2) restores version 1, and down(version: 2) drops the table" do
    # The suite's own upgrade migration, as the host would roll it back.
    Ecto.Migrator.down(
      TestRepo,
      20_261_027_000_001,
      Clementine.Test.Ecto.UpgradeAgentRunsToVersion2,
      log: false,
      log_migrator_sql: false,
      migration_lock: false
    )

    assert columns() == @v1_columns
    assert indexes() == @v1_indexes
    assert constraints() == @v1_constraints
    assert Migration.migrated_version(TestRepo) == 1

    version = migrate!(:up, Upgrade)
    assert_version_2!()

    migrate!(:down, Upgrade, version)
    assert columns() == @v1_columns
    assert Migration.migrated_version(TestRepo) == 1

    drop_table!()
    version = migrate!(:up, FromScratch)
    assert_version_2!()

    migrate!(:down, FromScratch, version)
    assert columns() == []
    assert Migration.migrated_version(TestRepo) == :missing
  end

  test "the version stamp reads back, and the check names the migration to write" do
    assert Migration.migrated_version(TestRepo) == 2
    assert Migration.check!(TestRepo) == :ok

    TestRepo.query!("COMMENT ON TABLE agent_runs IS '1'")
    assert Migration.migrated_version(TestRepo) == 1

    assert_raise RuntimeError, ~r/at version 1: .*up\(from: 1, version: 2\)/, fn ->
      Migration.check!(TestRepo)
    end

    TestRepo.query!("COMMENT ON TABLE agent_runs IS NULL")
    assert Migration.migrated_version(TestRepo) == :unstamped

    assert_raise RuntimeError,
                 ~r/no version stamp \(version 1\): .*up\(from: 1, version: 2\)/,
                 fn ->
                   Migration.check!(TestRepo)
                 end

    # A description someone left on the table is not a stamp either.
    TestRepo.query!("COMMENT ON TABLE agent_runs IS 'The agents'' runs.'")
    assert Migration.migrated_version(TestRepo) == :unstamped

    TestRepo.query!("COMMENT ON TABLE agent_runs IS '2 (with notes)'")
    assert Migration.migrated_version(TestRepo) == :unstamped
    assert_raise RuntimeError, ~r/no version stamp/, fn -> Migration.check!(TestRepo) end

    # The code rolled back after a migration: the table is ahead, and
    # starts.
    TestRepo.query!("COMMENT ON TABLE agent_runs IS '3'")
    assert Migration.migrated_version(TestRepo) == 3
    assert Migration.check!(TestRepo) == :ok

    drop_table!()
    assert Migration.migrated_version(TestRepo) == :missing

    assert_raise RuntimeError, ~r/has none: .*up\(version: 2\)/, fn ->
      Migration.check!(TestRepo)
    end
  end

  defp assert_version_2! do
    assert columns() == @v2_columns
    assert indexes() == @v2_indexes
    assert constraints() == @v2_constraints
    assert Migration.migrated_version(TestRepo) == 2
  end

  defp drop_table!, do: TestRepo.query!("DROP TABLE agent_runs")

  # The sandbox's connection carries the migration, so its DDL rolls back
  # with the test, and so does the migrator's record of the version. An up
  # registers a fresh version, later than the suite's own; a down must name
  # the version its up registered, or the migrator finds nothing to undo.
  defp migrate!(direction, module, version \\ nil) do
    version = version || 20_261_027_000_001 + System.unique_integer([:positive, :monotonic])

    apply(Ecto.Migrator, direction, [
      TestRepo,
      version,
      module,
      [log: false, log_migrator_sql: false, migration_lock: false]
    ])

    version
  end

  defp columns do
    TestRepo.query!("""
    SELECT column_name, data_type, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_name = 'agent_runs'
    ORDER BY ordinal_position
    """).rows
    |> Enum.map(&List.to_tuple/1)
  end

  defp indexes do
    TestRepo.query!(
      "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'agent_runs' ORDER BY indexname"
    ).rows
    |> Enum.map(&List.to_tuple/1)
  end

  defp constraints do
    TestRepo.query!("""
    SELECT conname, pg_get_constraintdef(oid)
    FROM pg_constraint WHERE conrelid = 'agent_runs'::regclass ORDER BY conname
    """).rows
    |> Enum.map(&List.to_tuple/1)
  end
end
