if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.StepWorker do
    @moduledoc false
    # The Oban worker that steps one loop: claim, drain, one atomic commit,
    # through Clementine.Loop.Runner.step/2 on Clementine.Runs.Loops. It
    # maps the runner's closed outcome union the way Clementine.Runs.Worker
    # maps Clementine.Runner.execute/2. In tests:
    #
    #     assert :ok = perform_job(Clementine.Runs.StepWorker, %{"run_id" => loop.id})
    #
    # max_attempts: 1 for the same reason as the run worker: the machinery,
    # not the job queue, owns retry. An in-step failure already requeued
    # the loop and enqueued its next step (the two-tier posture); a failed
    # commit is requeued by the reaper (LOOP_RFC A3a). Either way this job
    # acks.

    use Oban.Worker, queue: :agents, max_attempts: 1

    require Logger

    alias Clementine.Runs.{Config, Loops}

    # How long a job waits when it arrives before the runtime is up.
    @not_ready_snooze 1

    @impl Oban.Worker
    def perform(%Oban.Job{id: job_id, args: %{"run_id" => loop_id}}) do
      Logger.metadata(run_id: loop_id)

      case Config.fetch() do
        {:ok, _config} ->
          case Loops.step(loop_id, "oban:step:#{job_id}:#{node()}") do
            {:parked, _facts} ->
              :ok

            # A continue, or a park the commit downgraded: the next step's
            # job is already enqueued inside the same unit.
            {:continued, _facts} ->
              :ok

            {:finished, _facts} ->
              :ok

            # A lost claim race, a vanished row, a run that is not a loop,
            # an already-terminal loop: nothing was written, nothing to
            # retry.
            {:discard, reason} ->
              {:cancel, inspect(reason)}

            {:error, reason} ->
              {:cancel, inspect(reason)}
          end

        :error ->
          {:snooze, @not_ready_snooze}
      end
    end
  end
end
