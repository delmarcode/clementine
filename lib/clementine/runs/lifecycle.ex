if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Lifecycle do
    @moduledoc false
    # The storage contract between the durable-execution protocol and
    # agent_runs: the Ecto adapter's guarded compare-and-swap writes, with
    # the repo the child spec named. The projection runs inside the
    # transaction that makes a run terminal: it stores a completed run's
    # output, queues the host's run_committed/2 for after the commit, and
    # hands the result to the host's run_finished/2.

    @behaviour Clementine.Lifecycle
    @behaviour Clementine.Lifecycle.Ecto

    import Ecto.Query, only: [from: 2]

    require Logger

    alias Clementine.Emissions
    alias Clementine.Lifecycle.Ecto, as: EctoLifecycle
    alias Clementine.Result
    alias Clementine.Runs.{AgentRun, Config}

    @doc false
    def __clementine_config__, do: Config.fetch!().lifecycle

    @impl Clementine.Lifecycle
    def fetch(run_ref, ctx), do: EctoLifecycle.fetch(__MODULE__, run_ref, ctx)

    @impl Clementine.Lifecycle
    def apply(transition, ctx), do: EctoLifecycle.apply_transition(__MODULE__, transition, ctx)

    @impl Clementine.Lifecycle.Ecto
    def project(result, %AgentRun{} = run, _ctx) do
      %Config{repo: repo, host: host} = Config.fetch!()
      run = store_output(repo, result, run)

      # The adapter brackets this transaction for emissions: this one
      # fires once the transaction commits and is dropped if it rolls
      # back, including when run_finished/2 raises below.
      if exports?(host, :run_committed) do
        Emissions.emit(fn -> run_committed(host, run, result) end)
      end

      if exports?(host, :run_finished), do: host.run_finished(run, result)

      :ok
    end

    @impl Clementine.Lifecycle.Ecto
    def after_transition(_facts, _transition, _ctx), do: :ok

    defp store_output(repo, %Result.Completed{output: output}, run) do
      result = %{"output" => output}
      {1, _} = repo.update_all(from(r in AgentRun, where: r.id == ^run.id), set: [result: result])
      %{run | result: result}
    end

    defp store_output(_repo, _result, run), do: run

    defp exports?(nil, _callback), do: false
    defp exports?(host, callback), do: function_exported?(host, callback, 2)

    # The end is committed: a failing notification is logged and goes no
    # further, or it would fail (and retry) a write that already happened.
    defp run_committed(host, run, result) do
      host.run_committed(run, result)
    rescue
      e ->
        Logger.error(
          "#{inspect(host)}.run_committed/2 raised: #{Exception.message(e)} (run: #{run.id})"
        )
    catch
      kind, reason ->
        Logger.error(
          "#{inspect(host)}.run_committed/2 #{kind}: #{inspect(reason)} (run: #{run.id})"
        )
    end
  end
end
