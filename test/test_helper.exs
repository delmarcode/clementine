# Ecto adapter tests need a reachable Postgres; without one, :postgres-tagged
# tests are excluded so the rest of the suite still runs.
postgres? =
  case Ecto.Adapters.Postgres.storage_up(Clementine.TestRepo.config()) do
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
  Ecto.Adapters.SQL.Sandbox.mode(Clementine.TestRepo, :manual)
end

ExUnit.start(exclude: if(postgres?, do: [], else: [:postgres]))

# Define Mox mocks
Mox.defmock(Clementine.LLM.MockClient, for: Clementine.LLM.ClientBehaviour)

# Set Mox to verify on exit for all tests
Application.put_env(:clementine, :llm_client, Clementine.LLM.MockClient)
