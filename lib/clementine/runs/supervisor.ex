if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Supervisor do
    @moduledoc false
    # What {Clementine, opts} starts: the validated config, the drain
    # notifier, and the reaper.

    use Supervisor

    alias Clementine.Runs.{Config, DrainNotifier, Reaper}

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl Supervisor
    def init(opts) do
      config = Config.new!(opts)
      oban = oban_config!(config.oban)
      :ok = Config.put(config)

      # Oban's own plugins do not run in a testing mode; neither does the
      # reaper, which would sweep from outside the test's sandbox.
      reaper = if oban.testing == :disabled, do: [Reaper], else: []

      Supervisor.init([DrainNotifier | reaper], strategy: :one_for_one)
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
