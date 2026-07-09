defmodule Clementine.Test.MemoryLoopHost do
  @moduledoc """
  An in-memory `Clementine.Lifecycle` + `Clementine.Loop.Host` pairing
  with real atomicity, for step-runner tests: every unit the contract
  says commits together executes as one `Agent.get_and_update`, so the
  park re-check, in-unit appends, cascade child cancels, and the
  terminal sweep are honestly transactional — and every guarded write is
  an exact `(status, epoch)` CAS, exactly like `MemoryLifecycle`.

  The store also plays the host glue the Ecto adapter documents: a
  terminal transition of a loop child (any writer — cascade cargo, a
  reaper interrupt, a direct cancel) appends `{:completed, tag, result}`
  to its parent's inbox under the canonical dedup key and wakes a parked
  parent, inside the same update — delivery exactly-once at source
  (matrix row L12). Jobs are ledger rows (`jobs/1`), never executed;
  tests drive steps by calling `Clementine.Loop.Runner.step/2`.

  Fault injection (`inject_fault/3`) makes `apply_step` raise or return
  errors N times, for the crash-before-commit and transient-retry
  branches. `inject_decode_error/3` marks a stored input undecodable,
  for the deploy-shaped poison path. `ctx` is the store pid.
  """

  @behaviour Clementine.Lifecycle
  @behaviour Clementine.Loop.Host

  alias Clementine.Lifecycle.{Facts, Transition}
  alias Clementine.Loop.{Envelope, Input, StepCommit, StoredInput}
  alias Clementine.Result

  ## Store

  def start_store do
    {:ok, store} =
      Agent.start_link(fn ->
        %{
          runs: %{},
          loop: %{},
          children_meta: %{},
          inbox: %{},
          scopes: %{},
          jobs: [],
          projections: [],
          faults: %{},
          # Globally unique across stores: async tests share the global
          # telemetry handler space, and a colliding loop_ref would let
          # one test's events satisfy another's assertions.
          next_ref: System.unique_integer([:positive]) * 1_000_000
        }
      end)

    store
  end

  def facts!(store, ref), do: Agent.get(store, &Map.fetch!(&1.runs, ref))

  @doc """
  Seeds a run row directly — facts overrides plus, for loop-kind rows,
  the persisted spec — bypassing `create/2`, for shapes creation cannot
  mint (a 1000-epoch veteran, a rollout-kind ref for the kind guards).
  """
  def seed(store, facts_overrides \\ [], spec_overrides \\ %{}) do
    now = DateTime.utc_now()

    Agent.get_and_update(store, fn state ->
      {ref, state} = mint_ref(state)

      facts =
        struct!(
          %Facts{ref: ref, kind: :loop, status: :queued, queued_at: now},
          facts_overrides
        )

      spec =
        Map.merge(
          %{module: "Clementine.Test.ScriptedLoop", args: %{}, policy: %{}, envelope: nil},
          spec_overrides
        )

      state = put_in(state.runs[ref], facts)
      state = if facts.kind == :loop, do: put_in(state.loop[ref], spec), else: state
      {ref, state}
    end)
  end

  @doc "Every inbox row for the loop, consumed rows excluded, in FIFO order."
  def inbox!(store, loop_ref) do
    Agent.get(store, &(&1.inbox |> Map.get(loop_ref, []) |> Enum.reverse()))
  end

  def jobs!(store), do: Agent.get(store, &Enum.reverse(&1.jobs))

  @doc "Terminal results host projections saw, in commit order."
  def projections(store), do: Agent.get(store, &Enum.reverse(&1.projections))

  @doc "Rewrites the persisted loop_module spec — the renamed-deploy simulation."
  def rewrite_module!(store, loop_ref, module) do
    Agent.update(store, fn state ->
      put_in(state.loop[loop_ref].module, module)
    end)
  end

  @doc "Marks a pending input undecodable by the running code; `nil` clears (the deploy landed)."
  def inject_decode_error(store, row_ref, error) do
    Agent.update(store, fn state ->
      update_inbox_row(state, row_ref, &Map.put(&1, :decode_error, error))
    end)
  end

  @doc "Makes the next `n` apply_step calls fail: `mode` is `:raise` or `:error`."
  def inject_fault(store, mode, n) when mode in [:raise, :error] do
    Agent.update(store, &put_in(&1.faults[:apply_step], {mode, n}))
  end

  ## Clementine.Lifecycle — CAS semantics as MemoryLifecycle, plus the
  ## child-terminal completion glue in the same update.

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
    now = DateTime.utc_now()

    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.runs, transition.run_ref) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, %Facts{} = facts} ->
          if facts.status == transition.expect.status and
               facts.epoch == transition.expect.epoch do
            new_facts = apply_set(facts, transition.set, now)
            state = put_in(state.runs[transition.run_ref], new_facts)
            state = record_result(state, transition.run_ref, transition.result, now)
            {{:ok, new_facts}, state}
          else
            {{:error, :stale}, state}
          end
      end
    end)
  end

  # Projection plus the loop-child glue: a terminal result of a child
  # appends the parent's completion input and wakes a parked parent —
  # the memory analog of append_completion-inside-project plus
  # wake_parent, one update standing in for one transaction.
  defp record_result(state, _ref, nil, _now), do: state

  defp record_result(state, ref, result, now) do
    state = update_in(state.projections, &[{ref, result} | &1])

    case Map.fetch(state.children_meta, ref) do
      :error ->
        state

      {:ok, %{loop_ref: loop_ref, tag: tag, tag_key: tag_key}} ->
        dedup_key = "completed:#{tag_key}:#{ref}"

        {state, outcome} =
          insert_row(state, loop_ref, Input.completed(tag, result), dedup_key, now)

        if outcome == :appended, do: wake(state, loop_ref, now), else: state
    end
  end

  ## Clementine.Loop.Host

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
    now = DateTime.utc_now()

    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.runs, loop_ref) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, %Facts{kind: kind}} when kind != :loop ->
          {{:error, :rollout_run}, state}

        {:ok, %Facts{} = facts} ->
          cond do
            Facts.terminal?(facts) ->
              {{:error, :already_terminal}, state}

            true ->
              flag = facts.cancel || %{reason: reason, requested_at: now}
              state = put_in(state.runs[loop_ref].cancel, flag)

              state =
                if facts.status == :waiting, do: wake(state, loop_ref, now), else: state

              {{:ok, :flagged}, state}
          end
      end
    end)
  end

  @impl Clementine.Loop.Host
  def append(loop_ref, %Input{} = input, dedup_key, store) do
    now = DateTime.utc_now()

    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.runs, loop_ref) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, %Facts{kind: kind}} when kind != :loop ->
          {{:error, :rollout_run}, state}

        {:ok, %Facts{} = facts} ->
          cond do
            Facts.terminal?(facts) ->
              case insert_row(state, loop_ref, input, dedup_key, now, dead: :terminal) do
                {state, :appended} -> {{:ok, :dead_lettered}, state}
                {state, :duplicate} -> {{:ok, :duplicate}, state}
              end

            true ->
              case insert_row(state, loop_ref, input, dedup_key, now) do
                {state, :duplicate} ->
                  {{:ok, :duplicate}, state}

                {state, :appended} ->
                  state =
                    if facts.status == :waiting, do: wake(state, loop_ref, now), else: state

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
      |> Enum.reverse()
      |> Enum.reject(& &1.dead_reason)
      |> Enum.filter(fn row -> scope == :any or row.input.kind == :completed end)
      |> Enum.take(limit)
      |> Enum.map(&to_stored/1)
    end)
  end

  @impl Clementine.Loop.Host
  def dead_letters(loop_ref, limit, store) when is_integer(limit) and limit > 0 do
    Agent.get(store, fn state ->
      state.inbox
      |> Map.get(loop_ref, [])
      |> Enum.filter(& &1.dead_reason)
      |> Enum.take(limit)
      |> Enum.map(&to_stored/1)
    end)
  end

  defp to_stored(row) do
    %StoredInput{
      ref: row.ref,
      input: row.input,
      attempts: row.attempts,
      decode_error: row[:decode_error],
      dedup_key: row.dedup_key,
      inserted_at: row.inserted_at,
      dead_at: row.dead_at,
      dead_reason: row.dead_reason
    }
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
  def build_child(_facts, _tag, child_args, _store) do
    agent = Clementine.Agent.new(model: :claude_sonnet, instructions: "test child")
    {:ok, Clementine.Rollout.new(agent: agent, input: Map.get(child_args, "input", "go"))}
  end

  @impl Clementine.Loop.Host
  def enqueue_step(loop_ref, store) do
    Agent.update(store, &push_job(&1, loop_ref, "step"))
  end

  @impl Clementine.Loop.Host
  def create(spec, store) do
    now = DateTime.utc_now()

    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.scopes, spec.scope) do
        {:ok, existing_ref} ->
          {{:ok, :already_exists, Map.fetch!(state.runs, existing_ref)}, state}

        :error ->
          {ref, state} = mint_ref(state)
          facts = %Facts{ref: ref, kind: :loop, status: :queued, queued_at: now}

          state =
            state
            |> put_in([:runs, ref], facts)
            |> put_in([:loop, ref], %{
              module: inspect(spec.module),
              args: spec.args,
              policy: spec.policy,
              envelope: nil
            })
            |> put_in([:scopes, spec.scope], ref)
            |> push_job(ref, "step")

          {{:ok, facts}, state}
      end
    end)
  end

  @impl Clementine.Loop.Host
  def apply_step(%StepCommit{} = commit, store) do
    now = DateTime.utc_now()

    # Faults fire in the caller's process, before the unit runs — the
    # store is left exactly as a crashed step leaves it: bump committed,
    # nothing else (the crash-before-commit simulation, matrix row L1).
    case take_fault(store) do
      {:raise, _} -> raise "injected apply_step crash"
      {:error, _} -> {:error, :storage_down}
      nil -> Agent.get_and_update(store, &do_apply_step(&1, commit, now))
    end
  end

  defp take_fault(store) do
    Agent.get_and_update(store, fn state ->
      case state.faults[:apply_step] do
        nil -> {nil, state}
        {_mode, 0} -> {nil, update_in(state.faults, &Map.delete(&1, :apply_step))}
        {mode, n} -> {{mode, n}, put_in(state.faults[:apply_step], {mode, n - 1})}
      end
    end)
  end

  # The one atomic unit (atomicity sentence 1): the CAS fence first, then
  # every piece of cargo, the park re-check, the projection, and the
  # terminal sweep — all inside this single update.
  defp do_apply_step(state, %StepCommit{} = commit, now) do
    facts = Map.get(state.runs, commit.loop_ref)

    if facts != nil and facts.status == commit.expect.status and
         facts.epoch == commit.expect.epoch do
      case consume(state, commit) do
        {:error, reason} ->
          {{:error, reason}, state}

        {:ok, state} ->
          state = put_in(state.runs[commit.loop_ref], apply_set(facts, commit.set, now))
          state = mark_dead(state, commit, now)
          state = insert_appends(state, commit, now)
          {state, child_fills} = spawn_children(state, commit, now)
          {state, timer_fills} = schedule_timers(state, commit)
          state = retire_timers(state, commit)
          state = cancel_children(state, commit, child_fills, now)

          case execute_sends(state, commit, now) do
            {:error, reason} ->
              {{:error, reason}, state}

            {:ok, state} ->
              state = write_envelope(state, commit, child_fills, timer_fills)
              state = settle(state, commit, now)
              state = record_result(state, commit.loop_ref, commit.result, now)
              state = sweep(state, commit, now)
              {{:ok, Map.fetch!(state.runs, commit.loop_ref)}, state}
          end
      end
    else
      {{:error, :stale}, state}
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

  defp mark_dead(state, %StepCommit{marks: marks}, now) do
    Enum.reduce(marks, state, fn %{ref: ref, reason: reason}, state ->
      update_inbox_row(state, ref, &%{&1 | dead_at: now, dead_reason: reason})
    end)
  end

  defp insert_appends(state, %StepCommit{appends: appends, loop_ref: loop_ref}, now) do
    Enum.reduce(appends, state, fn %Input{} = input, state ->
      {state, :appended} = insert_row(state, loop_ref, input, nil, now)
      state
    end)
  end

  defp spawn_children(state, %StepCommit{children: specs, loop_ref: loop_ref}, now) do
    Enum.reduce(specs, {state, %{}}, fn spec, {state, fills} ->
      {ref, state} = mint_ref(state)
      child = %Facts{ref: ref, kind: :rollout, status: :queued, queued_at: now}

      state =
        state
        |> put_in([:runs, ref], child)
        |> put_in([:children_meta, ref], %{
          loop_ref: loop_ref,
          tag: spec.tag,
          tag_key: spec.tag_key
        })
        |> push_job(ref, "child")

      {state, Map.put(fills, spec.tag_key, ref)}
    end)
  end

  defp schedule_timers(state, %StepCommit{timers: specs, loop_ref: loop_ref}) do
    Enum.reduce(specs, {state, %{}}, fn spec, {state, fills} ->
      state = push_job(state, loop_ref, "timer", %{"tag_key" => spec.tag_key})
      {state, Map.put(fills, spec.tag_key, %{"tag_key" => spec.tag_key})}
    end)
  end

  defp retire_timers(state, %StepCommit{cancel_timers: tag_keys, loop_ref: loop_ref}) do
    update_in(state.jobs, fn jobs ->
      Enum.reject(jobs, fn job ->
        job.kind == "timer" and job.run_ref == loop_ref and
          job.args["tag_key"] in tag_keys
      end)
    end)
  end

  # Cascade cargo, exactly the Ecto adapter's semantics: queued/waiting
  # children direct-terminalize with Result.Cancelled — their glue
  # (record_result) appends completions to this very loop inside this
  # very unit, where the park re-check sees them; running children get
  # the cooperative flag; terminal or missing children are tolerated.
  defp cancel_children(state, %StepCommit{cancel_children: tag_keys} = commit, fills, now) do
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
          |> put_in(
            [:runs, ref],
            %{child | status: :cancelled, cancel: nil, suspension: nil, finished_at: now}
          )
          |> record_result(ref, result, now)

        %Facts{status: :running} = child ->
          put_in(
            state.runs[ref].cancel,
            child.cancel || %{reason: {:loop_cascade, commit.loop_ref}, requested_at: now}
          )

        %Facts{} ->
          state
      end
    end)
  end

  defp execute_sends(state, %StepCommit{sends: sends, loop_ref: loop_ref}, now) do
    Enum.reduce_while(sends, {:ok, state}, fn send, {:ok, state} ->
      case Map.get(state.runs, send.target) do
        nil ->
          {:halt, {:error, {:send_target_not_found, send.target}}}

        %Facts{kind: kind} when kind != :loop ->
          {:halt, {:error, {:send_target_not_a_loop, send.target}}}

        %Facts{} = target ->
          {state, outcome} =
            insert_row(state, send.target, Input.message(send.payload), send.dedup_key, now)

          state =
            if outcome == :appended and send.target != loop_ref and target.status == :waiting,
              do: wake(state, send.target, now),
              else: state

          {:cont, {:ok, state}}
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

  defp settle(state, %StepCommit{op: :continue, loop_ref: loop_ref}, _now) do
    push_job(state, loop_ref, "step")
  end

  defp settle(state, %StepCommit{op: :park, loop_ref: loop_ref} = commit, now) do
    scope = commit.park_recheck || :any
    facts = Map.fetch!(state.runs, loop_ref)

    pending? =
      state.inbox
      |> Map.get(loop_ref, [])
      |> Enum.any?(fn row ->
        is_nil(row.dead_reason) and (scope == :any or row.input.kind == :completed)
      end)

    cancel? = scope == :any and facts.cancel != nil

    if pending? or cancel?, do: wake(state, loop_ref, now), else: state
  end

  defp settle(state, %StepCommit{op: :finish}, _now), do: state

  defp sweep(state, %StepCommit{terminal_sweep: false}, _now), do: state

  defp sweep(state, %StepCommit{loop_ref: loop_ref}, now) do
    update_in(state.inbox[loop_ref], fn rows ->
      Enum.map(rows || [], fn
        %{dead_reason: nil} = row -> %{row | dead_at: now, dead_reason: :terminal_sweep}
        row -> row
      end)
    end)
  end

  ## Shared internals

  # The wake: CAS waiting -> queued (kind-guarded, field hygiene) plus
  # the step-job enqueue — no-op against any other status.
  defp wake(state, loop_ref, now) do
    case Map.get(state.runs, loop_ref) do
      %Facts{kind: :loop, status: :waiting} = facts ->
        state
        |> put_in([:runs, loop_ref], %{facts | status: :queued, suspension: nil, queued_at: now})
        |> push_job(loop_ref, "step")

      _ ->
        state
    end
  end

  defp insert_row(state, loop_ref, %Input{} = input, dedup_key, now, opts \\ []) do
    rows = Map.get(state.inbox, loop_ref, [])

    if dedup_key && Enum.any?(rows, &(&1.dedup_key == dedup_key)) do
      {state, :duplicate}
    else
      {ref, state} = mint_ref(state)

      row = %{
        ref: ref,
        input: input,
        dedup_key: dedup_key,
        attempts: 0,
        inserted_at: now,
        dead_at: if(opts[:dead], do: now),
        dead_reason: opts[:dead]
      }

      {put_in(state.inbox[loop_ref], [row | rows]), :appended}
    end
  end

  defp update_inbox_row(state, ref, fun) do
    update_in(state.inbox, fn inbox ->
      Map.new(inbox, fn {loop_ref, rows} ->
        {loop_ref, Enum.map(rows, &if(&1.ref == ref, do: fun.(&1), else: &1))}
      end)
    end)
  end

  defp push_job(state, run_ref, kind, args \\ %{}) do
    update_in(state.jobs, &[%{run_ref: run_ref, kind: kind, args: args} | &1])
  end

  defp mint_ref(state) do
    {state.next_ref, %{state | next_ref: state.next_ref + 1}}
  end

  # Absent keys untouched; present keys written (nil writes NULL);
  # symbolic stamps resolve one plain-map level deep — MemoryLifecycle's
  # exact semantics, restated here so the whole unit stays in one update.
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
