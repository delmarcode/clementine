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
    alias Clementine.LLM.Message.{AssistantMessage, ToolResultMessage, UserMessage}
    alias Clementine.Runs.{AgentRun, Config, Courier, DrainNotifier, Lifecycle}

    # The wall-clock budget of one execution, minted fresh at every claim,
    # unless the agent sets `defaults: [max_duration: ...]`.
    @max_duration :timer.minutes(10)

    # How long a job waits when it arrives before the runtime is up.
    @not_ready_snooze 1

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"run_id" => run_id}} = job) do
      Logger.metadata(run_id: run_id)

      # Oban starts first and may hand over a backlog before
      # {Clementine, ...} has published its config. Snoozing keeps the job
      # (Oban adds the attempt back), where failing would discard it and
      # leave the run to the reaper.
      case Config.fetch() do
        {:ok, config} -> perform(config, job)
        :error -> {:snooze, @not_ready_snooze}
      end
    end

    defp perform(config, %Oban.Job{id: job_id, args: %{"run_id" => run_id}}) do
      # Register first, so a drain at shutdown reaches this process.
      DrainNotifier.register()

      case execute(config, run_id, "oban:#{job_id}:#{node()}") do
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
            {:ok, run} -> execute_built(config, row, run, executor_id)
            {:error, reason} -> cancel_unstartable(row.id, reason)
          end
      end
    end

    # The lifecycle's ctx carries the row, so the host hears of this
    # execution's transitions without another read, and the courier that
    # carries its events to the host's run_event/2. Events come only from
    # a claimed run, so the courier's copy says it is running.
    defp execute_built(%Config{host: host}, row, run, executor_id) do
      courier =
        if exports?(host, :run_event, 2), do: Courier.start(host, %{row | status: "running"})

      try do
        Clementine.Runner.execute(run,
          lifecycle: Lifecycle,
          executor_id: executor_id,
          events: if(courier, do: Courier, else: Clementine.Events.Null),
          ctx: %{run: row, courier: courier}
        )
      after
        if courier, do: Courier.stop(courier)
      end
    end

    # The inert Clementine.Run for one execution. Agents are built at claim
    # time from code, so a deploy that changes an agent applies to the next
    # execution of every run.
    defp build(config, %AgentRun{} = row) do
      with {:ok, module} <- fetch_agent(config, row.agent_key),
           {:ok, prompt} <- prompt(row),
           {:ok, subject} <- resolve_subject(config.host, row),
           row = %{row | subject: subject},
           {:ok, history} <- history(module, row) do
        agent = module.agent(row)

        rollout =
          Clementine.Rollout.new(
            agent: agent,
            input: prompt,
            messages: history,
            context: %{
              run_id: row.id,
              agent_key: row.agent_key,
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

    # A run resumed from a checkpoint continues from the messages the
    # checkpoint holds, history and prompt included, so its history is
    # read only when it starts from its prompt. The test mirrors the
    # claim's: a suspension with a resume payload resumes.
    defp history(_module, %AgentRun{suspension: suspension, resume: resume})
         when is_map(suspension) and is_map(resume),
         do: {:ok, []}

    defp history(module, row) do
      if function_exported?(module, :history, 1) do
        row |> module.history() |> validate_history(module)
      else
        {:ok, []}
      end
    end

    defp validate_history(messages, module) do
      if is_list(messages) and Enum.all?(messages, &message?/1) do
        {:ok, messages}
      else
        {:error,
         "#{inspect(module)}.history/1 must return a list of Clementine.LLM.Message " <>
           "structs, got: #{inspect(messages, limit: 3, printable_limit: 80)}"}
      end
    end

    defp message?(%UserMessage{}), do: true
    defp message?(%AssistantMessage{}), do: true
    defp message?(%ToolResultMessage{}), do: true
    defp message?(_other), do: false

    defp exports?(nil, _function, _arity), do: false
    defp exports?(module, function, arity), do: function_exported?(module, function, arity)

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
