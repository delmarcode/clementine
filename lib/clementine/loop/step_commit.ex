defmodule Clementine.Loop.StepCommit do
  @moduledoc """
  Everything one step caused, as one value (LOOP_RFC §The Loop Host
  Contract): the guarded transition (exact `(status, epoch)` expectation
  and the partial facts to set, envelope included), the consumed input
  refs, dead-letter marks, synthesized appends, the dispatch cargo, and
  the terminal-sweep flag.

  The host's `apply_step/2` executes the *entire* value in one atomic
  unit — CAS transition, envelope, consumption, marks, appends, child rows
  and their jobs, sends, timer jobs, cancellations, terminal sweep — or
  none of it (`{:error, :stale}` when the guard misses). Dispatch is
  cargo, not a phase: nothing durable precedes this commit, which is what
  makes a loop always replayable (Governing Invariants 3–4).

  `set` follows `Clementine.Lifecycle.Transition` semantics exactly:
  absent key = leave untouched, present `nil` = write NULL, timestamps
  symbolic (`:now`), resolved against the storage clock. Two loop-only
  keys ride alongside the facts: `:envelope` (an `Envelope` struct the
  host encodes via `Envelope.encode/1`) and `:state_version`. A
  threshold poison commit omits both (and `:usage`) — it changes no app
  state, so the stored values ride along untouched.

  When `op` is `:park`, the host re-verifies *inside the same unit* that
  no unconsumed inputs in `park_recheck` scope exist, downgrading the park
  to a continue when they do (Governing Invariant 5b). The scope is `:any`
  for ordinary parks; a cascade park re-checks `:completions` only —
  non-completion inputs legitimately sit unconsumed until the terminal
  sweep, and an `:any` re-check would downgrade forever. The `:any`
  re-check also covers the cancel flag: a flag that landed mid-step is a
  wake the claim never saw, and parking over it would strand the
  cancellation (`Clementine.Loop.Host` states the full interleaving). A
  cascade park deliberately ignores the flag — the cascade is its handler.

  Dead-letter reasons are closed and observable (Governing Invariant 11):
  `:poison` (head attempts exhausted), `:unknown_tag` (completion for no
  live child), `:stale_elapsed` (fire racing a cancel or retire),
  `:terminal_sweep` (host-applied to every row remaining at a finish), and
  `:terminal` (host-applied to post-terminal appends).
  """

  alias Clementine.Loop.{Envelope, Input}
  alias Clementine.Result

  @dead_reasons [:poison, :unknown_tag, :stale_elapsed, :terminal_sweep, :terminal]

  @enforce_keys [:loop_ref, :op, :expect, :set]
  defstruct loop_ref: nil,
            op: nil,
            expect: nil,
            set: %{},
            result: nil,
            park_recheck: nil,
            consumed: [],
            marks: [],
            appends: [],
            children: [],
            cancel_children: [],
            sends: [],
            timers: [],
            cancel_timers: [],
            terminal_sweep: false,
            meta: %{}

  @type dead_reason :: :poison | :unknown_tag | :stale_elapsed | :terminal_sweep | :terminal

  @type mark :: %{ref: term(), reason: dead_reason(), error: Clementine.Error.t() | nil}

  @type child_spec :: %{tag: term(), tag_key: String.t(), child_args: map()}

  @type send_spec :: %{target: term(), payload: term(), dedup_key: String.t()}

  @type timer_spec :: %{
          tag: term(),
          tag_key: String.t(),
          fire: {:at, DateTime.t()} | {:now_plus, non_neg_integer()}
        }

  @type t :: %__MODULE__{
          loop_ref: term(),
          op: :park | :continue | :finish,
          expect: %{status: :running, epoch: pos_integer()},
          set: map(),
          result: Result.t() | nil,
          park_recheck: nil | :any | :completions,
          consumed: [term()],
          marks: [mark()],
          appends: [Input.t()],
          children: [child_spec()],
          cancel_children: [String.t()],
          sends: [send_spec()],
          timers: [timer_spec()],
          cancel_timers: [String.t()],
          terminal_sweep: boolean(),
          meta: map()
        }

  @spec dead_reasons() :: [dead_reason()]
  def dead_reasons, do: @dead_reasons

  @doc """
  The envelope this commit writes, or nil when the commit leaves the
  stored envelope untouched (threshold poison steps).
  """
  @spec envelope(t()) :: Envelope.t() | nil
  def envelope(%__MODULE__{set: %{envelope: %Envelope{} = envelope}}), do: envelope
  def envelope(%__MODULE__{}), do: nil
end
