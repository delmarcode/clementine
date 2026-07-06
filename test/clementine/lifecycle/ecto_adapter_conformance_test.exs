defmodule Clementine.Lifecycle.EctoAdapterConformanceTest do
  @moduledoc """
  The generated conformance battery against the Ecto adapter
  (`use Clementine.Lifecycle.Ecto`) — half of the suite's own acceptance:
  the same battery must pass here and against the hand-written escape
  hatch (`Clementine.Lifecycle.EctoHandWrittenConformanceTest`).
  """

  use Clementine.LifecycleCase,
    lifecycle: Clementine.Test.Ecto.Lifecycle,
    create_run: &Clementine.Test.Ecto.Factory.create_run/1,
    storage_now: &Clementine.Test.Ecto.Factory.db_now!/0,
    nonexistent_ref: -1,
    moduletag: :postgres

  # The documented setup for genuinely racing writers: shared sandbox
  # ownership (with async: false, the LifecycleCase default), so the
  # concurrent claimers' processes reach the test's connection and every
  # write still rolls back per test. The alternative is a dedicated
  # non-sandbox repo — see the Clementine.LifecycleCase moduledoc.
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Clementine.TestRepo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
