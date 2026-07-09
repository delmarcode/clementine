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
    its own writes count — and, for the `:any` scope, that no cancel flag
    is set, downgrading to continue (status `queued` + `enqueue_step/2`)
    when either holds: the append's and `cancel/4`'s run-row lock
    serializes the racing cases (matrix rows L3/L4, L8).

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
    wired (see Timers On The Scheduler Seam below).

    ## Send cargo and vocabularies

    Send payloads encode under the *sender's* declared vocabulary (the
    same contract `Clementine.Loop.Action` validated at drain time) and
    decode under the *receiver's* at its own drain — a sender's atom the
    receiver never declared surfaces as that input's `decode_error`,
    walking the receiver's poison path as observable evidence rather than
    failing anyone's fetch. A send whose target row does not exist — or is
    not a loop — fails the whole commit: the step retries and the causing
    input walks the sender's poison path — informed, never silently
    dropped.

    ## Timers on the scheduler seam

    `schedule_timer/3` and `cancel_timer/4` are the schedule half —
    invoked inside `apply_step/2`'s unit, so a schedule commits with the
    envelope entry recording it or not at all (matrix row L6's crash
    window: a job outliving its never-committed entry, draft v1's wedged
    watcher, is structurally impossible). `fire_timer/5` is the fire
    half: the timer worker's door, appending `{:elapsed, tag}` under the
    machinery dedup key `"elapsed:" <> tag_key <> ":" <> schedule_id` —
    per schedule, so a worker's retry collapses to `:duplicate` while a
    re-armed tag's next fire (a fresh schedule) lands. The Oban wiring,
    in full:

        @impl Clementine.Loop.Ecto
        def schedule_timer(loop_row, spec, _ctx) do
          {:ok, job} =
            Oban.insert(
              MyApp.LoopTimerWorker.new(
                %{"loop_ref" => loop_row.id, "tag_key" => spec.tag_key},
                scheduled_at: Clementine.Loop.Ecto.fire_at(__MODULE__, spec.fire)
              )
            )

          {:ok, %{"schedule_id" => job.id}}
        end

        @impl Clementine.Loop.Ecto
        def cancel_timer(_loop_row, _tag_key, %{"schedule_id" => job_id}, _ctx) do
          Oban.cancel_job(job_id)
          :ok
        end

        def cancel_timer(_loop_row, _tag_key, _meta, _ctx), do: :ok

        defmodule MyApp.LoopTimerWorker do
          use Oban.Worker, queue: :loop_timers

          @impl Oban.Worker
          def perform(%Oban.Job{id: id, args: %{"loop_ref" => ref, "tag_key" => tag_key}}) do
            case Clementine.Loop.Ecto.fire_timer(MyApp.LoopHost, ref, tag_key, id) do
              {:ok, _outcome} -> :ok
              {:error, :not_found} -> {:cancel, "loop row deleted"}
              {:error, :rollout_run} -> {:cancel, "not a loop"}
              {:error, reason} -> {:error, reason}
            end
          end
        end

    `Oban.insert/2` inside the unit commits with it (jobs are rows);
    `Oban.cancel_job/1` is exactly the best-effort cancel the contract
    asks for. `"schedule_id"` is the meta's one reserved key: the job id
    the worker will fire with, which makes the envelope entry the
    schedule's retained identity — `fire_timer/5` compares it under the
    run-row lock, so a fire redelivered after its row was consumed, or
    out-raced by a cancel + re-arm of the same tag, dead-letters at the
    door instead of masquerading as the fresh schedule's elapse. The
    races resolve as LOOP_RFC §Timers states them: a stale fire is
    consumed as a dead letter (`:stale_elapsed`) — never `handle/2`'s,
    never dropped; a fire against a terminal loop is answered
    `{:ok, :dead_lettered}` (`dead_reason: :terminal`) — distinguishable
    noise the worker acks.

    ## The child worker

    `build_child_run/4` is the child worker's door: from the job's
    durable identifiers (the child run ref and the JSON-safe `child_args`
    the step committed) to a ready-to-execute `Clementine.Run`, invoking
    the host's `build_child/4` with the child's facts and the decoded
    tag. Construction happens here, at spawn execution time — history by
    cursor, never transcripts in envelopes (LOOP_RFC §Children) — and the
    worker maps `Clementine.Runner.execute/2` exactly like the shipped
    run worker pattern. Completion delivery is not the worker's job: the
    child's terminal projection appends it (below).

    ## Child-terminal projection glue

    `append_completion/4` runs inside the child's terminal transaction —
    call it from the *lifecycle* module's `project/3` — appending
    `{:completed, tag, result}` to the parent's inbox with the
    replay-stable dedup key `"completed:" <> tag_key <> ":" <> child_ref`:
    exactly-once at source, because terminals are dead ends (matrix row
    L12). Reaper-interrupted children take the identical path — the
    interrupt is a terminal transition with a projection, `Result` and
    usage attached. `wake_parent/3` is the post-commit half — call it
    from `after_transition/3` — a wake and nothing else: best-effort by
    design, backstopped by the reaper's `:wake_pending` verdict,
    acceptable because delivery was durable before it.

    As completions fold, the step core aggregates the children's usage
    into the loop's envelope and terminal `Result` — so billing queries
    over the run table must exclude loop-kind rows or count every token
    twice (`Clementine.Loop.Ecto.Migration`'s Billing section shows the
    grain).

    Mutual cancellation is the one place lock ordering can cross (a parent
    step cancelling a child while that child's terminal appends its
    completion); Postgres resolves the deadlock by aborting one side, and
    both sides are safe to retry by construction — the step by
    replayability, the terminal by its bounded retry posture.

    Child cancels execute as cargo inside `apply_step/2`'s unit, so their
    post-commit emissions (`after_transition/3`, the cancel push, protocol
    telemetry) defer to the unit itself: fired after it commits, dropped
    if it rolls back — no observer, metric, or push hears of a transition
    that never happened. The wake such a hook would have delivered is not
    needed for correctness; the park re-check sees the in-unit completion
    rows and downgrades.

    The loop's own committed transition then reaches the host's
    `after_transition/3` — after the flushed child emissions, so
    children's terminals precede the loop's at every level — as a
    `Transition` in the shipped vocabulary: a park notifies as `:suspend`,
    a continue (or downgraded park) as `:requeue`, a finish as `:finish`
    with the `Result` attached. Wakes stay notification-silent by design
    (amendment A5 demotes that path to wake-only); observers tolerate the
    gap because facts order themselves. Step-level telemetry rides the
    step runner, not this adapter.
    """

    import Ecto.Query

    require Logger

    alias Clementine.Lifecycle.Ecto, as: LifecycleEcto
    alias Clementine.Lifecycle.Ecto.Codec, as: LifecycleCodec
    alias Clementine.Lifecycle.{Facts, Protocol, Transition}
    alias Clementine.Loop
    alias Clementine.Loop.Ecto.Codec
    alias Clementine.Loop.{Envelope, Input, StepCommit, StoredInput}
    alias Clementine.{Rollout, Run}

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
    relative form against the storage clock (`fire_at/2`). The fired
    job's door is `fire_timer/5`; the moduledoc's Timers section shows
    the full Oban wiring.

    One meta key is reserved: `"schedule_id"` — the id the worker will
    pass to `fire_timer/5`. Include it and the envelope entry becomes
    the schedule's retained identity, giving fires schedule-granular
    dedup that survives the fired row's consumption; omit it and the
    door degrades to tag-level liveness (the drain's own grain).
    """
    @callback schedule_timer(
                loop_row :: Ecto.Schema.t(),
                timer_spec :: StepCommit.timer_spec(),
                ctx :: term()
              ) ::
                {:ok, meta :: map()}

    @doc """
    Best-effort cancellation of a scheduled timer job — a fire that races
    the cancel is legal: it is consumed as a `:stale_elapsed` dead letter
    (at `fire_timer/5`'s door once the cancel committed, or at the next
    drain when the append got there first), never `handle/2`'s. Invoked
    inside `apply_step/2`'s atomic unit. Defaults to `:ok`.
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
        def pending(loop_ref, limit, scope, ctx) do
          Clementine.Loop.Ecto.pending(__MODULE__, loop_ref, limit, scope, ctx)
        end

        @impl Clementine.Loop.Host
        def dead_letters(loop_ref, limit, ctx) do
          Clementine.Loop.Ecto.dead_letters(__MODULE__, loop_ref, limit, ctx)
        end

        @impl Clementine.Loop.Host
        def bump_attempts(refs, ctx) do
          Clementine.Loop.Ecto.bump_attempts(__MODULE__, refs, ctx)
        end

        @impl Clementine.Loop.Host
        def create(spec, ctx) do
          Clementine.Loop.Ecto.create(__MODULE__, spec, ctx)
        end

        @impl Clementine.Loop.Host
        def load(loop_ref, ctx) do
          Clementine.Loop.Ecto.load(__MODULE__, loop_ref, ctx)
        end

        @impl Clementine.Loop.Host
        def cancel(loop_ref, reason, ctx) do
          Clementine.Loop.Ecto.cancel(__MODULE__, loop_ref, reason, ctx)
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
                  "(Timers On The Scheduler Seam in the Clementine.Loop.Ecto docs shows " <>
                  "the Oban wiring)"
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

      # Child cancels are cargo: their lifecycle transitions commit with
      # this unit, so their post-commit emissions (after_transition, the
      # cancel push, protocol telemetry) must too — fired only if the unit
      # commits, dropped if it rolls back. The adapter's own inbox
      # telemetry (:input, :dead_letter) rides the same frame.
      token = Clementine.Emissions.begin_deferral()

      try do
        config.repo.transaction(fn ->
          case do_apply_step(module, config, commit, ctx) do
            {:ok, facts} -> facts
            {:error, reason} -> config.repo.rollback(reason)
          end
        end)
        |> tap(fn
          {:ok, facts} ->
            Clementine.Emissions.flush(token)
            notify_step(config, commit, facts, ctx)

          {:error, _reason} ->
            :ok
        end)
      after
        Clementine.Emissions.drop(token)
      end
    end

    # The loop's own committed transition reaches the host's
    # after_transition/3 exactly like every lifecycle transition — the
    # universal observation point where notifications fan out and terminal
    # notifications close RunView folds. Fired after the flushed child
    # emissions, so children's terminals precede the loop's own facts at
    # every level. The op names the state movement in the shipped
    # vocabulary — park is a suspend, continue (and a downgraded park) is
    # a requeue, finish is a finish — read from the committed facts, not
    # the commit's intent.
    defp notify_step(config, %StepCommit{} = commit, %Facts{} = facts, ctx) do
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

      LifecycleEcto.notify_transition(config.lifecycle, facts, transition, ctx)
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
           :ok <- settle_transition(module, config, row, commit, ctx),
           :ok <- project_finish(config, commit, ctx),
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

        {count, _} =
          config.repo.update_all(
            from(i in pending_by_refs(config, loop_ref, refs),
              update: [set: [dead_at: fragment("now()"), dead_reason: ^encoded]]
            ),
            []
          )

        emit_dead_letter(loop_ref, reason, count)
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
                if loop_row?(config, target) do
                  deliver_locked(module, config, target, kind, payload, send.dedup_key,
                    wake?: true,
                    ctx: ctx
                  )

                  {:cont, :ok}
                else
                  {:halt, {:error, {:send_target_not_a_loop, send.target}}}
                end
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
    defp settle_transition(module, _config, _row, %StepCommit{op: :continue} = commit, ctx) do
      :ok = module.enqueue_step(commit.loop_ref, ctx)
    end

    defp settle_transition(module, config, row, %StepCommit{op: :park} = commit, ctx) do
      scope = commit.park_recheck || :any

      if pending_exists?(config, commit.loop_ref, scope) or cancel_pending?(config, row, scope) do
        case downgrade_to_continue(config, commit.loop_ref) do
          1 -> :ok = module.enqueue_step(commit.loop_ref, ctx)
          0 -> :ok
        end
      else
        :ok
      end
    end

    defp settle_transition(_module, _config, _row, %StepCommit{op: :finish}, _ctx), do: :ok

    # The `:any` re-check covers the cancel flag: a flag that landed
    # mid-step saw `running` and could not wake, so parking over it would
    # strand the cancellation — flag-first the CAS row carries it here and
    # the park downgrades; park-first the flag write's own CAS fails stale
    # and `cancel/4` re-routes to the wake. Cascade parks (`:completions`)
    # are exempt: mid-cascade the flag is expected set — the cascade is
    # its handler — and a flag downgrade would spin the loop hot until its
    # children finished.
    defp cancel_pending?(config, row, :any) do
      Map.fetch!(row, config.fields[:cancel]) != nil
    end

    defp cancel_pending?(_config, _row, :completions), do: false

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

    # The kind predicate is the belt under wake/3 and wake_parent/3: no
    # wake path may ever clear a parked rollout's suspension.
    defp downgrade_to_continue(config, loop_ref) do
      {count, _} =
        config.repo.update_all(
          from(r in config.schema,
            where: field(r, ^config.fields[:ref]) == ^loop_ref,
            where: field(r, ^config.fields[:status]) == "waiting",
            where: field(r, ^config.fields[:kind]) == "loop",
            update: [set: ^wake_set(config)]
          ),
          []
        )

      count
    end

    defp loop_row?(config, row) do
      Map.fetch!(row, config.fields[:kind]) == "loop"
    end

    # The loop's own terminal fires the host projection exactly like every
    # rollout terminal — inside the unit; a raise aborts the whole commit.
    # Re-fetched, not the CAS row: the CAS deliberately omits the envelope
    # (written post-cargo, refs filled), and the projection contract is
    # the freshly updated row — a host reading row.envelope must see the
    # terminal value, not the pre-step one.
    defp project_finish(config, %StepCommit{op: :finish, result: result} = commit, ctx) do
      row = config.repo.get!(config.schema, commit.loop_ref)
      config.lifecycle.project(result, row, ctx)
      :ok
    end

    defp project_finish(_config, _commit, _ctx), do: :ok

    defp terminal_sweep(_config, %StepCommit{terminal_sweep: false}), do: :ok

    defp terminal_sweep(config, %StepCommit{loop_ref: loop_ref}) do
      {count, _} =
        config.repo.update_all(
          from(i in config.inbox,
            where: i.loop_ref == type(^loop_ref, ^ref_type(config)),
            where: is_nil(i.dead_at),
            update: [set: [dead_at: fragment("now()"), dead_reason: "terminal_sweep"]]
          ),
          []
        )

      emit_dead_letter(loop_ref, :terminal_sweep, count)
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

      # The bracket holds the :input/:dead_letter emissions until this
      # unit commits — an append rolled back never happened to observers.
      token = Clementine.Emissions.begin_deferral()

      try do
        config.repo.transaction(fn ->
          case lock_run(config, loop_ref) do
            nil ->
              config.repo.rollback(:not_found)

            row ->
              # A2's mirror: the inbox verbs refuse rollout-kind rows the way
              # request_cancel refuses loop-kind ones — a miswired ref must
              # not grow a mailbox or have its suspension cleared by a wake.
              unless loop_row?(config, row), do: config.repo.rollback(:rollout_run)

              {kind, payload} = Codec.encode_input(input, vocabulary: vocabulary_of(row, config))
              deliver_locked(module, config, row, kind, payload, dedup_key, wake?: true, ctx: ctx)
          end
        end)
        |> tap(fn
          {:ok, _outcome} -> Clementine.Emissions.flush(token)
          {:error, _reason} -> :ok
        end)
      after
        Clementine.Emissions.drop(token)
      end
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
    # Every inbox row's birth emits exactly one deferred event: :input for
    # a pending row (or a dedup hit), :dead_letter for a row born dead.
    defp insert_input(config, loop_ref, kind, payload, dedup_key, opts \\ []) do
      row = %{loop_ref: loop_ref, kind: kind, payload: payload, dedup_key: dedup_key}

      row =
        case opts[:dead] do
          nil -> row
          reason -> Map.merge(row, %{dead_at: storage_now(config.repo), dead_reason: reason})
        end

      {count, _} = config.repo.insert_all(config.inbox, [row], on_conflict: :nothing)

      case {count, opts[:dead]} do
        {1, nil} -> emit_input(loop_ref, kind, :appended)
        {1, reason} -> emit_dead_letter(loop_ref, Codec.decode_dead_reason(reason), 1)
        {0, _} -> emit_input(loop_ref, kind, :duplicate)
      end

      count == 1
    end

    defp emit_input(loop_ref, kind, outcome) when is_binary(kind) do
      decoded = Enum.find(Input.kinds(), :message, &(Atom.to_string(&1) == kind))

      Clementine.Emissions.emit(fn ->
        :telemetry.execute(
          [:clementine, :loop, :input],
          %{},
          %{loop_ref: loop_ref, kind: decoded, outcome: outcome}
        )
      end)
    end

    defp emit_dead_letter(_loop_ref, _reason, 0), do: :ok

    defp emit_dead_letter(loop_ref, reason, count) when is_atom(reason) do
      Clementine.Emissions.emit(fn ->
        :telemetry.execute(
          [:clementine, :loop, :dead_letter],
          %{count: count},
          %{loop_ref: loop_ref, reason: reason}
        )
      end)
    end

    ## pending / bump_attempts

    @doc false
    def pending(module, loop_ref, limit, scope, _ctx)
        when is_integer(limit) and limit > 0 and scope in [:any, :completions] do
      config = module.__clementine_loop_config__()
      vocab = loop_vocabulary(config, loop_ref)

      query =
        from(i in config.inbox,
          where: i.loop_ref == type(^loop_ref, ^ref_type(config)),
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

      config.repo.all(query)
      |> Enum.map(fn row ->
        stored = %StoredInput{
          ref: row.id,
          input: placeholder_input(row.kind),
          attempts: row.attempts,
          dedup_key: row.dedup_key,
          inserted_at: row.inserted_at
        }

        case Codec.decode_input(row.kind, row.payload, vocabulary: vocab) do
          {:ok, input} -> %{stored | input: input}
          {:error, error} -> %{stored | decode_error: error}
        end
      end)
    end

    @doc false
    def dead_letters(module, loop_ref, limit, _ctx) when is_integer(limit) and limit > 0 do
      config = module.__clementine_loop_config__()
      vocab = loop_vocabulary(config, loop_ref)

      rows =
        config.repo.all(
          from(i in config.inbox,
            where: i.loop_ref == type(^loop_ref, ^ref_type(config)),
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
        )

      Enum.map(rows, fn row ->
        stored = %StoredInput{
          ref: row.id,
          input: placeholder_input(row.kind),
          attempts: row.attempts,
          dedup_key: row.dedup_key,
          inserted_at: row.inserted_at,
          dead_at: row.dead_at,
          dead_reason: Codec.decode_dead_reason(row.dead_reason)
        }

        case Codec.decode_input(row.kind, row.payload, vocabulary: vocab) do
          {:ok, input} -> %{stored | input: input}
          {:error, error} -> %{stored | decode_error: error}
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

    ## load — the step runner's read

    @doc false
    def load(module, loop_ref, _ctx) do
      config = module.__clementine_loop_config__()

      case config.repo.get(config.schema, loop_ref) do
        nil ->
          {:error, :not_found}

        row ->
          if loop_row?(config, row) do
            {:ok,
             %{
               facts: LifecycleCodec.to_facts(row, config.fields),
               module: Map.get(row, config.fields[:loop_module]),
               args: Map.get(row, config.fields[:loop_args]) || %{},
               policy: Map.get(row, config.fields[:loop_policy]) || %{},
               envelope: Map.get(row, config.fields[:envelope])
             }}
          else
            {:error, :rollout_run}
          end
      end
    end

    ## cancel — the loop-owned flag + wake (LOOP_RFC §Cancellation And Halt)

    # One transaction on the same lock as append/4: flag, wake, and
    # step-job enqueue commit together, serialized against a concurrent
    # step's park. Against a `running` row only the flag lands — the
    # park's `:any` re-check (or the next claim) is the wake's other
    # half. The flag write is idempotent and first-cause-wins; a
    # re-cancel of a parked loop still wakes it. No telemetry and no
    # notification: flag writes are the protocol's deliberate silent
    # pair, and wakes are notification-silent by design.
    @doc false
    def cancel(module, loop_ref, reason, ctx) do
      config = module.__clementine_loop_config__()

      config.repo.transaction(fn ->
        case lock_run(config, loop_ref) do
          nil ->
            config.repo.rollback(:not_found)

          row ->
            unless loop_row?(config, row), do: config.repo.rollback(:rollout_run)

            status = row |> Map.fetch!(config.fields[:status]) |> LifecycleCodec.decode_status()

            if Facts.terminal?(status), do: config.repo.rollback(:already_terminal)

            if Map.fetch!(row, config.fields[:cancel]) == nil do
              flag =
                LifecycleCodec.encode_cancel(%{
                  reason: reason,
                  requested_at: storage_now(config.repo)
                })

              {1, _} =
                config.repo.update_all(
                  from(r in config.schema,
                    where: field(r, ^config.fields[:ref]) == ^loop_ref
                  ),
                  set: [{config.fields[:cancel], flag}]
                )
            end

            if status == :waiting do
              1 = downgrade_to_continue(config, loop_ref)
              :ok = module.enqueue_step(loop_ref, ctx)
            end

            :flagged
        end
      end)
      |> case do
        {:ok, :flagged} -> {:ok, :flagged}
        {:error, reason} -> {:error, reason}
      end
    end

    ## The child worker

    @doc """
    The child worker's door (LOOP_RFC §Children): reads the child run row,
    decodes its tag from the stored `tag_key` under the parent loop's
    declared vocabulary, invokes the host's `build_child/4` with the
    child's `Clementine.Lifecycle.Facts`, and wraps the rollout in a
    `Clementine.Run` ready for `Clementine.Runner.execute/2`. The run's
    `metadata` carries `:loop_ref` and `:tag` for the worker's own
    logging and telemetry.

    Rollout construction happens here, at spawn execution time, from the
    durable JSON-safe args alone — the args say "messages through N", the
    host's `build_child/4` loads them: one source of truth, no envelope
    transcripts, no drift.

        defmodule MyApp.ChildRunWorker do
          use Oban.Worker, queue: :agents, max_attempts: 1

          @impl Oban.Worker
          def perform(%Oban.Job{args: %{"run_id" => run_id, "args" => child_args}}) do
            with {:ok, run} <-
                   Clementine.Loop.Ecto.build_child_run(MyApp.LoopHost, run_id, child_args) do
              case Clementine.Runner.execute(run,
                     lifecycle: MyApp.ClementineLifecycle,
                     executor_id: "oban:child:\#{run_id}"
                   ) do
                {:finished, %{status: :queued} = facts} -> MyApp.Runs.re_enqueue!(facts)
                {:finished, _facts} -> :ok
                {:suspended, _token} -> :ok
                {:discard, reason} -> {:cancel, inspect(reason)}
                {:error, reason} -> {:cancel, inspect(reason)}
              end
            end
          end
        end

    The worker never reports back to the parent — the child's terminal
    projection appends the completion (`append_completion/4`), whatever
    terminalized it. A cascade-cancelled child may reach its terminal
    before its job fires; `Clementine.Runner.execute/2`'s claim discards
    it (`{:not_claimable, status}`) — ack, nothing to run.

    `{:error, :not_found}` for a vanished row; `{:error, :not_loop_child}`
    for a row that is not a loop's child (loop-kind, or no `loop_ref`) —
    the kind-guard doctrine of `append/4` and `load/2`, worker-side.
    Errors from the host's own `build_child/4` pass through. A stored tag
    the parent's current vocabulary cannot decode raises, exactly like the
    drain's poison posture: the job queue's retry-then-discard makes the
    deploy drift observable rather than silently misread.
    """
    @spec build_child_run(module(), term(), map(), term()) ::
            {:ok, Run.t()} | {:error, :not_found | :not_loop_child | term()}
    def build_child_run(host, child_ref, child_args, ctx \\ nil) when is_map(child_args) do
      config = host.__clementine_loop_config__()

      case config.repo.get(config.schema, child_ref) do
        nil ->
          {:error, :not_found}

        row ->
          loop_ref = Map.get(row, config.fields[:loop_ref])

          if loop_row?(config, row) or loop_ref == nil do
            {:error, :not_loop_child}
          else
            tag_key = Map.fetch!(row, config.fields[:tag_key])
            tag = Codec.decode_tag(tag_key, vocabulary: loop_vocabulary(config, loop_ref))
            facts = LifecycleCodec.to_facts(row, config.fields)

            case host.build_child(facts, tag, child_args, ctx) do
              {:ok, %Rollout{} = rollout} ->
                {:ok,
                 Run.new(
                   ref: child_ref,
                   rollout: rollout,
                   metadata: %{loop_ref: loop_ref, tag: tag}
                 )}

              {:error, reason} ->
                {:error, reason}

              other ->
                raise ArgumentError,
                      "build_child/4 must return {:ok, %Clementine.Rollout{}} | " <>
                        "{:error, term}, got: #{inspect(other)}"
            end
          end
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
            if loop_row?(config, row) do
              deliver_locked(host, config, row, "completed", payload, dedup_key,
                wake?: false,
                ctx: nil
              )
            else
              Logger.warning(
                "child #{inspect(child_ref)} (#{tag_key}) names a non-loop parent " <>
                  "#{inspect(loop_ref)}; dropping completion"
              )
            end
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

    ## The timer fire door

    @doc """
    The timer worker's door (LOOP_RFC §Timers): appends the loop's
    `{:elapsed, tag}` input under the machinery dedup key
    `"elapsed:" <> tag_key <> ":" <> schedule_id`, waking a parked loop
    in the same unit — `append/4`'s exact semantics from the schedule's
    durable halves (the job's stored `tag_key`, its own id as
    `schedule_id`).

    Works in `tag_key` space, never the tag term: no vocabulary is
    consulted, so the fire survives any deploy — a renamed loop module
    parks `:incompatible_spec` with its elapses queued, never lost.

    Exactly-once per schedule rides two belts that meet under the run-row
    lock (the same lock that serializes `apply_step/2`): while the fired
    row lives, the inbox dedup key answers a scheduler's retry with
    `:duplicate`; once a drain consumes the row (freeing its key), the
    envelope's timer meta is the retained schedule identity — an absent
    entry, or a reserved `"schedule_id"` meta key that does not match,
    is proof the schedule was spent, cancelled, or superseded by a
    re-arm, and the fire dead-letters at the door (`:stale_elapsed`)
    without ever waking the loop. The lock leaves no seam between the
    belts: a redelivered or out-raced fire is never delivered to
    `handle/2` as a live elapse — not even attributed to a re-armed
    tag's fresh schedule. Only *provable* staleness diverts: a meta
    without the reserved key degrades to tag-level liveness, and an
    undecodable envelope (a deploy mid-park) stays live for the drain to
    re-judge — inputs are innocent of deploys.

    The scheduler cannot know what raced it, and does not need to:

    - `{:ok, :appended}` — durable and pending; the next drain consumes
      it, as the live elapse or (when a cancel or retire lands between
      this append and that drain) as a `:stale_elapsed` dead letter —
      never `handle/2`'s, never silently dropped (matrix row L6).
    - `{:ok, :duplicate}` — this schedule's fire is already recorded,
      live or dead (the worker's own retry); nothing changed.
    - `{:ok, :dead_lettered}` — retained as evidence, never to be
      consumed: the loop is terminal (`dead_reason: :terminal`) or the
      schedule is provably stale (`dead_reason: :stale_elapsed`) — the
      row's reason keeps the two distinguishable. Ack it.
    - `{:error, :not_found}` / `{:error, :rollout_run}` — a vanished row
      or a miswired ref; nothing written.
    """
    @spec fire_timer(module(), term(), String.t(), term(), term()) ::
            {:ok, :appended}
            | {:ok, :duplicate}
            | {:ok, :dead_lettered}
            | {:error, :not_found}
            | {:error, :rollout_run}
            | {:error, term()}
    def fire_timer(host, loop_ref, tag_key, schedule_id, ctx \\ nil) when is_binary(tag_key) do
      config = host.__clementine_loop_config__()
      payload = Codec.elapsed_payload(tag_key)
      dedup_key = Codec.elapsed_dedup_key(tag_key, schedule_id)

      token = Clementine.Emissions.begin_deferral()

      try do
        config.repo.transaction(fn ->
          case lock_run(config, loop_ref) do
            nil ->
              config.repo.rollback(:not_found)

            row ->
              unless loop_row?(config, row), do: config.repo.rollback(:rollout_run)

              status = row |> Map.fetch!(config.fields[:status]) |> LifecycleCodec.decode_status()

              cond do
                # Terminal wins the reason: the RFC's "timers of terminal
                # loops" clause, whatever else the schedule raced.
                Facts.terminal?(status) ->
                  deliver_locked(host, config, row, "elapsed", payload, dedup_key,
                    wake?: true,
                    ctx: ctx
                  )

                stale_fire?(config, row, tag_key, schedule_id) ->
                  ref = Map.fetch!(row, config.fields[:ref])

                  if insert_input(config, ref, "elapsed", payload, dedup_key,
                       dead: "stale_elapsed"
                     ) do
                    :dead_lettered
                  else
                    :duplicate
                  end

                true ->
                  deliver_locked(host, config, row, "elapsed", payload, dedup_key,
                    wake?: true,
                    ctx: ctx
                  )
              end
          end
        end)
        |> tap(fn
          {:ok, _outcome} -> Clementine.Emissions.flush(token)
          {:error, _reason} -> :ok
        end)
      after
        Clementine.Emissions.drop(token)
      end
    end

    # The door's staleness judgment, made under the row lock that
    # serializes it against apply_step — so "the envelope" is never a
    # half-superseded read: a consuming commit either landed (its meta
    # is visible here) or is blocked on this lock (and then the original
    # fired row still holds the dedup key, which answers instead). A nil
    # envelope column is provably schedule-free — schedules are cargo,
    # so nothing can be pending before the first commit (L6's
    # never-committed clause).
    defp stale_fire?(config, row, tag_key, schedule_id) do
      case Map.fetch!(row, config.fields[:envelope]) do
        nil ->
          true

        data ->
          case Envelope.decode(data) do
            {:ok, %Envelope{timers: timers}} ->
              case Map.get(timers, tag_key) do
                nil -> true
                %{"schedule_id" => id} -> Codec.ref_string(id) != Codec.ref_string(schedule_id)
                _meta -> false
              end

            {:error, _} ->
              false
          end
      end
    end

    @doc """
    Resolves a timer spec's fire position for the scheduler: `{:at, at}`
    passes through; the symbolic `{:now_plus, ms}` resolves against the
    storage clock — `Clementine.Loop.Action`'s contract, never this
    node's — which inside `apply_step/2`'s unit is the transaction's own
    timestamp. Accepts the whole `t:Clementine.Loop.StepCommit.timer_spec/0`
    or its `fire` value.
    """
    @spec fire_at(module(), StepCommit.timer_spec() | Clementine.Loop.Action.fire()) ::
            DateTime.t()
    def fire_at(host, %{fire: fire}), do: fire_at(host, fire)
    def fire_at(_host, {:at, %DateTime{} = at}), do: at

    def fire_at(host, {:now_plus, ms}) when is_integer(ms) and ms >= 0 do
      config = host.__clementine_loop_config__()
      DateTime.add(storage_now(config.repo), ms, :millisecond)
    end

    ## The paging gauges (LOOP_RFC §Operations)

    @doc """
    Per-loop pending-inbox gauges from one aggregate read: depth and the
    oldest unconsumed input's age in milliseconds, both on the storage
    clock — the stuck detector's raw data. Loops whose pending window is
    empty do not appear; dead letters never count.
    """
    @spec inbox_depths(module()) :: [
            %{loop_ref: term(), depth: non_neg_integer(), oldest_age_ms: non_neg_integer()}
          ]
    def inbox_depths(host) do
      config = host.__clementine_loop_config__()

      config.repo.all(
        from(i in config.inbox,
          where: is_nil(i.dead_at),
          group_by: i.loop_ref,
          select: %{
            loop_ref: i.loop_ref,
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

    @doc """
    Emits one `[:clementine, :loop, :inbox]` gauge event per loop with
    pending inputs — `inbox_depths/1` as the measurement half of a
    `:telemetry_poller` entry, the wiring LOOP_RFC §Operations asks the
    walkthrough for:

        {:telemetry_poller,
         measurements: [{Clementine.Loop.Ecto, :emit_inbox_depths, [MyApp.LoopHost]}],
         period: :timer.seconds(30)}

    Shapes in `Clementine.Telemetry`.
    """
    @spec emit_inbox_depths(module()) :: :ok
    def emit_inbox_depths(host) do
      Enum.each(inbox_depths(host), fn row ->
        :telemetry.execute(
          [:clementine, :loop, :inbox],
          %{depth: row.depth, oldest_age_ms: row.oldest_age_ms},
          %{loop_ref: row.loop_ref}
        )
      end)
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
