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

defmodule Clementine.Test.Ecto.CreateUuidJobs do
  @moduledoc """
  A plain table keyed by a run's UUID, standing in for the writes a host's
  `run_finished/2` makes: `Clementine.RunsCase.Host` records what it wrote
  here, so tests prove those writes commit, and roll back, with the run's
  end.
  """

  use Ecto.Migration

  def change do
    create table(:clementine_test_uuid_jobs) do
      add(:run_ref, :uuid)
      add(:kind, :text, null: false)
      add(:args, :map)
      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end
  end
end

defmodule Clementine.Test.Ecto.CreateRecipeV1Runs do
  @moduledoc """
  The versioned recipe, exercised for real: one table gets version 1 (its
  schema is asserted column by column against a frozen snapshot), and one
  gets version 1 and then loses it again.
  """

  use Ecto.Migration

  alias Clementine.Lifecycle.Ecto.Migration, as: Recipe

  def up do
    create table(:clementine_test_v1_runs) do
      add(:scope_id, :bigint)
    end

    Recipe.up(:clementine_test_v1_runs, version: 1, scope: :scope_id)

    create table(:clementine_test_v1_down) do
      add(:scope_id, :bigint)
    end

    Recipe.up(:clementine_test_v1_down, version: 1, scope: :scope_id)
    Recipe.down(:clementine_test_v1_down, version: 1)
  end
end

defmodule Clementine.Test.Ecto.CreateAgentRuns do
  @moduledoc """
  The durable runtime's tables, the way a host built them on version 1:
  `agent_runs` from `Clementine.Migration`, and Oban's `oban_jobs`.
  """

  use Ecto.Migration

  def up do
    Oban.Migration.up()
    Clementine.Migration.up(version: 1)
  end

  def down do
    Clementine.Migration.down(version: 1)
    Oban.Migration.down(version: 1)
  end
end

defmodule Clementine.Test.Ecto.UpgradeAgentRunsToVersion2 do
  @moduledoc """
  The migration a host on version 1 writes to adopt version 2. The runs
  suite runs on the upgraded table, so the upgrade path is the one every
  runtime test exercises; `Clementine.MigrationTest` proves it builds the
  same table as `up(version: 2)` from scratch.
  """

  use Ecto.Migration

  def up, do: Clementine.Migration.up(from: 1, version: 2)
  def down, do: Clementine.Migration.down(to: 1, version: 2)
end

defmodule Clementine.Test.Ecto.UpgradeAgentRunsToVersion3 do
  @moduledoc """
  The migration a host on version 2 writes to adopt version 3: the loop
  columns, the child tag, and the inbox. The runs suite runs on the
  upgraded table; `Clementine.MigrationTest` proves it builds the same
  table as `up(version: 3)` from scratch.
  """

  use Ecto.Migration

  def up, do: Clementine.Migration.up(from: 2, version: 3)
  def down, do: Clementine.Migration.down(to: 2, version: 3)
end

defmodule Clementine.Test.Ecto.UpgradeAgentRunsToVersion4 do
  @moduledoc """
  The migration a host on version 3 writes to adopt version 4: the
  trace table. The runs suite runs on the upgraded table;
  `Clementine.MigrationTest` proves it builds the same tables as
  `up(version: 4)` from scratch.
  """

  use Ecto.Migration

  def up, do: Clementine.Migration.up(from: 3, version: 4)
  def down, do: Clementine.Migration.down(to: 3, version: 4)
end

defmodule Clementine.Test.Ecto.UpgradeAgentRunsToVersion5 do
  @moduledoc """
  The migration a host on version 4 writes to adopt version 5: the
  trace's fact columns. The runs suite runs on the upgraded table;
  `Clementine.MigrationTest` proves it builds the same tables as
  `up(version: 5)` from scratch.
  """

  use Ecto.Migration

  def up, do: Clementine.Migration.up(from: 4, version: 5)
  def down, do: Clementine.Migration.down(to: 4, version: 5)
end
