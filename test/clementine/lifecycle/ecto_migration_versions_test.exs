defmodule Clementine.Lifecycle.EctoMigrationVersionsTest do
  @moduledoc """
  Version 1 of the recipe is frozen: a host migration that says
  `version: 1` must build this exact schema under every later Clementine.
  If this test fails, a change reached version 1's DDL; it belongs in a
  new version instead.
  """

  use Clementine.EctoCase, async: true

  alias Clementine.Lifecycle.Ecto.Migration, as: Recipe

  @v1_columns [
    {"id", "bigint", "NO", "nextval('clementine_test_v1_runs_id_seq'::regclass)"},
    {"scope_id", "bigint", "YES", nil},
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
    {"finished_at", "timestamp with time zone", "YES", nil}
  ]

  @v1_indexes [
    {"clementine_test_v1_runs_pkey",
     "CREATE UNIQUE INDEX clementine_test_v1_runs_pkey ON public.clementine_test_v1_runs " <>
       "USING btree (id)"},
    {"clementine_test_v1_runs_single_active_run_index",
     "CREATE UNIQUE INDEX clementine_test_v1_runs_single_active_run_index " <>
       "ON public.clementine_test_v1_runs USING btree (scope_id) " <>
       "WHERE ((status = ANY (ARRAY['queued'::text, 'running'::text, 'waiting'::text])) " <>
       "AND (kind = 'rollout'::text))"}
  ]

  test "version 1 builds the frozen schema" do
    assert columns("clementine_test_v1_runs") == @v1_columns
    assert indexes("clementine_test_v1_runs") == @v1_indexes
  end

  test "down from version 1 leaves only the host's columns" do
    assert [{"id", _, _, _}, {"scope_id", _, _, _}] = columns("clementine_test_v1_down")
    assert [{"clementine_test_v1_down_pkey", _}] = indexes("clementine_test_v1_down")
  end

  test "a migration must name a version the library has" do
    assert Recipe.current_version() == 1

    assert_raise KeyError, fn -> Recipe.up(:t, scope: :id) end

    for version <- [0, 2] do
      assert_raise ArgumentError, ~r/recipe versions run 1..1/, fn ->
        Recipe.up(:t, version: version, scope: :id)
      end
    end
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
end
