if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Clementine.Migration do
    @moduledoc """
    The `agent_runs` table the durable runtime (`Clementine.Runs`) runs on,
    as numbered versions, the way `Oban.Migration` ships `oban_jobs`. The
    host keeps one migration per version it adopts:

        defmodule MyApp.Repo.Migrations.AddClementine do
          use Ecto.Migration

          def up, do: Clementine.Migration.up(version: 1)
          def down, do: Clementine.Migration.down(version: 1)
        end

    Each version's DDL is frozen here: a migration that says `version: 1`
    builds the same table under every later Clementine. When a version 2
    exists, a host adopts it in a new migration with
    `up(from: 1, version: 2)`.

    ## Version 1

    `agent_runs`, keyed by UUID:

        agent_key     text, not null     the agent's key (Clementine.Agent)
        subject_type  text               what the run is about; at most one
        subject_id    text               active run per agent and subject
        input         jsonb              %{"prompt" => ...}
        result        jsonb              %{"output" => ...} once completed
        oban_job_id   bigint             the run's current job
        metadata      jsonb              the app's, stored as given
        inserted_at, updated_at

    plus the lifecycle columns of the column recipe
    (`Clementine.Lifecycle.Ecto.Migration`, version 1) and its
    single-active index on `(agent_key, subject_type, subject_id)`. Two
    agents may work on one subject at once, and one agent only once: a
    chat turn and a triage check of the same conversation don't block
    each other. The index counts queued, running, and waiting runs as
    active, so a run parked on an approval blocks new runs of its agent
    for its subject until it resolves; runs without a subject id never
    block each other, because NULLs are distinct in a unique index.
    """

    import Ecto.Migration

    @table :agent_runs
    @current_version 1

    @doc "The newest version `up/1` can apply."
    @spec current_version() :: pos_integer()
    def current_version, do: @current_version

    @doc """
    Migrates `agent_runs` from version `:from` (default `0`, no table)
    through `:version`. `:version` is required, so a migration always names
    the DDL it was written against.
    """
    @spec up(keyword()) :: :ok
    def up(opts) do
      {from, version} = range!(opts, :from)

      for step <- (from + 1)..version//1, do: step_up(step)
      :ok
    end

    @doc """
    Reverses `up/1`: removes versions `:version` down through `:to` + 1
    (default `0`, dropping the table).
    """
    @spec down(keyword()) :: :ok
    def down(opts) do
      {to, version} = range!(opts, :to)

      for step <- version..(to + 1)//-1, do: step_down(step)
      :ok
    end

    defp range!(opts, floor_key) do
      version = Keyword.fetch!(opts, :version)
      floor = Keyword.get(opts, floor_key, 0)

      unless version in 1..@current_version//1 and floor in 0..version//1 do
        raise ArgumentError,
              "Clementine.Migration versions run 1..#{@current_version}; got " <>
                "#{floor_key}: #{inspect(floor)}, version: #{inspect(version)}"
      end

      {floor, version}
    end

    # Frozen. A new version is a new pair of clauses, never an edit here.
    defp step_up(1) do
      create table(@table, primary_key: false) do
        add(:id, :binary_id, primary_key: true)
        add(:agent_key, :text, null: false)
        add(:subject_type, :text)
        add(:subject_id, :text)
        add(:input, :map, null: false, default: %{})
        add(:result, :map)
        add(:oban_job_id, :bigint)
        add(:metadata, :map, null: false, default: %{})

        timestamps(type: :utc_datetime_usec)
      end

      Clementine.Lifecycle.Ecto.Migration.up(@table,
        version: 1,
        scope: [:agent_key, :subject_type, :subject_id]
      )

      create(index(@table, [:kind, :status]))
      create(index(@table, [:agent_key]))
      create(index(@table, [:subject_type, :subject_id]))
      create(index(@table, [:oban_job_id]))
    end

    defp step_down(1) do
      drop(table(@table))
    end
  end
end
