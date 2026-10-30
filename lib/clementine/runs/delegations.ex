if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Delegations do
    @moduledoc false
    # The rollout half of parent and child (Clementine.Delegation): a run
    # whose `delegate` calls start children, waits on them, and resumes
    # when the last one ends. Three writes, each one transaction, each
    # reached through Clementine.Runs.Lifecycle:
    #
    #   * the park: the parent's suspend, which starts its children in the
    #     same transaction, so they exist exactly when it waits on them. A
    #     child whose lane is taken is refused there, its call settled as
    #     an error in the checkpoint; with no child started, the parent
    #     resumes at once in the same unit;
    #   * a child's end: inside the child's terminal transaction
    #     (Loops.append_completion/2 dispatches here on the parent's
    #     kind), under the parent's row lock, the last child to end
    #     resumes the parent with every child's outcome and its new job;
    #   * the parent's end while it waits (a cancel, the reaper's wait
    #     ceiling): its live children are cancelled in the same
    #     transaction, a running one by its flag.
    #
    # Lock order is child before parent everywhere: a child's terminal
    # write holds its own row and then locks its parent's, so the
    # parent's end locks its live descendants, deepest first, before its
    # own compare-and-swap. Two children ending at once serialize on the
    # parent's row, so exactly one of them sees every child ended.

    import Ecto.Query, only: [from: 2]

    alias Clementine.{Checkpoint, Delegation, Emissions, Pending, Suspension, ToolResult}
    alias Clementine.Lifecycle.Ecto, as: EctoLifecycle
    alias Clementine.Lifecycle.Ecto.Codec
    alias Clementine.Lifecycle.{Facts, Protocol, Transition}
    alias Clementine.LLM.Message.AssistantMessage
    alias Clementine.Runs
    alias Clementine.Runs.{AgentRun, Config, Lifecycle, Worker}

    @fields Codec.resolve_fields(:id, [])
    @active_statuses Enum.map(Facts.active_statuses(), &Atom.to_string/1)
    @tag_kind "delegate"

    ## The park

    @doc false
    # A rollout parking on its `delegate` calls.
    @spec park?(Transition.t()) :: boolean()
    def park?(%Transition{
          op: :suspend,
          set: %{
            suspension: %Suspension{
              reason: {:external, {:delegation, _ids}},
              checkpoint: %Checkpoint{pending: %Pending.Delegation{}}
            }
          }
        }),
        do: true

    def park?(%Transition{}), do: false

    @doc false
    # The park and the children, one transaction: each child is checked
    # and inserted through Runs.insert_queued/2, then the parent's
    # suspension records the ids and any refusal, then its
    # compare-and-swap. A lane taken between the check and the insert
    # (a racing start) fails the unit, and the protocol's retry finds it
    # taken and refuses it.
    @spec park(Transition.t(), term()) :: {:ok, Facts.t()} | {:error, term()}
    def park(%Transition{} = transition, ctx) do
      %Config{repo: repo} = config = Config.fetch!()

      Emissions.after_commit(fn ->
        repo.transaction(fn ->
          parent = parent_row(repo, transition.run_ref, ctx)
          {transition, started} = start_children(config, parent, transition)

          case EctoLifecycle.apply_transition(Lifecycle, transition, ctx) do
            {:ok, %Facts{} = facts} ->
              if started == [], do: resume!(facts.ref, facts.suspension.token, %{})
              facts

            {:error, reason} ->
              repo.rollback(reason)
          end
        end)
      end)
    end

    defp parent_row(_repo, _ref, %{run: %AgentRun{} = run}), do: run
    defp parent_row(repo, ref, _ctx), do: repo.get!(AgentRun, ref)

    # In the batch's order, so of two calls to one agent the first starts.
    defp start_children(config, %AgentRun{} = parent, %Transition{} = transition) do
      %Suspension{checkpoint: %Checkpoint{pending: pending} = checkpoint} =
        suspension = transition.set.suspension

      {children, refusals, started} =
        checkpoint.messages
        |> call_order(pending)
        |> Enum.reduce({%{}, pending.completed_results, []}, fn id,
                                                                {children, refusals, started} ->
          child = Map.fetch!(pending.children, id)

          case start_child(config, parent, id, child) do
            {:ok, run_id} ->
              {Map.put(children, id, %{child | run_id: run_id}), refusals, [run_id | started]}

            {:refused, message} ->
              refusal = %ToolResult{content: message, is_error: true}
              {Map.put(children, id, child), Map.put(refusals, id, refusal), started}
          end
        end)

      pending = %{pending | children: children, completed_results: refusals}

      suspension = %{
        suspension
        | reason: {:external, {:delegation, Enum.reverse(started)}},
          checkpoint: %{checkpoint | pending: pending}
      }

      {put_in(transition.set.suspension, suspension), started}
    end

    defp call_order(messages, %Pending.Delegation{children: children}) do
      batch =
        case List.last(messages) do
          %AssistantMessage{} = message ->
            Enum.map(AssistantMessage.get_tool_uses(message), & &1.id)

          _other ->
            []
        end

      ordered = Enum.filter(batch, &Map.has_key?(children, &1))
      ordered ++ Enum.sort(Map.keys(children) -- ordered)
    end

    # A child is a task of its agent on the parent's subject, with the
    # parent's actor: start/3's checks, then its lane, then the insert.
    defp start_child(%Config{} = config, %AgentRun{} = parent, tool_use_id, child) do
      with {:ok, module} <- child_agent(config, child.agent),
           {:ok, attrs} <- child_attrs(config, parent, module, child),
           :ok <- lane_free(config, attrs, child.agent) do
        attrs =
          Map.merge(attrs, %{parent_id: parent.id, tag_kind: @tag_kind, tag_id: tool_use_id})

        case Runs.insert_queued(config, attrs) do
          {:ok, %AgentRun{id: id}} -> {:ok, id}
          {:error, reason} -> config.repo.rollback({:delegate_insert, tool_use_id, reason})
        end
      end
    end

    defp child_agent(%Config{agents: agents}, key) do
      with module when is_atom(module) and not is_nil(module) <- Map.get(agents, key),
           true <- Config.agent?(module) do
        {:ok, module}
      else
        _ -> {:refused, "Cannot ask #{inspect(key)}: this app runs no agent by that key."}
      end
    end

    defp child_attrs(config, %AgentRun{} = parent, module, child) do
      if module.turn() do
        {:refused,
         "Cannot ask #{inspect(child.agent)}: it takes turns on a conversation, and only " <>
           "an agent that runs tasks can be asked."}
      else
        case Runs.queued_attrs(config, module, child.prompt,
               subject: reference(parent.subject_type, parent.subject_id),
               actor: reference(parent.actor_type, parent.actor_id),
               metadata: %{"delegated_by" => parent.agent_key}
             ) do
          {:ok, attrs} ->
            {:ok, attrs}

          {:error, reason} ->
            {:refused, "Cannot ask #{inspect(child.agent)}: #{inspect(reason)}."}
        end
      end
    end

    defp reference(nil, _id), do: nil
    defp reference(type, id), do: {type, id}

    # A task's lane is its agent and subject; one with no subject id has
    # none. Read in this transaction, so a sibling started a moment ago
    # in the same batch takes the lane too.
    defp lane_free(_config, %{subject_id: nil}, _key), do: :ok

    defp lane_free(%Config{repo: repo}, attrs, key) do
      taken? =
        repo.exists?(
          from(r in AgentRun,
            where: r.status in @active_statuses and not r.turn,
            where: r.agent_key == ^attrs.agent_key,
            where: r.subject_type == ^attrs.subject_type and r.subject_id == ^attrs.subject_id
          )
        )

      if taken? do
        {:refused,
         "Cannot ask #{inspect(key)}: it is already at work on this subject. Wait for that " <>
           "task to end, or ask it everything in one call."}
      else
        :ok
      end
    end

    ## A child's end

    @doc false
    # Inside `child`'s terminal transaction, with `parent` (a rollout)
    # locked: when the parent waits on it and every child it waits on has
    # ended, the parent resumes with their outcomes, and its job commits
    # with the child's end. A parent that no longer waits on the child
    # (cancelled, or resumed by an earlier end) hears nothing.
    @spec child_ended(AgentRun.t(), AgentRun.t()) :: :ok
    def child_ended(%AgentRun{} = parent, %AgentRun{} = child) do
      case Codec.to_facts(parent, @fields) do
        %Facts{
          status: :waiting,
          suspension: %Suspension{reason: {:external, {:delegation, ids}}, token: token}
        } ->
          if child.id in ids, do: resume_when_all_ended(parent, ids, token)
          :ok

        %Facts{} ->
          :ok
      end
    end

    defp resume_when_all_ended(%AgentRun{} = parent, ids, token) do
      %Config{repo: repo} = Config.fetch!()
      children = repo.all(from(r in AgentRun, where: r.id in ^ids))

      if length(children) == length(ids) and Enum.all?(children, &AgentRun.terminal?/1) do
        outcomes =
          Map.new(children, fn child ->
            {child.tag_id, Delegation.outcome(child.agent_key, Lifecycle.terminal_result(child))}
          end)

        resume!(parent.id, token, outcomes)
      end
    end

    # The resume and the parent's new job, in the unit at hand.
    defp resume!(parent_id, token, outcomes) do
      {:ok, _facts} = Protocol.resume(Lifecycle, token, {:delegated, outcomes})
      :ok = Worker.re_enqueue!(parent_id)
    end

    ## The parent's end while it waits

    @doc false
    # A terminal write of a run that waits: the one end that can find
    # live children.
    @spec ends_wait?(Transition.t()) :: boolean()
    def ends_wait?(%Transition{result: result, expect: %{status: :waiting}}) when result != nil,
      do: true

    def ends_wait?(%Transition{}), do: false

    @doc false
    # The end and the cascade, one transaction: the live descendants are
    # locked deepest first, then the run's own compare-and-swap, then each
    # live child is cancelled (a waiting one cascades the same way).
    @spec end_wait(Transition.t(), term()) :: {:ok, Facts.t()} | {:error, term()}
    def end_wait(%Transition{run_ref: run_id} = transition, ctx) do
      %Config{repo: repo} = Config.fetch!()

      Emissions.after_commit(fn ->
        repo.transaction(fn ->
          rollout? = rollout?(repo, run_id)
          if rollout?, do: lock_live_descendants(repo, run_id)

          case EctoLifecycle.apply_transition(Lifecycle, transition, ctx) do
            {:ok, %Facts{} = facts} ->
              if rollout?, do: cancel_live_children(repo, run_id)
              facts

            {:error, reason} ->
              repo.rollback(reason)
          end
        end)
      end)
    end

    # A loop's children are its controller's; only a rollout's are its
    # delegates.
    defp rollout?(repo, run_id) do
      repo.one(from(r in AgentRun, where: r.id == ^run_id, select: r.kind)) == "rollout"
    end

    defp lock_live_descendants(repo, run_id) do
      repo
      |> live_levels([run_id], [])
      |> Enum.each(fn ids ->
        repo.all(from(r in AgentRun, where: r.id in ^ids, lock: "FOR UPDATE", select: r.id))
      end)
    end

    # The live descendants by level, deepest first.
    defp live_levels(repo, parent_ids, levels) do
      case repo.all(
             from(r in AgentRun,
               where: r.parent_id in ^parent_ids and r.status in @active_statuses,
               select: r.id
             )
           ) do
        [] -> levels
        ids -> live_levels(repo, ids, [ids | levels])
      end
    end

    defp cancel_live_children(repo, run_id) do
      reason = %{"code" => "parent_ended", "parent_id" => run_id}

      repo.all(
        from(r in AgentRun,
          where: r.parent_id == ^run_id and r.status in @active_statuses,
          select: r.id
        )
      )
      |> Enum.each(fn child_id ->
        case Protocol.request_cancel(Lifecycle, child_id, reason) do
          {:ok, _flagged_or_finished} -> :ok
          {:error, :already_terminal} -> :ok
          {:error, other} -> repo.rollback({:cancel_child_failed, child_id, other})
        end
      end)
    end
  end
end
