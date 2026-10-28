if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Loops do
    @moduledoc false
    # The loop half of the durable runtime. A loop is a run: its row has
    # kind "loop", its controller's key in agent_key, its args in input,
    # and its policy, envelope, and state version in columns of its own.
    # Its inbox is agent_run_inbox. Its children are runs a step started,
    # inserted through Clementine.Runs.insert_queued/2 with parent_id and
    # (tag_kind, tag_id), and built at their claim like any run.
    #
    # This module is four things, all behind Clementine.Runs:
    #
    #   * the step runner's seam, which Clementine.Loop.Runner.step/2
    #     drives: load/2, pending/4, bump_attempts/2, apply_step/2, and
    #     enqueue_step/2 (Clementine.Runs.StepWorker performs the step);
    #   * the inbox verbs: append/3, cancel/2, wake/1, and the timer fire
    #     door fire_timer/3 (Clementine.Runs.TimerWorker's);
    #   * the child glue Clementine.Runs.Lifecycle calls: the completion
    #     append inside a child's terminal transaction, and the parent
    #     wake after it;
    #   * the loop sweep's evidence and the strand healing it asks for.
    #
    # Two atomic units (LOOP_RFC §The Loop Host Contract). A step commit
    # is one transaction: the guarded CAS first (a stale commit dies
    # before any cargo exists), then consumption, dead-letter marks,
    # synthesized appends, child rows and their jobs, timer jobs, child
    # cancels, sends, the envelope, the park re-check, the terminal
    # projection, and the terminal sweep. An append is one transaction:
    # the input row, the wake, and the step job, under the loop row's
    # lock, which serializes it against a step's park: if a park holds
    # the row, the append waits and then sees `waiting`; if the append
    # holds it, the park's CAS waits and its in-unit re-check then sees
    # the committed input. The cancel flag rides the same lock.
    #
    # Post-commit emissions (the host's run_transition/2 and
    # run_committed/2, the cancel push, telemetry) are deferred through
    # Clementine.Emissions for the length of each unit, so nothing
    # describes a write that rolled back.

    import Ecto.Query

    require Logger

    alias Clementine.Emissions
    alias Clementine.Lifecycle.Ecto.Codec, as: LifecycleCodec
    alias Clementine.Lifecycle.{Facts, Protocol, Transition}
    alias Clementine.Loop
    alias Clementine.Loop.{Codec, Envelope, InboxCodec, Input, Runner, StepCommit, StoredInput}
    alias Clementine.Reconciler.LoopEvidence
    alias Clementine.Result
    alias Clementine.Runs
    alias Clementine.Runs.{AgentRun, Config, Lifecycle, StepWorker, TimerWorker}

    @inbox "agent_run_inbox"

    # The lifecycle columns plus the two the step commit writes beside them.
    @fields LifecycleCodec.resolve_fields(:id, []) ++
              [envelope: :envelope, state_version: :state_version]

    @terminal_statuses Enum.map(Facts.terminal_statuses(), &Atom.to_string/1)

    @typedoc "What `append/3` and the fire door answer."
    @type append_outcome :: {:ok, :appended | :duplicate | :dead_lettered}

    ## The step

    @doc false
    @spec step(Ecto.UUID.t(), String.t()) :: Runner.outcome()
    def step(loop_id, executor_id) do
      Runner.step(loop_id, host: __MODULE__, lifecycle: Lifecycle, executor_id: executor_id)
    end

    ## The step runner's seam

    @doc false
    def load(loop_id, _ctx) do
      %Config{repo: repo} = config = Config.fetch!()

      case repo.get(AgentRun, loop_id) do
        nil ->
          {:error, :not_found}

        %AgentRun{kind: "loop"} = row ->
          {:ok,
           %{
             facts: facts(row),
             module: controller(config, row),
             args: row.input || %{},
             policy: row.loop_policy || %{},
             envelope: row.envelope
           }}

        %AgentRun{} ->
          {:error, :not_a_loop}
      end
    end

    # The controller module the row's key names, or the key itself when
    # the child spec no longer lists it: Clementine.Loop.resolve/1 then
    # parks the loop as :incompatible_spec with the key in the detail.
    defp controller(%Config{agents: agents}, %AgentRun{agent_key: key}) do
      Map.get(agents, key, key)
    end

    @doc false
    def pending(loop_id, limit, scope, _ctx)
        when is_integer(limit) and limit > 0 and scope in [:any, :completions] do
      %Config{repo: repo} = config = Config.fetch!()
      vocab = vocabulary(config, repo.get(AgentRun, loop_id))

      query =
        from(i in @inbox,
          where: i.run_id == type(^loop_id, Ecto.UUID),
          where: is_nil(i.dead_at),
          order_by: [asc: i.id],
          limit: ^limit,
          select: %{
            id: i.id,
            kind: i.kind,
            payload: i.payload,
            attempts: i.attempts,
            dedup_key: i.dedup_key,
            inserted_at: i.inserted_at
          }
        )

      query =
        case scope do
          :completions -> where(query, [i], i.kind == "completed")
          :any -> query
        end

      query |> repo.all() |> Enum.map(&stored(&1, vocab))
    end

    @doc false
    def dead_letters(loop_id, limit, _ctx) when is_integer(limit) and limit > 0 do
      %Config{repo: repo} = config = Config.fetch!()
      vocab = vocabulary(config, repo.get(AgentRun, loop_id))

      from(i in @inbox,
        where: i.run_id == type(^loop_id, Ecto.UUID),
        where: not is_nil(i.dead_at),
        order_by: [desc: i.id],
        limit: ^limit,
        select: %{
          id: i.id,
          kind: i.kind,
          payload: i.payload,
          attempts: i.attempts,
          dedup_key: i.dedup_key,
          inserted_at: i.inserted_at,
          dead_at: i.dead_at,
          dead_reason: i.dead_reason
        }
      )
      |> repo.all()
      |> Enum.map(&stored(&1, vocab))
    end

    # One inbox row as the step core reads it. A payload the running code
    # cannot decode is poison for that input alone, surfaced as
    # decode_error, never a failed fetch (matrix row L7).
    defp stored(row, vocab) do
      stored = %StoredInput{
        ref: row.id,
        input: %Input{kind: Enum.find(Input.kinds(), :message, &(Atom.to_string(&1) == row.kind))},
        attempts: row.attempts,
        dedup_key: row.dedup_key,
        inserted_at: row.inserted_at,
        dead_at: row[:dead_at],
        dead_reason: row[:dead_reason] && InboxCodec.decode_dead_reason(row.dead_reason)
      }

      case InboxCodec.decode_input(row.kind, row.payload, vocabulary: vocab) do
        {:ok, input} -> %{stored | input: input}
        {:error, error} -> %{stored | decode_error: error}
      end
    end

    @doc false
    def bump_attempts([], _ctx), do: :ok

    def bump_attempts(refs, _ctx) when is_list(refs) do
      %Config{repo: repo} = Config.fetch!()
      repo.update_all(from(i in @inbox, where: i.id in ^refs), inc: [attempts: 1])
      :ok
    end

    @doc false
    # The step's job on the child spec's queue, linked from the row so the
    # reaper's Oban cross-check can find it. Inside a unit it commits with
    # the unit (jobs are rows); standalone (the reaper's :reenqueue) it is
    # its own write.
    def enqueue_step(loop_id, _ctx) do
      %Config{repo: repo, oban: oban, queue: queue} = Config.fetch!()
      {:ok, job} = Oban.insert(oban, StepWorker.new(%{"run_id" => loop_id}, queue: queue))

      {1, _} =
        repo.update_all(from(r in AgentRun, where: r.id == ^loop_id), set: [oban_job_id: job.id])

      :ok
    end

    ## apply_step: atomicity sentence 1

    @doc false
    def apply_step(%StepCommit{} = commit, ctx) do
      %Config{repo: repo} = config = Config.fetch!()

      # Child cancels are cargo: their lifecycle transitions commit with
      # this unit, so their post-commit emissions (the host's hooks, the
      # cancel push, telemetry) must too: fired once the unit commits,
      # dropped if it rolls back.
      in_unit(repo, fn ->
        repo.transaction(fn ->
          case do_apply_step(config, commit, ctx) do
            {:ok, facts} -> facts
            {:error, reason} -> repo.rollback(reason)
          end
        end)
      end)
      |> tap(fn
        {:ok, facts} -> notify_step(commit, facts, ctx)
        {:error, _reason} -> :ok
      end)
    end

    # The loop's own committed transition reaches the host like every
    # lifecycle transition, after the flushed child emissions, so a child's
    # end precedes its loop's at every level. The op names the state
    # movement: a park is a suspend, a continue (or a downgraded park) a
    # requeue, a finish a finish, read from the committed facts.
    defp notify_step(%StepCommit{} = commit, %Facts{} = facts, ctx) do
      op =
        case facts.status do
          :waiting -> :suspend
          :queued -> :requeue
          _terminal -> :finish
        end

      transition = %Transition{
        op: op,
        run_ref: commit.loop_ref,
        expect: commit.expect,
        set: Map.drop(commit.set, [:envelope, :state_version]),
        result: commit.result,
        meta: commit.meta
      }

      Lifecycle.after_transition(facts, transition, ctx)
    end

    defp do_apply_step(config, %StepCommit{} = commit, ctx) do
      with {:ok, row} <- cas_step(config, commit),
           :ok <- consume(config, commit),
           :ok <- mark_dead(config, commit),
           :ok <- insert_appends(config, commit),
           :ok <- cancel_children(commit, :existing, %{}),
           {:ok, children} <- spawn_children(config, row, commit),
           {:ok, timers} <- schedule_timers(config, row, commit),
           :ok <- retire_timers(config, row, commit),
           :ok <- execute_sends(config, row, commit),
           :ok <- write_envelope(config, commit, children, timers),
           :ok <- cancel_children(commit, :spawned, children),
           :ok <- settle_transition(config, row, commit),
           :ok <- project_finish(config, commit, ctx),
           :ok <- terminal_sweep(config, commit) do
        {:ok, final_facts(config, commit.loop_ref)}
      end
    end

    # The fence first: a stale commit dies before any cargo exists.
    defp cas_step(%Config{repo: repo}, %StepCommit{} = commit) do
      updates =
        commit.set
        |> Map.drop([:envelope])
        |> Enum.map(fn {key, value} ->
          {Keyword.fetch!(@fields, key), encode_set_value(key, value)}
        end)

      query =
        from(r in AgentRun,
          where: r.id == ^commit.loop_ref,
          where: r.status == ^LifecycleCodec.encode_status(commit.expect.status),
          where: r.lease_epoch == ^commit.expect.epoch,
          update: [set: ^updates],
          select: r
        )

      case repo.update_all(query, []) do
        {1, [row]} -> {:ok, row}
        {0, _} -> {:error, :stale}
      end
    end

    defp encode_set_value(_key, :now), do: dynamic(fragment("now()"))

    defp encode_set_value(_key, {:now_plus, ms}) when is_integer(ms) do
      dynamic(fragment("now() + (? * interval '1 millisecond')", ^ms))
    end

    defp encode_set_value(key, value), do: LifecycleCodec.encode_value(key, value)

    defp consume(_config, %StepCommit{consumed: []}), do: :ok

    defp consume(%Config{repo: repo}, %StepCommit{consumed: refs, loop_ref: loop_id}) do
      {count, _} = repo.delete_all(pending_by_refs(loop_id, refs))

      # A consumed ref that is already gone means two commits raced past
      # the fence: corruption the guard exists to make impossible.
      if count == length(refs) do
        :ok
      else
        {:error, {:consumption_mismatch, %{expected: length(refs), deleted: count}}}
      end
    end

    defp mark_dead(_config, %StepCommit{marks: []}), do: :ok

    defp mark_dead(%Config{repo: repo}, %StepCommit{marks: marks, loop_ref: loop_id}) do
      marks
      |> Enum.group_by(& &1.reason, & &1.ref)
      |> Enum.each(fn {reason, refs} ->
        encoded = InboxCodec.encode_dead_reason(reason)

        {count, _} =
          repo.update_all(
            from(i in pending_by_refs(loop_id, refs),
              update: [set: [dead_at: fragment("now()"), dead_reason: ^encoded]]
            ),
            []
          )

        emit_dead_letter(loop_id, reason, count)
      end)

      :ok
    end

    defp pending_by_refs(loop_id, refs) do
      from(i in @inbox,
        where: i.run_id == type(^loop_id, Ecto.UUID),
        where: i.id in ^refs,
        where: is_nil(i.dead_at)
      )
    end

    # Synthesized poison evidence ({:input_failed}) rides the same commit.
    # The core never parks alongside appends, so no wake is needed: the
    # transition is a continue and the step job re-drains them.
    defp insert_appends(_config, %StepCommit{appends: []}), do: :ok

    defp insert_appends(%Config{repo: repo}, %StepCommit{appends: appends, loop_ref: loop_id}) do
      Enum.each(appends, fn %Input{} = input ->
        {kind, payload} = InboxCodec.encode_input(input, vocabulary: [])
        true = insert_input(repo, loop_id, kind, payload, nil)
      end)

      :ok
    end

    # A child is a run the step starts: inserted through the same path as
    # Clementine.Runs.start/3, with its parent and tag, inside this unit.
    # It occupies its lane like any run (a turn's is its thread), so a
    # child that would put a second active turn on the loop's thread fails
    # the step, and the input walks the poison path (invariant 12). Every
    # other refusal here is an app-contract violation and fails the step
    # the same way.
    defp spawn_children(_config, _row, %StepCommit{children: []}), do: {:ok, %{}}

    defp spawn_children(config, %AgentRun{} = loop, %StepCommit{children: specs}) do
      filled =
        Enum.reduce(specs, %{}, fn spec, acc ->
          child = insert_child!(config, loop, spec)
          Map.put(acc, spec.tag_key, child.id)
        end)

      {:ok, filled}
    end

    # The child's attrs are start/3's, checked the way start/3 checks them
    # (the key, the turn, the prompt, a turn's subject), plus its parent
    # and tag.
    defp insert_child!(config, %AgentRun{} = loop, %{tag: tag, child_args: child}) do
      {tag_kind, tag_id} = Codec.split_tag(tag)
      module = child_agent!(config, child, tag)
      subject = child_reference(child, "subject", {loop.subject_type, loop.subject_id}, tag)
      actor = child_reference(child, "actor", {loop.actor_type, loop.actor_id}, tag)

      attrs =
        case Runs.queued_attrs(config, module, child_prompt!(child, tag),
               subject: subject,
               actor: actor,
               metadata: child_metadata!(child, tag)
             ) do
          {:ok, attrs} ->
            Map.merge(attrs, %{parent_id: loop.id, tag_kind: tag_kind, tag_id: tag_id})

          {:error, :subject_required} ->
            raise ArgumentError,
                  "child #{inspect(tag)} is a turn of #{inspect(module.key())} and needs a " <>
                    "subject: the loop has none, and the child names none"

          {:error, reason} ->
            raise ArgumentError, "child #{inspect(tag)} cannot start: #{inspect(reason)}"
        end

      case Runs.insert_queued(config, attrs) do
        {:ok, %AgentRun{} = child} ->
          child

        {:error, :active_run_exists} ->
          raise ArgumentError,
                "the lane for child #{inspect(tag)} already holds an active run " <>
                  "(#{lane(attrs)}); a controller that wants to interrupt cancels the " <>
                  "running child first and spawns on its completion"

        {:error, %Ecto.Changeset{} = changeset} ->
          raise ArgumentError,
                "child #{inspect(tag)} could not be inserted: #{inspect(changeset.errors)}"

        {:error, reason} ->
          raise ArgumentError, "child #{inspect(tag)} could not be inserted: #{inspect(reason)}"
      end
    end

    defp lane(%{turn: true, subject_type: type, subject_id: id}),
      do: "the turn lane of #{type} #{id}"

    defp lane(%{agent_key: key, subject_type: type, subject_id: id}),
      do: "#{key} on #{type} #{id}"

    defp child_agent!(%Config{agents: agents}, child, tag) do
      case Map.get(child, "agent") do
        key when is_binary(key) ->
          case Map.get(agents, key) do
            nil ->
              raise ArgumentError,
                    "child #{inspect(tag)} names agent #{inspect(key)}, which the child spec " <>
                      "does not list"

            module ->
              if Config.agent?(module) do
                module
              else
                raise ArgumentError,
                      "child #{inspect(tag)} names #{inspect(key)}, a loop controller; a " <>
                        "child is a run of an agent"
              end
          end

        other ->
          raise ArgumentError,
                "child #{inspect(tag)} needs an \"agent\" key naming an agent of the child " <>
                  "spec, got: #{inspect(other)}"
      end
    end

    defp child_prompt!(child, tag) do
      case Map.get(child, "prompt") do
        prompt when is_binary(prompt) ->
          if String.trim(prompt) == "" do
            raise ArgumentError, "child #{inspect(tag)} has a blank \"prompt\""
          else
            prompt
          end

        other ->
          raise ArgumentError,
                "child #{inspect(tag)} needs a \"prompt\" string, got: #{inspect(other)}"
      end
    end

    # "subject" and "actor" come as [type, id] and default to the loop's own.
    defp child_reference(child, key, default, tag) do
      case Map.get(child, key) do
        nil ->
          case default do
            {nil, _id} -> nil
            reference -> reference
          end

        [type, id] when is_binary(type) and (is_nil(id) or is_binary(id) or is_integer(id)) ->
          {type, id}

        other ->
          raise ArgumentError,
                "child #{inspect(tag)} has a malformed #{inspect(key)}: #{inspect(other)}"
      end
    end

    defp child_metadata!(child, tag) do
      case Map.get(child, "metadata", %{}) do
        %{} = metadata ->
          metadata

        other ->
          raise ArgumentError,
                "child #{inspect(tag)} has a malformed \"metadata\": #{inspect(other)}"
      end
    end

    # A timer is an Oban job scheduled for its fire time, on the child
    # spec's queue; the job id is the schedule's retained identity in the
    # envelope (the fire door compares it), and what cancel_timer removes.
    defp schedule_timers(_config, _row, %StepCommit{timers: []}), do: {:ok, %{}}

    defp schedule_timers(%Config{repo: repo, oban: oban, queue: queue}, row, %StepCommit{
           timers: specs
         }) do
      metas =
        Map.new(specs, fn spec ->
          {:ok, job} =
            Oban.insert(
              oban,
              TimerWorker.new(%{"run_id" => row.id, "tag_key" => spec.tag_key},
                queue: queue,
                scheduled_at: fire_at(repo, spec.fire)
              )
            )

          {spec.tag_key, %{"schedule_id" => job.id}}
        end)

      {:ok, metas}
    end

    # The symbolic form resolves against the storage clock, never this
    # node's; inside the unit that is the transaction's own timestamp.
    defp fire_at(_repo, {:at, %DateTime{} = at}), do: at

    defp fire_at(repo, {:now_plus, ms}) when is_integer(ms) and ms >= 0 do
      DateTime.add(storage_now(repo), ms, :millisecond)
    end

    # The stored envelope still holds the retired entries' metas here: the
    # CAS never touches the envelope column, which is written post-cargo
    # with the refs filled, so the CAS-returned row carries the pre-step
    # value. Cancelling the job is best-effort: a fire that races it
    # dead-letters at the door or at the drain.
    defp retire_timers(_config, _row, %StepCommit{cancel_timers: []}), do: :ok

    defp retire_timers(%Config{oban: oban}, row, %StepCommit{cancel_timers: tag_keys}) do
      metas =
        case decode_stored_envelope(row.envelope) do
          %Envelope{timers: timers} -> timers
          nil -> %{}
        end

      Enum.each(tag_keys, fn tag_key ->
        case Map.get(metas, tag_key) do
          %{"schedule_id" => job_id} when is_integer(job_id) ->
            :ok = Oban.cancel_job(oban, job_id)

          _meta ->
            :ok
        end
      end)

      :ok
    end

    defp decode_stored_envelope(nil), do: nil

    defp decode_stored_envelope(data) do
      case Envelope.decode(data) do
        {:ok, envelope} -> envelope
        {:error, _} -> nil
      end
    end

    # Cancel cargo, for a {:cancel, tag} action or the cascade: the
    # machinery, not handle/2, cancels live children. A queued or waiting
    # child ends here, and its terminal projection appends its completion
    # to this very loop inside this very unit, where the park re-check
    # sees it; a running child gets the cooperative flag, pushed to its
    # runner once the unit commits. Already-terminal and missing children
    # are tolerated: their completions are en route, or the loop sweep's
    # :reconcile_children verdict will synthesize them.
    # Cancels of the children the envelope already holds go before the
    # step's spawns: a cancelled child that was never claimed ends inside
    # this unit and frees its lane, so a controller interrupts it and
    # starts its successor in one step, while a running child only takes
    # the flag. A halt in the very step that spawned a child (the drain
    # spawns, its next input halts) cascades to that child too; it has no
    # ref until it is inserted, and its completion finds its tag through
    # the parent's envelope, so those cancels follow the envelope write.
    # The step core refuses a controller's own {:cancel, tag} for a
    # same-step spawn, so only the cascade reaches the second phase.
    defp cancel_children(%StepCommit{cancel_children: []}, _phase, _spawned), do: :ok

    defp cancel_children(%StepCommit{cancel_children: tag_keys} = commit, phase, spawned) do
      stored = StepCommit.envelope(commit)
      reason = cancel_reason(commit)

      tag_keys
      |> Enum.flat_map(fn tag_key ->
        case {phase, stored && Map.get(stored.children, tag_key)} do
          {:existing, nil} -> []
          {:existing, ref} -> [ref]
          {:spawned, nil} -> [spawned_ref!(spawned, tag_key)]
          {:spawned, _ref} -> []
        end
      end)
      |> Enum.reduce_while(:ok, fn ref, :ok ->
        case Protocol.request_cancel(Lifecycle, ref, reason) do
          {:ok, _} -> {:cont, :ok}
          {:error, :already_terminal} -> {:cont, :ok}
          {:error, :not_found} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:cancel_child_failed, ref, reason}}}
        end
      end)
    end

    defp spawned_ref!(spawned, tag_key) do
      Map.get(spawned, tag_key) ||
        raise ArgumentError,
              "cancel for #{inspect(tag_key)} names no child: the commit's envelope must " <>
                "carry every live child"
    end

    # The loop's own end (a halt with children in flight, or a cancel flag)
    # cascades; anything else is the controller's {:cancel, tag}.
    defp cancel_reason(%StepCommit{loop_ref: loop_id, meta: meta} = commit) do
      cascade? =
        Map.get(meta, :mode) == :cascade or
          match?(%Envelope{pending_halt: halt} when halt != nil, StepCommit.envelope(commit))

      code = if cascade?, do: "loop_cascade", else: "loop_cancel"
      %{"code" => code, "loop_id" => loop_id}
    end

    # A send targets another loop by id; the target row locks like an
    # append's. A target that does not exist, or is not a loop, fails the
    # whole commit: the step retries, and the causing input walks the
    # sender's poison path, informed rather than silently dropped.
    defp execute_sends(_config, _row, %StepCommit{sends: []}), do: :ok

    defp execute_sends(config, row, %StepCommit{sends: sends, loop_ref: loop_id}) do
      vocab = vocabulary(config, row)

      Enum.reduce_while(sends, :ok, fn send, :ok ->
        {kind, payload} = InboxCodec.encode_input(Input.message(send.payload), vocabulary: vocab)

        cond do
          send.target == loop_id ->
            # A self-send skips the wake: the park re-check sees the row.
            insert_input(config.repo, loop_id, kind, payload, send.dedup_key)
            {:cont, :ok}

          true ->
            case cast_id(send.target) && lock_run(config, send.target) do
              %AgentRun{kind: "loop"} = target ->
                deliver_locked(config, target, kind, payload, send.dedup_key, wake?: true)
                {:cont, :ok}

              %AgentRun{} ->
                {:halt, {:error, {:send_target_not_a_loop, send.target}}}

              _missing ->
                {:halt, {:error, {:send_target_not_found, send.target}}}
            end
        end
      end)
    end

    defp cast_id(id) do
      case Ecto.UUID.cast(id) do
        {:ok, id} -> id
        :error -> nil
      end
    end

    defp write_envelope(_config, %StepCommit{set: set, children: [], timers: []}, _c, _t)
         when not is_map_key(set, :envelope),
         do: :ok

    defp write_envelope(_config, %StepCommit{set: set} = commit, _c, _t)
         when not is_map_key(set, :envelope) do
      raise ArgumentError,
            "commit for #{inspect(commit.loop_ref)} carries cargo but no envelope to record it"
    end

    defp write_envelope(%Config{repo: repo}, %StepCommit{} = commit, children, timers) do
      envelope = StepCommit.envelope(commit)

      filled = %{
        envelope
        | children: Map.merge(envelope.children, children),
          timers: Map.merge(envelope.timers, timers)
      }

      {1, _} =
        repo.update_all(from(r in AgentRun, where: r.id == ^commit.loop_ref),
          set: [envelope: Envelope.encode(filled)]
        )

      :ok
    end

    # The park re-check runs after every in-unit append (synthesized,
    # self-sends, cascade completions), so its own writes count, and for
    # the :any scope it covers the cancel flag: a flag that landed
    # mid-step saw `running` and could not wake, so parking over it would
    # strand the cancellation. A cascade park (:completions) ignores the
    # flag: the cascade is its handler, and a downgrade would spin the loop
    # until its children finished.
    defp settle_transition(_config, _row, %StepCommit{op: :continue} = commit) do
      enqueue_step(commit.loop_ref, nil)
    end

    defp settle_transition(config, row, %StepCommit{op: :park} = commit) do
      scope = commit.park_recheck || :any

      if pending_exists?(config, commit.loop_ref, scope) or
           (scope == :any and row.cancel != nil) do
        case downgrade_to_continue(config, commit.loop_ref) do
          1 -> enqueue_step(commit.loop_ref, nil)
          0 -> :ok
        end
      else
        :ok
      end
    end

    defp settle_transition(_config, _row, %StepCommit{op: :finish}), do: :ok

    defp pending_exists?(%Config{repo: repo}, loop_id, scope) do
      query =
        from(i in @inbox,
          where: i.run_id == type(^loop_id, Ecto.UUID),
          where: is_nil(i.dead_at)
        )

      query =
        case scope do
          :completions -> where(query, [i], i.kind == "completed")
          :any -> query
        end

      repo.exists?(query)
    end

    # The wake: waiting -> queued, with the suspension cleared and the
    # queued_at stamp renewed. The kind predicate is the belt under every
    # wake path: none may ever clear a parked rollout's suspension.
    defp downgrade_to_continue(%Config{repo: repo}, loop_id) do
      {count, _} =
        repo.update_all(
          from(r in AgentRun,
            where: r.id == ^loop_id,
            where: r.status == "waiting",
            where: r.kind == "loop",
            update: [set: [status: "queued", suspension: nil, queued_at: fragment("now()")]]
          ),
          []
        )

      count
    end

    # The loop's own end fires the projection exactly like a rollout's,
    # inside the unit: the host's run_finished/2 commits with it, and its
    # run_committed/2 hears of it once the unit commits. Re-fetched, not
    # the CAS row: the envelope was written after the CAS.
    defp project_finish(
           %Config{repo: repo},
           %StepCommit{op: :finish, result: result} = commit,
           ctx
         ) do
      row = repo.get!(AgentRun, commit.loop_ref)
      Lifecycle.project(result, row, ctx)
      :ok
    end

    defp project_finish(_config, _commit, _ctx), do: :ok

    defp terminal_sweep(_config, %StepCommit{terminal_sweep: false}), do: :ok

    defp terminal_sweep(%Config{repo: repo}, %StepCommit{loop_ref: loop_id}) do
      {count, _} =
        repo.update_all(
          from(i in @inbox,
            where: i.run_id == type(^loop_id, Ecto.UUID),
            where: is_nil(i.dead_at),
            update: [set: [dead_at: fragment("now()"), dead_reason: "terminal_sweep"]]
          ),
          []
        )

      emit_dead_letter(loop_id, :terminal_sweep, count)
      :ok
    end

    defp final_facts(%Config{repo: repo}, loop_id) do
      AgentRun |> repo.get!(loop_id) |> facts()
    end

    ## append: atomicity sentence 2

    @doc false
    @spec append(Ecto.UUID.t(), Input.t(), String.t() | nil) ::
            append_outcome() | {:error, :not_found | :not_a_loop | term()}
    def append(loop_id, %Input{} = input, dedup_key)
        when is_binary(dedup_key) or is_nil(dedup_key) do
      %Config{repo: repo} = config = Config.fetch!()

      # Inside a caller's transaction the row and the job commit with it,
      # and the host hears of the wake through the claim that follows: a
      # notification or an input event here would describe a write the
      # caller may yet roll back, and nothing of ours runs at its commit.
      announce? = not repo.in_transaction?()

      in_unit(repo, fn ->
        repo.transaction(fn ->
          case lock_run(config, loop_id) do
            nil ->
              repo.rollback(:not_found)

            %AgentRun{kind: "loop"} = row ->
              {kind, payload} =
                InboxCodec.encode_input(input, vocabulary: vocabulary(config, row))

              deliver_locked(config, row, kind, payload, dedup_key,
                wake?: true,
                notify?: announce?,
                emit?: announce?
              )

            %AgentRun{} ->
              repo.rollback(:not_a_loop)
          end
        end)
      end)
    end

    # The serialization point: the run-row lock closes the lost-wakeup
    # interleavings. If a park holds the row, we block until it commits and
    # then see `waiting`; if we hold it, the park's CAS blocks and its
    # in-unit re-check sees our committed input.
    defp lock_run(%Config{repo: repo}, loop_id) do
      repo.one(from(r in AgentRun, where: r.id == ^loop_id, lock: "FOR UPDATE"))
    end

    defp deliver_locked(config, %AgentRun{} = row, kind, payload, dedup_key, opts) do
      repo = config.repo
      emit? = Keyword.get(opts, :emit?, true)

      cond do
        row.status in @terminal_statuses ->
          if insert_input(repo, row.id, kind, payload, dedup_key, dead: "terminal", emit?: emit?),
            do: :dead_lettered,
            else: :duplicate

        not insert_input(repo, row.id, kind, payload, dedup_key, emit?: emit?) ->
          :duplicate

        row.status == "waiting" and opts[:wake?] ->
          1 = downgrade_to_continue(config, row.id)
          :ok = enqueue_step(row.id, nil)
          if Keyword.get(opts, :notify?, true), do: notify_woken(config, row.id)
          :appended

        true ->
          :appended
      end
    end

    # The host hears a wake as :resumed, once the unit that woke the loop
    # commits.
    defp notify_woken(%Config{repo: repo}, loop_id) do
      facts = AgentRun |> repo.get!(loop_id) |> facts()
      Emissions.emit(fn -> Lifecycle.notify_transition(facts, :resumed) end)
    end

    # true = inserted; false = the dedup index already holds the key. Every
    # row's birth emits exactly one deferred event: :input for a pending
    # row (or a dedup hit), :dead_letter for a row born dead; `emit?: false`
    # is the append nested in a caller's transaction, where no bracket of
    # ours fires at the commit.
    defp insert_input(repo, loop_id, kind, payload, dedup_key, opts \\ []) do
      row = %{
        run_id: Ecto.UUID.dump!(loop_id),
        kind: kind,
        payload: payload,
        dedup_key: dedup_key
      }

      row =
        case opts[:dead] do
          nil -> row
          reason -> Map.merge(row, %{dead_at: storage_now(repo), dead_reason: reason})
        end

      {count, _} = repo.insert_all(@inbox, [row], on_conflict: :nothing)

      case {count, opts[:dead], Keyword.get(opts, :emit?, true)} do
        {_count, _dead, false} -> :ok
        {1, nil, _emit?} -> emit_input(loop_id, kind, :appended)
        {1, reason, _emit?} -> emit_dead_letter(loop_id, InboxCodec.decode_dead_reason(reason), 1)
        {0, _dead, _emit?} -> emit_input(loop_id, kind, :duplicate)
      end

      count == 1
    end

    defp emit_input(loop_id, kind, outcome) when is_binary(kind) do
      decoded = Enum.find(Input.kinds(), :message, &(Atom.to_string(&1) == kind))

      Emissions.emit(fn ->
        :telemetry.execute(
          [:clementine, :loop, :input],
          %{},
          %{loop_ref: loop_id, kind: decoded, outcome: outcome}
        )
      end)
    end

    defp emit_dead_letter(_loop_id, _reason, 0), do: :ok

    defp emit_dead_letter(loop_id, reason, count) when is_atom(reason) do
      Emissions.emit(fn ->
        :telemetry.execute(
          [:clementine, :loop, :dead_letter],
          %{count: count},
          %{loop_ref: loop_id, reason: reason}
        )
      end)
    end

    ## cancel: the loop-owned flag plus the wake

    @doc false
    # One transaction on the same lock as append/3: the flag, the wake, and
    # the step job commit together, serialized against a concurrent step's
    # park. Against a running row only the flag lands; the park's :any
    # re-check, or the next claim, is the wake's other half. The flag is
    # idempotent and first cause wins; a re-cancel of a parked loop still
    # wakes it. The host hears :cancel_requested once the flag commits.
    @spec cancel(Ecto.UUID.t(), term()) ::
            {:ok, :flagged} | {:error, :already_terminal | :not_found | :not_a_loop | term()}
    def cancel(loop_id, reason) do
      %Config{repo: repo} = config = Config.fetch!()

      in_unit(repo, fn ->
        repo.transaction(fn ->
          case lock_run(config, loop_id) do
            nil ->
              repo.rollback(:not_found)

            %AgentRun{kind: "loop", status: status} when status in @terminal_statuses ->
              repo.rollback(:already_terminal)

            %AgentRun{kind: "loop"} = row ->
              if row.cancel == nil do
                flag =
                  LifecycleCodec.encode_cancel(%{reason: reason, requested_at: storage_now(repo)})

                {1, _} =
                  repo.update_all(from(r in AgentRun, where: r.id == ^loop_id),
                    set: [cancel: flag]
                  )
              end

              if row.status == "waiting" do
                1 = downgrade_to_continue(config, loop_id)
                :ok = enqueue_step(loop_id, nil)
              end

              if row.cancel == nil do
                facts = AgentRun |> repo.get!(loop_id) |> facts()
                Emissions.emit(fn -> Lifecycle.notify_transition(facts, :cancel_requested) end)
              end

              :flagged

            %AgentRun{} ->
              repo.rollback(:not_a_loop)
          end
        end)
      end)
    end

    ## wake: the wake half alone

    @doc false
    # waiting -> queued plus the step job, one transaction, a no-op when
    # the loop is not parked: a running step's park re-check owns the
    # visibility of inputs that are already durable.
    @spec wake(Ecto.UUID.t()) :: :ok
    def wake(loop_id) do
      %Config{repo: repo} = config = Config.fetch!()

      {:ok, :ok} =
        in_unit(repo, fn ->
          repo.transaction(fn ->
            case downgrade_to_continue(config, loop_id) do
              1 ->
                :ok = enqueue_step(loop_id, nil)
                notify_woken(config, loop_id)

              0 ->
                :ok
            end
          end)
        end)

      :ok
    end

    ## The timer fire door

    @doc false
    # Appends {:elapsed, tag} under the schedule's dedup key, waking a
    # parked loop in the same unit. In tag_key space, never the tag term,
    # so a fire survives any deploy. Exactly-once per schedule rides two
    # belts that meet under the row lock: while the fired row lives, the
    # dedup key answers a retry with :duplicate; once a drain consumed it,
    # the envelope's timer meta is the retained schedule identity, and a
    # fire whose schedule is absent or superseded dead-letters at the door
    # (:stale_elapsed) without waking the loop. A fire against a terminal
    # loop dead-letters as :terminal.
    @spec fire_timer(Ecto.UUID.t(), String.t(), term()) ::
            append_outcome() | {:error, :not_found | :not_a_loop | term()}
    def fire_timer(loop_id, tag_key, schedule_id) when is_binary(tag_key) do
      %Config{repo: repo} = config = Config.fetch!()
      payload = InboxCodec.elapsed_payload(tag_key)
      dedup_key = InboxCodec.elapsed_dedup_key(tag_key, schedule_id)

      in_unit(repo, fn ->
        repo.transaction(fn ->
          case cast_id(loop_id) && lock_run(config, loop_id) do
            %AgentRun{kind: "loop"} = row ->
              cond do
                # Terminal wins the reason, whatever else the schedule raced.
                row.status in @terminal_statuses ->
                  deliver_locked(config, row, "elapsed", payload, dedup_key, wake?: true)

                stale_fire?(row, tag_key, schedule_id) ->
                  if insert_input(repo, row.id, "elapsed", payload, dedup_key,
                       dead: "stale_elapsed"
                     ),
                     do: :dead_lettered,
                     else: :duplicate

                true ->
                  deliver_locked(config, row, "elapsed", payload, dedup_key, wake?: true)
              end

            %AgentRun{} ->
              repo.rollback(:not_a_loop)

            nil ->
              repo.rollback(:not_found)
          end
        end)
      end)
    end

    # Judged under the row lock that serializes it against apply_step, so
    # the envelope is never a half-superseded read. A nil envelope is
    # provably schedule-free: schedules are cargo, so nothing can be
    # pending before the first commit. Only provable staleness diverts; an
    # undecodable envelope stays live for the drain to judge.
    defp stale_fire?(%AgentRun{envelope: nil}, _tag_key, _schedule_id), do: true

    defp stale_fire?(%AgentRun{envelope: data}, tag_key, schedule_id) do
      case Envelope.decode(data) do
        {:ok, %Envelope{timers: timers}} ->
          case Map.get(timers, tag_key) do
            nil ->
              true

            %{"schedule_id" => id} ->
              InboxCodec.ref_string(id) != InboxCodec.ref_string(schedule_id)

            _meta ->
              false
          end

        {:error, _} ->
          false
      end
    end

    ## The child glue

    @doc false
    # Inside a child's terminal transaction: the parent's
    # {:completed, tag, result} input, under the replay-stable dedup key
    # "completed:<tag_key>:<child_id>", exactly-once at source because
    # terminals are dead ends (matrix row L12). The tag key comes from the
    # parent's envelope, which recorded the child under it; a child the
    # envelope no longer lists dead-letters as :unknown_tag at the drain.
    # No wake here: the parent may be mid-step, and wake_parent/1 takes
    # it after the commit.
    @spec append_completion(AgentRun.t(), Result.t()) :: :ok
    def append_completion(%AgentRun{parent_id: parent_id} = child, result)
        when is_binary(parent_id) do
      config = Config.fetch!()

      case lock_run(config, parent_id) do
        %AgentRun{kind: "loop"} = parent ->
          tag_key = child_tag_key(parent, child)
          payload = InboxCodec.completion_payload(tag_key, result)
          dedup_key = InboxCodec.completion_dedup_key(tag_key, child.id)
          deliver_locked(config, parent, "completed", payload, dedup_key, wake?: false)

        _missing_or_not_a_loop ->
          Logger.warning(
            "loop #{parent_id} is gone; dropping the completion of child #{child.id} " <>
              "(#{child.tag_kind} #{child.tag_id})"
          )
      end

      :ok
    end

    def append_completion(%AgentRun{}, _result), do: :ok

    # The envelope keys children by the canonical tag key, which keeps the
    # id's type; the row keeps the two halves as text. A child the envelope
    # does not list (retired already) gets the text form, which the drain
    # dead-letters as :unknown_tag.
    defp child_tag_key(%AgentRun{envelope: data}, %AgentRun{} = child) do
      listed =
        case decode_stored_envelope(data) do
          %Envelope{children: children} ->
            Enum.find_value(children, fn {key, id} -> id == child.id && key end)

          nil ->
            nil
        end

      listed || Jason.encode!(["t", [["a", child.tag_kind], child.tag_id]])
    end

    @doc false
    # After a child's terminal commits: wake its parent if parked. Best
    # effort by design; delivery was durable in the terminal transaction,
    # and the loop sweep's :wake_pending verdict backstops a lost wake.
    @spec wake_parent(AgentRun.t()) :: :ok
    def wake_parent(%AgentRun{parent_id: parent_id}) when is_binary(parent_id),
      do: wake(parent_id)

    def wake_parent(%AgentRun{}), do: :ok

    ## The loop sweep's evidence

    @doc false
    # What a parked loop's judgment needs beyond its facts: its live
    # children joined to their rows and the inbox, and the oldest unconsumed
    # input's stamp.
    @spec evidence(AgentRun.t()) :: LoopEvidence.t()
    def evidence(%AgentRun{kind: "loop"} = row) do
      %Config{repo: repo} = Config.fetch!()

      children =
        case decode_stored_envelope(row.envelope) do
          %Envelope{children: children} -> Enum.map(children, &child_evidence(repo, row.id, &1))
          nil -> []
        end

      %LoopEvidence{children: children, oldest_pending_at: oldest_pending_at(repo, row.id)}
    end

    defp child_evidence(repo, loop_id, {tag_key, child_id}) do
      child = child_id && cast_id(child_id) && repo.get(AgentRun, child_id)

      %{
        tag_key: tag_key,
        child_ref: child_id,
        terminal?: child != nil and child.status in @terminal_statuses,
        # Present at all, pending or dead-lettered: dead letters are
        # retained evidence, and re-synthesizing a poison completion would
        # only re-poison.
        completion_present?:
          repo.exists?(
            from(i in @inbox,
              where: i.run_id == type(^loop_id, Ecto.UUID),
              where: i.dedup_key == ^InboxCodec.completion_dedup_key(tag_key, child_id)
            )
          )
      }
    end

    defp oldest_pending_at(repo, loop_id) do
      repo.one(
        from(i in @inbox,
          where: i.run_id == type(^loop_id, Ecto.UUID),
          where: is_nil(i.dead_at),
          select: min(i.inserted_at)
        )
      )
    end

    @doc false
    # Synthesizes a stranded child's completion from its terminal row,
    # under the dedup key the projection glue would have written, so a
    # racing real delivery collapses to :duplicate. The parent's fold needs
    # the variant and the usage; the child's output lives where the host's
    # run_finished/2 put it.
    @spec reconcile_child(AgentRun.t(), Clementine.Reconciler.strand()) :: :ok
    def reconcile_child(%AgentRun{kind: "loop"} = loop, %{tag_key: tag_key, child_ref: child_id}) do
      %Config{repo: repo} = config = Config.fetch!()
      child = repo.get!(AgentRun, child_id)
      tag = InboxCodec.decode_tag(tag_key, vocabulary: vocabulary(config, loop))

      {:ok, _outcome} =
        append(
          loop.id,
          Input.completed(tag, synthesized_result(child)),
          InboxCodec.completion_dedup_key(tag_key, child_id)
        )

      :ok
    end

    # The child's terminal row holds what the lost delivery carried: the
    # output a completed run stored, the error, the cancel reason, the
    # interrupt reason, and the usage. The synthesized completion folds as
    # the lost one would have, so the controller decides the same way.
    defp synthesized_result(%AgentRun{} = child) do
      facts = facts(child)
      usage = facts.usage || %Clementine.Usage{}

      case facts.status do
        :completed ->
          Result.completed(output: child.result && child.result["output"], usage: usage)

        :failed ->
          Result.failed(facts.error || %Clementine.Error{message: "child failed"}, usage)

        :cancelled ->
          Result.cancelled(
            (facts.cancel && facts.cancel.reason) || %{"code" => "reconciled"},
            usage
          )

        :interrupted ->
          Result.interrupted(facts.interrupt || {:app, :reconciled}, usage)
      end
    end

    ## The paging gauge

    @doc false
    @spec inbox_depths() :: [
            %{loop_id: Ecto.UUID.t(), depth: non_neg_integer(), oldest_age_ms: non_neg_integer()}
          ]
    def inbox_depths do
      %Config{repo: repo} = Config.fetch!()

      repo.all(
        from(i in @inbox,
          where: is_nil(i.dead_at),
          group_by: i.run_id,
          select: %{
            loop_id: type(i.run_id, Ecto.UUID),
            depth: count(i.id),
            oldest_age_ms:
              fragment(
                "greatest((extract(epoch from (now() - min(?))) * 1000)::bigint, 0)",
                i.inserted_at
              )
          }
        )
      )
    end

    ## Shared

    defp facts(%AgentRun{} = row), do: LifecycleCodec.to_facts(row, @fields)

    defp vocabulary(%Config{agents: agents}, %AgentRun{agent_key: key}) do
      case Map.get(agents, key) do
        module when is_atom(module) and not is_nil(module) ->
          if Loop.loop?(module), do: module.__loop__(:vocabulary), else: []

        _unknown ->
          []
      end
    end

    defp vocabulary(_config, nil), do: []

    # Brackets one unit: its emissions fire once `transaction` returns
    # `{:ok, _}` and are dropped otherwise.
    defp in_unit(_repo, transaction), do: Emissions.after_commit(transaction)

    defp storage_now(repo) do
      %{rows: [[%DateTime{} = now]]} = repo.query!("SELECT now()")
      now
    end
  end
end
