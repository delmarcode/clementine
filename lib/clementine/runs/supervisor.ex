if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Supervisor do
    @moduledoc false
    # What {Clementine, opts} starts: the validated config, the drain
    # notifier, the cancel relay, the supervisor of the steps send/3 runs
    # inline, and the reaper.

    use Supervisor

    alias Clementine.Runs.{CancelRelay, Config, DrainNotifier, Reaper, StepSupervisor}

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl Supervisor
    def init(opts) do
      config = Config.new!(opts)
      oban = oban_config!(config.oban)
      same_repo!(config, oban)
      # The table and the code that writes it move together: a table
      # behind the code's version refuses the start and names the
      # migration to write.
      :ok = Clementine.Migration.check!(config.repo)

      # Oban's own plugins do not run in a testing mode; neither does the
      # reaper, which would sweep from outside the test's sandbox, nor the
      # step send/3 runs inline, which would step from outside it too:
      # tests drive perform_job(Clementine.Runs.StepWorker, ...).
      live? = oban.testing == :disabled
      :ok = Config.put(%{config | inline_steps: live?})
      reaper = if live?, do: [Reaper], else: []

      Supervisor.init(
        [
          DrainNotifier,
          {CancelRelay, oban: config.oban},
          {Task.Supervisor, name: StepSupervisor} | reaper
        ],
        strategy: :one_for_one
      )
    end

    # A run and its job commit in one transaction (start, resume, requeue),
    # and only one repo can hold it: Oban inserts through its own repo.
    defp same_repo!(%Config{repo: repo}, %Oban.Config{repo: repo}), do: :ok

    defp same_repo!(%Config{repo: repo, oban: name}, %Oban.Config{repo: oban_repo}) do
      raise ArgumentError,
            "{Clementine, ...} uses repo #{inspect(repo)} but Oban instance #{inspect(name)} " <>
              "uses #{inspect(oban_repo)}. A run and its job commit in one transaction, " <>
              "so both must use the same repo"
    end

    defp oban_config!(name) do
      Oban.config(name)
    rescue
      RuntimeError ->
        reraise ArgumentError,
                [
                  message:
                    "no Oban instance named #{inspect(name)} is running. Start " <>
                      "{Clementine, ...} after Oban in your application's children, and " <>
                      "pass oban: the Oban instance's name if it is not Oban"
                ],
                __STACKTRACE__
    end
  end
end
