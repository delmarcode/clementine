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
