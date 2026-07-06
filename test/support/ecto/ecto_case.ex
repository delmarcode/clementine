defmodule Clementine.EctoCase do
  @moduledoc """
  Case template for tests that hit the Postgres-backed lifecycle. Tagged
  `:postgres` so the suite degrades gracefully where no server is
  reachable (see `test_helper.exs`).
  """

  use ExUnit.CaseTemplate

  alias Clementine.Test.Ecto.Run
  alias Clementine.TestRepo

  using do
    quote do
      @moduletag :postgres

      import Clementine.EctoCase

      alias Clementine.Test.Ecto.Run
      alias Clementine.TestRepo
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
  end

  @doc "Inserts a queued run row; `queued_at` comes from the column default."
  def insert_run!(attrs \\ []) do
    TestRepo.insert!(
      struct!(Run, Keyword.merge([scope_id: System.unique_integer([:positive])], attrs))
    )
  end

  @doc "The storage clock — in a sandbox transaction, the transaction timestamp."
  def db_now! do
    %{rows: [[%DateTime{} = now]]} = TestRepo.query!("SELECT now()")
    now
  end
end
