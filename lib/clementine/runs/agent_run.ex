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

    `kind` says what the run is: `"rollout"` for a run of an agent, or
    `"loop"` for a loop (`Clementine.Runs.start_loop/3`), whose
    `agent_key` is its controller's key, `input` its args, `loop_policy`
    its policy, and `envelope` and `state_version` the state the
    controller last committed. A run a loop's step started carries its
    `parent_id` and the two halves of its tag, `tag_kind` and `tag_id`
    (`Clementine.Runs.child/2` reads them back as `{kind, id}`).

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

      # A loop's row (version 3).
      field(:loop_policy, :map)
      field(:envelope, :map)
      field(:state_version, :integer)

      # A child's row: the loop that started it, and its tag.
      field(:parent_id, :binary_id)
      field(:tag_kind, :string)
      field(:tag_id, :string)

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
    # A queued run. The unique_constraints name the lane index and the
    # one-live-child-per-tag index, so a second active run in one lane,
    # or a second live child under one tag, is a changeset error, not an
    # exception.
    def queued_changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, [
        :kind,
        :agent_key,
        :subject_type,
        :subject_id,
        :actor_type,
        :actor_id,
        :turn,
        :input,
        :metadata,
        :loop_policy,
        :state_version,
        :parent_id,
        :tag_kind,
        :tag_id
      ])
      |> validate_required([:agent_key])
      |> validate_turn_has_subject()
      |> validate_typed(:subject_type, :subject_id)
      |> validate_typed(:actor_type, :actor_id)
      |> check_constraint(:agent_key,
        name: :agent_runs_agent_key_present,
        message: "can't be blank"
      )
      |> check_constraint(:subject_id,
        name: :agent_runs_turn_has_subject,
        message: "a turn needs a subject"
      )
      |> check_constraint(:subject_type,
        name: :agent_runs_subject_typed,
        message: "a subject id needs a type"
      )
      |> check_constraint(:actor_type,
        name: :agent_runs_actor_typed,
        message: "an actor id needs a type"
      )
      |> unique_constraint([:agent_key, :subject_type, :subject_id], name: :agent_runs_lane_index)
      |> unique_constraint([:parent_id, :tag_kind, :tag_id], name: :agent_runs_child_tag_index)
    end

    # The table's checks, mirrored: a row that would slip out of its lane
    # through a NULL is a changeset error before it is a constraint
    # violation.
    defp validate_turn_has_subject(changeset) do
      if get_field(changeset, :turn) == true do
        validate_required(changeset, [:subject_id], message: "a turn needs a subject")
      else
        changeset
      end
    end

    defp validate_typed(changeset, type_field, id_field) do
      if is_nil(get_field(changeset, id_field)) do
        changeset
      else
        validate_required(changeset, [type_field], message: "an id needs a type")
      end
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
