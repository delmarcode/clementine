if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Worker do
    @moduledoc false
    # The Oban worker that executes one run. Clementine.Runs.start/3 and a
    # loop's step commit enqueue it on the child spec's queue; in tests,
    # run a job with Oban.Testing:
    #
    #     assert :ok = perform_job(Clementine.Runs.Worker, %{"run_id" => run.id})
    #
    # Deliberately thin: load the row, build the agent and the rollout,
    # call Clementine.Runner, map its closed return union. Claims, lease
    # fencing, heartbeats, suspension, cancellation, and the terminal
    # commit are the runner's. A loop's child builds like any run: its
    # history, its subject, and its actor resolve at the claim.
    #
    # max_attempts: 1 is correct. Retry is the reaper's decision, never
    # Oban's blind re-perform: a failed or interrupted run may already
    # have touched the world.

    use Oban.Worker, queue: :agents, max_attempts: 1

    import Ecto.Query, only: [from: 2]

    require Logger

    alias Clementine.Lifecycle.{Facts, Protocol}
    alias Clementine.LLM.Message.{AssistantMessage, ToolResultMessage, UserMessage}
    alias Clementine.Runs.{AgentRun, CancelRelay, Config, Courier, DrainNotifier, Lifecycle}

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

        # A loop steps through Clementine.Runs.StepWorker; a job that
        # names one here is miswired, and nothing may run it as a rollout.
        %AgentRun{kind: "loop"} ->
          {:discard, :loop_run}

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
    # a claimed run, and the claim hands the courier the claimed run. The
    # runner subscribes to cancels once it holds the run, and this process
    # stops listening when it lets go. Last, the agent releases what the
    # execution held (after_execution/2), whatever the outcome.
    defp execute_built(%Config{host: host} = config, row, run, executor_id) do
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
        CancelRelay.unsubscribe(row.id)
        if courier, do: Courier.stop(courier)
        after_execution(config, row, run)
      end
    end

    # The outcome stands whatever the cleanup does: a raise here is logged.
    defp after_execution(%Config{agents: agents}, %AgentRun{} = row, %Clementine.Run{} = run) do
      module = Map.fetch!(agents, row.agent_key)

      if function_exported?(module, :after_execution, 2) do
        module.after_execution(row, run.rollout.context)
      end
    rescue
      e ->
        Logger.error(
          "#{inspect(agent_module(agents, row))}.after_execution/2 raised: " <>
            "#{Exception.message(e)} (run: #{row.id})"
        )
    catch
      kind, reason ->
        Logger.error(
          "#{inspect(agent_module(agents, row))}.after_execution/2 #{kind}: " <>
            "#{inspect(reason)} (run: #{row.id})"
        )
    end

    defp agent_module(agents, %AgentRun{agent_key: key}), do: Map.get(agents, key)

    # The inert Clementine.Run for one execution. Agents are built at claim
    # time from code, so a deploy that changes an agent applies to the next
    # execution of every run.
    defp build(config, %AgentRun{} = row) do
      with {:ok, module} <- fetch_agent(config, row.agent_key),
           {:ok, prompt} <- prompt(row),
           {:ok, subject} <-
             resolve(config.host, :resolve_subject, row.subject_type, row.subject_id),
           {:ok, actor} <- resolve(config.host, :resolve_actor, row.actor_type, row.actor_id),
           row = %{row | subject: subject, actor: actor},
           {:ok, history} <- history(module, row) do
        agent = module.agent(row)

        rollout =
          Clementine.Rollout.new(
            agent: agent,
            input: prompt,
            messages: history,
            context:
              Map.merge(tool_context!(module, agent), %{
                run_id: row.id,
                agent_key: row.agent_key,
                turn: row.turn,
                subject_type: row.subject_type,
                subject_id: row.subject_id,
                subject: subject,
                actor_type: row.actor_type,
                actor_id: row.actor_id,
                actor: actor,
                parent_id: row.parent_id,
                tag: tag(row),
                metadata: row.metadata
              }),
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

    # What the agent adds for its tools (a working_dir, a sandbox handle)
    # goes under the runtime's keys, which always win: an agent adds to
    # what its tools see, never changes what the run is. Anything but a
    # map is a construction failure, cancelled as unstartable.
    defp tool_context!(_module, %Clementine.Agent{tool_context: context}) when is_map(context),
      do: context

    defp tool_context!(module, %Clementine.Agent{tool_context: other}) do
      raise ArgumentError,
            "#{inspect(module)}.agent/1 returned a tool_context that is not a map: " <>
              inspect(other)
    end

    # A loop's child sees its tag as the controller gave it, `{kind, id}`,
    # with the id as the row stores it: text. The kind is the controller's
    # vocabulary atom; one no loaded code declares stays text rather than
    # mint an atom from a column.
    defp tag(%AgentRun{tag_kind: kind, tag_id: id}) when is_binary(kind) and is_binary(id) do
      {String.to_existing_atom(kind), id}
    rescue
      ArgumentError -> {kind, id}
    end

    defp tag(%AgentRun{}), do: nil

    defp fetch_agent(%Config{agents: agents}, key) do
      case Map.fetch(agents, key) do
        {:ok, module} ->
          if Config.agent?(module), do: {:ok, module}, else: {:error, :unknown_agent}

        :error ->
          {:error, :unknown_agent}
      end
    end

    defp prompt(%AgentRun{input: %{"prompt" => prompt}}) when is_binary(prompt) do
      if String.trim(prompt) == "", do: {:error, :blank_prompt}, else: {:ok, prompt}
    end

    defp prompt(%AgentRun{}), do: {:error, :blank_prompt}

    # The subject and the actor resolve the same way, at every claim: the
    # one after a resume included, so a reference refused since the run
    # parked cancels it rather than continuing it.
    defp resolve(host, callback, type, id) when is_binary(type) and not is_nil(host) do
      if function_exported?(host, callback, 2) do
        apply(host, callback, [type, id])
      else
        {:ok, nil}
      end
    end

    defp resolve(_host, _callback, _type, _id), do: {:ok, nil}

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
