defmodule Clementine.Loop.Step do
  @moduledoc """
  The pure step core (LOOP_RFC §The Step): given the decoded envelope, the
  pending window, and a plan, compute the one `StepCommit` the host applies
  atomically. This module is the loop design — every decision the RFC
  makes about draining, dedup, blame, halt, and cascade lives here as a
  pure function, property-testable with no database.

  Two phases, split so the attempts bump can commit *before* `handle/2`
  runs (Governing Invariant 3's one deliberate exception — a payload that
  kills the VM must still advance toward its dead-letter threshold):

      plan  = Step.plan(envelope, pending, cancel: facts_cancel, ...)
      :ok   = host.bump_attempts(plan.bump, ctx)   # committed, pre-drain
      {:ok, commit} = Step.drain(module, envelope, plan, loop_ref: ..., epoch: ...)
      host.apply_step(commit, ctx)                 # the one atomic unit

  ## Failure channels

  Deploy-shaped problems return clean errors — `{:error,
  {:incompatible_state, _}}` (stored `state_version` this code cannot
  load) and `{:error, {:incompatible_spec, _}}` (not a loop module) — the
  loop parks visibly until compatible code deploys (matrix row L2). Inputs
  are innocent of deploys, so these never dead-letter anything.

  App-contract violations raise (`ArgumentError`): actions outside the
  closed set, tag collisions among live children or pending timers,
  returns outside the callback contract, non-map `dump/1` output,
  un-encodable payloads. A raise fails the step; the drain-time bump has
  already counted it, so deterministic violations walk the poison path —
  head-of-batch blame, batch-1 degrade, dead-letter at the threshold with
  a synthesized `{:input_failed, ref, error}` — and the mailbox never jams
  (matrix row L7).

  Cascade mode (facts cancel flag, or a pending halt in the envelope)
  never invokes `handle/2`, `load/1`, or `dump/1`: completions are
  absorbed into the envelope (usage included), non-completion inputs stay
  unconsumed for the terminal sweep, and version incompatibilities cannot
  block a cancellation.
  """

  alias Clementine.Loop.{Action, Codec, Envelope, Input, StepCommit, StoredInput}
  alias Clementine.{Error, Result, ResumeToken, Suspension, Usage}

  # Both defaults are RFC non-final policy knobs (LOOP_RFC §Non-Final);
  # hosts override per loop via loop_policy.
  @default_batch_cap 20
  @default_dead_letter_after 3

  defmodule Plan do
    @moduledoc """
    The pre-drain phase of one step, computed pure from the pending window:
    which ref to bump (the head, blamed for any pre-commit death), the
    batch to fold (degraded to one after a failed step — the head's
    attempts are the evidence), the at-threshold poison mark with its
    synthesized `{:input_failed}`, and the window remainder the transition
    computation reads.
    """

    defstruct mode: :normal,
              cancel: nil,
              bump: [],
              batch: [],
              rest: [],
              dead: [],
              synthesize: []

    @type t :: %__MODULE__{
            mode: :normal | :cascade,
            cancel: term(),
            bump: [term()],
            batch: [StoredInput.t()],
            rest: [StoredInput.t()],
            dead: [StepCommit.mark()],
            synthesize: [Input.t()]
          }
  end

  @doc """
  Computes the drain plan from the decoded envelope (nil before the first
  commit) and the pending window, oldest first.

  Options:

  - `:cancel` — the facts' cancel-flag reason; non-nil enters cascade mode
    (a pending halt in the envelope does too).
  - `:batch_cap` — max inputs folded per step (default #{@default_batch_cap}).
  - `:dead_letter_after` — head attempts at which poison dead-letters
    (default #{@default_dead_letter_after}); the head gets exactly that many
    executions, the Oban `max_attempts` analog.

  Cascade plans never bump: `handle/2` never runs, so nothing can poison.
  The synthesized `{:input_failed}` is itself subject to the same
  threshold but never re-synthesizes — poison evidence does not recurse.
  """
  @spec plan(Envelope.t() | nil, [StoredInput.t()], keyword()) :: Plan.t()
  def plan(envelope, pending, opts \\ []) do
    cancel = Keyword.get(opts, :cancel)
    batch_cap = Keyword.get(opts, :batch_cap, @default_batch_cap)
    threshold = Keyword.get(opts, :dead_letter_after, @default_dead_letter_after)

    if cancel != nil or (envelope && Envelope.cascading?(envelope)) do
      {batch, rest} = Enum.split(pending, batch_cap)
      %Plan{mode: :cascade, cancel: cancel, batch: batch, rest: rest}
    else
      plan_normal(pending, batch_cap, threshold)
    end
  end

  defp plan_normal([], _batch_cap, _threshold), do: %Plan{}

  defp plan_normal([head | rest] = pending, batch_cap, threshold) do
    cond do
      head.attempts >= threshold ->
        error = poison_error(head)
        mark = %{ref: head.ref, reason: :poison, error: error}

        synthesize =
          if head.input.kind == :input_failed,
            do: [],
            else: [Input.input_failed(head.ref, error)]

        %Plan{dead: [mark], synthesize: synthesize, rest: rest}

      # Attempts on an unconsumed head mean a prior step died before its
      # commit: degrade to one so innocents behind a poison head never
      # accumulate attempts.
      head.attempts > 0 ->
        %Plan{bump: [head.ref], batch: [head], rest: rest}

      true ->
        {batch, rest} = Enum.split(pending, batch_cap)
        %Plan{bump: [head.ref], batch: batch, rest: rest}
    end
  end

  defp poison_error(%StoredInput{} = head) do
    %Error{
      kind: :runtime,
      code: :input_dead_lettered,
      message: "Loop input dead-lettered after #{head.attempts} attempts.",
      retryable?: false,
      raw: nil
    }
  end

  @doc """
  Folds the plan's batch through `init/1`-or-`handle/2` (or absorbs it, in
  cascade mode) and computes the `StepCommit`.

  Required options: `:loop_ref` and `:epoch` (the claim's — the commit's
  CAS guard). `:loop_args` (default `%{}`) feeds `init/1` on the first
  step.

  Dedup consults the in-fold envelope — the stored envelope plus actions
  accumulated earlier in this drain — never the stored envelope alone:
  "not yet recorded" and "no longer live" are different answers (Governing
  Invariant 7, matrix row L5). Completions and elapses for tags live
  nowhere in-fold dead-letter as `:unknown_tag`/`:stale_elapsed` evidence,
  never reaching `handle/2` and never silently dropping (rows L6, L17). A
  tag retired earlier in the drain is immediately re-armable — live-key
  lifetime, the watcher's re-armed `:poll`.

  A completion or elapse absorbed for a tag spawned *in this same drain*
  also retires that spawn's cargo: the input's existence proves the child
  ran (or the fire happened) on some substrate that leaked it past the
  commit, and re-dispatching would duplicate work the active-only dedup
  index no longer guards.

  Send dedup keys are causally derived and replay-stable —
  `"send:" <> loop_key <> ":" <> causal <> ":" <> index` where `causal` is
  the consumed input's ref key (or `"init"`) — so a crash replay re-emits
  the identical key and the target's unique index makes delivery
  exactly-once in effect (Governing Invariant 12).
  """
  @spec drain(module(), Envelope.t() | nil, Plan.t(), keyword()) ::
          {:ok, StepCommit.t()}
          | {:error, {:incompatible_state, map()} | {:incompatible_spec, map()}}
  def drain(module, envelope, %Plan{} = plan, opts) do
    loop_ref = Keyword.fetch!(opts, :loop_ref)
    epoch = Keyword.fetch!(opts, :epoch)
    loop_args = Keyword.get(opts, :loop_args, %{})

    with :ok <- check_module(module) do
      case plan.mode do
        :cascade -> drain_cascade(module, envelope, plan, loop_ref, epoch)
        :normal -> drain_normal(module, envelope, plan, loop_ref, epoch, loop_args)
      end
    end
  end

  defp check_module(module) do
    if Clementine.Loop.loop?(module) do
      :ok
    else
      {:error, {:incompatible_spec, %{module: inspect(module), reason: :not_a_loop}}}
    end
  end

  ## Normal mode

  defp drain_normal(module, envelope, plan, loop_ref, epoch, loop_args) do
    vocab = module.__loop__(:vocabulary)
    declared = module.__loop__(:state_version)

    with {:ok, fold} <- initial_fold(module, envelope, loop_args, vocab, plan, loop_ref) do
      fold = fold_batch(module, fold, plan.batch, vocab)

      commit =
        if fold.halted do
          halt_commit(module, fold, plan, loop_ref, epoch, vocab, declared)
        else
          steady_commit(module, fold, plan, loop_ref, epoch, vocab, declared)
        end

      {:ok, commit}
    end
  end

  # The first claim runs init — state and actions land in the same commit
  # as the first drain, under the synthetic causal ref "init".
  defp initial_fold(module, nil, loop_args, vocab, plan, loop_ref) do
    fold = new_fold(nil, plan, loop_ref)

    case module.init(loop_args) do
      {:ok, state, actions} ->
        fold = %{fold | state: state, initialized?: true}
        {:ok, apply_actions(fold, actions, :init, vocab)}

      # Halting out of init: no state ever existed, so nothing to dump.
      {:halt, result} ->
        {:ok, %{fold | halted: normalize_halt(result)}}

      other ->
        raise ArgumentError,
              "init/1 must return {:ok, state, actions} | {:halt, result}, got: #{inspect(other)}"
    end
  end

  defp initial_fold(module, %Envelope{} = envelope, _loop_args, vocab, plan, loop_ref) do
    declared = module.__loop__(:state_version)

    if envelope.state_version == declared do
      state = module.load(Codec.decode(envelope.state, vocabulary: vocab))
      {:ok, %{new_fold(envelope, plan, loop_ref) | state: state, initialized?: true}}
    else
      {:error,
       {:incompatible_state, %{state_version: envelope.state_version, declared: declared}}}
    end
  end

  defp new_fold(envelope, plan, loop_ref) do
    %{
      loop_ref: loop_ref,
      state: nil,
      initialized?: false,
      children: (envelope && envelope.children) || %{},
      timers: (envelope && envelope.timers) || %{},
      usage: (envelope && envelope.usage) || %Usage{},
      pending_halt: envelope && envelope.pending_halt,
      consumed: [],
      marks: plan.dead,
      appends: plan.synthesize,
      child_cargo: [],
      send_cargo: [],
      timer_cargo: [],
      cancel_timer_cargo: [],
      halted: nil,
      leftover: []
    }
  end

  defp fold_batch(_module, fold, [], _vocab), do: fold

  defp fold_batch(_module, %{halted: halted} = fold, batch, _vocab) when halted != nil do
    # Stop early on halt: undrained inputs stay unconsumed for the
    # post-cascade sweep — neither consumed nor marked by this commit.
    %{fold | leftover: fold.leftover ++ batch}
  end

  defp fold_batch(module, fold, [stored | rest], vocab) do
    fold_batch(module, fold_one(module, fold, stored, vocab), rest, vocab)
  end

  defp fold_one(
         module,
         fold,
         %StoredInput{input: %Input{kind: :completed} = input} = stored,
         vocab
       ) do
    tag_key = Codec.key(input.tag, vocabulary: vocab)

    if Map.has_key?(fold.children, tag_key) do
      fold =
        fold
        |> Map.update!(:children, &Map.delete(&1, tag_key))
        |> Map.update!(:usage, &Usage.add(&1, Result.usage(input.result)))
        |> retire_cargo(:child_cargo, tag_key)

      deliver(module, fold, stored, vocab)
    else
      mark(fold, stored, :unknown_tag)
    end
  end

  defp fold_one(module, fold, %StoredInput{input: %Input{kind: :elapsed} = input} = stored, vocab) do
    tag_key = Codec.key(input.tag, vocabulary: vocab)

    if Map.has_key?(fold.timers, tag_key) do
      fold =
        fold
        |> Map.update!(:timers, &Map.delete(&1, tag_key))
        |> retire_cargo(:timer_cargo, tag_key)

      deliver(module, fold, stored, vocab)
    else
      mark(fold, stored, :stale_elapsed)
    end
  end

  defp fold_one(module, fold, %StoredInput{} = stored, vocab) do
    deliver(module, fold, stored, vocab)
  end

  defp deliver(module, fold, %StoredInput{ref: ref, input: input}, vocab) do
    case module.handle(Input.to_callback(input), fold.state) do
      {:ok, state, actions} ->
        fold = %{fold | state: state, consumed: [ref | fold.consumed]}
        apply_actions(fold, actions, {:input, ref}, vocab)

      {:halt, result, state} ->
        %{
          fold
          | state: state,
            consumed: [ref | fold.consumed],
            halted: normalize_halt(result)
        }

      other ->
        raise ArgumentError,
              "handle/2 must return {:ok, state, actions} | {:halt, result, state}, " <>
                "got: #{inspect(other)}"
    end
  end

  defp mark(fold, %StoredInput{ref: ref}, reason) do
    %{fold | marks: fold.marks ++ [%{ref: ref, reason: reason, error: nil}]}
  end

  # A this-drain spawn or schedule absorbed by its own completion/elapse
  # retires its cargo; at most one un-retired spec per live tag_key can
  # exist, because arming a live tag raises.
  defp retire_cargo(fold, cargo_key, tag_key) do
    Map.update!(fold, cargo_key, fn specs ->
      Enum.reject(specs, &(&1.tag_key == tag_key))
    end)
  end

  defp apply_actions(fold, actions, causal, vocab) when is_list(actions) do
    actions
    |> Enum.with_index()
    |> Enum.reduce(fold, fn {action, index}, fold ->
      apply_action(fold, Action.normalize(action, vocabulary: vocab), causal, index)
    end)
  end

  defp apply_actions(_fold, actions, _causal, _vocab) do
    raise ArgumentError, "actions must be a list, got: #{inspect(actions)}"
  end

  defp apply_action(fold, %Action{kind: :run} = action, _causal, _index) do
    if Map.has_key?(fold.children, action.tag_key) do
      raise ArgumentError,
            "tag #{inspect(action.tag)} is already a live child — tags are unique " <>
              "among live children; retire it (completion) before re-spawning"
    end

    spec = %{tag: action.tag, tag_key: action.tag_key, child_args: action.child_args}

    %{
      fold
      | children: Map.put(fold.children, action.tag_key, nil),
        child_cargo: fold.child_cargo ++ [spec]
    }
  end

  defp apply_action(fold, %Action{kind: :timer} = action, _causal, _index) do
    if Map.has_key?(fold.timers, action.tag_key) do
      raise ArgumentError,
            "tag #{inspect(action.tag)} is already a pending timer — tags are unique " <>
              "among pending timers; it becomes re-armable once fired or cancelled"
    end

    spec = %{tag: action.tag, tag_key: action.tag_key, fire: action.fire}

    %{
      fold
      | timers: Map.put(fold.timers, action.tag_key, %{}),
        timer_cargo: fold.timer_cargo ++ [spec]
    }
  end

  defp apply_action(fold, %Action{kind: :cancel_timer} = action, _causal, _index) do
    cond do
      # Armed earlier this drain: net zero — nothing durable ever exists.
      Enum.any?(fold.timer_cargo, &(&1.tag_key == action.tag_key)) ->
        fold
        |> Map.update!(:timers, &Map.delete(&1, action.tag_key))
        |> retire_cargo(:timer_cargo, action.tag_key)

      Map.has_key?(fold.timers, action.tag_key) ->
        %{
          fold
          | timers: Map.delete(fold.timers, action.tag_key),
            cancel_timer_cargo: fold.cancel_timer_cargo ++ [action.tag_key]
        }

      # Not pending: a benign race (its fire may sit earlier in this very
      # batch), not an app bug — no-op, per the best-effort cancel model.
      true ->
        fold
    end
  end

  defp apply_action(fold, %Action{kind: :send} = action, causal, index) do
    spec = %{
      target: action.target,
      payload: action.payload,
      dedup_key:
        "send:#{Codec.key(fold.loop_ref)}:#{causal_key(causal)}:#{Integer.to_string(index)}"
    }

    %{fold | send_cargo: fold.send_cargo ++ [spec]}
  end

  defp causal_key(:init), do: "init"
  defp causal_key({:input, ref}), do: Codec.key(ref)

  defp normalize_halt(result) do
    case result do
      # The loop's terminal Completed carries the halt's summary, empty
      # messages, nil input_message (LOOP_RFC §The Behaviour) — history
      # lives in the messages table, folded by cursor, never in terminals.
      %Result.Completed{} = completed ->
        %{completed | messages: [], input_message: nil}

      %Result.Failed{} = failed ->
        failed

      %Result.Cancelled{} = cancelled ->
        cancelled

      %Result.Interrupted{} = interrupted ->
        interrupted

      other ->
        raise ArgumentError, "halt must carry a Clementine.Result, got: #{inspect(other)}"
    end
  end

  ## Commit assembly — normal mode

  defp steady_commit(module, fold, plan, loop_ref, epoch, vocab, declared) do
    envelope = build_envelope(module, fold, vocab, declared)

    if fold.appends != [] or plan.rest != [] do
      commit(
        fold,
        plan,
        loop_ref,
        epoch,
        :continue,
        continue_set(envelope, declared),
        nil,
        nil,
        false
      )
    else
      set = park_set(envelope, declared, loop_ref, epoch)
      commit(fold, plan, loop_ref, epoch, :park, set, :any, nil, false)
    end
  end

  # A halt with children in flight enters the cascade: the machinery — not
  # handle/2 — cancels live children as cargo, parks with the pending
  # result held in the envelope, and finishes when the last completion
  # folds. With nothing in flight it finishes now, terminal sweep included.
  defp halt_commit(module, fold, plan, loop_ref, epoch, vocab, declared) do
    if map_size(fold.children) == 0 do
      result = put_usage(fold.halted, fold.usage)
      envelope = build_envelope(module, fold, vocab, declared)
      set = finish_set(envelope, declared, result)
      commit(fold, plan, loop_ref, epoch, :finish, set, nil, result, true)
    else
      fold = %{fold | pending_halt: %{result: fold.halted}}
      envelope = build_envelope(module, fold, vocab, declared)
      window = fold.leftover ++ plan.rest

      %StepCommit{
        cascade_park_or_continue(fold, plan, loop_ref, epoch, envelope, declared, window)
        | cancel_children: fold.children |> Map.keys() |> Enum.sort()
      }
    end
  end

  defp build_envelope(module, fold, vocab, declared) do
    %Envelope{
      version: Envelope.version(),
      state_version: declared,
      state: if(fold.initialized?, do: dump_state(module, fold.state, vocab)),
      children: fold.children,
      timers: fold.timers,
      pending_halt: fold.pending_halt,
      usage: fold.usage
    }
  end

  defp dump_state(module, state, vocab) do
    dumped = module.dump(state)

    unless is_map(dumped) and not is_struct(dumped) do
      raise ArgumentError, "dump/1 must return a map, got: #{inspect(dumped)}"
    end

    Codec.encode(dumped, vocabulary: vocab)
  end

  ## Cascade mode

  # Cancellation cascades without touching app state: no load, no dump, no
  # handle — an :incompatible_state loop is still cancellable (row L2's
  # host-chosen terminal), and queued inputs are short-circuited, swept at
  # the finish.
  defp drain_cascade(module, envelope, plan, loop_ref, epoch) do
    vocab = module.__loop__(:vocabulary)
    entering? = envelope == nil or envelope.pending_halt == nil

    base = envelope || %Envelope{state_version: module.__loop__(:state_version), state: nil}
    fold = %{new_fold(base, plan, loop_ref) | state: base.state}
    fold = Enum.reduce(plan.batch, fold, &absorb(&2, &1, vocab))

    halt_result =
      case base.pending_halt do
        # First cause wins: a cancel flag arriving mid-halt-cascade does
        # not replace the halt's result.
        %{result: result} -> result
        nil -> Result.cancelled(plan.cancel)
      end

    commit =
      if map_size(fold.children) == 0 do
        result = put_usage(halt_result, fold.usage)
        envelope = cascade_envelope(%{fold | pending_halt: nil}, base)
        set = finish_set(envelope, base.state_version, result)
        commit(fold, plan, loop_ref, epoch, :finish, set, nil, result, true)
      else
        fold = %{fold | pending_halt: %{result: halt_result}}
        envelope = cascade_envelope(fold, base)
        window = fold.leftover ++ plan.rest
        cancel = if entering?, do: fold.children |> Map.keys() |> Enum.sort(), else: []

        %StepCommit{
          cascade_park_or_continue(
            fold,
            plan,
            loop_ref,
            epoch,
            envelope,
            base.state_version,
            window
          )
          | cancel_children: cancel
        }
      end

    {:ok, commit}
  end

  # Completions absorb without handle/2; everything else stays unconsumed
  # until the terminal sweep.
  defp absorb(fold, %StoredInput{input: %Input{kind: :completed} = input} = stored, vocab) do
    tag_key = Codec.key(input.tag, vocabulary: vocab)

    if Map.has_key?(fold.children, tag_key) do
      %{
        fold
        | children: Map.delete(fold.children, tag_key),
          usage: Usage.add(fold.usage, Result.usage(input.result)),
          consumed: [stored.ref | fold.consumed]
      }
    else
      mark(fold, stored, :unknown_tag)
    end
  end

  defp absorb(fold, %StoredInput{} = stored, _vocab) do
    %{fold | leftover: fold.leftover ++ [stored]}
  end

  defp cascade_envelope(fold, %Envelope{} = base) do
    %Envelope{
      base
      | children: fold.children,
        pending_halt: fold.pending_halt,
        usage: fold.usage
    }
  end

  # A mid-cascade park re-checks completions only: non-completion inputs
  # legitimately sit unconsumed until the terminal sweep, and an :any
  # re-check would downgrade the park forever. Completions already visible
  # in the window skip the park entirely.
  defp cascade_park_or_continue(fold, plan, loop_ref, epoch, envelope, state_version, window) do
    if Enum.any?(window, &(&1.input.kind == :completed)) do
      set = continue_set(envelope, state_version)
      commit(fold, plan, loop_ref, epoch, :continue, set, nil, nil, false)
    else
      set = park_set(envelope, state_version, loop_ref, epoch)
      commit(fold, plan, loop_ref, epoch, :park, set, :completions, nil, false)
    end
  end

  ## Transition sets — `Transition` semantics: absent key untouched,
  ## present nil writes NULL, :now resolves on the storage clock.

  defp park_set(envelope, state_version, loop_ref, epoch) do
    token = %ResumeToken{run_ref: loop_ref, epoch: epoch, reason_type: :external}

    %{
      status: :waiting,
      envelope: envelope,
      state_version: state_version,
      suspension: %Suspension{reason: {:external, :loop}, checkpoint: nil, token: token},
      executor_id: nil,
      deadline: nil,
      heartbeat_at: nil,
      queued_at: :now,
      usage: envelope.usage
    }
  end

  defp continue_set(envelope, state_version) do
    %{
      status: :queued,
      envelope: envelope,
      state_version: state_version,
      suspension: nil,
      executor_id: nil,
      deadline: nil,
      heartbeat_at: nil,
      queued_at: :now,
      usage: envelope.usage
    }
  end

  defp finish_set(envelope, state_version, result) do
    %{
      status: Result.status(result),
      envelope: envelope,
      state_version: state_version,
      suspension: nil,
      finished_at: :now,
      usage: envelope.usage
    }
    |> put_terminal_detail(result)
  end

  defp put_terminal_detail(set, %Result.Failed{error: error}), do: Map.put(set, :error, error)

  defp put_terminal_detail(set, %Result.Interrupted{reason: reason}),
    do: Map.put(set, :interrupt, reason)

  defp put_terminal_detail(set, _result), do: set

  defp put_usage(%{__struct__: _} = result, %Usage{} = usage), do: %{result | usage: usage}

  defp commit(fold, plan, loop_ref, epoch, op, set, recheck, result, sweep?) do
    %StepCommit{
      loop_ref: loop_ref,
      op: op,
      expect: %{status: :running, epoch: epoch},
      set: set,
      result: result,
      park_recheck: recheck,
      consumed: Enum.reverse(fold.consumed),
      marks: fold.marks,
      appends: fold.appends,
      children: fold.child_cargo,
      sends: fold.send_cargo,
      timers: fold.timer_cargo,
      cancel_timers: fold.cancel_timer_cargo,
      terminal_sweep: sweep?,
      meta: %{mode: plan.mode, batch: length(plan.batch)}
    }
  end
end
