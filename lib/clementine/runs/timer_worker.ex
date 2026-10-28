if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.TimerWorker do
    @moduledoc false
    # The timer fire door: a loop's `{:timer, tag, ...}` action schedules
    # one of these jobs inside the step's commit, and when it fires it
    # appends `{:elapsed, tag}` to the loop's inbox under the schedule's
    # own dedup key, waking a parked loop in the same unit. A redelivered
    # fire collapses to :duplicate; a fire out-raced by a cancel or a
    # re-arm, or against a terminal loop, dead-letters as retained
    # evidence (LOOP_RFC §Timers, matrix row L6). All of those ack.

    use Oban.Worker, queue: :agents, max_attempts: 3

    require Logger

    alias Clementine.Runs.{Config, Loops}

    @not_ready_snooze 1

    @impl Oban.Worker
    def perform(%Oban.Job{id: id, args: %{"run_id" => loop_id, "tag_key" => tag_key}}) do
      Logger.metadata(run_id: loop_id)

      case Config.fetch() do
        {:ok, _config} ->
          case Loops.fire_timer(loop_id, tag_key, id) do
            {:ok, _outcome} -> :ok
            {:error, :not_found} -> {:cancel, "loop row deleted"}
            {:error, :not_a_loop} -> {:cancel, "not a loop"}
            {:error, reason} -> {:error, reason}
          end

        :error ->
          {:snooze, @not_ready_snooze}
      end
    end
  end
end
