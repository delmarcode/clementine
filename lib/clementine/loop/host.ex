defmodule Clementine.Loop.Host do
  @moduledoc """
  The loop layer's storage contract (LOOP_RFC §The Loop Host Contract) —
  the analog of the two-function `Clementine.Lifecycle`, and the seam the
  step machinery speaks through. `Clementine.Loop.Ecto` implements all of
  it for the Phoenix/Ecto case; hand-written hosts implement the same
  callbacks and pass the same conformance battery.

  ## The two atomicity sentences (normative)

  1. `apply_step/2` executes the *entire* `Clementine.Loop.StepCommit` —
     CAS transition, envelope, consumption, dead-letter marks, synthesized
     appends, child rows *and their jobs*, sends, timer jobs and
     cancellations, terminal sweep — **in one atomic unit**, and when the
     commit's intent is park, it re-verifies inside that unit that no
     unconsumed inputs in `park_recheck` scope exist — nor, for the `:any`
     scope, a set cancel flag — downgrading the park to a continue (status
     `queued` plus `enqueue_step/2`) when either does.
  2. `append/4` commits the input row, the wake (a CAS `waiting -> queued`
     that no-ops stale), and the step-job enqueue **in one atomic unit**.

  The cancel flag joins the `:any` re-check because a flag landing while a
  step runs is a wake the step cannot have read at claim: `cancel/3`'s own
  wake no-ops against a `running` row, so the park's in-unit re-check is
  the other half of the lock that closes the interleaving — flag-first
  downgrades the park, park-first makes `cancel/3` see `waiting` and take
  the wake itself. A cascade park (`:completions` scope) is exempt by
  design: mid-cascade the flag is *expected* set — the cascade is its
  handler — and a flag-downgrade would spin the loop hot until its
  children finished.

  On Postgres both are one transaction (Oban jobs are rows; the run-row
  CAS serializes append against park). Substrates that cannot honor
  sentence 1's re-check perfectly lean on the reaper's `:wake_pending`
  verdict — correctness degrades to bounded latency, never to loss.
  Redis-shaped hosts implement the unit with their own primitives
  (MULTI/Lua); the sentences are the contract, not the SQL.

  `bump_attempts/2` deliberately belongs to *neither* atomic unit — it is
  Governing Invariant 3's one exception, committed before handling so that
  VM-death poison is counted (matrix row L7). Everything else the step
  causes is StepCommit cargo.

  `build_child/4` is where rollouts come from: the host loads whatever the
  JSON-safe `child_args` reference (agent config, history by cursor) and
  constructs the `Clementine.Rollout` — in the child's worker, at spawn
  execution time, exactly like the shipped worker pattern. The loop never
  holds a rollout.

  `create/2` is the storage half of `Clementine.Loop.Protocol.create/3`
  (LOOP_RFC §Creation): insert-or-get, idempotent on the host's scope key,
  the row landing `queued` with the spec persisted. The RFC's contract
  block lists the six step-machinery callbacks; creation, the step
  runner's read (`load/2`), and loop-owned cancellation (`cancel/3`, the
  storage half of `Clementine.Loop.Protocol.cancel/4`) need the same
  seam, so they live here too.

  ## Append return contract

  `{:ok, :appended}` — the input is durable and any needed wake committed
  with it. `{:ok, :duplicate}` — the dedup key already exists (webhook
  retries and re-sent loop messages land here); nothing changed.
  `{:ok, :dead_lettered}` — the loop is terminal and the row was retained
  as evidence (`dead_reason: :terminal`), never to be consumed: the caller
  *knows* (a webhook can ack-and-alert; a sender loop can react). Matrix
  row L10.
  """

  alias Clementine.Lifecycle.Facts
  alias Clementine.Loop.{Input, StepCommit, StoredInput}

  @typedoc "The host's reference for a loop run row — same grain as `Facts.ref`."
  @type loop_ref :: term()

  @typedoc "Opaque host context, threaded exactly like `Clementine.Lifecycle`'s."
  @type ctx :: term()

  @doc """
  Executes one `StepCommit` under atomicity sentence 1. `{:error, :stale}`
  means the `(status, epoch)` guard missed — the fence working, not a
  fault — and nothing was written.
  """
  @callback apply_step(StepCommit.t(), ctx()) ::
              {:ok, Facts.t()} | {:error, :stale} | {:error, term()}

  @doc """
  Appends one input to a loop's inbox under atomicity sentence 2.
  `dedup_key` is nullable; when present it is unique per loop for live and
  dead rows alike (the provider message id for webhooks, machinery-derived
  keys for completions, elapses, and sends).

  Refuses rollout-kind rows with `{:error, :rollout_run}` — amendment A2's
  mirror: run kinds discriminate the verbs that may touch them, and a
  miswired ref must not grow a mailbox or have its suspension cleared by
  a wake.
  """
  @callback append(loop_ref(), Input.t(), dedup_key :: String.t() | nil, ctx()) ::
              {:ok, :appended}
              | {:ok, :duplicate}
              | {:ok, :dead_lettered}
              | {:error, :not_found}
              | {:error, :rollout_run}
              | {:error, term()}

  @doc """
  The pending window: up to `limit` unconsumed, un-dead-lettered inputs in
  FIFO (commit-visibility) order, decoded per row — a payload the current
  code cannot decode comes back with `StoredInput.decode_error` set rather
  than failing the fetch or poisoning its neighbors.

  `scope` mirrors the park re-check's: `:any` is the ordinary drain;
  `:completions` returns completion inputs only, skipping any
  non-completion backlog ahead of them — the cascade's read. Completions
  are all a cascade can consume, and a FIFO-limited `:any` window would
  never surface one parked behind a backlog longer than the cap: the
  cascade would park empty, the `:completions` re-check would downgrade,
  and the loop would spin without absorbing the child terminal.
  """
  @callback pending(loop_ref(), limit :: pos_integer(), scope :: :any | :completions, ctx()) ::
              [StoredInput.t()]

  @doc """
  The retained dead letters, newest first, up to `limit` — the doctor's
  evidence read (`Clementine.Loop.inspect/3`), never the step machinery's.
  Rows come back with `dead_at`/`dead_reason` set (the reason decoded to
  its `t:Clementine.Loop.StepCommit.dead_reason/0` atom) and the same
  lazy per-row payload decoding as `pending/4`. Optional: a host that
  does not implement it degrades the doctor's report, nothing else.
  """
  @callback dead_letters(loop_ref(), limit :: pos_integer(), ctx()) :: [StoredInput.t()]

  @doc """
  The drain-time attempts bump: one small committed write, outside both
  atomic units, so a payload that kills the VM still advances toward its
  dead-letter threshold.
  """
  @callback bump_attempts([input_ref :: term()], ctx()) :: :ok

  @doc """
  Constructs the child rollout from its durable JSON-safe args — invoked
  by the host's child worker at spawn execution time, never by the step.
  """
  @callback build_child(Facts.t(), tag :: term(), child_args :: map(), ctx()) ::
              {:ok, Clementine.Rollout.t()} | {:error, term()}

  @doc """
  Inserts the step job for a loop. Invoked inside the atomic units (a
  continue's re-enqueue, a park downgrade, an append's wake) and
  standalone (the reaper's `:reenqueue` verdict) — implementations must
  write through the same storage so an in-unit call commits with the unit
  (with Oban, `Oban.insert/2` against the configured repo does).
  """
  @callback enqueue_step(loop_ref(), ctx()) :: :ok

  @doc """
  Insert-or-get on the scope key (LOOP_RFC §Creation). The spec arrives
  normalized by `Clementine.Loop.Protocol.create/3`.
  """
  @callback create(spec :: map(), ctx()) ::
              {:ok, Facts.t()} | {:ok, :already_exists, Facts.t()} | {:error, term()}

  @doc """
  The step runner's read: current lifecycle facts plus the persisted loop
  spec and the stored (encoded) envelope, from one row read.

  The runner calls it twice per step — before the claim for the policy the
  claim's deadline is minted from (spec columns are create-time-stable),
  and again after the claim for the envelope and cancel flag, which only
  the claim's fence makes safe to trust (a pre-claim envelope could be
  superseded by a commit that raced the claim).

  Refuses rollout-kind rows with `{:error, :rollout_run}` — the same
  kind guard as `append/4`.
  """
  @callback load(loop_ref(), ctx()) ::
              {:ok,
               %{
                 facts: Facts.t(),
                 module: module() | String.t() | nil,
                 args: map(),
                 policy: map(),
                 envelope: map() | nil
               }}
              | {:error, :not_found}
              | {:error, :rollout_run}
              | {:error, term()}

  @doc """
  Loop-owned cancellation's storage half (LOOP_RFC §Cancellation And
  Halt), reached through `Clementine.Loop.Protocol.cancel/4`: set the
  kind-aware cancel flag and, when the loop is parked, wake it (the CAS
  `waiting -> queued` plus `enqueue_step/2`) — in one atomic unit where
  the substrate allows, serialized against a concurrent step's park on
  the same lock as `append/4`. A flag landing against a `running` row
  needs no wake here: the park's `:any` re-check (atomicity sentence 1)
  or the next claim honors it.

  Idempotent on the flag — a second cancel returns `{:ok, :flagged}`
  without replacing the first reason (first cause wins, same doctrine as
  the cascade's pending halt). Terminal loops answer
  `{:error, :already_terminal}`; rollout-kind rows are refused with
  `{:error, :rollout_run}` — `Lifecycle.Protocol.request_cancel/4` is the
  rollout verb, and amendment A2 splits the two by kind.
  """
  @callback cancel(loop_ref(), reason :: term(), ctx()) ::
              {:ok, :flagged}
              | {:error, :already_terminal}
              | {:error, :rollout_run}
              | {:error, :not_found}
              | {:error, term()}

  @optional_callbacks dead_letters: 3
end
