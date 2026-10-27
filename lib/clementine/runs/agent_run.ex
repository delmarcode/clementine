if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Clementine.Runs.AgentRun do
    @moduledoc """
    One durable attempt to execute an agent: a row of `agent_runs`
    (`Clementine.Migration`), as `Clementine.Runs.get/1` returns it.

    The app's fields are `agent_key` (the agent's key), `subject_type` and
    `subject_id` (what the run is about), `actor_type` and `actor_id`
    (whose authority it acts with), `turn` (whether it is a turn on a
    thread, copied from the agent at start), `input`
    (`%{"prompt" => ...}`), `result` (`%{"output" => ...}` once completed),
    `oban_job_id`, and `metadata`. `status` is one of `queued`, `running`,
    `waiting`, `completed`, `failed`, `cancelled`, and `interrupted`;
    `active?/1` and `terminal?/1` read it. The other lifecycle fields are
    Clementine's column recipe, which only the runtime writes, each write
    a guarded compare-and-swap on `(status, lease_epoch)`. Read the row
    freely; never update it by hand.

    `subject` and `actor` are not stored: while the run executes they hold
    what `c:Clementine.Host.resolve_subject/2` and
    `c:Clementine.Host.resolve_actor/2` returned, and they are `nil` on a
    run read back from the database.
    """

    use Ecto.Schema

    import Ecto.Changeset

    alias Clementine.Lifecycle.Facts

    @primary_key {:id, :binary_id, autogenerate: true}

    @type t :: %__MODULE__{}

    @active Enum.map(Facts.active_statuses(), &Atom.to_string/1)
    @terminal Enum.map(Facts.terminal_statuses(), &Atom.to_string/1)

    schema "agent_runs" do
      field(:agent_key, :string)
      field(:subject_type, :string)
      field(:subject_id, :string)
      field(:subject, :any, virtual: true)
      field(:actor_type, :string)
      field(:actor_id, :string)
      field(:actor, :any, virtual: true)
      field(:turn, :boolean, default: false)
      field(:input, :map, default: %{})
      field(:result, :map)
      field(:oban_job_id, :integer)
      field(:metadata, :map, default: %{})

      # Clementine's column recipe.
      field(:kind, :string, default: "rollout")
      field(:status, :string, default: "queued")
      field(:lease_epoch, :integer, default: 0)
      field(:executor_id, :string)
      field(:heartbeat_at, :utc_datetime_usec)
      field(:deadline, :utc_datetime_usec)
      # Stamped by the database (the column defaults to now()).
      field(:queued_at, :utc_datetime_usec, read_after_writes: true)
      field(:cancel, :map)
      field(:suspension, :map)
      field(:resume, :map)
      field(:effects, :boolean, default: false)
      field(:usage, :map)
      field(:error, :map)
      field(:interrupt, :map)
      field(:finished_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    @doc "Whether the run is queued, running, or waiting."
    @spec active?(t()) :: boolean()
    def active?(%__MODULE__{status: status}), do: status in @active

    @doc "Whether the run has ended: completed, failed, cancelled, or interrupted."
    @spec terminal?(t()) :: boolean()
    def terminal?(%__MODULE__{status: status}), do: status in @terminal

    @doc false
    # A queued run. The unique_constraint names the lane index, so a second
    # active run in one lane is a changeset error, not an exception.
    def queued_changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, [
        :agent_key,
        :subject_type,
        :subject_id,
        :actor_type,
        :actor_id,
        :turn,
        :input,
        :metadata
      ])
      |> validate_required([:agent_key])
      |> unique_constraint([:agent_key, :subject_type, :subject_id], name: :agent_runs_lane_index)
    end

    @doc false
    def active_run_conflict?(%Ecto.Changeset{errors: errors}) do
      Enum.any?(errors, fn
        {:agent_key, {_message, opts}} -> opts[:constraint] == :unique
        _other -> false
      end)
    end
  end
end
