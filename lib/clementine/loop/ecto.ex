if Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Loop.Ecto do
    @moduledoc """
    The Ecto implementation of `Clementine.Loop.Host` (LOOP_RFC amendment
    A5): both normative atomicity sentences as one Postgres transaction
    each, against the host's own tables carrying the loop recipe
    (`Clementine.Loop.Ecto.Migration`).

        defmodule MyApp.LoopHost do
          use Clementine.Loop.Ecto,
            lifecycle: MyApp.ClementineLifecycle,   # a use Clementine.Lifecycle.Ecto module
            inbox_table: "loop_inbox"

          @impl Clementine.Loop.Host
          def build_child(facts, tag, args, _ctx),
            do: {:ok, MyApp.Agents.rollout_for(facts, tag, args)}

          @impl Clementine.Loop.Host
          def enqueue_step(loop_ref, _ctx) do
            {:ok, _} = Oban.insert(MyApp.LoopStepWorker.new(%{"loop_ref" => loop_ref}))
            :ok
          end

          @impl Clementine.Loop.Ecto
          def enqueue_child(child_row, child_args, _ctx) do
            {:ok, _} = Oban.insert(MyApp.RunWorker.new(%{"run_id" => child_row.id, "args" => child_args}))
            :ok
          end
        end

    The adapter derives repo, schema, and column mapping from the
    lifecycle module's configuration — one source of truth for the run
    table — and speaks to the inbox schemalessly by its configured name
    (the recipe owns its shape).

    ## The two atomic units, in SQL terms

    `apply_step/2` is one transaction: the guarded CAS `UPDATE` first (the
    fence — a zombie's commit dies here before any cargo exists), then
    consumption (`DELETE`), dead-letter marks, synthesized appends, child
    rows and their jobs, timer schedules and cancellations, cascade child
    cancels, sends, the park re-check, the filled envelope write, the
    terminal projection, and the terminal sweep. A park re-verifies
    pending-emptiness *inside the unit* — after every in-unit append, so
    its own writes count — and downgrades to continue (status `queued` +
    `enqueue_step/2`) when inputs exist: the append's run-row lock
    serializes the racing cases (matrix rows L3/L4).

    `append/4` is one transaction: `SELECT ... FOR UPDATE` on the loop's
    run row — the serialization point against a concurrent park's CAS —
    then the input insert (`ON CONFLICT DO NOTHING` on the dedup index →
    `:duplicate`), and, when the row is `waiting`, the wake CAS plus the
    step-job enqueue. A terminal loop's append inserts the row directly
    dead-lettered (`dead_reason: :terminal`) and returns
    `{:ok, :dead_lettered}` — the caller knows (matrix row L10).

    Job insertion is the host's (`enqueue_step/2`, `enqueue_child/3`,
    `schedule_timer/3`): implementations must write rows through the same
    repo so an in-unit call commits with the unit — `Oban.insert/2`
    against the configured repo does, because Ecto transactions are
    per-process. The timer seam raises by default until a scheduler is
    wired (its Oban-backed implementation ships with the timers epic).

    ## Send cargo and vocabularies

    Send payloads encode under the *sender's* declared vocabulary (the
    same contract `Clementine.Loop.Action` validated at drain time) and
    decode under the *receiver's* at its own drain — a sender's atom the
    receiver never declared surfaces as that input's `decode_error`,
    walking the receiver's poison path as observable evidence rather than
    failing anyone's fetch. A send whose target row does not exist fails
    the whole commit: the step retries and the causing input walks the
    sender's poison path — informed, never silently dropped.

    ## Child-terminal projection glue

    `append_completion/4` runs inside the child's terminal transaction —
    call it from the *lifecycle* module's `project/3` — appending
    `{:completed, tag, result}` to the parent's inbox with the
    replay-stable dedup key `"completed:" <> tag_key <> ":" <> child_ref`:
    exactly-once at source, because terminals are dead ends (matrix row
    L12). `wake_parent/3` is the post-commit half — call it from
    `after_transition/3` — a wake and nothing else: best-effort by design,
    backstopped by the reaper's `:wake_pending` verdict, acceptable
    because delivery was durable before it.

    Mutual cancellation is the one place lock ordering can cross (a parent
    step cancelling a child while that child's terminal appends its
    completion); Postgres resolves the deadlock by aborting one side, and
    both sides are safe to retry by construction — the step by
    replayability, the terminal by its bounded retry posture.
    """

    import Ecto.Query

    require Logger

    alias Clementine.Lifecycle.Ecto.Codec, as: LifecycleCodec
    alias Clementine.Lifecycle.{Facts, Protocol, Transition}
    alias Clementine.Loop
    alias Clementine.Loop.Ecto.Codec
    alias Clementine.Loop.{Envelope, Input, StepCommit, StoredInput}

    @loop_field_defaults [
      loop_module: :loop_module,
      loop_args: :loop_args,
      loop_policy: :loop_policy,
      envelope: :envelope,
      state_version: :state_version,
      loop_scope: :loop_scope,
      loop_ref: :loop_ref,
      tag_key: :tag_key
    ]

    @doc """
    Product columns for a child run row (a foreign key the host's table
    demands, say), merged under the machinery's own columns. Invoked
    inside `apply_step/2`'s atomic unit. Defaults to `%{}`.
    """
    @callback child_attrs(
                loop_row :: Ecto.Schema.t(),
                tag_key :: String.t(),
                child_args :: map(),
                ctx :: term()
              ) ::
                map()

    @doc """
    Inserts the freshly created child run row's job. Invoked inside
    `apply_step/2`'s atomic unit; must write through the same repo. The
    durable `child_args` belong in the job — the child worker hands them
    to `build_child/4` at spawn execution time.
    """
    @callback enqueue_child(child_row :: Ecto.Schema.t(), child_args :: map(), ctx :: term()) ::
                :ok

    @doc """
    Schedules one durable timer job and returns its JSON-safe envelope
    meta (the schedule handle `cancel_timer/4` gets back). Invoked inside
    `apply_step/2`'s atomic unit. The spec's `fire` is
    `{:at, DateTime.t()}` or the symbolic `{:now_plus, ms}` — resolve the
    relative form against the storage clock.
    """
    @callback schedule_timer(
                loop_row :: Ecto.Schema.t(),
                timer_spec :: StepCommit.timer_spec(),
                ctx :: term()
              ) ::
                {:ok, meta :: map()}

    @doc """
    Best-effort cancellation of a scheduled timer job — a fire that races
    the cancel is legal and dead-letters as `:stale_elapsed` on arrival.
    Invoked inside `apply_step/2`'s atomic unit. Defaults to `:ok`.
    """
    @callback cancel_timer(
                loop_row :: Ecto.Schema.t(),
                tag_key :: String.t(),
                meta :: map(),
                ctx :: term()
              ) ::
                :ok

    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        @behaviour Clementine.Loop.Host
        @behaviour Clementine.Loop.Ecto

        @clementine_loop_lifecycle Keyword.fetch!(opts, :lifecycle)
        @clementine_loop_inbox opts |> Keyword.fetch!(:inbox_table) |> to_string()
        @clementine_loop_fields Keyword.get(opts, :fields, [])

        @doc false
        def __clementine_loop_config__ do
          Clementine.Loop.Ecto.config(
            @clementine_loop_lifecycle,
            @clementine_loop_inbox,
            @clementine_loop_fields
          )
        end

        @impl Clementine.Loop.Host
        def apply_step(commit, ctx) do
          Clementine.Loop.Ecto.apply_step(__MODULE__, commit, ctx)
        end

        @impl Clementine.Loop.Host
        def append(loop_ref, input, dedup_key, ctx) do
          Clementine.Loop.Ecto.append(__MODULE__, loop_ref, input, dedup_key, ctx)
        end

        @impl Clementine.Loop.Host
        def pending(loop_ref, limit, ctx) do
          Clementine.Loop.Ecto.pending(__MODULE__, loop_ref, limit, ctx)
        end

        @impl Clementine.Loop.Host
        def bump_attempts(refs, ctx) do
          Clementine.Loop.Ecto.bump_attempts(__MODULE__, refs, ctx)
        end

        @impl Clementine.Loop.Host
        def create(spec, ctx) do
          Clementine.Loop.Ecto.create(__MODULE__, spec, ctx)
        end

        @impl Clementine.Loop.Ecto
        def child_attrs(_loop_row, _tag_key, _child_args, _ctx), do: %{}

        @impl Clementine.Loop.Ecto
        def enqueue_child(_child_row, _child_args, _ctx) do
          raise "#{inspect(__MODULE__)} spawned a child but does not implement " <>
                  "enqueue_child/3 — override it to insert the child's job"
        end

        @impl Clementine.Loop.Ecto
        def schedule_timer(_loop_row, timer_spec, _ctx) do
          raise "#{inspect(__MODULE__)} armed timer #{inspect(timer_spec.tag)} but does not " <>
                  "implement schedule_timer/3 — override it to insert the timer job " <>
                  "(the Oban-backed seam ships with the timers epic)"
        end

        @impl Clementine.Loop.Ecto
        def cancel_timer(_loop_row, _tag_key, _meta, _ctx), do: :ok

        defoverridable child_attrs: 4, enqueue_child: 3, schedule_timer: 3, cancel_timer: 4
      end
    end

    @doc false
    def config(lifecycle, inbox_table, field_overrides) do
      base = lifecycle.__clementine_config__()

      case Keyword.keys(field_overrides) -- Keyword.keys(@loop_field_defaults) do
        [] ->
          %{
            repo: base.repo,
            schema: base.schema,
            lifecycle: lifecycle,
            inbox: inbox_table,
            fields: base.fields ++ Keyword.merge(@loop_field_defaults, field_overrides)
          }

        unknown ->
          raise ArgumentError,
                "unknown loop fields: #{inspect(unknown)} — lifecycle column overrides " <>
                  "belong on the lifecycle module"
      end
    end

    ## apply_step — atomicity sentence 1

    @doc false
    def apply_step(module, %StepCommit{} = commit, ctx) do
      config = module.__clementine_loop_config__()

      config.repo.transaction(fn ->
        case do_apply_step(module, config, commit, ctx) do
          {:ok, facts} -> facts
          {:error, reason} -> config.repo.rollback(reason)
        end
      end)
    end

    defp do_apply_step(module, config, %StepCommit{} = commit, ctx) do
      with {:ok, row} <- cas_step(config, commit),
           :ok <- consume(config, commit),
           :ok <- mark_dead(config, commit),
           :ok <- insert_appends(config, commit),
           {:ok, children} <- spawn_children(module, config, row, commit, ctx),
           {:ok, timers} <- schedule_timers(module, row, commit, ctx),
           :ok <- retire_timers(module, config, row, commit, ctx),
           :ok <- cancel_children(config, commit, children, ctx),
           :ok <- execute_sends(module, config, row, commit, ctx),
           :ok <- write_envelope(config, commit, children, timers),
           :ok <- settle_transition(module, config, commit, ctx),
           :ok <- project_finish(config, commit, row, ctx),
           :ok <- terminal_sweep(config, commit) do
        {:ok, final_facts(config, commit.loop_ref)}
      end
    end

    # The fence first: a stale commit dies before any cargo exists.
    defp cas_step(config, %StepCommit{} = commit) do
      updates =
        commit.set
        |> Map.drop([:envelope])
        |> Enum.map(fn {key, value} ->
          {Keyword.fetch!(config.fields, key), encode_set_value(key, value)}
        end)

      query =
        from(r in config.schema,
          where: field(r, ^config.fields[:ref]) == ^commit.loop_ref,
          where:
            field(r, ^config.fields[:status]) ==
              ^LifecycleCodec.encode_status(commit.expect.status),
          where: field(r, ^config.fields[:epoch]) == ^commit.expect.epoch,
          update: [set: ^updates],
          select: r
        )

      case config.repo.update_all(query, []) do
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

    defp consume(config, %StepCommit{consumed: refs, loop_ref: loop_ref}) do
      {count, _} = config.repo.delete_all(pending_by_refs(config, loop_ref, refs))

      # A consumed ref that is already gone means two commits raced past
      # the fence — corruption the guard exists to make impossible.
      if count == length(refs) do
        :ok
      else
        {:error, {:consumption_mismatch, %{expected: length(refs), deleted: count}}}
      end
    end

    defp mark_dead(_config, %StepCommit{marks: []}), do: :ok

    defp mark_dead(config, %StepCommit{marks: marks, loop_ref: loop_ref}) do
      marks
      |> Enum.group_by(& &1.reason, & &1.ref)
      |> Enum.each(fn {reason, refs} ->
        encoded = Codec.encode_dead_reason(reason)

        config.repo.update_all(
          from(i in pending_by_refs(config, loop_ref, refs),
            update: [set: [dead_at: fragment("now()"), dead_reason: ^encoded]]
          ),
          []
        )
      end)

      :ok
    end

    defp pending_by_refs(config, loop_ref, refs) do
      from(i in config.inbox,
        where: i.loop_ref == type(^loop_ref, ^ref_type(config)),
        where: i.id in ^refs,
        where: is_nil(i.dead_at)
      )
    end

    # Synthesized poison evidence ({:input_failed}) rides the same commit.
    # The core never parks alongside appends, so no wake is needed: the
    # transition is a continue and the step job re-drains them.
    defp insert_appends(_config, %StepCommit{appends: []}), do: :ok

    defp insert_appends(config, %StepCommit{appends: appends, loop_ref: loop_ref}) do
      Enum.each(appends, fn %Input{} = input ->
        {kind, payload} = Codec.encode_input(input, vocabulary: [])
        true = insert_input(config, loop_ref, kind, payload, nil)
      end)

      :ok
    end

    defp spawn_children(_module, _config, _row, %StepCommit{children: []}, _ctx), do: {:ok, %{}}

    defp spawn_children(module, config, row, %StepCommit{children: specs}, ctx) do
      filled =
        Enum.reduce(specs, %{}, fn spec, acc ->
          attrs = module.child_attrs(row, spec.tag_key, spec.child_args, ctx)

          machine = %{
            config.fields[:kind] => "rollout",
            config.fields[:status] => "queued",
            config.fields[:loop_ref] => Map.fetch!(row, config.fields[:ref]),
            config.fields[:tag_key] => spec.tag_key
          }

          child =
            config.repo.insert!(struct!(config.schema, Map.to_list(Map.merge(attrs, machine))))

          :ok = module.enqueue_child(child, spec.child_args, ctx)
          Map.put(acc, spec.tag_key, Map.fetch!(child, config.fields[:ref]))
        end)

      {:ok, filled}
    end

    defp schedule_timers(_module, _row, %StepCommit{timers: []}, _ctx), do: {:ok, %{}}

    defp schedule_timers(module, row, %StepCommit{timers: specs}, ctx) do
      metas =
        Map.new(specs, fn spec ->
          {:ok, meta} = module.schedule_timer(row, spec, ctx)

          {spec.tag_key,
           Loop.Codec.validate_json_map!(meta, "schedule_timer/3 meta for #{inspect(spec.tag)}")}
        end)

      {:ok, metas}
    end

    # The stored envelope still holds the retired entries' metas at this
    # point: the CAS never touches the envelope column (it is written
    # post-cargo, refs filled), so the CAS-returned row carries the
    # pre-step value.
    defp retire_timers(_module, _config, _row, %StepCommit{cancel_timers: []}, _ctx), do: :ok

    defp retire_timers(module, config, row, %StepCommit{cancel_timers: tag_keys}, ctx) do
      metas =
        case row |> Map.fetch!(config.fields[:envelope]) |> decode_stored_envelope() do
          %Envelope{timers: timers} -> timers
          nil -> %{}
        end

      Enum.each(tag_keys, fn tag_key ->
        :ok = module.cancel_timer(row, tag_key, Map.get(metas, tag_key, %{}), ctx)
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

    # Cascade cargo: the machinery — not handle/2 — cancels live children.
    # A queued or waiting child direct-terminalizes here, and its terminal
    # projection appends its completion to this very loop inside this very
    # unit, where the park re-check will see it. Already-terminal and
    # missing children are tolerated: their completions are en route or
    # the reaper's :reconcile_children verdict will synthesize them.
    defp cancel_children(_config, %StepCommit{cancel_children: []}, _children, _ctx), do: :ok

    defp cancel_children(config, %StepCommit{cancel_children: tag_keys} = commit, children, ctx) do
      stored = StepCommit.envelope(commit)

      Enum.reduce_while(tag_keys, :ok, fn tag_key, :ok ->
        ref = Map.get(children, tag_key) || (stored && Map.get(stored.children, tag_key))

        if ref == nil do
          raise ArgumentError,
                "cascade cancel for #{inspect(tag_key)} names no child ref — " <>
                  "the commit's envelope must carry every live child"
        end

        case Protocol.request_cancel(config.lifecycle, ref, {:loop_cascade, commit.loop_ref}, ctx) do
          {:ok, _} -> {:cont, :ok}
          {:error, :already_terminal} -> {:cont, :ok}
          {:error, :not_found} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:cancel_child_failed, ref, reason}}}
        end
      end)
    end

    defp execute_sends(_module, _config, _row, %StepCommit{sends: []}, _ctx), do: :ok

    defp execute_sends(module, config, row, %StepCommit{sends: sends, loop_ref: loop_ref}, ctx) do
      vocab = vocabulary_of(row, config)

      Enum.reduce_while(sends, :ok, fn send, :ok ->
        {kind, payload} = Codec.encode_input(Input.message(send.payload), vocabulary: vocab)

        cond do
          send.target == loop_ref ->
            # Self-sends skip the wake: the park re-check sees the row.
            insert_input(config, loop_ref, kind, payload, send.dedup_key)
            {:cont, :ok}

          true ->
            case lock_run(config, send.target) do
              nil ->
                {:halt, {:error, {:send_target_not_found, send.target}}}

              target ->
                deliver_locked(module, config, target, kind, payload, send.dedup_key,
                  wake?: true,
                  ctx: ctx
                )

                {:cont, :ok}
            end
        end
      end)
    end

    defp write_envelope(_config, %StepCommit{set: set, children: [], timers: []}, _c, _t)
         when not is_map_key(set, :envelope),
         do: :ok

    defp write_envelope(_config, %StepCommit{set: set} = commit, _c, _t)
         when not is_map_key(set, :envelope) do
      raise ArgumentError,
            "commit for #{inspect(commit.loop_ref)} carries cargo but no envelope to record it"
    end

    defp write_envelope(config, %StepCommit{} = commit, children, timers) do
      envelope = StepCommit.envelope(commit)

      filled = %{
        envelope
        | children: Map.merge(envelope.children, children),
          timers: Map.merge(envelope.timers, timers)
      }

      {1, _} =
        config.repo.update_all(
          from(r in config.schema, where: field(r, ^config.fields[:ref]) == ^commit.loop_ref),
          set: [{config.fields[:envelope], Envelope.encode(filled)}]
        )

      :ok
    end

    # The park re-check runs after every in-unit append (synthesized,
    # sends-to-self, cascade completions), so its own writes count. A
    # downgrade that matches zero rows lost to an in-unit wake that
    # already queued the row and enqueued the job — nothing left to do.
    defp settle_transition(module, _config, %StepCommit{op: :continue} = commit, ctx) do
      :ok = module.enqueue_step(commit.loop_ref, ctx)
    end

    defp settle_transition(module, config, %StepCommit{op: :park} = commit, ctx) do
      if pending_exists?(config, commit.loop_ref, commit.park_recheck || :any) do
        case downgrade_to_continue(config, commit.loop_ref) do
          1 -> :ok = module.enqueue_step(commit.loop_ref, ctx)
          0 -> :ok
        end
      else
        :ok
      end
    end

    defp settle_transition(_module, _config, %StepCommit{op: :finish}, _ctx), do: :ok

    defp pending_exists?(config, loop_ref, scope) do
      query =
        from(i in config.inbox,
          where: i.loop_ref == type(^loop_ref, ^ref_type(config)),
          where: is_nil(i.dead_at)
        )

      query =
        case scope do
          :completions -> where(query, [i], i.kind == "completed")
          :any -> query
        end

      config.repo.exists?(query)
    end

    defp downgrade_to_continue(config, loop_ref) do
      {count, _} =
        config.repo.update_all(
          from(r in config.schema,
            where: field(r, ^config.fields[:ref]) == ^loop_ref,
            where: field(r, ^config.fields[:status]) == "waiting",
            update: [set: ^wake_set(config)]
          ),
          []
        )

      count
    end

    # The loop's own terminal fires the host projection exactly like every
    # rollout terminal — inside the unit; a raise aborts the whole commit.
    defp project_finish(config, %StepCommit{op: :finish, result: result}, row, ctx) do
      config.lifecycle.project(result, row, ctx)
      :ok
    end

    defp project_finish(_config, _commit, _row, _ctx), do: :ok

    defp terminal_sweep(_config, %StepCommit{terminal_sweep: false}), do: :ok

    defp terminal_sweep(config, %StepCommit{loop_ref: loop_ref}) do
      config.repo.update_all(
        from(i in config.inbox,
          where: i.loop_ref == type(^loop_ref, ^ref_type(config)),
          where: is_nil(i.dead_at),
          update: [set: [dead_at: fragment("now()"), dead_reason: "terminal_sweep"]]
        ),
        []
      )

      :ok
    end

    defp final_facts(config, loop_ref) do
      config.schema
      |> config.repo.get!(loop_ref)
      |> LifecycleCodec.to_facts(config.fields)
    end

    ## append — atomicity sentence 2

    @doc false
    def append(module, loop_ref, %Input{} = input, dedup_key, ctx)
        when is_binary(dedup_key) or is_nil(dedup_key) do
      config = module.__clementine_loop_config__()

      config.repo.transaction(fn ->
        case lock_run(config, loop_ref) do
          nil ->
            config.repo.rollback(:not_found)

          row ->
            {kind, payload} = Codec.encode_input(input, vocabulary: vocabulary_of(row, config))
            deliver_locked(module, config, row, kind, payload, dedup_key, wake?: true, ctx: ctx)
        end
      end)
    end

    # The serialization point (LOOP_RFC §The Loop Host Contract): the
    # run-row lock is what closes the lost-wakeup interleavings. If a park
    # holds the row, we block until it commits and then see `waiting`; if
    # we hold it, the park's CAS blocks and its in-unit re-check then sees
    # our committed input.
    defp lock_run(config, loop_ref) do
      config.repo.one(
        from(r in config.schema,
          where: field(r, ^config.fields[:ref]) == ^loop_ref,
          lock: "FOR UPDATE"
        )
      )
    end

    defp deliver_locked(module, config, row, kind, payload, dedup_key, opts) do
      loop_ref = Map.fetch!(row, config.fields[:ref])
      status = row |> Map.fetch!(config.fields[:status]) |> LifecycleCodec.decode_status()

      cond do
        Facts.terminal?(status) ->
          if insert_input(config, loop_ref, kind, payload, dedup_key, dead: "terminal") do
            :dead_lettered
          else
            :duplicate
          end

        not insert_input(config, loop_ref, kind, payload, dedup_key) ->
          :duplicate

        status == :waiting and opts[:wake?] ->
          1 = downgrade_to_continue(config, loop_ref)
          :ok = module.enqueue_step(loop_ref, opts[:ctx])
          :appended

        true ->
          :appended
      end
    end

    # true = inserted; false = the dedup index already holds the key.
    defp insert_input(config, loop_ref, kind, payload, dedup_key, opts \\ []) do
      row = %{loop_ref: loop_ref, kind: kind, payload: payload, dedup_key: dedup_key}

      row =
        case opts[:dead] do
          nil -> row
          reason -> Map.merge(row, %{dead_at: storage_now(config.repo), dead_reason: reason})
        end

      {count, _} = config.repo.insert_all(config.inbox, [row], on_conflict: :nothing)
      count == 1
    end

    ## pending / bump_attempts

    @doc false
    def pending(module, loop_ref, limit, _ctx) when is_integer(limit) and limit > 0 do
      config = module.__clementine_loop_config__()
      vocab = loop_vocabulary(config, loop_ref)

      rows =
        config.repo.all(
          from(i in config.inbox,
            where: i.loop_ref == type(^loop_ref, ^ref_type(config)),
            where: is_nil(i.dead_at),
            order_by: [asc: i.id],
            limit: ^limit,
            select: %{id: i.id, kind: i.kind, payload: i.payload, attempts: i.attempts}
          )
        )

      Enum.map(rows, fn row ->
        case Codec.decode_input(row.kind, row.payload, vocabulary: vocab) do
          {:ok, input} ->
            %StoredInput{ref: row.id, input: input, attempts: row.attempts}

          {:error, error} ->
            %StoredInput{
              ref: row.id,
              input: placeholder_input(row.kind),
              attempts: row.attempts,
              decode_error: error
            }
        end
      end)
    end

    defp placeholder_input(kind) do
      %Input{kind: Enum.find(Input.kinds(), :message, &(Atom.to_string(&1) == kind))}
    end

    defp loop_vocabulary(config, loop_ref) do
      with row when row != nil <- config.repo.get(config.schema, loop_ref),
           name when name != nil <- Map.fetch!(row, config.fields[:loop_module]),
           {:ok, module} <- Loop.resolve(name) do
        module.__loop__(:vocabulary)
      else
        # An unresolvable spec parks the loop as :incompatible_spec before
        # any drain; vocabulary-free decoding here only serves inspection.
        _ -> []
      end
    end

    defp vocabulary_of(row, config) do
      with name when name != nil <- Map.get(row, config.fields[:loop_module]),
           {:ok, module} <- Loop.resolve(name) do
        module.__loop__(:vocabulary)
      else
        _ -> []
      end
    end

    @doc false
    def bump_attempts(_module, [], _ctx), do: :ok

    def bump_attempts(module, refs, _ctx) when is_list(refs) do
      config = module.__clementine_loop_config__()

      config.repo.update_all(
        from(i in config.inbox, where: i.id in ^refs),
        inc: [attempts: 1]
      )

      :ok
    end

    ## create

    @doc false
    def create(module, %{module: loop_module, scope: scope} = spec, ctx) do
      config = module.__clementine_loop_config__()
      scope_column = config.fields[:loop_scope]

      row =
        spec.attrs
        |> Map.new()
        |> Map.merge(%{
          config.fields[:kind] => "loop",
          config.fields[:status] => "queued",
          config.fields[:loop_module] => inspect(loop_module),
          config.fields[:loop_args] => spec.args,
          config.fields[:loop_policy] => spec.policy,
          config.fields[:state_version] => spec.state_version,
          scope_column => scope
        })
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      config.repo.transaction(fn ->
        insert =
          config.repo.insert_all(config.schema, [row],
            on_conflict: :nothing,
            conflict_target:
              {:unsafe_fragment, "(#{scope_column}) WHERE #{scope_column} IS NOT NULL"},
            returning: true
          )

        case insert do
          {1, [inserted]} ->
            :ok = module.enqueue_step(Map.fetch!(inserted, config.fields[:ref]), ctx)
            {:created, LifecycleCodec.to_facts(inserted, config.fields)}

          {0, _} ->
            existing =
              config.repo.one(from(r in config.schema, where: field(r, ^scope_column) == ^scope))

            case existing do
              nil -> config.repo.rollback(:not_found)
              found -> {:existing, LifecycleCodec.to_facts(found, config.fields)}
            end
        end
      end)
      |> case do
        {:ok, {:created, facts}} -> {:ok, facts}
        {:ok, {:existing, facts}} -> {:ok, :already_exists, facts}
        {:error, reason} -> {:error, reason}
      end
    end

    ## Child-terminal projection glue

    @doc """
    Appends the parent loop's `{:completed, tag, result}` input — call
    inside the child's terminal projection (`project/3` on the lifecycle
    module), so delivery commits with the terminal: exactly-once at
    source. No-ops for rows that are not loop children (`loop_ref` NULL),
    so hosts call it unconditionally. A missing parent (deleted loop) is
    logged and skipped; a terminal parent retains the row as dead-letter
    evidence. Storage failures raise so the terminal transaction aborts
    and retries under `finish`'s bounded posture.
    """
    @spec append_completion(module(), Clementine.Result.t(), Ecto.Schema.t(), term()) ::
            :ok
    def append_completion(host, result, child_row, _ctx \\ nil) do
      config = host.__clementine_loop_config__()

      with loop_ref when loop_ref != nil <- Map.get(child_row, config.fields[:loop_ref]) do
        tag_key = Map.fetch!(child_row, config.fields[:tag_key])
        child_ref = Map.fetch!(child_row, config.fields[:ref])
        payload = Codec.completion_payload(tag_key, result)
        dedup_key = Codec.completion_dedup_key(tag_key, child_ref)

        case lock_run(config, loop_ref) do
          nil ->
            Logger.warning(
              "loop #{inspect(loop_ref)} is gone; dropping completion for child " <>
                "#{inspect(child_ref)} (#{tag_key})"
            )

          row ->
            deliver_locked(host, config, row, "completed", payload, dedup_key,
              wake?: false,
              ctx: nil
            )
        end
      end

      :ok
    end

    @doc """
    The post-commit half of completion delivery — call from the lifecycle
    module's `after_transition/3`. On a terminal transition of a loop
    child, wakes the parent (`wake/3`); otherwise a no-op. Best-effort by
    design: delivery was durable in the terminal transaction, and the
    reaper's `:wake_pending` verdict backstops a lost wake.
    """
    @spec wake_parent(module(), Transition.t(), term()) :: :ok
    def wake_parent(host, transition, ctx \\ nil)
    def wake_parent(_host, %Transition{result: nil}, _ctx), do: :ok

    def wake_parent(host, %Transition{run_ref: run_ref}, ctx) do
      config = host.__clementine_loop_config__()

      with row when row != nil <- config.repo.get(config.schema, run_ref),
           loop_ref when loop_ref != nil <- Map.get(row, config.fields[:loop_ref]) do
        wake(host, loop_ref, ctx)
      end

      :ok
    end

    @doc """
    Wake-only: the CAS `waiting -> queued` plus the step-job enqueue, one
    transaction, no-op when the loop is not parked (a running step's park
    re-check owns visibility of already-durable inputs).
    """
    @spec wake(module(), term(), term()) :: :ok
    def wake(host, loop_ref, ctx \\ nil) do
      config = host.__clementine_loop_config__()

      {:ok, :ok} =
        config.repo.transaction(fn ->
          case downgrade_to_continue(config, loop_ref) do
            1 -> :ok = host.enqueue_step(loop_ref, ctx)
            0 -> :ok
          end
        end)

      :ok
    end

    ## Shared

    defp wake_set(config) do
      [
        {config.fields[:status], "queued"},
        {config.fields[:suspension], nil},
        {config.fields[:queued_at], dynamic(fragment("now()"))}
      ]
    end

    defp ref_type(config) do
      config.schema.__schema__(:type, config.fields[:ref])
    end

    defp storage_now(repo) do
      %{rows: [[%DateTime{} = now]]} = repo.query!("SELECT now()")
      now
    end
  end
end
