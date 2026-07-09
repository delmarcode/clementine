defmodule Clementine.Loop.EctoUuidLoopConformanceTest do
  @moduledoc """
  The generated loop conformance battery against the **uuid-keyed** host —
  Meli's key shape (binary_id primary keys), found by its adoption run:
  refs cross the schemaless inbox boundary as UUID strings, which the
  integer-keyed battery can never regress.
  """

  use Clementine.LoopCase,
    host: Clementine.Test.Ecto.UuidLoopHost,
    lifecycle: Clementine.Test.Ecto.UuidLifecycle,
    create_loop: &Clementine.Test.Ecto.Factory.create_uuid_loop/1,
    step_jobs: &Clementine.Test.Ecto.Factory.uuid_step_jobs/1,
    timer_schedules: &Clementine.Test.Ecto.Factory.uuid_timer_schedules/1,
    nonexistent_ref: "00000000-0000-0000-0000-000000000000",
    moduletag: :postgres

  # The documented setup for genuinely racing writers: shared sandbox
  # ownership (with async: false, the LoopCase default). See the
  # Clementine.LoopCase moduledoc.
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Clementine.TestRepo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
