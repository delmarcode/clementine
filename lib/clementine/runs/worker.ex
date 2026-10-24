if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Worker do
    @moduledoc """
    The Oban worker that executes one run. `Clementine.Runs.start/3`
    enqueues it on the child spec's queue; in tests, run a job with
    `Oban.Testing`:

        assert :ok = perform_job(Clementine.Runs.Worker, %{"run_id" => run.id})

    Deliberately thin: load the row, build the agent and the rollout, call
    `Clementine.Runner`, map its closed return union. Claims, lease
    fencing, heartbeats, suspension, cancellation, and the terminal commit
    are the runner's.

    `max_attempts: 1` is correct. Retry is the reaper's decision, never
    Oban's blind re-perform: a failed or interrupted run may already have
    touched the world.
    """

    use Oban.Worker, queue: :agents, max_attempts: 1

    import Ecto.Query, only: [from: 2]

    alias Clementine.Lifecycle.{Facts, Protocol}
    alias Clementine.Runs.{AgentRun, Config, DrainNotifier, Lifecycle}

    # The wall-clock budget of one execution, minted fresh at every claim,
    # unless the agent sets `defaults: [max_duration: ...]`.
    @max_duration :timer.minutes(10)

    @impl Oban.Worker
    def perform(%Oban.Job{id: job_id, args: %{"run_id" => run_id}}) do
      Logger.metadata(run_id: run_id)

      # Register first, so a drain at shutdown reaches this process.
      DrainNotifier.register()

      case execute(Config.fetch!(), run_id, "oban:#{job_id}:#{node()}") do
        {:finished, %Facts{status: :queued}} ->
          # A graceful drain requeued the run before any effect fired; the
          # next node picks it up and it survives the deploy unseen.
          re_enqueue!(run_id)

        {:finished, _facts} ->
          # Any terminal; the projection committed with it.
          :ok

        {:suspended, _token} ->
          # Parked in `waiting` until Clementine.Runs.resume/2. A completed
          # job is the normal state of a parked run.
          :ok

        {:discard, reason} ->
          # Nothing was written and nothing may be: a lost claim race, a
          # lost lease, or a terminal that already exists.
          {:cancel, inspect(reason)}

        {:unstartable, reason} ->
          # The run could not be built and was cancelled with the reason.
          {:cancel, inspect(reason)}

        {:error, reason} ->
          # The terminal write ran out of retries; the run is still
          # `running` and the reaper finishes the story. Re-performing
          # could repeat effects, so cancel the job instead.
          {:cancel, inspect(reason)}
      end
    end

    @doc false
    # A new job for an existing run, linked from the row: after a resume, a
    # drain, or a reaper requeue. Inside a transaction it commits with the
    # write that made the run queued.
    @spec re_enqueue!(Ecto.UUID.t()) :: :ok
    def re_enqueue!(run_id) do
      %Config{repo: repo, oban: oban, queue: queue} = Config.fetch!()
      {:ok, job} = Oban.insert(oban, new(%{"run_id" => run_id}, queue: queue))

      {1, _} =
        repo.update_all(from(r in AgentRun, where: r.id == ^run_id), set: [oban_job_id: job.id])

      :ok
    end

    defp execute(%Config{repo: repo} = config, run_id, executor_id) do
      case repo.get(AgentRun, run_id) do
        nil ->
          {:discard, :run_not_found}

        %AgentRun{} = row ->
          case build(config, row) do
            {:ok, run} ->
              Clementine.Runner.execute(run, lifecycle: Lifecycle, executor_id: executor_id)

            {:error, reason} ->
              cancel_unstartable(row.id, reason)
          end
      end
    end

    # The inert Clementine.Run for one execution. Agents are built at claim
    # time from code, so a deploy that changes an agent applies to the next
    # execution of every run.
    defp build(config, %AgentRun{} = row) do
      with {:ok, module} <- fetch_agent(config, row.agent),
           {:ok, prompt} <- prompt(row),
           {:ok, subject} <- resolve_subject(config.host, row) do
        row = %{row | subject: subject}
        agent = module.agent(row)

        rollout =
          Clementine.Rollout.new(
            agent: agent,
            input: prompt,
            context: %{
              run_id: row.id,
              agent: row.agent,
              subject_type: row.subject_type,
              subject_id: row.subject_id,
              subject: subject
            },
            limits: default_limits(agent)
          )

        {:ok, Clementine.Run.new(ref: row.id, rollout: rollout)}
      end
    rescue
      # Construction failures (a bad model alias, a malformed agent) happen
      # before any claim; left alone, the row would sit queued until the
      # reaper's claim timeout.
      e in [ArgumentError, KeyError, FunctionClauseError] -> {:error, Exception.message(e)}
    end

    defp fetch_agent(%Config{agents: agents}, key) do
      case Map.fetch(agents, key) do
        {:ok, module} -> {:ok, module}
        :error -> {:error, :unknown_agent}
      end
    end

    defp prompt(%AgentRun{input: %{"prompt" => prompt}}) when is_binary(prompt) do
      if String.trim(prompt) == "", do: {:error, :blank_prompt}, else: {:ok, prompt}
    end

    defp prompt(%AgentRun{}), do: {:error, :blank_prompt}

    defp resolve_subject(host, %AgentRun{subject_type: type, subject_id: id})
         when is_binary(type) and not is_nil(host) do
      if function_exported?(host, :resolve_subject, 2) do
        host.resolve_subject(type, id)
      else
        {:ok, nil}
      end
    end

    defp resolve_subject(_host, _row), do: {:ok, nil}

    defp default_limits(%Clementine.Agent{defaults: defaults}) do
      if Keyword.has_key?(defaults, :max_duration), do: [], else: [max_duration: @max_duration]
    end

    defp cancel_unstartable(run_id, reason) do
      detail = if is_binary(reason), do: reason, else: inspect(reason)

      # String keys keep the stored reason readable as JSON.
      _ =
        Protocol.request_cancel(Lifecycle, run_id, %{"code" => "unstartable", "detail" => detail})

      {:unstartable, reason}
    end
  end
end
