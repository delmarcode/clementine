# RFC: Clementine Durable Loops

Status: draft v2 (post-cold-read revision)  
Scope: the outer control primitive reserved by the durable execution RFC  
Builds on: `docs/DURABLE_EXECUTION_RFC.md` (v2.2, fully implemented — SKUNK-124)  
Origin: the vocabulary reserved in that RFC, the suspend-versus-complete
discriminator, and the situated-agent thesis

## Summary

A loop is a durable receive: OTP process semantics lifted to organizational
timescale, with the host database as the mailbox.

Concretely: a loop is a *run* — the same lifecycle object the durable
execution RFC shipped — whose executions are **steps**. A step is one atomic
commit: drain pending inputs through a pure `handle/2`, fold state, and
write *everything the step caused* — consumed inputs, the new envelope,
child-run rows and jobs, outbound messages, timer schedules, and the
park/continue/finish transition — **in one atomic unit**. Dispatch is cargo
on the commit, not a phase before it; that single sentence is what makes a
loop always safely replayable, because nothing durable ever exists that the
commit did not create.

All work, and therefore all effects, live in **child rollout-runs**, each
with its own lease, fence, approval gates, and whole-rollout durability. The
loop decides; children act. Loops never build rollouts — steps emit
JSON-safe child *args*, and the host constructs the rollout at the child
boundary (the shipped worker pattern, unchanged).

Two new mechanisms are required: the **Inbox** (a durable per-loop FIFO
through which everything arrives — messages, child completions, timer
expirations) and the **step commit** (a loop-layer host operation the
shipped protocol does not have). Everything else — claiming, epochs,
fencing, heartbeats, resume tokens, requeue, transition notifications, the
reaper's sweep discipline — is the shipped machinery, reused **subject to
the explicit amendments in "Amendments To The Shipped Layer."** Draft v1
claimed verbatim reuse; the cold read proved that claim false in six places,
and this revision replaces it with an auditable amendment ledger.

### Changes from draft v1 (cold-read ledger)

Three independent cold reads (implementer-against-shipped-code,
distributed-systems, adopter-against-Meli's-real-adoption) produced
converging findings. The verified results:

- **The step is now one atomic commit** (dispatch-as-cargo). V1 dispatched
  before committing, opening a family of holes: replayed `{:send}`
  duplicates whose dedup record died with the uncommitted step; a fast
  child's early completion dropped as a "stale duplicate" during crash
  replay (stranding the parent forever); a timer whose job outlived its
  never-committed envelope entry (wedging the watcher permanently). All
  three are impossible when nothing durable precedes the commit.
- **Rollout construction moves to the child boundary.** V1's flagship
  example built rollouts (DB reads) inside `handle/2`, violating its own
  purity contract, and the validation target implied storing transcripts in
  loop state — MB-scale envelope rewrites per turn and permanent
  double-truth drift against the messages table. Actions now carry JSON-safe
  args; hosts build rollouts in the child worker; loop state holds cursors,
  not transcripts.
- **Completion delivery is exactly-once at the source.** V1 rode
  `after_transition/3` — post-commit, best-effort by the baseline's own
  definition — so a crash between a child's terminal commit and the inbox
  append stranded the parent forever, invisibly (the v1 `max_wait`
  exemption removed the only backstop). Completions now append inside the
  child's terminal projection (same transaction), and two new reaper
  verdicts make residual strands self-healing.
- **Cancellation is loop-owned.** The shipped `request_cancel`
  direct-terminalizes `waiting` runs (correct for rollouts; orphans a
  loop's children), the shipped suspend's post-CAS cancel check would
  terminalize a mid-cascade park, and no operation clears the flag. Loop
  cancel is now a kind-aware flag + wake handled by step machinery;
  `request_cancel` refuses loop-kind runs.
- **"The one change to shipped reaper behavior" was false — the ledger
  below counts six shipped-layer amendments**, including a reaper policy
  fork (the epoch-as-attempt-cap gate would terminally interrupt any
  long-lived loop on its first crashed step, and stale-`queued` handling
  would kill a loop over one lost enqueue).
- The lost-wakeup race (append landing between drain and park) is closed
  *transactionally* — the park re-checks pending inputs inside its own
  commit and downgrades to continue; append's wake serializes on the run
  row. Terminal-time sweeps close the append-races-finish and
  halt-leftover losses. Dedup consults the in-fold envelope. Poison-input
  attempts bump at drain time in a committed write (VM-death poison counted,
  not just rescued raises), with head-of-batch blame and degrade-to-one
  isolation. Loop creation, the host seam contract, tag/payload codecs, the
  adoption path for conversations (cutover, index rescope, mutation
  semantics), and the operations surface (doctor, paging signals,
  fleet-scale sweep exclusion) are all now specified — each was a named
  cold-read gap.

## The Situated-Agent Thesis

Today's agentic harnesses stand *outside* the systems they operate, talking
to applications — the things that hold real operational state — through
low-bandwidth keyholes: MCP servers, CLIs, screen pixels. But an application
is itself a textual artifact in motion, and an agent situated *within* the
application it serves — able to `execute_code` against its own host, able to
engage the app-as-text directly, able in the limit to upgrade itself — is
unhobbled in a way no keyhole protocol can match. In that world, app-to-app
integration stops being bespoke API plumbing and becomes
**situated-agent-to-situated-agent communication**: the accounting app's
agent asks the CRM app's agent about contract terms by sending it a message.

Two consequences are load-bearing here:

1. **Loop-to-loop messaging is honored as core mechanism.** A message
   between loops is an inbox append — the same verb that delivers child
   completions — deduplicated by a replay-stable causal key so the paradigm's
   communication primitive is exactly-once in effect from day one. V1 ships
   the verb; directories and cross-app transports layer on it without
   changing it.
2. **The durable execution machinery is the governance substrate that makes
   the vision grantable.** An interior agent with `execute_code` is exactly
   the agent whose effectful acts must pass approval gates, whose runs must
   be cancellable by durable flag, whose acts must fold into auditable
   terminal results. Human control is not adjacent to situated agents; it is
   their precondition. Loops add the final lever: the standing entity a
   human can message, pause, and halt.

## Changes From The Reserved Form

The durable execution RFC reserved:

```elixir
next(state) ->
  {:run, rollout} | {:parallel, [rollout]} | {:wait, suspension} | {:halt, result}
```

Receive-minded, three corrections:

- **Waiting is not an action; it is the ground state.** `{:ok, state, []}`
  with nothing in flight is the park. `{:wait, _}` is deleted.
- **The callback receives the input.** The receive clause is
  `handle(input, state)`.
- **`{:parallel, _}` dissolves.** Fan-out is emitting N tagged run actions;
  fan-in is state you keep.

And one correction v1 itself needed: actions carry **data, not structs with
module references** — `{:run, tag, args}` where args are JSON-safe, because
actions are durable cargo and rollouts are built at the child boundary.

## Reader Frame And Normative Baseline

This RFC specifies the loop layer. It inherits — normatively, by reference
to implemented code and the durable execution RFC — the lifecycle contract
(`Lifecycle`, `Facts`, `Transition`, the CAS grain, symbolic stamps, field
hygiene), `Lifecycle.Protocol` and its invariants, suspension storage and
`ResumeToken` semantics, checkpoint doctrine, transition notifications,
RunView folds, the reaper's sweep discipline, and the adapter + column
recipe + conformance-suite pattern.

Where the loop layer *changes* shipped behavior, the change appears in
**Amendments To The Shipped Layer** — the complete list, each item a
checkable claim. Anything not listed there is reuse without modification.

## Amendments To The Shipped Layer

The cold read demanded honesty here: v1 said "one change"; the truth is six.
Each amendment lands as its own reviewed change to the shipped layer, with
conformance coverage, before or alongside the loop epic's first consumer.

- **A1 — `Facts.kind`.** Facts and the column recipe gain
  `kind: :rollout | :loop` (default `:rollout`). The reaper's sweep, the
  cancel path, billing queries, and single-active indexes discriminate on
  it. (Adopters backfill existing rows to `:rollout`.)
- **A2 — `request_cancel` refuses loop-kind runs** with
  `{:error, :loop_run}`. The direct-terminal flavor orphans a loop's
  children; loop cancellation is loop-owned (see Cancellation And Halt).
  Rollout-run behavior is unchanged.
- **A3 — Reaper policy forks by kind.** For loop-kind runs: (a) stale
  `running` → **requeue always** — no `retry` opt-in, no
  `epoch < max_claims` gate (epoch counts a loop's lifetime claims; capping
  it kills loops *for having lived*; poison protection lives in the
  dead-letter machinery instead); (b) stale `queued` → new **`:reenqueue`**
  verdict (the host re-inserts the step job) instead of terminal
  `:claim_timeout` — a standing entity must not die from one lost enqueue;
  (c) `waiting` is exempt from `max_wait` **and gains two self-healing
  verdicts**: `:reconcile_children` (envelope lists a child whose run is
  terminal but whose completion input is absent → synthesize and append it)
  and `:wake_pending` (unconsumed inputs older than a threshold with the
  loop parked → wake it). These verdicts replace the backstop the exemption
  removes; every strand class becomes self-healing rather than invisible.
- **A4 — `Suspension.checkpoint` becomes nilable for `{:external, _}`
  reasons**, with a codec branch. A loop park needs the token machinery
  (resume-by-reference) but has no rollout checkpoint; its durable state is
  the envelope, which lives in its own recipe column (see The Loop Recipe).
- **A5 — Adapter: the step commit and transactional completion glue.** The
  Ecto adapter implements the loop host contract (below): `apply_step/2` as
  one transaction, `append/4` with atomic wake+enqueue, and a
  child-terminal projection helper that appends the parent's completion
  input **inside the child's terminal transaction** (exactly-once at
  source). `after_transition/3` demotes to wake-only and remains
  best-effort — which is now acceptable, because delivery is durable before
  the wake and `:wake_pending` backstops a lost one.
- **A6 — Recipe additions.** Loop columns on the run table (`kind`,
  `loop_module`, `loop_args`, `loop_policy`, `envelope`,
  `state_version`); child columns (`loop_ref`, `tag_key`) with a **unique
  index on `(loop_ref, tag_key) where active** (dedup, NOT single-active —
  fan-out is unconstrained by the machinery); the inbox table recipe (see
  The Inbox) with its `dedup_key` unique index.

## Governing Invariants

1. **A loop is a run** (`kind: :loop`): same facts, same state machine, same
   fencing. Its executions are steps; the epoch counts claims (crashed and
   continued steps included — the epoch is execution identity, not a
   completed-step counter).
2. **`handle/2` and `init/1` are pure** over their arguments: no reads, no
   clocks, no randomness. Actions are JSON-safe data; **all construction
   happens at host boundaries** — rollouts in the child worker, payload
   decoding at the seam.
3. **The step is one atomic commit.** Consumed inputs, attempts/dead-letter
   marks, the new envelope, child rows and jobs, sends, timer schedules,
   and the transition (park, continue, or finish-with-sweep) commit
   together or not at all. Dispatch is cargo, not a phase. Corollary:
4. **A loop is always replayable.** Nothing durable exists that a committed
   step did not create, so a crashed step replays from unchanged inputs
   through pure decisions to an identical commit. No effect fence exists at
   the loop level because it structurally cannot be needed.
5. **Waiting is the ground state; the inbox is the only wake source.** Two
   atomicity sentences govern the boundary: *(a)* append + wake + step
   enqueue commit as one atomic unit; *(b)* a park re-verifies
   pending-emptiness inside its own commit and downgrades to continue if
   inputs exist. Together they close every lost-wakeup interleaving at the
   lock, and `:wake_pending` backstops the substrate that cannot honor them
   perfectly.
6. **Input handling is effectively once; completion delivery is
   exactly-once at source.** Inputs: at-least-once delivery, consumption in
   the step commit. Completions: appended in the child's terminal
   transaction, which fires exactly once because terminals are dead ends.
7. **Dedup consults the in-fold envelope** (stored envelope ⊕ actions
   accumulated earlier in this drain), never the stored envelope alone —
   "not yet recorded" and "no longer live" are different answers. Tags are
   unique among *live* children/timers (re-arming a fired timer tag is
   legal); completions and elapses for unknown tags **dead-letter, never
   silently drop** (they are evidence, possibly of a deploy inside a crash
   window).
8. **Cancellation cascades down cooperatively and never propagates up
   automatically.** Loop cancel is a kind-aware flag + wake; the step
   machinery runs the cascade (cancel children, drain terminals, finish
   last). A child's failure or interruption arrives as an ordinary
   completion input — the parent decides.
9. **No selective receive.** Arrival order (commit-visibility order per
   loop); defer-in-state if you must.
10. **State and payloads are JSON-safe; structs are doors.** State crosses
    storage via `dump/1`/`load/1` (identity default); tags and payloads are
    terms encoded by a canonical, stable codec (see Tags And Payloads);
    the substrate owes nothing to Postgres.
11. **No silent loss, ever.** Every input ends exactly one of: consumed, or
    dead-lettered (poison, unknown-tag, terminal-time sweep, post-terminal
    append). Dead letters are retained evidence with an observable rate.
12. **Loop-to-loop send is durable, per-recipient ordered, and deduped by a
    replay-stable causal key** — exactly-once in effect within a substrate,
    at-least-once with the same key across substrates.

Inherited and restated: the session is the loop's state and it is a fold —
of inputs at the loop level, of terminal child results (by cursor, not by
copy) for history. And the discriminator: mid-operation parks are rollout
suspensions; between-turn parks are loop waits.

## Vocabulary

- **Loop** — the behaviour module (decision logic) plus the persisted spec
  (`loop_module`, `loop_args`, `loop_policy` columns). Inert; animated by
  steps.
- **Step** — one claim-cycle: claim → load → bump-attempts → drain → one
  atomic commit. Short by construction; the work lives in children.
- **Input** — what wakes a loop:
  `{:message, payload} | {:completed, tag, Result.t()} | {:elapsed, tag} |
  {:input_failed, input_ref, Error.t()}`.
- **Action** — what a step emits:
  `{:run, tag, child_args :: map()} | {:timer, tag, at | ms} |
  {:cancel_timer, tag} | {:send, loop_ref, payload}`.
- **Tag** — correlation and idempotency key for children/timers; a term,
  canonically encoded to `tag_key` for indexes and envelope maps.
- **Inbox** — the durable per-loop FIFO (host table, library semantics).
- **Envelope** — machinery-owned durable wrapper: envelope version, app
  `state_version`, dumped state, live children (`tag_key → child run ref`),
  pending timers, pending halt (during cascade), aggregated usage.
- **Step commit** — the loop layer's atomic host operation (see The Loop
  Host Contract).
- **Dead letter** — a retained, marked input that will never be consumed;
  always observable, never a crash and never a jam.

## The Behaviour

```elixir
defmodule Clementine.Loop do
  @callback init(args :: map()) ::
              {:ok, state :: term(), [action()]} | {:halt, Clementine.Result.t()}

  @callback handle(input(), state :: term()) ::
              {:ok, state :: term(), [action()]}
              | {:halt, Clementine.Result.t(), state :: term()}

  @callback dump(state :: term()) :: map()     # default: identity (state is a map)
  @callback load(map()) :: state :: term()     # default: identity

  @optional_callbacks dump: 1, load: 1
end
```

- **Purity is the contract for `init/1` and `handle/2` both.** No reads
  (not even "referentially stable" ones — a config row is not stable across
  a deploy), no clock, no randomness. Everything a decision needs must
  arrive in the input payload or live in state; everything it wants done is
  action data. Hosts that need request-time data put it in the payload at
  append time or load it in the child worker at spawn time.
- `init/1` runs inside the **first step**, not at creation: create inserts
  the row `queued`; the first claim runs init (state ← init, actions
  dispatched as cargo) and then drains whatever the inbox already holds, in
  one commit. Init's actions get a synthetic causal ref (`:init`).
- `{:halt, result}` finishes through the terminal path, cascading first if
  children are in flight (see Cancellation And Halt). A loop's terminal
  `Result.Completed` carries `output` (the halt's summary), empty
  `messages`, nil `input_message`, and machinery-aggregated `usage`; hosts
  discriminate loop terminals by `Facts.kind`.
- `state_version` is declared via `use Clementine.Loop, state_version: n`
  and recorded per commit. A version the current code cannot `load/1` fails
  the step as loop-level **`:incompatible_state`** — a distinct path from
  input dead-letters (inputs are innocent of deploys): the loop parks with
  an operator-visible error fact until upgraded code deploys or the host
  chooses a terminal. A reserved `handle_upgrade/2` is the `code_change`
  analog (shape non-final). The same clean-failure doctrine covers a
  renamed `loop_module` (`:incompatible_spec`) — module names persist in
  the spec columns and share checkpoint doctrine's deploy honesty.

### Tags And Payloads

Tags and payloads are terms, but they persist — so they encode through a
canonical, stable codec (`Clementine.Loop.Codec`): JSON scalars pass
through; tuples encode as tagged arrays; atoms whitelist through the loop
module's declared vocabulary. `tag_key` (the canonical string form) is what
indexes, envelope maps, and idempotency keys use. The worked examples keep
tuple tags; the codec is why that is legal.

## The Loop Host Contract

The loop layer's analog of the two-function lifecycle — the seam v1 never
specified. The Ecto adapter implements all of it; hand-written hosts get the
same conformance battery.

```elixir
defmodule Clementine.Loop.Host do
  @callback apply_step(StepCommit.t(), ctx :: term()) ::
              {:ok, Facts.t()} | {:error, :stale} | {:error, term()}

  @callback append(loop_ref, Input.t(), dedup_key :: String.t() | nil, ctx) ::
              {:ok, :appended} | {:ok, :duplicate} | {:ok, :dead_lettered}
              | {:error, :not_found} | {:error, term()}

  @callback pending(loop_ref, limit :: pos_integer(), ctx) :: [StoredInput.t()]
  @callback bump_attempts([input_ref], ctx) :: :ok
  @callback build_child(Facts.t(), tag, child_args :: map(), ctx) ::
              {:ok, Clementine.Rollout.t()} | {:error, term()}
  @callback enqueue_step(loop_ref, ctx) :: :ok
end
```

`StepCommit` is a value (the pure step core computes it): the guarded
transition (expect/set including the envelope and, on finish, the `Result`),
the consumed input refs, dead-letter marks, terminal-sweep flag, and the
dispatch cargo — child specs `{tag_key, child_args}`, sends
`{target, payload, dedup_key}`, timer schedules/cancellations.

**The two atomicity sentences (normative):**

1. `apply_step/2` executes the *entire* StepCommit — CAS transition,
   envelope, consumption, marks, child rows *and their jobs*, sends, timer
   jobs, terminal sweep — **in one atomic unit**, and when the commit's
   intent is park, it re-verifies inside that unit that no unconsumed
   inputs exist, downgrading park to continue when they do.
2. `append/4` commits the input row, the wake (a CAS `waiting → queued`
   that no-ops stale), and the step-job enqueue **in one atomic unit**.

On Postgres both are one transaction (Oban jobs are rows; the run-row CAS
serializes append against park). Substrates that cannot honor sentence 1's
re-check perfectly leans on `:wake_pending` — correctness degrades to
bounded latency, never to loss. Redis-shaped hosts implement the unit with
their own primitives (MULTI/Lua); the sentences are the contract, not the
SQL.

`build_child/4` is where rollouts come from: the host loads whatever the
JSON-safe `child_args` reference (agent config, history by cursor) and
constructs the `Rollout` — in the child's worker, at spawn execution time,
exactly like the shipped worker pattern. The loop never holds a rollout.

## The Step

```
1. Claim (Protocol.claim — kind :loop; deadline from loop_policy).
2. Load: envelope from the envelope column; load/1 the state (version
   check → :incompatible_state path on mismatch); if facts.cancel is set,
   enter cascade mode instead (see Cancellation And Halt).
3. Bump attempts: one small committed write marking the drained batch's
   HEAD input attempt+1 (the Oban fetch-increment analog — counted even if
   this VM dies mid-step). Head at K → dead-letter it + synthesize its
   {:input_failed} before draining. After any failed step, the next step
   drains with batch = 1 until a commit succeeds (poison isolation:
   innocents behind a poison head never accumulate attempts).
4. Drain: up to batch-cap inputs in order through init-or-handle, folding
   state and accumulating actions; dedup against the IN-FOLD envelope;
   unknown-tag completions/elapses divert to dead-letter marks; stop early
   on halt (undrained inputs stay unconsumed for the post-cascade sweep).
5. Compute the StepCommit (pure): envelope', consumption, marks, cargo,
   and the transition — park (nothing pending, nothing halting), continue
   (backlog remains → status queued + enqueue_step), or finish (halt with
   no children → result + terminal inbox sweep to dead-letter).
6. apply_step — the one atomic unit. Post-commit only: transition
   notifications, telemetry. Crash anywhere before it: the reaper requeues
   (A3a), the identical inputs re-drain, purity converges, cargo keyed by
   (loop_ref, tag_key) and dedup_keys no-ops.
```

The step runner is `Clementine.Loop.Runner.step/2` with the closed outcome
union `{:parked, facts} | {:continued, facts} | {:finished, facts} |
{:discard, reason} | {:error, term}`; the host's step worker maps it exactly
as the run worker maps `Runner.execute/2`.

## The Inbox

- **Recipe**: `loop_ref`, ordered id, `kind`, `payload` (jsonb, codec-
  encoded), `dedup_key` (nullable, **unique per loop where present**),
  `inserted_at`, `attempts`, `dead_at`, `dead_reason`. Consumed rows delete
  (default) or mark; dead letters are always retained (host owns TTL/GC —
  and the GDPR answer: dead letters are host rows, host deletes them).
- **Append contract**: dedup_key hit → `{:ok, :duplicate}` (webhook retries
  and re-sent loop messages land here); terminal loop → row inserted
  directly as dead-lettered, `{:ok, :dead_lettered}` — the caller *knows*
  (a webhook can ack-and-alert; a sender loop can react).
- **Ordering**: per-loop FIFO in commit-visibility order (the only order a
  concurrent-append world honestly has). No priorities; model urgency in
  state.
- **Effectively-once**: consumption rides `apply_step`. Redelivery happens
  only for steps that died pre-commit, which replay identically.
- **Dead letters**: head-attempts at K (default 3, policy); `{:input_failed,
  ref, error}` synthesized once, itself subject to the same threshold,
  never recursing. Plus the non-poison classes: unknown-tag evidence,
  terminal-time sweep, post-terminal appends — each with a `dead_reason`.
- **Backpressure honesty**: append never refuses; sustained input above
  cap × step-rate grows the inbox. The telemetry section names per-loop
  depth and oldest-unconsumed-age as the paging signals; a depth ceiling
  with load-shedding is deliberately host policy.

## Children

- **Spawn** is cargo: `apply_step` inserts the child run row (+ job) with
  `loop_ref` and `tag_key`, unique-indexed on `(loop_ref, tag_key) where
  active` — a **dedup** index; fan-out is unconstrained by the machinery
  (emit five run actions, five children run; a chat loop that wants
  one-at-a-time expresses that in `handle/2`, where it belongs).
- **Rollout construction** happens in the child worker via
  `build_child/4` from the JSON-safe args. History flows by cursor: the
  args say "messages through N"; the worker loads them from the messages
  table. One source of truth; no envelope transcripts; no drift.
- **Completion** is exactly-once at source: the child's terminal projection
  (inside its terminal transaction) appends `{:completed, tag, result}`
  with dedup_key `"completed:" <> tag_key <> ":" <> child_ref`;
  `after_transition` merely wakes. Reaper-interrupted children take the
  identical path (the interrupt is a terminal transition with a
  projection). `:reconcile_children` (A3c) synthesizes the append if a
  host's projection glue was missing or a non-transactional substrate
  dropped it.
- **Usage** aggregates into the loop's envelope as completions fold — and
  billing queries exclude loop-kind rows (`Facts.kind`) or they will count
  every token twice; the adoption section repeats this out loud.

## Timers

Cargo like everything else: `apply_step` inserts the timer job atomically
with the envelope entry recording it. Fire → `append` of `{:elapsed, tag}`
(dedup_key `"elapsed:" <> tag_key <> ":" <> schedule_id`). `cancel_timer`
cargo removes the envelope entry and best-effort-cancels the job — a fire
that races the cancel appends an elapsed whose tag is no longer pending:
dropped by the in-fold dedup, never seen by `handle/2`. Live-key lifetime:
a fired or cancelled tag is immediately re-armable (the watcher's `:poll`
is legal). Timers of terminal loops dead-letter on arrival with
`dead_reason: :terminal` — distinguishable noise.

## Loop-To-Loop Messaging

`{:send, target_loop_ref, payload}` as cargo, and
`Clementine.Loop.Protocol.send(host, loop_ref, payload, opts)` for host code
(the webhook's verb is `append` with the provider's message id as
dedup_key; `send` is sugar over it for loop callers).

The dedup key for loop-emitted sends is **replay-stable and
causally derived**: `"send:" <> sender_ref <> ":" <> causal_input_ref <>
":" <> action_index` — stable across crash replay (same input, same pure
decision, same index), unique across genuine re-sends (new causal input).
Within a substrate the target's unique index makes delivery exactly-once in
effect; across substrates the key travels with the message and the far
side's inbox enforces it. Addressing, authorization, and transport across
trust boundaries are host meaning; an MCP `send_message` tool wrapping this
verb is the accounting-agent-to-CRM-agent story.

## Creation

```elixir
Clementine.Loop.Protocol.create(host, spec, opts) ::
  {:ok, Facts.t()} | {:ok, :already_exists, Facts.t()} | {:error, term()}
```

Insert-or-get, idempotent on the host's scope key (recipe ships a unique
`loop_scope` column pattern: `("thread", mailbox_id, thread_key)` for the
email agent; `("conversation", id)` for chat). The row lands `queued` with
the spec persisted (`loop_module` as string, `loop_args` JSON, policy);
`init/1` runs in the first step. Webhook-safe under provider retries by the
scope key alone; the first message rides the same request as an `append`
after create returns.

## Cancellation And Halt

- **Cancel** is loop-owned: `Loop.Protocol.cancel(host, loop_ref, reason)`
  sets the kind-aware flag (a plain guarded write, legal in `waiting` for
  loop-kind) and wakes. `request_cancel` refuses loop runs (A2). The flag
  survives crashes; only cascade completion clears it (the finish).
- **Cascade mode** (entered at step 2 when the flag is set, or when a drain
  hits `{:halt, ...}` with children in flight): the machinery — not
  `handle/2` — `request_cancel`s live children (cargo), parks with the
  pending result held in the envelope, and on each wake folds arriving
  completions into the envelope (usage included) without invoking
  `handle/2`. Non-completion inputs arriving mid-cascade stay unconsumed.
  When `children` empties: finish — result (the halt's, or
  `Result.cancelled(reason)`), terminal projection, and the **terminal
  sweep**: every remaining inbox row dead-letters in the same atomic unit.
  Nothing is silently retained (invariant 11); the loop's terminal is last,
  after its children's, at every level.
- Children are guaranteed to reach terminals under shipped belts (their own
  cancel flavor, deadline, reaper), so the cascade always completes;
  `:reconcile_children` covers the delivery of those terminals.

## Worked Examples

### The thread agent

```elixir
defmodule Meli.ThreadAgent do
  use Clementine.Loop, state_version: 1

  # state: %{"agent_id" => id, "cursor" => n}  — a cursor, never a transcript

  def init(%{"agent_id" => agent_id}) do
    {:ok, %{"agent_id" => agent_id, "cursor" => 0}, []}
  end

  def handle({:message, %{"email_id" => email_id}}, state) do
    args = %{
      "agent_id" => state["agent_id"],
      "email_id" => email_id,
      "history_through" => state["cursor"]
    }

    {:ok, state, [{:run, {:reply, email_id}, args}]}
  end

  def handle({:completed, {:reply, _}, %Result.Completed{} = r}, state) do
    # The child already sent the reply — via a tool, behind the approval
    # gate if policy demands — and its projection appended the new
    # messages to the messages table. The loop advances its cursor:
    {:ok, %{state | "cursor" => state["cursor"] + length(r.messages) + 1}, []}
  end

  def handle({:completed, {:reply, id}, %Result.Failed{error: e}}, state) do
    {:ok, state, [{:timer, {:retry, id, e.code}, :timer.minutes(5)}]}
  end

  def handle({:completed, {:reply, id}, %Result.Interrupted{}}, state) do
    # Pod died mid-reply: decide. Here: try once more, immediately.
    {:ok, state, [{:run, {:reply_retry, id}, retry_args(state, id)}]}
  end

  def handle({:completed, {:reply, _}, %Result.Cancelled{}}, state) do
    {:ok, state, []}
  end

  def handle({:elapsed, {:retry, id, _code}}, state) do
    {:ok, state, [{:run, {:reply_retry, id}, retry_args(state, id)}]}
  end

  def handle({:input_failed, _ref, _error}, state) do
    # Poison evidence: park a note for the operator via a child, or ignore.
    {:ok, state, []}
  end
end
```

Every failure the design showcases has a clause; the child worker's
`build_child/4` turns `args` into a Rollout by loading the agent and the
messages through the cursor. Days pass between clauses; deploys pass between
clauses; the loop does not care.

### The judge loop

Run → judge (a pure function of the completion) → re-run with feedback args
threading the cursor, `{:halt, result}` on pass or attempts exhausted.
Verifier's durable, final form.

### The watcher

`init` arms `{:timer, :poll, ...}`; `{:elapsed, :poll}` spawns a read-only
child; its completion decides notify-or-sleep and re-arms `:poll` (legal —
live-key lifetime). A cron with memory and judgment.

### The script path

```elixir
{:ok, result} = Clementine.Loop.run_local(JudgeLoop, %{"prompt" => "..."})
```

`run_local` simulates production shape: an in-memory inbox with the same
FIFO/consumption semantics, children executed via the ephemeral runner *but
their completions enqueued as inputs* (the hop is modeled, so ordering
matches production), timers on a virtual clock that jumps to the next
deadline when the loop is otherwise idle. Deterministic for evals; same
behaviour module production runs.

## Adoption Path: Conversations As Loops

The validation target, stated with its costs — the adopter read proved the
v1 claim of "natural collapse" hid four product decisions. They are
decisions, not surprises:

- **Same table, kind-discriminated.** Conversation loops live in the runs
  table with `kind: :loop`. The existing single-active-per-conversation
  index **retires** (a loop is permanently active by design); its two jobs
  move to their successors — enqueue-time duplicate protection to the loop's
  `(loop_ref, tag_key)` dedup index and the loop scope key, and
  one-turn-at-a-time to `handle/2` logic (chat spawns the next child only
  after the previous completes).
- **Busy-ness becomes queueing — a product change, chosen.** Today a second
  message is rejected (`:active_run_exists`); loop-world *queues* it and
  answers in order. If the product wants rejection, the mutation checks the
  host-queryable busy surface (live child rows + inbox depth — both host
  columns, no envelope spelunking) before appending. The RFC's default is
  queue, because a durable agent that drops your second email is wrong.
- **History stays in the messages table.** Loop state holds a cursor
  (see the worked example); child projections keep appending messages
  exactly as today. No backfill of transcripts into envelopes, no
  double-truth, no MB-scale step commits. Edits/regenerations remain
  message-table operations plus a cursor-adjusting input.
- **Mutations re-map**: `sendMessageStream` returns the loop ref and the
  turn tag; the child ref for streaming resolves via the host's
  `(loop_ref, tag_key)` lookup as it spawns (one extra hop, dwarfed by model
  latency — accepted in Alternatives). Sync `sendMessage` awaits the
  completion by subscribing to the child's terminal notification, a host
  correlation the adapter's glue exposes. `cancelRun` targets the *current
  child* (cancels the turn); nothing user-facing may cancel the loop —
  loop cancel is the conversation-deletion path, which becomes: cancel →
  cascade drains → terminal sweep → delete rows. Deletion is asynchronous
  now; that is the honest price of children with real effects in flight.
- **Cutover**: per-conversation flip on quiescence. Conversations with no
  active run adopt on their next message (create loop, append). Active
  turns finish under the old path first; parked approval turns block their
  conversation's flip until resolved (they resolve by the existing
  approval machinery). No retroactive envelope surgery, no dual-write
  window.
- **Billing**: exclude `kind: :loop` rows from usage sums or count twice.

## Operations

- **Paging signals** (telemetry ships them; the walkthrough wires them):
  per-loop inbox depth and oldest-unconsumed-input age (the stuck detector),
  dead-letter creation rate by `dead_reason`, step duration and batch size,
  `:reconcile_children`/`:wake_pending` firing rates (should be ~zero on
  Postgres; nonzero is a substrate or glue bug surfacing safely),
  appends-to-terminal rate.
- **Doctor**: `Clementine.Loop.inspect(host, loop_ref)` — decoded envelope,
  live children with statuses, pending inputs with ages, timer schedule,
  spec/version facts. Frozen-conversation diagnosis is one function call,
  not jsonb spelunking.
- **Fleet scale**: parked loops are one cheap row each; the reaper's
  rollout sweep excludes loop-kind rows in SQL (A1), and the loop sweep
  (the two A3c verdicts) runs on its own slower cadence over loop rows
  only. Dormant loops cost storage, not compute; "hibernation" is what
  `waiting` already is.

## Failure Matrix

| # | Scenario | Mechanism | Outcome |
|---|----------|-----------|---------|
| L1 | Step crashes anywhere before commit | one-atomic-commit + A3a requeue-always | identical replay; cargo no-ops on tag/dedup keys; no duplicate children, sends, or timers |
| L2 | Deploy during a weeks-long park | state_version / loop_module checks | `:incompatible_state`/`:incompatible_spec` — parked visibly, never a crash; upgrade or host-chosen terminal |
| L3 | Appends race each other and the wake | append's atomic insert+wake+enqueue; claim CAS | one step drains all, FIFO commit-visibility order |
| L4 | Append lands between drain and park | park's in-commit pending re-check → downgrade to continue | never parked with pending inputs; `:wake_pending` backstops imperfect substrates |
| L5 | Fast child completes during crash window; replay re-drains spawn + completion | in-fold dedup | replayed spawn re-records the tag before its completion is judged: delivered once, dropped never |
| L6 | Timer fires against a never-committed schedule / after cancel | schedule is cargo (cannot precede its envelope entry); in-fold dedup for cancel races | no wedge; no ghost elapsed to `handle/2` |
| L7 | Poison input, including VM-killing payloads | drain-time attempts bump (committed) + head blame + batch-1 degrade + K dead-letter + non-recursive `{:input_failed}` | mailbox never jams; innocents never dead-letter; decision layer informed |
| L8 | Loop cancelled with children in flight | kind-aware flag + machinery cascade | children terminal first (their own belts guarantee it), loop terminal last, terminal sweep leaves nothing behind |
| L9 | Halt with children in flight / inputs behind the halt | cascade + terminal sweep in the finish's atomic unit | drained-to-terminals; leftovers dead-lettered with reasons, never silently retained |
| L10 | Append races the finish / arrives after terminal | finish's in-unit sweep; append-to-terminal returns `:dead_lettered` | sender observes the outcome; nothing lost silently |
| L11 | Zombie step after requeue | epoch fence for writes; cargo keys for dispatch | lifecycle writes `:stale`; re-dispatch no-ops on `(loop_ref, tag_key)` and dedup keys |
| L12 | Child interrupted by pod death | child reaper interrupt → terminal projection appends completion | parent decides; delivery exactly-once at source, `:reconcile_children` as belt |
| L13 | Completion glue lost (non-transactional substrate, missing projection) | `:reconcile_children` sweep | synthesized completion; strand self-heals, firing rate is the alarm |
| L14 | Inbox burst | batch cap + continue (atomic re-enqueue) | bounded steps, strict order; depth/age telemetry pages before users do |
| L15 | Crash between resume and step enqueue | append's atomic unit prevents it; A3b `:reenqueue` covers residuals | loop never dies of `:claim_timeout` |
| L16 | 1000-step loop crashes once | A3a: no epoch cap for loops | requeued; longevity is not a death sentence |
| L17 | Deploy inside a crash window changes `handle/2`'s decision | old cargo already committed or nothing did (one-commit); unknown-tag completions dead-letter | divergence surfaces as evidence, not silent drops |
| L18 | Impure `handle/2`/`init/1` | outside the contract | protocol state stays consistent; replay convergence forfeited by the app alone |

## Alternatives Considered

- **Dispatch as a pre-commit phase** (draft v1). Rejected by three
  independent interleavings (replayed sends, dropped early completions, the
  wedged watcher): any durable effect preceding the commit is a dedup
  problem the commit cannot retroactively own. One atomic commit, cargo
  model.
- **Completion delivery via `after_transition/3`** (draft v1). Rejected:
  post-commit best-effort loses completions permanently against dead-end
  terminals. Projection-transactional append + reconcile sweep.
- **Transcripts in loop state** (draft v1's implication). Rejected: per-step
  envelope rewrites of full histories, TOAST/WAL amplification on the
  hottest table, and permanent double-truth against the messages table.
  Cursor in state; construction at the child boundary.
- **Rollout structs in actions** (draft v1). Rejected: actions are durable
  JSON cargo; structs carry module refs and defeat purity. `child_args` +
  `build_child/4`.
- **Cancel via the shipped `request_cancel`** (draft v1's inheritance).
  Rejected: both shipped flavors orphan children (direct-terminal on
  waiting; suspend's post-CAS conversion mid-cascade). Kind-aware flag,
  loop-owned cascade.
- **Cancel as an inbox input.** Considered as the pure alternative;
  rejected: FIFO delivery makes "stop" wait behind fifty queued inputs. The
  flag reads at claim, ahead of the drain.
- **`{:wait, _}` as an action; selective receive; ETF state;
  GenServer-resident loops; inline child execution** — as in v1, rejected
  or deferred for the same reasons, now with `run_local` modeling the hop
  so script and production semantics agree.

## Non-Final

- `handle_upgrade/2` shape; dead-letter K default; per-step batch cap
  default; loop deadline defaults in `loop_policy`.
- `LoopView` (the fold for dashboards) — `inspect/2` covers operations
  first.
- Send-key exposure for host-initiated appends (today: caller-supplied
  dedup_key); loop directories; cross-app transports.
- Atom-vocabulary declaration ergonomics for the codec.
- Per-loop budgets (deadline pattern is the template; usage is already
  aggregated).

## Initial Epic Shape

1. **Amendments A1–A4** to the shipped layer, each with conformance
   coverage (kind, cancel refusal, reaper fork + two loop verdicts,
   nilable checkpoint).
2. **Pure step core**: drain/fold/dedup/StepCommit computation —
   property-tested with unfiltered op sequences; the in-fold dedup and
   head-blame rules live here.
3. **Loop host contract + Ecto implementation** (A5–A6): `apply_step` as
   one transaction with the park re-check, atomic `append`, recipes,
   codec.
4. **`LoopCase` conformance battery** — first tests, by name: the
   park-vs-append interleaving and the crash-replay early-completion
   (the two the cold read said must lead), then the full matrix.
5. **Step runner + creation + cascade** on the protocol.
6. **Child glue**: projection append helper, `build_child` seam, dedup
   index, usage aggregation.
7. **Timers** on the scheduler seam.
8. **Send** verb + causal keys.
9. **`run_local`** with modeled hop + virtual clock.
10. **Telemetry + doctor + walkthrough** (thread agent with full clauses,
    judge, watcher; the operations signals wired).
11. **Meli validation**: conversations-as-loops per the Adoption Path —
    including the queue-vs-reject product decision made explicitly — and
    the email agent on the same module; graduate this RFC's designed rows.
