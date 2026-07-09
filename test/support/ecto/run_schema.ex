defmodule Clementine.Test.Ecto.Run do
  @moduledoc """
  A host-shaped run table: the recipe columns plus the product columns a
  real app would keep (`scope_id` for the single-active index, `label` as a
  stand-in product field the projection can read).
  """

  use Ecto.Schema

  schema "clementine_test_runs" do
    field(:scope_id, :integer)
    field(:label, :string)

    field(:kind, :string, default: "rollout")
    field(:status, :string, default: "queued")
    field(:lease_epoch, :integer, default: 0)
    field(:executor_id, :string)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:deadline, :utc_datetime_usec)
    field(:queued_at, :utc_datetime_usec)
    field(:cancel, :map)
    field(:suspension, :map)
    field(:resume, :map)
    field(:effects, :boolean, default: false)
    field(:usage, :map)
    field(:error, :map)
    field(:interrupt, :map)
    field(:finished_at, :utc_datetime_usec)

    field(:loop_module, :string)
    field(:loop_args, :map)
    field(:loop_policy, :map)
    field(:envelope, :map)
    field(:state_version, :integer)
    field(:loop_scope, :string)
    field(:loop_ref, :integer)
    field(:tag_key, :string)
  end
end

defmodule Clementine.Test.Ecto.UuidRun do
  @moduledoc """
  The uuid-keyed twin of `Clementine.Test.Ecto.Run` — Meli's key shape.
  Refs are UUID strings on this table, so every seam that carries one to
  the schemaless inbox exercises the adapter's ref dumping.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "clementine_test_uuid_runs" do
    field(:scope_id, :integer)
    field(:label, :string)

    field(:kind, :string, default: "rollout")
    field(:status, :string, default: "queued")
    field(:lease_epoch, :integer, default: 0)
    field(:executor_id, :string)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:deadline, :utc_datetime_usec)
    field(:queued_at, :utc_datetime_usec)
    field(:cancel, :map)
    field(:suspension, :map)
    field(:resume, :map)
    field(:effects, :boolean, default: false)
    field(:usage, :map)
    field(:error, :map)
    field(:interrupt, :map)
    field(:finished_at, :utc_datetime_usec)

    field(:loop_module, :string)
    field(:loop_args, :map)
    field(:loop_policy, :map)
    field(:envelope, :map)
    field(:state_version, :integer)
    field(:loop_scope, :string)
    field(:loop_ref, :binary_id)
    field(:tag_key, :string)
  end
end
