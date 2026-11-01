if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Delegations do
    @moduledoc false
    # The rollout half of parent and child (Clementine.Delegation): a run
    # whose `delegate` calls start children, waits on them, and resumes
    # when the last one ends. Each write is one transaction, reached
    # through Clementine.Runs.Lifecycle:
    #
    #   * the park: the parent's suspend, which starts its children in the
    #     same transaction, so they exist exactly when it waits on them. A
    #     child whose lane is taken, or whose agent already asked on the
    #     way here, is refused there, its call settled as an error in the
    #     checkpoint. A parent flagged for cancel starts none;
    #   * a child's end: inside the child's terminal transaction
    #     (Loops.append_completion/2 dispatches here on the parent's
    #     kind), under the parent's row lock, the last child to end
    #     resumes the parent with every child's outcome and its new job;
    #   * the parent's cancel while it waits: a flag, like a running
    #     run's, and its live children cancelled in the same transaction.
    #     The last child's end resumes it, and its next execution honors
    #     the flag, so it ends after them and a cascade finishes bottom up;
    #   * the parent's end while it waits (the reaper's wait ceiling, a
    #     cancel of a park that started no child): its live children are
    #     cancelled in the same transaction.
    #
    # reconcile/1 resumes a parent whose children have all ended and that
    # still waits: after a park that started none (the worker calls it
    # once the execution is over), and for an end a child's terminal
    # write dropped (the reaper calls it; code from before delegation
    # drops a rollout parent's completion).
    #
    # Lock order is child before parent everywhere: a child's terminal
    # write holds its own row and then locks its parent's, so a write to a
    # waiting parent locks its live descendants, deepest first, before its
    # own row. Two children ending at once serialize on the parent's row,
    # so exactly one of them sees every child ended.

    import Ecto.Query, only: [from: 2]

    require Logger

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

    # How far up a parent's ancestry is read, and how many times its
    # descendants are found again while they are being locked: bounds on
    # data that should never come near them.
    @max_ancestry 100
    @lock_attempts 5

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
    # The park and the children, one transaction: the parent's row is
    # locked and read afresh, each child is checked and inserted through
    # Runs.insert_queued/2, then the parent's suspension records the ids
    # and any refusal, then its compare-and-swap. A lane taken between the
    # check and the insert (a racing start) fails the unit, and the
    # protocol's retry finds it taken and refuses it. Nothing here resumes
    # the parent: a park that started no child waits until the worker has
    # finished with the execution (reconcile/1).
    @spec park(Transition.t(), term()) :: {:ok, Facts.t()} | {:error, term()}
    def park(%Transition{} = transition, ctx) do
      %Config{repo: repo} = config = Config.fetch!()

      Emissions.after_commit(fn ->
        repo.transaction(fn ->
          parent =
            repo.one(from(r in AgentRun, where: r.id == ^transition.run_ref, lock: "FOR UPDATE"))

          transition = start_children(config, parent, transition)

          case EctoLifecycle.apply_transition(Lifecycle, transition, ctx) do
            {:ok, %Facts{} = facts} -> facts
            {:error, reason} -> repo.rollback(reason)
          end
        end)
      end)
    end

    # In the batch's order, so of two calls to one agent the first starts.
    defp start_children(_config, nil, transition), do: transition

    defp start_children(config, %AgentRun{} = parent, %Transition{} = transition) do
      %Suspension{checkpoint: %Checkpoint{pending: pending} = checkpoint} =
        suspension = transition.set.suspension

      ancestry = ancestry(config.repo, parent)

      {children, refusals, started} =
        checkpoint.messages
        |> call_order(pending)
        |> Enum.reduce({%{}, pending.completed_results, []}, fn id,
                                                                {children, refusals, started} ->
          child = Map.fetch!(pending.children, id)

          case start_child(config, parent, ancestry, id, child) do
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

      put_in(transition.set.suspension, suspension)
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

    # The agents whose requests led to this park: the parent's and its
    # ancestors', up the parent_id chain.
    defp ancestry(repo, %AgentRun{agent_key: key, parent_id: parent_id}) do
      parent_id
      |> Stream.unfold(fn
        nil ->
          nil

        id ->
          case repo.one(
                 from(r in AgentRun, where: r.id == ^id, select: {r.agent_key, r.parent_id})
               ) do
            nil -> nil
            {key, up} -> {key, up}
          end
      end)
      |> Enum.take(@max_ancestry)
      |> MapSet.new()
      |> MapSet.put(key)
    end

    # A child is a task of its agent on the parent's subject, with the
    # parent's actor: no cancel pending on the parent, an agent that has
    # not asked on the way here, start/3's checks, its lane, the insert.
    defp start_child(%Config{} = config, %AgentRun{} = parent, ancestry, tool_use_id, child) do
      with :ok <- not_cancelling(parent),
           :ok <- not_an_ancestor(ancestry, child.agent),
           {:ok, module} <- child_agent(config, child.agent),
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

    # A cancel that reached the parent before its park: nothing starts
    # for a run that is going away, and the park resolves as a cancel.
    defp not_cancelling(%AgentRun{cancel: nil}), do: :ok
    defp not_cancelling(%AgentRun{}), do: {:refused, "Not asked: this run is being cancelled."}

    # An agent asked again below itself could ask again forever; refusing
    # one already in the ancestry bounds a chain by the agents there are.
    defp not_an_ancestor(ancestry, key) do
      if MapSet.member?(ancestry, key) do
        {:refused,
         "Cannot ask #{inspect(key)}: it is among the agents whose requests led here, so " <>
           "asking it would go in a circle."}
      else
        :ok
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

    ## A child's end, and the reconcile

    @doc false
    # Inside `child`'s terminal transaction, with `parent` (a rollout)
    # locked: when the parent waits on it and every child it waits on has
    # ended, the parent resumes with their outcomes, and its job commits
    # with the child's end. A parent that no longer waits on the child
    # (ended, or resumed by an earlier end) hears nothing.
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

    @doc false
    # Resumes the rollout `parent_id` if it waits on children that have
    # all ended (none, for a park that started none), under its row lock,
    # so a racing child's end and this one resume it once between them.
    # The worker calls it once an execution that parked has finished; the
    # reaper, for a parent whose children's ends never reached it.
    @spec reconcile(Ecto.UUID.t()) :: :resumed | :waiting | :not_waiting
    def reconcile(parent_id) do
      %Config{repo: repo} = Config.fetch!()

      {:ok, outcome} =
        Emissions.after_commit(fn ->
          repo.transaction(fn ->
            with %AgentRun{kind: "rollout"} = parent <-
                   repo.one(from(r in AgentRun, where: r.id == ^parent_id, lock: "FOR UPDATE")),
                 %Facts{
                   status: :waiting,
                   suspension: %Suspension{reason: {:external, {:delegation, ids}}, token: token}
                 } <- Codec.to_facts(parent, @fields) do
              if resume_when_all_ended(parent, ids, token), do: :resumed, else: :waiting
            else
              _other -> :not_waiting
            end
          end)
        end)

      outcome
    end

    @doc false
    # When the children in `ids` had all ended: `{:ended, at}`, `at` the
    # latest of their finished_at (`nil` with no children), or `:live`
    # while one runs. The reaper's cheap read before it takes a parent's
    # lock.
    @spec ended([Ecto.UUID.t()]) :: {:ended, DateTime.t() | nil} | :live
    def ended([]), do: {:ended, nil}

    def ended(ids) do
      %Config{repo: repo} = Config.fetch!()

      rows =
        repo.all(from(r in AgentRun, where: r.id in ^ids, select: {r.status, r.finished_at}))

      if length(rows) == length(ids) and Enum.all?(rows, &(elem(&1, 0) not in @active_statuses)) do
        {:ended,
         rows
         |> Enum.map(&elem(&1, 1))
         |> Enum.reject(&is_nil/1)
         |> Enum.max(DateTime, fn -> nil end)}
      else
        :live
      end
    end

    defp resume_when_all_ended(%AgentRun{id: parent_id} = parent, ids, token) do
      %Config{repo: repo} = Config.fetch!()
      children = repo.all(from(r in AgentRun, where: r.id in ^ids))

      if length(children) == length(ids) and Enum.all?(children, &AgentRun.terminal?/1) do
        outcomes =
          Map.new(children, fn child ->
            {child.tag_id, Delegation.outcome(child.agent_key, Lifecycle.terminal_result(child))}
          end)

        {:ok, _facts} =
          Protocol.resume(Lifecycle, token, {:delegated, outcomes}, nil,
            agent_key: parent.agent_key
          )

        :ok = Worker.re_enqueue!(parent_id)
        true
      else
        false
      end
    end

    ## Writes to a parent that waits

    @doc false
    # The cancel flag on a run waiting on its children (request_cancel/4
    # gives it one rather than ending it).
    @spec flags_wait?(Transition.t()) :: boolean()
    def flags_wait?(
          %Transition{op: :cancel_request, result: nil, expect: %{status: :waiting}} = t
        ),
        do: not is_map_key(t.set, :status)

    def flags_wait?(%Transition{}), do: false

    @doc false
    # A terminal write of a run that waits.
    @spec ends_wait?(Transition.t()) :: boolean()
    def ends_wait?(%Transition{result: result, expect: %{status: :waiting}}) when result != nil,
      do: true

    def ends_wait?(%Transition{}), do: false

    @doc false
    # The flag, or the end, and the cascade, one transaction: the live
    # descendants locked deepest first, then the run's own row, compared
    # with what the write expects, then the write, then each live child
    # cancelled (a waiting one cascades the same way). A run that moved
    # meanwhile (its last child's end resumed it) is `{:error, :stale}`,
    # returned as a value with nothing written, so a cancel inside an
    # enclosing unit (a loop's step) fetches again and goes on.
    @spec write_wait(Transition.t(), term()) :: {:ok, Facts.t()} | {:error, term()}
    def write_wait(%Transition{run_ref: run_id} = transition, ctx) do
      %Config{repo: repo} = Config.fetch!()
      code = if transition.result, do: "parent_ended", else: "parent_cancelled"

      Emissions.after_commit(fn ->
        repo.transaction(fn ->
          rollout? = rollout?(repo, run_id)
          if rollout?, do: lock_live_descendants(repo, run_id)

          if expected?(repo, transition) do
            case EctoLifecycle.apply_transition(Lifecycle, transition, ctx) do
              {:ok, %Facts{} = facts} ->
                if rollout?, do: cancel_live_children(repo, run_id, code)
                facts

              {:error, reason} ->
                repo.rollback(reason)
            end
          else
            :stale
          end
        end)
      end)
      |> case do
        {:ok, :stale} -> {:error, :stale}
        other -> other
      end
    end

    # A loop's children are its controller's; only a rollout's are its
    # delegates.
    defp rollout?(repo, run_id) do
      repo.one(from(r in AgentRun, where: r.id == ^run_id, select: r.kind)) == "rollout"
    end

    defp expected?(repo, %Transition{run_ref: run_id, expect: expect}) do
      case repo.one(from(r in AgentRun, where: r.id == ^run_id, lock: "FOR UPDATE")) do
        nil ->
          false

        row ->
          %Facts{status: status, epoch: epoch} = Codec.to_facts(row, @fields)
          status == expect.status and epoch == expect.epoch
      end
    end

    # Deepest first, so this write takes rows in the order a child's end
    # does. A descendant found only after the others were locked (a
    # child's park committed in between) would be taken after its parent,
    # the other way round: the locks go back to a savepoint, and the walk
    # starts again with it. A locked run cannot park, so the walk settles.
    defp lock_live_descendants(repo, run_id, attempts \\ @lock_attempts) do
      repo.query!("SAVEPOINT clementine_descendants")
      levels = live_levels(repo, [run_id], [])
      Enum.each(levels, &lock_rows(repo, &1))
      locked = MapSet.new(List.flatten(levels))
      found = MapSet.new(List.flatten(live_levels(repo, [run_id], [])))

      cond do
        MapSet.subset?(found, locked) ->
          repo.query!("RELEASE SAVEPOINT clementine_descendants")

        attempts == 1 ->
          Logger.warning(
            "run #{run_id}: its live descendants kept changing while they were locked " <>
              "(#{@lock_attempts} walks); going on with the #{MapSet.size(locked)} it holds, " <>
              "and #{MapSet.size(MapSet.difference(found, locked))} found since unlocked"
          )

          repo.query!("RELEASE SAVEPOINT clementine_descendants")

        true ->
          repo.query!("ROLLBACK TO SAVEPOINT clementine_descendants")
          lock_live_descendants(repo, run_id, attempts - 1)
      end
    end

    defp lock_rows(repo, ids) do
      repo.all(from(r in AgentRun, where: r.id in ^ids, lock: "FOR UPDATE", select: r.id))
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

    defp cancel_live_children(repo, run_id, code) do
      reason = %{"code" => code, "parent_id" => run_id}

      repo.all(
        from(r in AgentRun,
          where: r.parent_id == ^run_id and r.status in @active_statuses,
          select: {r.id, r.agent_key}
        )
      )
      |> Enum.each(fn {child_id, agent_key} ->
        case Protocol.request_cancel(Lifecycle, child_id, reason, nil, agent_key: agent_key) do
          {:ok, _flagged_or_finished} -> :ok
          {:error, :already_terminal} -> :ok
          {:error, other} -> repo.rollback({:cancel_child_failed, child_id, other})
        end
      end)
    end
  end
end
