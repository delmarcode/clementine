if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Clementine.Runs.AgentRun do
    @moduledoc """
    One durable attempt to execute an agent: a row of `agent_runs`
    (`Clementine.Migration`), as `Clementine.Runs.get/1` returns it.

    The app's fields are `agent` (the agent's key), `subject_type` and
    `subject_id`, `input` (`%{"prompt" => ...}`), `result`
    (`%{"output" => ...}` once completed), `oban_job_id`, and `metadata`.
    `status` is one of `queued`, `running`, `waiting`, `completed`,
    `failed`, `cancelled`, and `interrupted`. The other lifecycle fields
    are Clementine's column recipe, which only the runtime writes, each
    write a guarded compare-and-swap on `(status, lease_epoch)`. Read the
    row freely; never update it by hand.

    `subject` is not stored: it holds what
    `c:Clementine.Host.resolve_subject/2` returned while the run executes.
    """

    use Ecto.Schema

    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}

    @type t :: %__MODULE__{}

    schema "agent_runs" do
      field(:agent, :string)
      field(:subject_type, :string)
      field(:subject_id, :string)
      field(:subject, :any, virtual: true)
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

    @doc false
    # A queued run. The unique_constraint names the single-active index, so
    # a second active run for one subject is a changeset error, not an
    # exception.
    def queued_changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, [:agent, :subject_type, :subject_id, :input, :metadata])
      |> validate_required([:agent])
      |> unique_constraint([:subject_type, :subject_id],
        name: :agent_runs_single_active_run_index
      )
    end

    @doc false
    def active_run_conflict?(%Ecto.Changeset{errors: errors}) do
      Enum.any?(errors, fn
        {:subject_type, {_message, opts}} -> opts[:constraint] == :unique
        _other -> false
      end)
    end
  end
end
