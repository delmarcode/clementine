if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.StepSupervisor do
    @moduledoc false
    # The Task.Supervisor under Clementine.Runs.Supervisor that runs the
    # step Clementine.Runs.send/3 starts inline, on the sending node, once
    # the append has committed. The step job the append enqueued stays as
    # the backstop: whichever claims first steps the loop, and the other
    # discards on the lost claim. A task that dies mid-step leaves the
    # loop running under a stale claim, which the reaper's loop sweep
    # requeues (LOOP_RFC A3a).

    alias Clementine.Runs.{Config, Loops}

    @doc false
    @spec step(Config.t(), Ecto.UUID.t()) :: :ok
    def step(%Config{inline_steps: true}, loop_id) do
      {:ok, _pid} =
        Task.Supervisor.start_child(__MODULE__, fn ->
          Loops.step(loop_id, "inline:#{node()}:#{inspect(self())}")
        end)

      :ok
    end

    def step(%Config{}, _loop_id), do: :ok
  end
end
