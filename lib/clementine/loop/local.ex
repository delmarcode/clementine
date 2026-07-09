defmodule Clementine.Loop.Local do
  @moduledoc """
  The script path (LOOP_RFC §Worked Examples): `Clementine.Loop.run_local/3`
  animates one loop against an in-memory host, deterministically, in the
  caller's process — the loop analog of `Clementine.run/3`.

  Production shape is simulated, not approximated:

  - **The inbox is the real contract.** An in-memory FIFO with identical
    consumption semantics — append/wake/enqueue as one unit, consumption in
    the step commit, dedup keys, dead letters — and every input round-trips
    the production value codec (`Clementine.Loop.Ecto.Codec`), so a payload
    outside the loop's declared vocabulary fails here exactly as it would
    against real storage.
  - **The hop is modeled.** Children are real rollout-runs executed by
    `Clementine.Runner.execute/2`, and their completions are *enqueued as
    inputs* by the terminal projection glue — never handed to `handle/2`
    inline — so script and production ordering agree (the §Alternatives
    verdict on inline execution).
  - **Timers ride a virtual clock.** The store's storage clock starts at
    wall now and only ever jumps forward — to the next schedule's deadline,
    and only when the loop is otherwise idle (no step to run, no child to
    run). A five-minute retry timer costs nothing and fires in order.

  Everything above the store is the shipped machinery unmodified:
  `Clementine.Loop.Protocol.create/3`, `Clementine.Loop.Runner.step/2`, the
  pure step core, and the rollout runner. Determinism follows from
  single-threaded drive order (one FIFO job ledger: steps and children in
  commit order, timers only at idle) plus the loop contract's own purity;
  the one wall-clock anchor is the virtual clock's start, chosen because
  the rollout engine checks child deadlines against wall time.

  This is an eval harness, not a host: the loop lives exactly as long as
  the call, `{:send, ...}` can only target the loop itself, and there is no
  reaper because a single process cannot lose a lease. The module's
  `Clementine.Lifecycle` and `Clementine.Loop.Host` callbacks exist for the
  machinery it drives; `run/3` is the API.
  """

  @behaviour Clementine.Lifecycle
  @behaviour Clementine.Loop.Host

  alias Clementine.Lifecycle.{Facts, Transition}
  alias Clementine.Loop
  alias Clementine.Loop.Ecto.Codec, as: InboxCodec
  alias Clementine.Loop.{Envelope, Input, StepCommit, StoredInput}
  alias Clementine.{Result, Rollout, Run, Runner}

  @default_max_steps 1000

  @doc """
  Runs `module` from `init(args)` to its halt result. See
  `Clementine.Loop.run_local/3` for the full option and return contract.
  """
  @spec run(module(), map(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(module, args, opts \\ []) when is_atom(module) and is_map(args) do
    store = start_store(Keyword.get(opts, :build_child), vocabulary(module))

    spec = %{
      module: module,
      scope: "run_local",
      args: args,
      policy: Keyword.get(opts, :policy, %{})
    }

    try do
      case Loop.Protocol.create(__MODULE__, spec, ctx: store) do
        {:ok, %Facts{ref: loop_ref}} ->
          Enum.each(Keyword.get(opts, :messages, []), fn payload ->
            {:ok, :appended} = append(loop_ref, Input.message(payload), nil, store)
          end)

          drive(store, loop_ref, Keyword.get(opts, :max_steps, @default_max_steps), 0)

        {:error, reason} ->
          {:error, reason}
      end
    after
      Agent.stop(store)
    end
  end

  defp vocabulary(module) do
    case Loop.resolve(module) do
      {:ok, resolved} -> resolved.__loop__(:vocabulary)
      # Protocol.create refuses the module with the loop layer's clean
      # error; the store just needs to outlive that refusal.
      {:error, _} -> []
    end
  end

  ## The drive: one FIFO ledger, steps and children in commit order,
  ## timers only when nothing else is runnable.

  defp drive(store, loop_ref, max_steps, steps) do
    case pop_job(store) do
      {:step, ^loop_ref} when steps >= max_steps ->
        {:error, {:max_steps, max_steps}}

      {:step, ^loop_ref} ->
        outcome =
          Loop.Runner.step(loop_ref,
            host: __MODULE__,
            lifecycle: __MODULE__,
            executor_id: "run_local",
            ctx: store
          )

        case outcome do
          {:finished, %Facts{}} ->
            {:ok, result!(store, loop_ref)}

          {:parked, %Facts{}} ->
            drive(store, loop_ref, max_steps, steps + 1)

          {:continued, %Facts{}} ->
            drive(store, loop_ref, max_steps, steps + 1)

          {:discard, :already_terminal} ->
            {:ok, result!(store, loop_ref)}

          {:discard, _reason} ->
            drive(store, loop_ref, max_steps, steps + 1)

          # An in-step raise was requeued and re-enqueued by the runner —
          # the worker acks and the poison path owns the retry. A run left
          # :running is the reaper's territory (A3a); no reaper lives
          # here, so that one surfaces (a structurally failing commit,
          # e.g. a send to a target that does not exist locally).
          {:error, reason} ->
            case facts!(store, loop_ref) do
              %Facts{status: :queued} -> drive(store, loop_ref, max_steps, steps + 1)
              %Facts{} -> {:error, reason}
            end
        end

      {:child, child_ref, tag, child_args} ->
        execute_child(store, child_ref, tag, child_args)
        drive(store, loop_ref, max_steps, steps)

      :empty ->
        settle_idle(store, loop_ref, max_steps, steps)
    end
  end

  defp settle_idle(store, loop_ref, max_steps, steps) do
    %Facts{} = facts = facts!(store, loop_ref)

    cond do
      Facts.terminal?(facts) ->
        {:ok, result!(store, loop_ref)}

      # The A3b `:reenqueue` verdict, locally: a queued loop with no step
      # job is a lost enqueue, and a standing entity must not die of one.
      facts.status == :queued ->
        :ok = enqueue_step(loop_ref, store)
        drive(store, loop_ref, max_steps, steps)

      fire_due_timers(store, loop_ref) ->
        drive(store, loop_ref, max_steps, steps)

      # Parked with nothing in flight, no timers, and the script spent:
      # production would wait for the world; a script has no world left.
      true ->
        {:error, {:parked, facts}}
    end
  end

  ## Children — the modeled hop: a real run against this store, whose
  ## terminal projection (record_result) appends the completion input.

  defp execute_child(store, child_ref, tag, child_args) do
    case facts!(store, child_ref) do
      # Direct-terminalized by a cascade before its job came up; the
      # completion is already in the parent's inbox.
      %Facts{status: status} = child when status != :queued ->
        if Facts.terminal?(child), do: :ok, else: raise_child_invariant(child_ref, status)

      %Facts{} = child ->
        {:ok, %Rollout{} = rollout} = build_child(child, tag, child_args, store)
        run_child(store, Run.new(ref: child_ref, rollout: rollout))
    end
  end

  defp run_child(store, %Run{} = run) do
    outcome =
      Runner.execute(run,
        lifecycle: __MODULE__,
        ctx: store,
        executor_id: "run_local:child:#{inspect(run.ref)}",
        heartbeat: false
      )

    case outcome do
      # The ephemeral translation of a drain requeue: re-enqueue is
      # running again (`Clementine.run/3`'s contract, restated).
      {:finished, %Facts{status: :queued}} ->
        run_child(store, run)

      {:finished, %Facts{}} ->
        :ok

      {:suspended, _token} ->
        raise "run_local children cannot park: approval-gated tools are not " <>
                "supported on the script path (child #{inspect(run.ref)})"

      other ->
        raise "run_local child runner invariant violated: #{inspect(other)}"
    end
  end

  defp raise_child_invariant(child_ref, status) do
    raise "run_local child #{inspect(child_ref)} in impossible status #{inspect(status)}: " <>
            "a single-threaded drive leaves no child mid-flight"
  end

  ## The virtual clock jump (LOOP_RFC §Worked Examples, the script path):
  ## idle means no step and no child is runnable, so the earliest deadline
  ## is the next thing that can happen — jump to it and fire, through the
  ## fire door's exact semantics (elapsed append under the schedule-grain
  ## dedup key, wake in the same unit).

  defp fire_due_timers(store, loop_ref) do
    Agent.get_and_update(store, fn state ->
      # Integer sort key: DateTime structs do not order under term
      # comparison, and a virtual jump may cross any calendar boundary.
      schedules =
        state.schedules
        |> Enum.filter(fn {_id, s} -> s.loop_ref == loop_ref end)
        |> Enum.sort_by(fn {id, s} -> {DateTime.to_unix(s.fire_at, :microsecond), id} end)

      case schedules do
        [] ->
          {false, state}

        [{_id, %{fire_at: next_at}} | _] = all ->
          now = if DateTime.compare(next_at, state.now) == :gt, do: next_at, else: state.now
          state = %{state | now: now}

          due = Enum.take_while(all, fn {_id, s} -> DateTime.compare(s.fire_at, now) != :gt end)

          state =
            Enum.reduce(due, state, fn {id, %{tag_key: tag_key}}, state ->
              state = update_in(state.schedules, &Map.delete(&1, id))

              {state, _outcome} =
                insert_row(
                  state,
                  loop_ref,
                  "elapsed",
                  InboxCodec.elapsed_payload(tag_key),
                  InboxCodec.elapsed_dedup_key(tag_key, id)
                )

              wake(state, loop_ref)
            end)

          {true, state}
      end
    end)
  end

  ## Store

  defp start_store(build_child, vocabulary) do
    {:ok, store} =
      Agent.start_link(fn ->
        %{
          # The storage clock. Starts at wall now — the rollout engine
          # checks child deadlines against wall time, and a virtual epoch
          # would mint children born dead — and only ever jumps forward.
          now: DateTime.utc_now(),
          runs: %{},
          loop: %{},
          children_meta: %{},
          inbox: %{},
          jobs: [],
          schedules: %{},
          results: %{},
          build_child: build_child,
          vocabulary: vocabulary,
          next_ref: 1
        }
      end)

    store
  end

  defp facts!(store, ref), do: Agent.get(store, &Map.fetch!(&1.runs, ref))

  defp result!(store, ref), do: Agent.get(store, &Map.fetch!(&1.results, ref))

  defp pop_job(store) do
    Agent.get_and_update(store, fn
      %{jobs: []} = state -> {:empty, state}
      %{jobs: [job | rest]} = state -> {job, %{state | jobs: rest}}
    end)
  end

  ## Clementine.Lifecycle — exact (status, epoch) CAS on the store, plus
  ## the child-terminal completion glue inside the same update: delivery
  ## exactly-once at source, the modeled half of matrix row L12.

  @impl Clementine.Lifecycle
  def fetch(run_ref, store) do
    Agent.get(store, fn state ->
      case Map.fetch(state.runs, run_ref) do
        {:ok, facts} -> {:ok, facts}
        :error -> {:error, :not_found}
      end
    end)
  end

  @impl Clementine.Lifecycle
  def apply(%Transition{} = transition, store) do
    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.runs, transition.run_ref) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, %Facts{} = facts} ->
          if facts.status == transition.expect.status and
               facts.epoch == transition.expect.epoch do
            new_facts = apply_set(facts, transition.set, state.now)
            state = put_in(state.runs[transition.run_ref], new_facts)
            state = record_result(state, transition.run_ref, transition.result)
            {{:ok, new_facts}, state}
          else
            {{:error, :stale}, state}
          end
      end
    end)
  end

  # A terminal result of a loop child appends the parent's completion
  # input under the canonical dedup key and wakes a parked parent — the
  # in-memory analog of append_completion-inside-project plus wake_parent,
  # one update standing in for one transaction.
  defp record_result(state, _ref, nil), do: state

  defp record_result(state, ref, result) do
    state = put_in(state.results[ref], result)

    case Map.fetch(state.children_meta, ref) do
      :error ->
        state

      {:ok, %{loop_ref: loop_ref, tag_key: tag_key}} ->
        {state, outcome} =
          insert_row(
            state,
            loop_ref,
            "completed",
            InboxCodec.completion_payload(tag_key, result),
            InboxCodec.completion_dedup_key(tag_key, ref)
          )

        if outcome == :appended, do: wake(state, loop_ref), else: state
    end
  end

  ## Clementine.Loop.Host

  @impl Clementine.Loop.Host
  def create(spec, store) do
    Agent.get_and_update(store, fn state ->
      {ref, state} = mint_ref(state)
      facts = %Facts{ref: ref, kind: :loop, status: :queued, queued_at: state.now}

      state =
        state
        |> put_in([:runs, ref], facts)
        |> put_in([:loop, ref], %{
          module: spec.module,
          args: spec.args,
          policy: spec.policy,
          envelope: nil
        })
        |> push_job({:step, ref})

      {{:ok, facts}, state}
    end)
  end

  @impl Clementine.Loop.Host
  def load(loop_ref, store) do
    Agent.get(store, fn state ->
      with {:ok, %Facts{} = facts} <- Map.fetch(state.runs, loop_ref),
           :ok <- if(facts.kind == :loop, do: :ok, else: :rollout_run) do
        spec = Map.fetch!(state.loop, loop_ref)

        {:ok,
         %{
           facts: facts,
           module: spec.module,
           args: spec.args,
           policy: spec.policy,
           envelope: spec.envelope
         }}
      else
        :error -> {:error, :not_found}
        :rollout_run -> {:error, :rollout_run}
      end
    end)
  end

  @impl Clementine.Loop.Host
  def cancel(loop_ref, reason, store) do
    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.runs, loop_ref) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, %Facts{kind: kind}} when kind != :loop ->
          {{:error, :rollout_run}, state}

        {:ok, %Facts{} = facts} ->
          if Facts.terminal?(facts) do
            {{:error, :already_terminal}, state}
          else
            flag = facts.cancel || %{reason: reason, requested_at: state.now}
            state = put_in(state.runs[loop_ref].cancel, flag)
            state = if facts.status == :waiting, do: wake(state, loop_ref), else: state
            {{:ok, :flagged}, state}
          end
      end
    end)
  end

  @impl Clementine.Loop.Host
  def append(loop_ref, %Input{} = input, dedup_key, store) do
    # Encode outside the update so a vocabulary violation raises at the
    # caller — the production seam's posture, loud and immediate.
    vocab = Agent.get(store, & &1.vocabulary)
    {kind, payload} = InboxCodec.encode_input(input, vocabulary: vocab)

    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.runs, loop_ref) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, %Facts{kind: k}} when k != :loop ->
          {{:error, :rollout_run}, state}

        {:ok, %Facts{} = facts} ->
          if Facts.terminal?(facts) do
            case insert_row(state, loop_ref, kind, payload, dedup_key, dead: :terminal) do
              {state, :appended} -> {{:ok, :dead_lettered}, state}
              {state, :duplicate} -> {{:ok, :duplicate}, state}
            end
          else
            case insert_row(state, loop_ref, kind, payload, dedup_key) do
              {state, :duplicate} ->
                {{:ok, :duplicate}, state}

              {state, :appended} ->
                state = if facts.status == :waiting, do: wake(state, loop_ref), else: state
                {{:ok, :appended}, state}
            end
          end
      end
    end)
  end

  @impl Clementine.Loop.Host
  def pending(loop_ref, limit, scope, store) when scope in [:any, :completions] do
    Agent.get(store, fn state ->
      state.inbox
      |> Map.get(loop_ref, [])
      |> Enum.reject(& &1.dead_reason)
      |> Enum.filter(fn row -> scope == :any or row.kind == "completed" end)
      |> Enum.take(limit)
      |> Enum.map(&decode_row(&1, state.vocabulary))
    end)
  end

  # The seam's per-row decode contract: an undecodable payload is poison
  # for that input, surfaced as decode_error, never a failed fetch.
  defp decode_row(row, vocab) do
    case InboxCodec.decode_input(row.kind, row.payload, vocabulary: vocab) do
      {:ok, input} ->
        %StoredInput{ref: row.ref, input: input, attempts: row.attempts}

      {:error, error} ->
        %StoredInput{
          ref: row.ref,
          input: placeholder_input(row.kind),
          attempts: row.attempts,
          decode_error: error
        }
    end
  end

  defp placeholder_input(kind) do
    %Input{kind: Enum.find(Input.kinds(), :message, &(Atom.to_string(&1) == kind))}
  end

  @impl Clementine.Loop.Host
  def bump_attempts(refs, store) do
    Agent.update(store, fn state ->
      Enum.reduce(refs, state, fn ref, state ->
        update_inbox_row(state, ref, &Map.update!(&1, :attempts, fn n -> n + 1 end))
      end)
    end)
  end

  @impl Clementine.Loop.Host
  def build_child(%Facts{} = facts, tag, child_args, store) do
    case Agent.get(store, & &1.build_child) do
      nil ->
        raise ArgumentError,
              "the loop emitted {:run, #{inspect(tag)}, ...} but run_local was not " <>
                "given :build_child — pass build_child: fn tag, child_args -> " <>
                "{:ok, %Clementine.Rollout{}} end"

      fun when is_function(fun, 2) ->
        case fun.(tag, child_args) do
          {:ok, %Rollout{} = rollout} ->
            {:ok, rollout}

          {:error, reason} ->
            raise ArgumentError,
                  "build_child failed for #{inspect(tag)} " <>
                    "(child #{inspect(facts.ref)}): #{inspect(reason)}"

          other ->
            raise ArgumentError,
                  "build_child must return {:ok, %Clementine.Rollout{}} | {:error, term}, " <>
                    "got: #{inspect(other)}"
        end
    end
  end

  @impl Clementine.Loop.Host
  def enqueue_step(loop_ref, store) do
    Agent.update(store, &push_job(&1, {:step, loop_ref}))
  end

  # The one atomic unit (atomicity sentence 1): the CAS fence first, then
  # every piece of cargo, the park re-check, the projection, and the
  # terminal sweep — all inside this single update.
  @impl Clementine.Loop.Host
  def apply_step(%StepCommit{} = commit, store) do
    Agent.get_and_update(store, &do_apply_step(&1, commit))
  end

  # Errors return `original` — all-or-nothing, whatever phase failed.
  defp do_apply_step(original, %StepCommit{} = commit) do
    facts = Map.get(original.runs, commit.loop_ref)

    with true <-
           facts != nil and facts.status == commit.expect.status and
             facts.epoch == commit.expect.epoch,
         {:ok, state} <- consume(original, commit),
         state = put_in(state.runs[commit.loop_ref], apply_set(facts, commit.set, state.now)),
         state = mark_dead(state, commit),
         state = insert_appends(state, commit),
         {state, child_fills} = spawn_children(state, commit),
         {state, timer_fills} = schedule_timers(state, commit),
         state = retire_timers(state, commit),
         state = cancel_children(state, commit, child_fills),
         {:ok, state} <- execute_sends(state, commit) do
      state =
        state
        |> write_envelope(commit, child_fills, timer_fills)
        |> settle(commit)
        |> record_result(commit.loop_ref, commit.result)
        |> sweep(commit)

      {{:ok, Map.fetch!(state.runs, commit.loop_ref)}, state}
    else
      false -> {{:error, :stale}, original}
      {:error, reason} -> {{:error, reason}, original}
    end
  end

  defp consume(state, %StepCommit{consumed: refs, loop_ref: loop_ref}) do
    rows = Map.get(state.inbox, loop_ref, [])
    {gone, kept} = Enum.split_with(rows, &(&1.ref in refs and is_nil(&1.dead_reason)))

    if length(gone) == length(refs) do
      {:ok, put_in(state.inbox[loop_ref], kept)}
    else
      {:error, {:consumption_mismatch, %{expected: length(refs), deleted: length(gone)}}}
    end
  end

  defp mark_dead(state, %StepCommit{marks: marks}) do
    Enum.reduce(marks, state, fn %{ref: ref, reason: reason}, state ->
      update_inbox_row(state, ref, &%{&1 | dead_at: state.now, dead_reason: reason})
    end)
  end

  defp insert_appends(state, %StepCommit{appends: appends, loop_ref: loop_ref}) do
    Enum.reduce(appends, state, fn %Input{} = input, state ->
      {kind, payload} = InboxCodec.encode_input(input, vocabulary: state.vocabulary)
      {state, :appended} = insert_row(state, loop_ref, kind, payload, nil)
      state
    end)
  end

  # Child rows and their jobs, in one unit with the commit — the job
  # carries the durable child_args, exactly the production worker's food.
  defp spawn_children(state, %StepCommit{children: specs, loop_ref: loop_ref}) do
    Enum.reduce(specs, {state, %{}}, fn spec, {state, fills} ->
      {ref, state} = mint_ref(state)
      child = %Facts{ref: ref, kind: :rollout, status: :queued, queued_at: state.now}

      state =
        state
        |> put_in([:runs, ref], child)
        |> put_in([:children_meta, ref], %{
          loop_ref: loop_ref,
          tag: spec.tag,
          tag_key: spec.tag_key
        })
        |> push_job({:child, ref, spec.tag, spec.child_args})

      {state, Map.put(fills, spec.tag_key, ref)}
    end)
  end

  # The schedule half of the timer seam: the schedule commits with the
  # envelope entry recording it, and the entry's reserved "schedule_id"
  # is the retained identity the fire door keys its dedup on.
  defp schedule_timers(state, %StepCommit{timers: specs, loop_ref: loop_ref}) do
    Enum.reduce(specs, {state, %{}}, fn spec, {state, fills} ->
      {id, state} = mint_ref(state)

      fire_at =
        case spec.fire do
          {:at, %DateTime{} = at} -> at
          {:now_plus, ms} -> DateTime.add(state.now, ms, :millisecond)
        end

      state =
        put_in(state.schedules[id], %{loop_ref: loop_ref, tag_key: spec.tag_key, fire_at: fire_at})

      {state, Map.put(fills, spec.tag_key, %{"schedule_id" => id})}
    end)
  end

  # Best-effort cancel is exact here: single-threaded, a schedule cannot
  # be mid-fire. The stale-elapsed race (cancel landing after a fire's
  # append) still exists and the drain owns it, as everywhere.
  defp retire_timers(state, %StepCommit{cancel_timers: tag_keys, loop_ref: loop_ref}) do
    update_in(state.schedules, fn schedules ->
      Map.reject(schedules, fn {_id, s} ->
        s.loop_ref == loop_ref and s.tag_key in tag_keys
      end)
    end)
  end

  # Cascade cargo: queued children direct-terminalize with
  # Result.Cancelled — record_result appends their completions to this
  # very loop inside this very unit, where the park re-check sees them.
  # Terminal children are tolerated; :running cannot exist between drive
  # iterations, but the production branch stays for honesty.
  defp cancel_children(state, %StepCommit{cancel_children: tag_keys} = commit, fills) do
    stored = StepCommit.envelope(commit)

    Enum.reduce(tag_keys, state, fn tag_key, state ->
      ref = Map.get(fills, tag_key) || (stored && Map.get(stored.children, tag_key))

      case Map.get(state.runs, ref) do
        nil ->
          state

        %Facts{status: status} = child when status in [:queued, :waiting] ->
          result =
            Result.cancelled({:loop_cascade, commit.loop_ref}, child.usage || %Clementine.Usage{})

          state
          |> put_in([:runs, ref], %{
            child
            | status: :cancelled,
              cancel: nil,
              suspension: nil,
              finished_at: state.now
          })
          |> record_result(ref, result)

        %Facts{status: :running} = child ->
          put_in(
            state.runs[ref].cancel,
            child.cancel || %{reason: {:loop_cascade, commit.loop_ref}, requested_at: state.now}
          )

        %Facts{} ->
          state
      end
    end)
  end

  # One loop per store: self-sends are the modeled case (the payload
  # re-encodes under the same vocabulary that validated it at drain);
  # any other target fails the commit, exactly as a vanished target row
  # fails the Ecto adapter's.
  defp execute_sends(state, %StepCommit{sends: sends, loop_ref: loop_ref}) do
    Enum.reduce_while(sends, {:ok, state}, fn send, {:ok, state} ->
      case Map.get(state.runs, send.target) do
        # Self-delivery, and self is mid-step: no wake can apply. The
        # payload re-encodes under the vocabulary that validated it at
        # drain time.
        %Facts{kind: :loop} when send.target == loop_ref ->
          {kind, payload} =
            InboxCodec.encode_input(Input.message(send.payload), vocabulary: state.vocabulary)

          {state, _outcome} = insert_row(state, loop_ref, kind, payload, send.dedup_key)
          {:cont, {:ok, state}}

        nil ->
          {:halt, {:error, {:send_target_not_found, send.target}}}

        %Facts{} ->
          {:halt, {:error, {:send_target_not_a_loop, send.target}}}
      end
    end)
  end

  defp write_envelope(state, %StepCommit{set: set} = commit, child_fills, timer_fills) do
    case set do
      %{envelope: %Envelope{} = envelope} ->
        filled = %{
          envelope
          | children: Map.merge(envelope.children, child_fills),
            timers: Map.merge(envelope.timers, timer_fills)
        }

        put_in(state.loop[commit.loop_ref].envelope, Envelope.encode(filled))

      _ ->
        state
    end
  end

  defp settle(state, %StepCommit{op: :continue, loop_ref: loop_ref}) do
    push_job(state, {:step, loop_ref})
  end

  # The park re-check (atomicity sentence 1): unconsumed inputs in scope —
  # or, for :any scope, a set cancel flag — downgrade the park to a
  # continue inside this same unit.
  defp settle(state, %StepCommit{op: :park, loop_ref: loop_ref} = commit) do
    scope = commit.park_recheck || :any
    facts = Map.fetch!(state.runs, loop_ref)

    pending? =
      state.inbox
      |> Map.get(loop_ref, [])
      |> Enum.any?(fn row ->
        is_nil(row.dead_reason) and (scope == :any or row.kind == "completed")
      end)

    cancel? = scope == :any and facts.cancel != nil

    if pending? or cancel?, do: wake(state, loop_ref), else: state
  end

  defp settle(state, %StepCommit{op: :finish}), do: state

  defp sweep(state, %StepCommit{terminal_sweep: false}), do: state

  defp sweep(state, %StepCommit{loop_ref: loop_ref}) do
    update_in(state.inbox[loop_ref], fn rows ->
      Enum.map(rows || [], fn
        %{dead_reason: nil} = row -> %{row | dead_at: state.now, dead_reason: :terminal_sweep}
        row -> row
      end)
    end)
  end

  ## Shared internals

  # The wake: CAS waiting -> queued (kind-guarded, field hygiene) plus the
  # step-job enqueue — no-op against any other status.
  defp wake(state, loop_ref) do
    case Map.get(state.runs, loop_ref) do
      %Facts{kind: :loop, status: :waiting} = facts ->
        state
        |> put_in([:runs, loop_ref], %{
          facts
          | status: :queued,
            suspension: nil,
            queued_at: state.now
        })
        |> push_job({:step, loop_ref})

      _ ->
        state
    end
  end

  defp insert_row(state, loop_ref, kind, payload, dedup_key, opts \\ []) do
    rows = Map.get(state.inbox, loop_ref, [])

    if dedup_key && Enum.any?(rows, &(&1.dedup_key == dedup_key)) do
      {state, :duplicate}
    else
      {ref, state} = mint_ref(state)

      row = %{
        ref: ref,
        kind: kind,
        payload: payload,
        dedup_key: dedup_key,
        attempts: 0,
        inserted_at: state.now,
        dead_at: if(opts[:dead], do: state.now),
        dead_reason: opts[:dead]
      }

      {put_in(state.inbox[loop_ref], rows ++ [row]), :appended}
    end
  end

  defp update_inbox_row(state, ref, fun) do
    update_in(state.inbox, fn inbox ->
      Map.new(inbox, fn {loop_ref, rows} ->
        {loop_ref, Enum.map(rows, &if(&1.ref == ref, do: fun.(&1), else: &1))}
      end)
    end)
  end

  defp push_job(state, job), do: %{state | jobs: state.jobs ++ [job]}

  defp mint_ref(state), do: {state.next_ref, %{state | next_ref: state.next_ref + 1}}

  # Absent keys untouched; present keys written (nil writes NULL);
  # symbolic stamps resolve against the virtual clock — the storage clock
  # here, which is what makes `{:now_plus, ms}` deadlines and `queued_at`
  # stamps deterministic relative to timer fires.
  defp apply_set(%Facts{} = facts, set, now) do
    set
    |> Map.drop([:envelope, :state_version])
    |> Enum.reduce(facts, fn {key, value}, acc ->
      Map.replace!(acc, key, resolve(value, now))
    end)
  end

  defp resolve(:now, now), do: now
  defp resolve({:now_plus, ms}, now), do: DateTime.add(now, ms, :millisecond)

  defp resolve(value, now) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {k, resolve(v, now)} end)
  end

  defp resolve(value, _now), do: value
end
