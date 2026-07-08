defmodule Clementine.Loop.EctoLoopConformanceTest do
  @moduledoc """
  The generated loop conformance battery against the Ecto loop host
  (`use Clementine.Loop.Ecto`) — the battery's own acceptance: green
  here, and documented in `Clementine.LoopCase` as runnable against
  hand-written hosts.
  """

  use Clementine.LoopCase,
    host: Clementine.Test.Ecto.LoopHost,
    lifecycle: Clementine.Test.Ecto.Lifecycle,
    create_loop: &Clementine.Test.Ecto.Factory.create_loop/1,
    nonexistent_ref: -1,
    moduletag: :postgres

  # The documented setup for genuinely racing writers: shared sandbox
  # ownership (with async: false, the LoopCase default), so racing
  # appenders reach the test's connection and every write still rolls
  # back per test. See the Clementine.LoopCase moduledoc.
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Clementine.TestRepo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
