defmodule Clementine.Lifecycle.EctoHandWrittenConformanceTest do
  @moduledoc """
  The generated conformance battery against the RFC's hand-written
  two-function lifecycle (§A Hand-Written Lifecycle, In Full) — the other
  half of the suite's acceptance. An escape-hatch implementation that
  forgets half the CAS guard fails here on day one, which is the suite's
  reason to exist.
  """

  use Clementine.LifecycleCase,
    lifecycle: Clementine.Test.Ecto.HandWrittenLifecycle,
    create_run: &Clementine.Test.Ecto.Factory.create_run/1,
    storage_now: &Clementine.Test.Ecto.Factory.db_now!/0,
    nonexistent_ref: -1,
    moduletag: :postgres

  # Same racing-writers setup as the adapter conformance module; see the
  # Clementine.LifecycleCase moduledoc for both documented options.
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Clementine.TestRepo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
