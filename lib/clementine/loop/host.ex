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
     unconsumed inputs in `park_recheck` scope exist, downgrading the park
     to a continue (status `queued` plus `enqueue_step/2`) when they do.
  2. `append/4` commits the input row, the wake (a CAS `waiting -> queued`
     that no-ops stale), and the step-job enqueue **in one atomic unit**.

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
  block lists the six step-machinery callbacks; creation needs the same
  seam, so it lives here too.

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
  """
  @callback pending(loop_ref(), limit :: pos_integer(), ctx()) :: [StoredInput.t()]

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
end
