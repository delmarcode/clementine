defmodule Clementine.Runs.LifecycleTest do
  @moduledoc """
  Clementine's conformance suite against the runtime's own lifecycle and
  `agent_runs` as `Clementine.Migration` builds it: concurrent claim
  races, zombie fencing across suspend and resume, cancel racing suspend
  in both orders, projection atomicity (the host's `run_finished/2` runs
  inside the terminal write), and storage-clock stamps.
  """

  use Clementine.LifecycleCase,
    lifecycle: Clementine.Runs.Lifecycle,
    create_run: &Clementine.RunsCase.create_conformance_run/1,
    storage_now: &Clementine.RunsCase.db_now!/0,
    nonexistent_ref: "00000000-0000-0000-0000-000000000000",
    moduletag: :postgres

  alias Clementine.TestRepo

  # Racing writers need sibling processes on the sandbox connection: shared
  # ownership serializes queries at the connection, while every logical
  # interleaving the compare-and-swap must survive still occurs.
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(TestRepo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    start_supervised!({Oban, repo: TestRepo, testing: :manual})

    start_supervised!({Clementine, repo: TestRepo, agents: [], host: Clementine.RunsCase.Host})

    :ok
  end
end
