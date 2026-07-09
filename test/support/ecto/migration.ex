defmodule Clementine.Test.Ecto.CreateRuns do
  @moduledoc """
  The walkthrough migration, exercised for real: a host table gains the
  recipe columns via `run_columns/0` and the single-flight guard via
  `single_active_index/2`.
  """

  use Ecto.Migration

  def change do
    create table(:clementine_test_runs) do
      add(:scope_id, :bigint)
      add(:label, :text)
    end

    alter table(:clementine_test_runs) do
      Clementine.Lifecycle.Ecto.Migration.run_columns()
    end

    Clementine.Lifecycle.Ecto.Migration.single_active_index(
      :clementine_test_runs,
      scope: :scope_id
    )
  end
end

defmodule Clementine.Test.Ecto.AddLoopSupport do
  @moduledoc """
  The loop-adoption migration, exercised for real (LOOP_RFC amendment A6):
  an existing run table gains the loop and child columns, the scope and
  dedup indexes, and the inbox — plus a plain jobs table standing in for
  Oban, so tests prove job rows commit atomically with their units.
  """

  use Ecto.Migration

  def change do
    alter table(:clementine_test_runs) do
      Clementine.Loop.Ecto.Migration.loop_columns()
      Clementine.Loop.Ecto.Migration.child_columns()
    end

    Clementine.Loop.Ecto.Migration.loop_scope_index(:clementine_test_runs)
    Clementine.Loop.Ecto.Migration.child_dedup_index(:clementine_test_runs)
    Clementine.Loop.Ecto.Migration.create_inbox(:clementine_test_loop_inbox)

    create table(:clementine_test_jobs) do
      add(:run_ref, :bigint)
      add(:kind, :text, null: false)
      add(:args, :map)
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end
  end
end

defmodule Clementine.Test.Ecto.CreateUuidRuns do
  @moduledoc """
  The same recipe on a uuid-keyed host table — the key shape Meli's
  adoption runs (binary_id primary keys), which the integer-keyed table
  cannot regress: refs cross the schemaless inbox boundary as UUID
  strings and must dump through the adapter.
  """

  use Ecto.Migration

  def change do
    create table(:clementine_test_uuid_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:scope_id, :bigint)
      add(:label, :text)
    end

    alter table(:clementine_test_uuid_runs) do
      Clementine.Lifecycle.Ecto.Migration.run_columns()
      Clementine.Loop.Ecto.Migration.loop_columns()
      Clementine.Loop.Ecto.Migration.child_columns(type: :binary_id)
    end

    Clementine.Loop.Ecto.Migration.loop_scope_index(:clementine_test_uuid_runs)
    Clementine.Loop.Ecto.Migration.child_dedup_index(:clementine_test_uuid_runs)

    Clementine.Loop.Ecto.Migration.create_inbox(:clementine_test_uuid_loop_inbox,
      loop_ref_type: :binary_id
    )

    create table(:clementine_test_uuid_jobs) do
      add(:run_ref, :uuid)
      add(:kind, :text, null: false)
      add(:args, :map)
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end
  end
end
