# Ecto adapter tests need a reachable Postgres; without one, :postgres-tagged
# tests are excluded so the rest of the suite still runs. The dedicated test
# database is recreated from scratch each run — a change to the column
# recipe must reach a database migrated before it, and the migration's own
# down/0 can't reverse a definition the old table never had. Only a database
# named disposable by convention (suffixed "_test") is ever dropped:
# PGDATABASE may point anywhere, and a schema refresh must not cost anyone
# a real database.
repo_config = Clementine.TestRepo.config()

if String.ends_with?(repo_config[:database], "_test") do
  _ = Ecto.Adapters.Postgres.storage_down(repo_config)
else
  IO.warn(
    "database #{inspect(repo_config[:database])} lacks the \"_test\" suffix; skipping " <>
      "recreation — :postgres tests may run against a stale schema"
  )
end

postgres? =
  case Ecto.Adapters.Postgres.storage_up(repo_config) do
    :ok ->
      true

    {:error, :already_up} ->
      true

    {:error, reason} ->
      IO.warn("Postgres unavailable (#{inspect(reason)}); excluding :postgres tests")
      false
  end

if postgres? do
  {:ok, _} = Clementine.TestRepo.start_link()
  Ecto.Migrator.up(Clementine.TestRepo, 20_260_705_000_001, Clementine.Test.Ecto.CreateRuns)
  Ecto.Migrator.up(Clementine.TestRepo, 20_260_708_000_001, Clementine.Test.Ecto.AddLoopSupport)
  Ecto.Migrator.up(Clementine.TestRepo, 20_260_709_000_001, Clementine.Test.Ecto.CreateUuidRuns)
  Ecto.Adapters.SQL.Sandbox.mode(Clementine.TestRepo, :manual)
end

ExUnit.start(exclude: if(postgres?, do: [], else: [:postgres]))

# Define Mox mocks
Mox.defmock(Clementine.LLM.MockClient, for: Clementine.LLM.ClientBehaviour)

# Set Mox to verify on exit for all tests
Application.put_env(:clementine, :llm_client, Clementine.LLM.MockClient)
