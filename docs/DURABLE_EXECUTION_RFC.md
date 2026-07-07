# RFC: Clementine Durable Execution Model

Status: draft v2.2 (CAS revision)  
Scope: greenfield Clementine API design  
Origin: Meli integration learnings, especially Oban-backed turn execution  
Supersedes: v1, which sketched a five-callback lifecycle protocol

## Summary

Clementine should model agent work as inert definitions animated by explicit
execution machinery, with durability guaranteed by a single mechanism: every
lifecycle write is a compare-and-swap against the host application's own
storage.

An agent is a capability definition. A rollout is one inner agent execution
spec. A run is one durable attempt to execute that rollout. A runner turns the
crank. The host app owns product storage and process boundaries; Clementine
owns the lifecycle semantics needed to execute safely — and, in this revision,
ships them as a pure protocol core the app cannot easily get wrong, plus an
Ecto adapter and a conformance suite so most apps never hand-roll the
mechanics at all.

This RFC treats the current Clementine API as primordial learning-only design.
Compatibility with the current `Clementine.Loop` and GenServer-backed
`Clementine.Agent` APIs is not a design constraint.

### Changes from v1

- The lifecycle protocol is regrained. Apps no longer implement five
  operations (claim/heartbeat/suspend/finish/cancellation); they implement a
  two-function behaviour (`fetch` + `apply`) with compare-and-swap semantics.
  The five operations survive as library-internal `Protocol` functions built
  on that behaviour.
- Lease fencing is specified: a `lease_epoch` guard on every write, with
  loss discovered at write time rather than detected proactively.
- Suspension is confronted as what it is — a durable checkpoint of rollout
  progress — with a concrete `Checkpoint`/`Suspension`/`ResumeToken` design.
- The runner algorithm gains the missing paths: suspended (no finish),
  rescued exceptions (fail fast), lost lease (write nothing), graceful drain.
- Event ordering across executions is specified as `(epoch, seq)`, and
  Clementine owns the canonical fold from events to a live `RunView`.
- The reaper (stale-run reconciliation) and its interruption-reason taxonomy
  are promoted to standardized mechanism.
- Verifiers exit the inner loop and become the first worked outer-loop
  control example.
- An Ecto lifecycle adapter, a column recipe (not a managed table), and a
  generated conformance suite are v1 deliverables, not future options.
- `Session` leaves the ontology; the execution-graph model is demoted to a
  future-work appendix, keeping only epoch-stamped resume references.
- New sections: failure matrix, telemetry, deadlines and usage accounting,
  effect fence, proven-versus-designed tagging, and a scorecard against the
  design's own evaluation criteria.

### Changes from the cold-read review (v2.1)

Three independent cold reads (implementer, distributed-systems, and adopting-
app lenses) were run against v2.0. The verified findings produced these
revisions:

- A `requeue` transition (`running -> queued`) now exists, making fence-gated
  same-run retry mechanically possible; v2.0 promised the policy while the
  state machine had no path for it. Drain prefers requeue over terminal
  interrupt when the effect fence is unset.
- `Protocol.suspend` re-checks the cancel flag after its own CAS, closing the
  interleaving where a cancel request lands just before a suspend and would
  otherwise strand a "cancelled" run in `waiting`.
- The event scheme is split: `(epoch, seq)` stamping applies to execution
  events only; lifecycle transitions reach observers as transition
  notifications through the lifecycle's own `apply` (post-commit hook), and a
  terminal notification *closes* the RunView fold — v2.0's epoch-comparison
  rule could never drop a post-reap zombie's events because no successor
  epoch exists after a reap.
- Reaper judgment is status-scoped: the Oban job cross-check is meaningless
  for `waiting` runs (their job completed legitimately at suspend) and would
  otherwise have interrupted every suspension at the first sweep; deadline
  checks apply to `running` only; `queued` runs get a claim-timeout check via
  a new `Facts.queued_at`.
- Field hygiene rule: a transition clears every field whose meaning does not
  survive into the target status (`suspend` clears `executor_id`, `deadline`,
  `heartbeat_at`).
- Timestamps in transitions are symbolic (`:now`) and resolved by the host
  `apply` against the storage clock, removing a hidden node-clock/database-
  clock split at claim time.
- Terminal writes (`finish`, `suspend`) retry transient storage errors under
  a still-live heartbeat; v2.0 could silently convert a completed rollout
  into `interrupted` on a two-second database blip.
- The lease is a runtime handle carrying the lifecycle module and context, so
  leased protocol operations are self-contained (v2.0's signatures could not
  reach storage).
- Terminal transitions of every kind (`:finish`, `:interrupt`, control-plane
  cancel) carry the `Result`, so the app projection fires uniformly —
  including for reaped runs.
- Normative shapes added: approval resume payloads, `Completed.input_message`
  (so history-as-fold does not silently drop user input), the runner's return
  union, `Clementine.run/3` and `stream/3` contracts, checkpoint/token
  assembly responsibilities (rollout body, runner cursor, protocol token),
  and the resume-token security posture (staleness defense, not
  authorization).
- A Host Integration Walkthrough replaces the bare worker example: migration,
  atomic enqueue, worker return mapping, reaper scheduling, drain wiring, and
  the approval round trip.
- A Normative Baseline section scopes what this document specifies versus
  what it inherits from the existing library (canonical messages, tool
  contract, providers).

### Changes from implementation (v2.2)

- `Protocol.suspend` stamps `queued_at: :now` alongside its field-hygiene
  clears (found implementing SKUNK-131, confirmed by review). Suspend is a
  transition into an unowned state exactly like resume and requeue, which
  both already stamped, so `queued_at` now uniformly records when the run
  last entered its current unowned state. This is what makes the reaper's
  `max_wait` ceiling implementable at all: v2.1 specified the ceiling over
  suspension age while no fact recorded suspension time, and measuring
  from an enqueue-era `queued_at` could expire a just-parked run whose
  pre-claim queue wait exceeded a short ceiling. Each suspension gets its
  own `max_wait` window; the queued-scope claim-timeout check is
  unaffected because resume re-stamps on the way back to `queued`.

## Reader Frame

This is not an implementation ticket and not a narrow API sketch. It is a
design RFC for Clementine's next shape, written so that a cold read leaves an
implementer with every durable-execution concept, invariant, and boundary
needed to build it — and enough rationale to improvise where the text is
silent. The inner rollout substrate (message structs, tool contract, provider
clients) is inherited from the existing library rather than re-specified
here; the Normative Baseline section below draws that line precisely.

A reader should come away understanding:

- What problem space Clementine is trying to occupy.
- Why the current API shape is insufficient for real applications.
- Which pieces Meli proved are general-purpose runtime mechanics.
- Which pieces should remain host-app product logic.
- The lifecycle contract, its fencing model, and why it is safe.
- How suspension, resume, and approval work end to end.
- Which decisions are directional and which are intentionally non-final.

This document assumes the reader is comfortable with Elixir/Phoenix, OTP,
Oban-like durable execution, LLM tool loops, and the vocabulary of classical
distributed systems (leases, fencing tokens, at-most-once commits). It does
not assume familiarity with Meli or the existing Clementine codebase.

### Normative Baseline

This RFC is the specification for the durable-execution layer. The inner
rollout substrate is the existing library, adopted wholesale as the baseline
and renamed per this document. The following are normative by reference to
that code, not re-specified here:

- **Canonical message structs** — `UserMessage`, `AssistantMessage`,
  `ToolResultMessage` and their content blocks (`Text`, `ToolUse`,
  `ToolResult`), plus their canonical JSON serialization. That serialization
  lands on main with SKUNK-125 (it was written for SKUNK-113 but sat
  unmerged on a branch while Meli main already called it), is stable, and is
  what checkpoints embed; checkpoint
  `version` (see Checkpoints And Suspension) versions the *checkpoint
  envelope*, and bumps whenever the embedded message encoding changes.
- **The tool contract** — `use Clementine.Tool` with name, description, a
  validated parameter schema, and `run(args, context)` returning
  `{:ok, content} | {:ok, content, meta} | {:error, message}`, normalized
  into `Clementine.ToolResult`. This RFC adds only the `approval`/`retry`
  metadata fields.
- **`ToolRunner`** — parallel tool execution with per-tool timeouts, crash
  normalization, and telemetry. This RFC layers batch-level behavior on it
  (approval gating, cancellation kill policy) without changing its execution
  semantics.
- **`Clementine.Usage`** — token accounting as accumulated from provider
  responses.
- **The provider layer** — Anthropic/OpenAI clients, streaming parsers, the
  retry-safe `ProviderStream`, and the model registry. The error
  *normalization tables* move up into `Clementine.Error` (see Errors And
  Results); the wire handling does not change.
- **The Gather → Act loop mechanics** — today's `Clementine.Loop` iteration
  logic, minus verifiers, renamed `Rollout`.

An implementer building from scratch needs that source alongside this
document; an implementer evolving the existing library needs only this
document.

## The Shape In One Page

The simplest consumption must stay one line:

```elixir
{:ok, %Clementine.Result.Completed{} = result} = Clementine.run(agent, "prompt")
```

Under that line sit the same nouns production uses — a `Rollout` built from
the agent and prompt, a `Run` around the rollout, the `Runner`, and an
ephemeral in-memory lifecycle. Scripts and evals never see them unless they
ask.

A production Phoenix app uses the same nouns explicitly. Its Oban worker:

```elixir
Clementine.Runner.execute(run,
  lifecycle: MyApp.ClementineLifecycle,
  events: MyApp.ClementineEvents,
  executor_id: "oban:#{job.id}:#{node()}"
)
```

Its lifecycle implementation is two functions (or a `use` of the Ecto adapter
plus one projection function — the projection being the product rows the app
writes at terminal commit). Its run table is its own table, carrying a recipe
of standard columns. Its correctness is checked by a generated
conformance suite. Everything else — claim, heartbeat, fencing, suspension,
resume, terminal commit, reaping, event ordering, the live-view fold — is
library mechanism.

The rest of this document earns that page.

## Context

### What Clementine Is Trying To Be

Clementine is an Elixir library for building LLM agents that use tools. The
initial implementation came from a pragmatic intuition: the useful primitive
is not a sprawling chain framework. It is an agentic rollout: call a model,
execute tool calls, feed tool results back, and continue until a terminal
answer or limit.

That intuition still holds, but the first incarnation overfit to "agent as
GenServer process" and "stream as caller-owned enumerable." That is fine for
experiments. It is not enough for applications where agent work must survive
browser disconnects, pod shutdown, worker restarts, approval pauses, and
multi-tenant runtime configuration.

This RFC keeps the good part of Clementine's origin: directness, ordinary
data, plain Elixir, and a small conceptual surface. It discards the accidental
part: process-owned agents as the primary abstraction, `Loop` as the name for
both inner rollout and outer control loop, and verifier retry as a hidden
control mechanism inside the inner loop.

### What Meli Is

Meli is the Phoenix application that forced these design questions into the
open. It integrates Clementine into user- and workspace-owned agents,
DB-backed conversations, Phoenix Channels and GraphQL, Oban jobs on
Kubernetes, and Postgres as the durable application database.

Meli is not the product Clementine should hard-code. It is the compass,
because it exposed which integration problems appear when an agent library is
used by a normal Phoenix/Postgres/Oban app rather than by an in-memory demo.

The relevant Meli machinery, as actually built:

- A user message creates a queued `conversation_runs` row and an Oban job,
  with a partial unique index enforcing one active run per conversation.
- The worker claims the run under a row lock, marks it running, and starts a
  15-second heartbeat process.
- The worker constructs Clementine config from app-owned agent data, identity,
  tools, model selection, and conversation history, then calls the streaming
  loop primitive directly.
- Stream events are broadcast over PubSub to SSE and Channel observers, and
  accumulated (with sequence numbers) in a node-local ETS draft cache
  (`ActiveRunCache`) so reconnecting observers can snapshot mid-run state.
- On success, generated messages are appended and the run is completed in one
  transaction.
- A periodic reconciler (`RunReconciler`) marks runs interrupted on stale
  heartbeat, and cross-checks Oban job state (missing, cancelled, discarded,
  completed without a terminal run) into a small taxonomy of interruption
  codes.
- `max_attempts: 1`: a failed or interrupted turn is never automatically
  re-executed, because tools may already have caused effects.

Important negative facts, preserved from v1 because they shaped the design:

- Meli does not persist every token to Postgres.
- Meli does not have a Clementine-owned run table.
- Meli does not treat Oban job state as product truth.
- Meli does not automatically replay a turn after infrastructure failure.

And two facts v1 glossed over, recorded here for honesty:

- Meli never implemented cooperative cancellation. A cancel function exists,
  but no user-facing mutation calls it and the running worker never polls it;
  a mid-run cancel only bites when the terminal commit fails its status
  transition. The cancellation protocol below is designed, not proven.
- Meli's fencing is implicit: terminal states are dead ends in its transition
  table, so a zombie worker's commit fails the status check. This RFC
  generalizes that accident into an explicit mechanism.

### Existing Clementine Lessons

First, the inner model/tool loop is real. Repeatedly calling an LLM, executing
tools, feeding results back, and producing final messages is a coherent unit.
That unit survives as `Rollout`.

Second, `Clementine.Agent.stream/2` has the wrong ownership semantics for real
apps. It ties execution lifetime to the stream consumer. Meli needed clients
to observe execution without owning it, which pushed Meli to call the
lower-level stream primitive from a server-owned Oban worker.

Third, Clementine lacked a durable execution protocol. Meli had to build
claiming, heartbeat, stale-run reconciliation, terminal-state mapping, stream
fanout, active draft state, atomic terminal commit, and error normalization.
Many of those are runtime semantics Clementine should name, standardize, and
— this revision adds — implement, so that the nth app does not rebuild them.

Fourth, the current loop is Gather → Act → Verify: a `Verifier` subsystem can
reject a final answer and force a retry with feedback, inside the same loop.
That is a control mechanism living one floor below where control belongs. Its
disposition is settled in this revision (see Verifiers And The Inner/Outer
Boundary).

Fifth, the library already contains seeds this design grows from:
`Loop.continue/3` (resume a loop from prior messages) prefigures checkpoint
resume; `ProviderStream` retries a provider call only if no bytes have reached
the consumer, prefiguring the effect fence (see Attempts, Retries, And The
Effect Fence); and the telemetry taxonomy
(`[:clementine, :loop | :llm | :tool, ...]`) prefigures run-level telemetry.

## Motivation

Meli proved that real Phoenix apps need more than an in-memory agent process
and a consumer-owned stream. It also proved something sharper, which v1 of
this RFC missed: naming lifecycle semantics is not enough. If Clementine
specifies claim/heartbeat/finish as callbacks and leaves the implementation to
each app, every app re-derives the same subtle concurrency code — the
compare-and-swap claim, the lease guard on terminal commit, the reaper race —
and some of them get it wrong. The library would keep the easy forty lines
(the runner's orchestration) and outsource the hard two hundred.

The design goal is the Oban virtue: an opinionated, clean execution surface
that is neither a bag of low-level callbacks nor a sprawling conceptual
universe. This revision pursues it by shrinking the app-facing contract to the
smallest surface that can be made mechanically safe, and shipping the safety
apparatus (adapter, column recipe, conformance suite) as first-class
deliverables.

## Design Ethos

The desired API should feel more like idiomatic Elixir than a framework that
smuggles a private runtime model behind macros.

Principles:

- Prefer ordinary data over hidden processes.
- Prefer explicit execution over magical `use`-macro ownership.
- Prefer small nouns with strong meanings over generic extension points.
- Preserve host-app ownership of product schemas.
- Make the safe production path clear, not mandatory for every script.
- Put subtle mechanics in the library; put meaning in the app. If a piece of
  code is easy to get wrong under concurrency, apps should not be writing it.
- Let runtime construction be first-class.
- Keep the core small enough that a reader can hold the model in their head.
- Do not prematurely generalize tool metadata, graph traversal, or outer-loop
  step semantics before production use sharpens them.

A macro is acceptable exactly when it removes mechanical mapping without
hiding the mental model, and the de-sugared form remains public and
documented. The Ecto adapter below is the worked example; the rejected
Oban-worker macro remains the counterexample.

## Governing Invariants

These sentences govern the design. Later sections are elaborations.

1. **The terminal result is truth; events are advisory projections.**
   Anything an observer derives from events must be re-derivable from the
   terminal `Result` plus lifecycle `Facts`. This is why live-only event
   delivery is acceptable, why the event log need not be durable, and why an
   application's conversation history is a fold of terminal run results
   rather than of event streams.
2. **Every lifecycle write is a guarded compare-and-swap.** No lifecycle
   state changes unconditionally. The guard is `(status, epoch)`.
3. **Lease loss is discovered, not detected.** No component ever "knows" it
   holds a valid lease; it finds out at its next write. Heartbeat frequency
   bounds discovery latency; the epoch guard makes late discovery harmless.
4. **An epoch identifies one execution.** `claim` is the only operation that
   increments it. Events, writes, and fencing all key off it.
5. **Suspension is a checkpoint.** A run may leave `running` without
   finishing only by durably storing everything needed to continue.
6. **Resume is snapshot restoration, not deterministic replay.** Clementine
   trusts checkpoints; it does not re-derive them from history.
7. **Two-tier failure handling.** In-process exceptions are rescued and
   finished as `failed` immediately, with a normalized error. Process death
   writes nothing and is reaped after the stale threshold. There is no third
   tier.
8. **Finish fires at most once per run.** Terminal states are dead ends. The
   suspend path does not finish.
9. **Heartbeat proves liveness, not progress.** Progress is bounded
   separately, by `max_iterations` and a wall-clock deadline.
10. **Whole-rollout durability is the default quantum; checkpoints refine
    it.** V1 checkpoints only at suspension. The future tool-call ledger is
    the same mechanism at higher frequency, not a second system (see One
    Mechanism, Two Frequencies).

## Prior-Art Triangulation

### Oban

The strongest Elixir reference. Oban gives apps a coherent job runtime —
persistence, reliability, observability — while product data remains product
data, and workers remain ordinary modules. Clementine borrows the posture:
productize the execution protocol for agent runs without turning application
conversations into Clementine's product. Where Clementine differs: Oban owns
`oban_jobs` because jobs are its product; agent runs overlap with app product
rows, so Clementine ships a column recipe for the app's own table instead of
owning one. Reference: [Oban docs](https://hexdocs.pm/oban/Oban.html)

### Ecto.Multi

Explicit, inspectable composition of transactional work: one module builds a
value describing what must commit together; the integration boundary executes
it. V1 applied this only to terminal commit. This revision applies it to the
whole protocol: Clementine's pure core computes a fully-specified `Transition`
value; the app executes it atomically. Reference:
[Ecto.Multi docs](https://hexdocs.pm/ecto/Ecto.Multi.html)

### Temporal

The maximal end of the spectrum: deterministic replay, event history as
truth, a service owning execution state. Clementine deliberately stops short —
snapshot checkpoints instead of replay, host-owned persistence instead of a
service — and this RFC records the consequences honestly (checkpoint
versioning instead of replay determinism). Reference:
[Temporal Workflow docs](https://docs.temporal.io/workflows)

### Fencing Tokens And Epochs

The lease design is the classical fencing-token construction (Kleppmann's
formulation of the stalled-lease-holder problem), as deployed in Kafka
producer epochs, Raft terms, and Chubby sequencers: a monotonic number issued
with ownership, checked on every write, so a stale owner's writes are rejected
rather than raced. Postgres is the arbiter; no consensus machinery is needed.
Event ordering borrows the same trick: `(epoch, seq)` is Raft's
`(term, index)`.

### OpenAI Agents SDK

A small primitive set — agents, tools, handoffs, sessions, runner — useful out
of the box, customizable underneath. Clementine's nouns differ because
Elixir/Phoenix/Oban pressure points differ, but the shared lesson holds: a
small set of strong primitives beats both bare model calls and overgrown graph
frameworks. Reference:
[OpenAI Agents SDK docs](https://openai.github.io/openai-agents-python/)

### Loop Engineering

The reason `Loop` is reserved for the outer control primitive. The
higher-leverage unit is the system one floor above the rollout: find work,
hand it out, check it, record state, decide the next action. Reference:
[Loop Engineering](https://addyosmani.com/blog/loop-engineering/)

## Problems To Solve

The problems, and where this document resolves each:

| #  | Problem | Resolved in |
|----|---------|-------------|
| 1  | Consumer-owned streaming is the wrong production default | Runner Algorithm; Events And Observation |
| 2  | No durable run protocol | The Lifecycle Contract |
| 3  | Terminal messages and terminal state need one commit boundary | The Lifecycle Contract (`:finish` projection) |
| 4  | Stream events need ordering | Events And Observation (`(epoch, seq)`) |
| 5  | Cancellation must be cooperative, not only process death | Cancellation |
| 6  | Provider errors need stable normalized shape and retryability | Errors And Results |
| 7  | Approval and external waits require suspend/resume by reference | Checkpoints And Suspension |
| 8  | Parent/child work needs graph-shaped references eventually | Appendix: Execution Graph (deferred); ResumeToken (kept) |
| 9  | Runtime-defined agents and rollouts must be normal | Runtime Construction |
| 10 | `Loop` must split into `Rollout` and outer `Loop` | Vocabulary; Verifiers And The Inner/Outer Boundary |
| 11 | Zombie executors must not corrupt state | Fencing And Lease Loss |
| 12 | Reconnecting observers need mid-run state | Events And Observation (RunView) |
| 13 | Stale runs must be reaped with a stable reason taxonomy | The Reaper |
| 14 | Liveness is not progress; runaway runs must be bounded | Deadlines, Budgets, And Usage |
| 15 | Apps must not hand-roll the subtle mechanics n times | Deliverables: Adapter, Recipe, Conformance |

Problems 11–15 are additions in this revision; Meli hit all five.

## Core Principle: Mechanism Versus Meaning

Clementine prescribes durable execution semantics, not host application
schemas.

The app owns product meaning:

- Product tables, tenancy, permissions, and user-visible run meanings.
- Whether a run is a chat turn, eval run, workflow run, or scheduled watch.
- Which users can approve a tool call, and the approval UI.
- Which product records are written at terminal commit (the projection).
- PubSub topics and channel payloads.
- Agent storage and runtime data resolution.
- The Oban worker module, queue topology, and job enqueueing.

Clementine owns execution mechanism:

- Vocabulary and state transitions.
- Epoch/lease semantics and fencing.
- The transition legality rules, computed as pure data.
- Ordered event semantics and the canonical fold to a live view.
- Result and error shapes, including retryability.
- The runner algorithm, heartbeat, and reaper judgment.
- Checkpoint, suspension, and resume-token semantics.
- The contract between execution and host persistence, plus the adapter,
  column recipe, and conformance suite that make it hard to get wrong.

This split prevents both failure modes: Clementine does not become an invasive
product schema, and apps do not repeatedly reimplement subtle execution
mechanics.

## Non-Goals

This RFC does not aim to:

- Design a general workflow engine.
- Replace Oban.
- Require Clementine-owned database tables.
- Preserve compatibility with current Clementine APIs.
- Specify every outer-loop pattern.
- Specify a rich tool-effect taxonomy up front (only `approval` and `retry`).
- Guarantee deterministic replay of arbitrary tool effects.
- Persist every streamed token to Postgres.
- Turn every app into a graph database.

The first target is durable execution of a single inner rollout, including
approval-shaped suspension, shaped so that outer loops and richer graph
introspection can grow naturally.

## Vocabulary

The vocabulary is the design. These nouns separate capability, specification,
attempt, execution ownership, terminal outcome, and outer control.

### Agent

A reusable capability definition: model selection, instructions, tools,
defaults and limits, policy/config. An agent is inert data — not a process,
and it does not execute by itself.

Naming note: `Clementine.Agent` shadows Elixir's built-in `Agent` under a bare
`alias`. The domain word is too strong to surrender; documentation should
model `alias Clementine.Agent, as: AgentDef` where the collision bites.

### Rollout

One inner agent execution spec: agent, input prompt, starting
messages/history, context, limits and options. A rollout is inert. It
describes what to try; it never contains generated assistant messages or tool
results. Today's `Clementine.Loop` becomes `Clementine.Rollout`, minus
verifiers (see Verifiers And The Inner/Outer Boundary). The inner loop is
Gather → Act, repeated.

Naming note: "rollout" is an RL loan-word (one sampled trajectory) and
collides colloquially with feature rollouts/deploys. It is kept because it is
increasingly the standard term for exactly this unit, and because the honest
alternatives are worse: `Task` collides fatally with Elixir, `Turn` is
chat-biased, `Attempt` is what `Run` means.

### Run

One durable attempt to execute a rollout: run reference, rollout spec or
reference, lifecycle facts (status, epoch, heartbeat, suspension), and
eventually a terminal result or error. The run is the lifecycle object — not
the worker, not the process.

### Facts

The library-defined, normalized view of a run's lifecycle state, produced by
the host lifecycle's `fetch`. Apps store facts in whatever columns they like;
`Facts` is the lingua franca between that storage and the protocol core.

### Transition

A fully-computed conditional write: an expectation (the CAS guard), the new
facts to set, an operation tag, and — for `:finish` — the terminal result the
app's projection consumes. Transitions are computed by the pure protocol core
and executed by the host lifecycle. They are values; they can be inspected,
logged, and tested.

### Lease

The current right to execute a run, held by exactly one execution per epoch.
Concretely: a runtime handle minted by a successful claim, carrying the
`(run_ref, epoch)` pair, executor id, deadline, any resume payload — and the
lifecycle module plus host context, so that every leased protocol operation
is self-contained. A lease is process-local and never serialized; it is not a
lock object with its own storage but knowledge of which epoch you are,
enforced by the guard on every write.

### Epoch

A monotonic integer identifying one execution of a run. Incremented by
`claim` and by nothing else. The fencing token.

### Checkpoint

Serializable rollout progress at a boundary: accumulated canonical messages,
iteration count, the pending operation, usage so far, and the event cursor. A
checkpoint is loop state, not a diff and not an event history.

### Suspension

A checkpoint plus a reason plus a resume contract (`ResumeToken`). The durable
fact that a run is parked awaiting an external decision, callback, or time.

### Result

The terminal semantic outcome of a run — a closed sum:

- `Completed`: the materialized input message, generated messages (tool
  calls and results ride inside them as content blocks), final output, usage.
- `Failed`: normalized error (with retryability) and usage.
- `Cancelled`: who/what requested the stop, and usage.
- `Interrupted`: interruption reason from the standard taxonomy, and usage.

Every variant carries usage; tokens burn on failures too.

### Event

An observable execution fact: run reference, epoch, sequence number, type,
payload. Ordered, append-only, immutable; corrections are new events.

### RunView

The canonical fold of a run's event stream into a live view: text so far,
tools in flight, usage so far, cursor. Library-owned because the event
taxonomy is library-owned. Apps store and transport RunViews; they do not
reimplement the fold.

### Runner

The interpreter that animates a run: claim, heartbeat, execute the rollout,
emit ordered events, observe cancellation and deadline, suspend or finish
exactly once, and stop cleanly on lease loss. Oban is not the runner; Oban is
one place the runner runs.

### Worker

The host process/job boundary. In Meli, an Oban worker: it loads app data,
builds agent/rollout/run values, and calls the runner. Ordinary host code.

### Loop

An outer control process, reserved for the next epic. A loop observes state
and decides the next action (shape sketch, not final syntax):

```elixir
next(state) ->
  {:run, rollout}
  | {:parallel, [rollout]}
  | {:wait, suspension}
  | {:halt, result}
```

Goal-directed loops are one family; `goal`/`evaluate`/`continue?` are not core
fields.

### Deliberately Absent Nouns

- **Session**: the lineage of interaction (conversation, eval run, workflow)
  is host-app product vocabulary. Clementine owns the canonical message
  serialization a session stores, and nothing else about it. There is no
  `Clementine.Session`, by design.
- **Store**: storage is an implementation detail of the lifecycle contract;
  naming it would pull attention toward database shape instead of execution
  semantics.
- **Step / Graph**: reserved for the outer-loop epic. See the appendix.

### Ontology

```text
Agent       = capability definition
Rollout     = what to try
Run         = this attempt to try it
Facts       = the run's lifecycle state, normalized
Transition  = one guarded write, as a value
Lease/Epoch = which execution currently owns the run
Checkpoint  = rollout progress, serialized
Suspension  = checkpoint + reason + resume contract
Runner      = interpreter that animates the run
Worker      = host process/job where the runner runs
Result      = what happened, closed sum, usage always
Event       = ordered observable fact, (epoch, seq)
RunView     = canonical fold of events into a live view
Loop        = outer controller (next epic)
```

## Run State Machine

```text
queued
  -> running      (claim; epoch increments)
  -> cancelled    (control-plane cancel before any claim)
  -> interrupted  (reaper: e.g. job vanished before claim)

running
  -> waiting      (suspend: checkpoint stored)
  -> queued       (requeue: stale + effect fence unset, per reaper policy;
                   or graceful drain before any effect)
  -> completed    (finish)
  -> failed       (finish)
  -> cancelled    (finish, after cooperative stop)
  -> interrupted  (reaper: stale heartbeat / lost executor; or runner drain
                   after effects)

waiting
  -> queued       (resume: token validated, payload stamped)
  -> cancelled    (control-plane cancel; e.g. approval denied-as-cancel)
  -> interrupted  (admin/policy: e.g. suspension expired)
```

Terminal states — `completed | failed | cancelled | interrupted` — are dead
ends with no outgoing transitions. That dead-endedness is itself a fencing
mechanism.

Design notes:

- Resume re-enters through `queued`, not directly to `running`. This keeps a
  single claim rule (`queued -> running`), lets the app re-enqueue its job in
  its own way, and makes the state machine a simple cycle:
  `running -> waiting -> queued -> running`.
- `running` covers ordinary provider calls and synchronous tool calls. A run
  is not `waiting` merely because the model is waiting on a bounded tool call
  inside the active runner. `waiting` means: no execution owns the run, and
  progress depends on something outside the system's control.
- There is no `queued -> failed`. Failure requires an execution; enqueue-time
  validation problems are app domain.
- `requeue` is the only path back from `running`, and it is evidence-gated
  exactly like a reap (stale heartbeat, or an explicit drain) plus
  effect-gated (fence unset — see Attempts, Retries, And The Effect Fence).
  It never touches a terminal state, so terminal dead-endedness — the
  fencing backstop — is preserved.
- Field hygiene: every transition clears the fields whose meaning does not
  survive into the target status. `suspend` and `requeue` clear
  `executor_id`, `deadline`, and `heartbeat_at`; `claim` overwrites all
  three. A `waiting` run has no executor, so no fact may claim one. The
  complement: every transition into an unowned state — enqueue, suspend,
  resume, requeue — stamps `queued_at`, the entry time the reaper's age
  checks read.

## The Lifecycle Contract

This is the heart of the revision. The contract has two layers:

1. A **pure protocol core** (`Clementine.Lifecycle.Protocol`) that knows every
   rule: which transitions are legal, when the epoch increments, what each
   operation expects and sets, how races resolve. It is pure — it computes
   `Transition` values and interprets `Facts` — and therefore exhaustively
   property-testable inside the library.
2. A **two-function host behaviour** (`Clementine.Lifecycle`) that executes
   those values against the app's own storage.

Apps implement layer 2. The runner, reaper, and control plane speak only to
layer 1.

### The Host Behaviour

```elixir
defmodule Clementine.Lifecycle do
  @moduledoc """
  The host application's storage contract. Two functions.

  `fetch/2` reads a run's lifecycle state into `Facts`.

  `apply/2` executes one `Transition`: atomically write `set` if and only if
  the stored facts match `expect` on `status` and `epoch`. On a `:finish`
  transition, the app's product projection (its terminal rows) must commit in
  the same atomic unit. If the guard does not match, return `{:error, :stale}`
  and change nothing.
  """

  @callback fetch(run_ref :: term(), ctx :: term()) ::
              {:ok, Facts.t()} | {:error, :not_found} | {:error, term()}

  @callback apply(Transition.t(), ctx :: term()) ::
              {:ok, Facts.t()} | {:error, :stale} | {:error, term()}
end
```

`ctx` is an opaque host context threaded from `Runner.execute/2` options
(commonly empty; useful for multi-repo or tenant routing).

The entire correctness burden on the app is one sentence: *the `apply` write
must be atomic and conditional on `(status, epoch)` exactly matching
`expect`.* The conformance suite exists to verify that sentence.

### Facts

```elixir
defmodule Clementine.Lifecycle.Facts do
  @type status ::
          :queued | :running | :waiting
          | :completed | :failed | :cancelled | :interrupted

  @type t :: %__MODULE__{
          ref: term(),
          status: status(),
          epoch: non_neg_integer(),        # 0 until first claim
          executor_id: String.t() | nil,
          heartbeat_at: DateTime.t() | nil,
          deadline: DateTime.t() | nil,
          cancel: nil | %{reason: term(), requested_at: DateTime.t()},
          suspension: Clementine.Suspension.t() | nil,
          resume: nil | %{payload: term(), resumed_at: DateTime.t()},
          effects?: boolean(),             # effect fence; see Attempts
          usage: Clementine.Usage.t() | nil,
          error: Clementine.Error.t() | nil,          # terminal :failed detail
          interrupt: Clementine.InterruptReason.t() | nil,  # terminal :interrupted detail
          queued_at: DateTime.t() | nil,   # when the run last entered an
                                           # unowned state (queued or waiting)
          finished_at: DateTime.t() | nil
        }
end
```

Apps map their columns to this struct in `fetch` and back in `apply`. The
Ecto adapter does the mapping declaratively. Statuses are atoms at the
protocol layer; storage representation (strings, integers) is the app's
business.

### Transition

```elixir
defmodule Clementine.Lifecycle.Transition do
  @type op ::
          :claim | :heartbeat | :mark_effects | :suspend
          | :resume | :requeue | :cancel_request | :finish | :interrupt

  @type t :: %__MODULE__{
          op: op(),
          run_ref: term(),
          expect: %{status: Facts.status(), epoch: non_neg_integer()},
          set: map(),                       # partial Facts to write
          result: Clementine.Result.t() | nil,  # present on every transition
                                                # into a terminal status
          meta: map()
        }
end
```

`expect` is always an exact `(status, epoch)` pair — never a set, never a
wildcard. This keeps the app's guarded write one query shape. Where an
operation must tolerate concurrent movement, the protocol core re-fetches and
recomputes; the app never loops.

`set` semantics: an absent key means *leave the stored value untouched*; an
explicitly present `nil` means *write NULL*. The core never includes a key it
does not intend to write (a heartbeat without a usage sample omits `usage`
entirely rather than nulling it). `to_columns/1` implementations translate
exactly the present keys.

Every transition into a terminal status — whether its op is `:finish`
(runner), `:interrupt` (reaper/admin), or `:cancel_request` resolving an
unowned run — carries the `Result` in `result`, and the app projection runs
for all of them uniformly. A projection that only cares about `Completed`
simply ignores the rest.

Timestamps in `set` are symbolic: the pure core writes `:now` (or
`{:now_plus, ms}` for deadlines), and the host `apply` resolves them against
the *storage* clock (in Postgres, `now()`), never the app node's clock. This
keeps the reaper's staleness arithmetic on a single time source; node-clock
skew can never make a freshly claimed run look already stale. One important
race this discipline does not cover by itself: a flag write (like a cancel
request) commutes with a status transition under an exact-pair guard, because
it changes neither status nor epoch. Therefore every protocol operation whose
*semantics* depend on a flag re-fetches after its own successful CAS — see
`Protocol.suspend` below for the case that matters.

### The Protocol Core

Runner- and control-plane-facing functions, implemented once in the library on
top of `fetch`/`apply`. Signatures and semantics:

```elixir
Protocol.claim(lifecycle, run_ref, opts) ::
  {:ok, Lease.t()}
  | {:error, :not_found}
  | {:error, {:not_claimable, Facts.status()}}
  | {:error, term()}
```

Fetch; require `status: :queued`; compute
`expect: {queued, E}, set: %{status: :running, epoch: E + 1, executor_id: id,
heartbeat_at: :now, deadline: {:now_plus, max_duration}}`; apply. The
deadline window is minted fresh at every claim (`max_duration` comes from the
rollout's limits — see Deadlines, Budgets, And Usage); a run that waited
three days for approval is not born dead on resume. On `:stale`, re-fetch
once and report `{:not_claimable, current_status}` — a lost claim race is not
an error to retry, it is the single-flight guard working. The returned
`Lease` is the runtime handle for everything that follows: `run_ref`, the new
epoch, executor id, resolved deadline, the lifecycle module and host `ctx` —
and, when the fetched facts held a suspension and resume payload,
`resume: {checkpoint, payload}` for the runner to hand to the rollout (see
The Resume Flow). Two claimers racing both read epoch `E`; one row matches
the guard; the loser gets `:stale`. No pessimistic lock is required anywhere
in the design.

```elixir
Protocol.heartbeat(lease, opts \\ []) ::
  :ok | {:error, :lost_lease} | {:error, term()}
```

`expect: {running, E}, set: %{heartbeat_at: :now}` — plus `usage:` only when
a sample is provided (absent keys are never written).
`:stale` maps to `:lost_lease` and is definitive. Any other error is treated
as transient (a database blip must not kill a healthy run); the heartbeat
process logs and retries on the next beat, and the generous stale threshold
absorbs the gap. The optional `usage` piggyback keeps `Facts.usage`
approximately current so that even interrupted runs have billing-grade
numbers.

```elixir
Protocol.cancellation(lease) ::
  :none | {:requested, reason :: term()} | {:error, :lost_lease}
```

A read: fetch, then compare. If `epoch != lease.epoch` or
`status != :running`, the lease is gone — report it so the rollout unwinds.
Otherwise report the `cancel` field.

```elixir
Protocol.mark_effects(lease) :: :ok | {:error, :lost_lease}
```

`expect: {running, E}, set: %{effects?: true}`. Called through a
runner-supplied closure *before* the first tool whose `retry` metadata (see
Attempts, Retries, And The Effect Fence) is not `:safe` executes. The fence
must be durable before the effect exists. At most one such write per run.

```elixir
Protocol.suspend(lease, %Suspension.Request{} = request) ::
  {:ok, ResumeToken.t()}
  | {:cancelled, Facts.t()}      # cancel won the race; run is terminal
  | {:error, :lost_lease}
  | {:error, term()}
```

The rollout produced the suspension *body* (reason, pending operation,
messages, iteration, usage); the runner completed the checkpoint's `cursor`
from its event stamper; `suspend` now derives the token from the lease —
`%ResumeToken{run_ref: ref, epoch: E, reason_type: type_of(reason)}` — and
persists the assembled `%Suspension{}` inside the facts it writes:
`expect: {running, E}, set: %{status: :waiting, suspension: s,
queued_at: :now, executor_id: nil, deadline: nil, heartbeat_at: nil}`
(field hygiene: a waiting run has no executor and no execution deadline —
and, like every transition into an unowned state, suspend stamps
`queued_at`, the entry time the reaper's `max_wait` ceiling measures
from). The token is
computed, not separately stored — it lives inside the suspension it
authorizes and is valid exactly while the run is `waiting` with that
suspension; see Checkpoints And Suspension for its security posture.

After its CAS succeeds, `suspend` re-fetches and checks the cancel flag. A
cancel request that won the write order just before the suspend changed
neither status nor epoch, so it cannot invalidate the suspend's guard — but
it must not strand a "cancelled" run in `waiting` with nobody left to honor
the flag. If the flag is set, `suspend` immediately resolves the freshly
parked run as a direct cancel (`expect: {waiting, E}`, terminal
`Result.Cancelled`, projection fires) and returns `{:cancelled, facts}` so
the runner knows the run is terminal, not parked. If instead the cancel
arrives *after* the suspend committed, `request_cancel` itself sees `waiting`
and takes its direct-cancel flavor. Either ordering converges on
`cancelled`; the conformance suite exercises both interleavings.

Transient (non-`:stale`) storage errors are retried bounded-with-backoff
under the still-live heartbeat, same posture as `finish` — a checkpoint that
was worth building is worth a few retries to persist.

```elixir
Protocol.resume(lifecycle, %ResumeToken{} = token, payload, ctx \\ nil) ::
  {:ok, Facts.t()}
  | {:error, :stale_reference | :run_not_waiting | :already_resumed
             | :wrong_reference_type | :not_found | term()}
```

The token names the run (`token.run_ref`); there is no separate `run_ref`
argument to disagree with it. Fetch; validate token against facts
(`status == :waiting`, `suspension` present, `token.epoch == facts.epoch`,
`token.reason_type` matches the stored suspension's reason); compute
`expect: {waiting, E}, set: %{status: :queued, queued_at: :now,
resume: %{payload: payload, resumed_at: :now}}`; apply. On `:stale`, re-fetch
and map to the precise error (`:already_resumed` if `queued`/`running`,
`:run_not_waiting` otherwise). Resume does not touch the epoch; the next
claim does. After a successful resume the app re-enqueues its job (or invokes
a runner directly) — resume never hides an enqueue.

Payload shapes are normative for approvals, opaque otherwise:

```elixir
{:approved, meta :: map()}   # e.g. %{by: user_id}
{:denied,   meta :: map()}   # e.g. %{by: user_id, message: "not in prod"}
```

On `{:approved, meta}` the resumed rollout executes the pending tool and
continues. On `{:denied, meta}` it synthesizes an error tool result carrying
`meta[:message]` (default: `"Denied by approver."`) and lets the model react.
For `{:until, t}` suspensions the payload is `:elapsed`; for `{:external, _}`
it is app-defined and delivered to the pending handler verbatim (reserved —
see Checkpoints And Suspension).

```elixir
Protocol.request_cancel(lifecycle, run_ref, reason) ::
  {:ok, :flagged} | {:ok, :finished} | {:error, :already_terminal | term()}
```

Cancellation has two flavors depending on ownership. If the run is `running`,
set the cooperative flag (`expect: {running, E}, set: %{cancel: ...}`) —
`{:ok, :flagged}`. If the run is `queued` or `waiting`, nobody owns it, so
cancel is a direct terminal transition carrying `Result.Cancelled` —
`{:ok, :finished}` (the projection fires and may write product state). On
`:stale`, the core re-fetches and re-routes between the flavors; the app
never sees this dance.

`{:ok, :flagged}` is a *delivery* promise, not an outcome promise: the run
will terminate as `cancelled`, **or** reach the terminal it was already
committing when the flag landed. A flag that arrives after the rollout's
last cancellation check but before `finish(Completed)` loses the race and
the completed work stands — standard cancel semantics, stated plainly. The
one interleaving that must never happen — flag lands, run suspends, nobody
ever honors the flag — is closed inside `Protocol.suspend` (see above).

```elixir
Protocol.finish(lease, %Result{} = result) ::
  {:ok, Facts.t()}
  | {:error, :lost_lease}
  | {:error, :already_terminal}
  | {:error, term()}
```

`expect: {running, E}, set: %{status: terminal_of(result), usage:
result.usage, error: error_of(result), finished_at: :now, ...}`, with
`result` attached for the app's projection. The app's `apply` must commit the
projection and the state write in one atomic unit; if the projection raises,
the transition must not commit (the conformance suite checks this). `:stale`
re-fetches: a terminal status maps to `:already_terminal` (the reaper won the
race), anything else to `:lost_lease`.

The terminal write is the most important write in the design, so it gets the
strongest retry posture: transient (non-`:stale`) storage errors are retried
bounded-with-backoff — and the runner keeps the heartbeat alive until the
terminal write returns, so a two-second database blip cannot convert a
completed rollout into a reaped `interrupted`. If retries exhaust, `finish`
returns `{:error, term}`, the run is eventually reaped, and the generated
messages are lost — the acknowledged residual (failure matrix row 16); the
future tool-call ledger shrinks it.

```elixir
Protocol.interrupt(lifecycle, %Facts{} = facts, %InterruptReason{} = reason) ::
  {:ok, Facts.t()} | {:error, :stale} | {:error, term()}
```

Reaper- and admin-facing: a terminal transition to `interrupted`, guarded by
the exact facts the reaper observed (`expect: {facts.status, facts.epoch}`),
carrying `result: %Result.Interrupted{reason: reason, usage: facts.usage}` so
the app projection fires for reaped runs exactly as it does for finished
ones (the usage is the heartbeat-piggybacked approximation — the best
available for a run whose executor vanished). The reason persists in
`Facts.interrupt`. If the runner finishes concurrently, the reaper's CAS
fails and that is correct — exactly one terminal writer per run, decided by
the database.

```elixir
Protocol.requeue(lifecycle, %Facts{} = facts, reason) ::   # reaper-facing
  {:ok, Facts.t()} | {:error, :stale} | {:error, :effects_present} | {:error, term()}

Protocol.requeue(lease, reason) ::                          # drain-facing
  {:ok, Facts.t()} | {:error, :lost_lease | :effects_present | term()}
```

The retry path. `expect: {running, E}, set: %{status: :queued,
queued_at: :now, executor_id: nil, deadline: nil, heartbeat_at: nil}`.
Refused outright when `facts.effects?` is set — re-executing a rollout whose
tools already touched the world is exactly what this design exists to
prevent; `mark_effects` writes the fence durably *before* the first unsafe
tool runs, so a fence-unset run is re-executable from scratch by
construction (an in-flight `retry: :safe` tool at requeue time is tolerable
by that tool's own declaration). The epoch is untouched — the next claim
increments it, and because the epoch counts claims it doubles as the attempt
counter: reaper policy caps retries with `facts.epoch < policy.max_claims`,
no extra field required. A zombie from epoch `E` is fenced by status the
moment requeue commits (`running` no longer matches), and by epoch again
after the next claim. The reaper-facing flavor fires only on the same
evidence as an interrupt (stale heartbeat) with the fence unset and policy
opted in; the lease-facing flavor is the drain path (see Runner Algorithm).
The app default remains no-retry (`policy: retry: :never`), preserving
Meli's `max_attempts: 1` posture until an app opts in.

### Epoch Semantics

One rule: **`claim` increments the epoch; nothing else does.** An epoch
therefore names one execution. Everything else falls out:

- A zombie executor from epoch `E` cannot write once epoch `E + 1` exists,
  even though the status is `running` again — the status alone would match,
  the epoch does not. This is the case (suspend → resume → re-claim) where
  status-only guards are insufficient and epochs earn their keep.
- The reaper does not need to bump anything: `interrupted` is terminal, and
  dead-end statuses reject all writes by the status half of the guard.
- Resume does not need to bump anything: `waiting -> queued` linearizes
  concurrent resumes by status alone, and the token pins the epoch it came
  from.
- Requeue does not need to bump anything either: the status change alone
  fences the old executor, and the claim that follows mints the new epoch.
  Because every execution begins with a claim, `epoch` is also the attempt
  count — which is what lets requeue policy cap retries without a new field.
- Events inherit execution identity for free (see Events And Observation).

### A Hand-Written Lifecycle, In Full

What a host app writes if it skips the adapter — the honest floor of the
contract (~60 lines):

```elixir
defmodule Meli.ClementineLifecycle do
  @behaviour Clementine.Lifecycle
  import Ecto.Query
  alias Clementine.Lifecycle.{Facts, Transition}
  alias Clementine.Result
  alias Meli.{Repo, Conversations}
  alias Meli.Conversations.ConversationRun

  @impl true
  def fetch(run_id, _ctx) do
    case Repo.get(ConversationRun, run_id) do
      nil -> {:error, :not_found}
      run -> {:ok, to_facts(run)}
    end
  end

  @impl true
  def apply(%Transition{} = t, ctx) do
    Repo.transaction(fn ->
      with {:ok, run} <- cas(t),
           :ok <- project(t, run, ctx) do
        to_facts(run)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The one subtle line in the module. The conformance suite fails
  # loudly if either half of the guard is missing.
  defp cas(%Transition{run_ref: id, expect: expect, set: set}) do
    from(r in ConversationRun,
      where: r.id == ^id,
      where: r.status == ^to_db_status(expect.status),
      where: r.lease_epoch == ^expect.epoch,
      select: r
    )
    |> Repo.update_all(set: to_columns(set))
    |> case do
      {1, [run]} -> {:ok, run}
      {0, _} -> {:error, :stale}
    end
  end

  # Every terminal transition carries a Result (finish, interrupt, direct
  # cancel); project the variants you care about, ignore the rest.
  defp project(%Transition{result: %Result.Completed{} = r}, run, _ctx) do
    Conversations.append_run_messages!(run, r.messages)
    :ok
  end

  defp project(_transition, _run, _ctx), do: :ok

  defp to_facts(run), do: %Facts{ref: run.id, status: ..., epoch: run.lease_epoch, ...}

  # Writes exactly the keys present in `set`; resolves symbolic :now and
  # {:now_plus, ms} against the database clock (fragment("now()")).
  defp to_columns(set), do: ...
  defp to_db_status(atom), do: Atom.to_string(atom)
end
```

Notes for implementers:

- The guarded `UPDATE ... RETURNING` is the whole concurrency story. Rowcount
  zero means the guard failed; the protocol core interprets why.
- `apply` may special-case ops for efficiency: a `:heartbeat` transition has
  no projection and can skip the wrapping transaction (a single `UPDATE` is
  already atomic).
- Large values (`suspension`) may live in a side table with a pointer column;
  `apply` owns that choice invisibly.

## Fencing And Lease Loss

The classical problem: a runner stalls (GC pause, network partition, suspended
VM), the reaper declares it dead, a new execution begins, and then the old
runner wakes up and writes. The classical answer is the fencing token, and the
lifecycle contract above already contains it. This section names the layers
and their division of labor.

**Correctness layer — the epoch guard.** Every write is conditional on
`(status, epoch)`. A fenced executor's writes return `:stale`, no matter how
late it wakes or how wrong its clock is. Safety requires no clock agreement
whatsoever.

**Liveness layer — heartbeat plus reaper.** The heartbeat writes
`heartbeat_at` (database clock, single time source) every interval; the reaper
interrupts runs whose heartbeat is older than the stale threshold. Defaults
inherited from Meli's production values: 15-second beat, 2-minute threshold —
eight missed beats before reaping, generous enough to absorb transient
database unavailability. These tune *how fast* failure is noticed, never
*whether* state stays consistent.

**Discovery, not detection.** No component ever affirmatively knows its lease
is valid. The heartbeat process discovers loss when its write returns
`:stale`; the runner discovers loss when heartbeat tells it, or at its own
next write (`mark_effects`, `suspend`, `finish`). Discovery latency is bounded
by the heartbeat interval; the epoch guard makes any latency harmless.

**In-runner propagation.** The heartbeat runs as a linked process started by
the runner. On `:lost_lease` it sends `{:clementine, :lease_lost, lease}` to
the runner and stops. The rollout's blocking points — the provider-stream
receive loop and the tool-await loop — additionally match that message and
unwind with `:lost_lease`, aborting the in-flight HTTP stream. The runner then
exits without finishing: there is nothing it is allowed to write, and the run
is already interrupted or re-owned.

**Zombie events.** Events are not database writes, so the guard cannot fence
them. Two mechanisms do, covering the two zombie cases:

- *A successor execution exists* (suspend → resume → re-claim): every event
  carries its execution's epoch, and consumers discard events from an epoch
  lower than the highest seen. The old executor's stragglers are dropped at
  zero cost, with no per-emit database check.
- *No successor will ever exist* (the run was reaped — `interrupted` is
  terminal, so no higher epoch is ever minted): epoch comparison alone can
  never drop these. The terminal transition itself is what silences them —
  every transition, including the reaper's, flows through the app's `apply`,
  whose post-commit notification (see Transition Notifications) *closes* the
  RunView fold. A closed view rejects all further events at or below its
  final epoch. Between the reap and that notification reaching an observer
  there is a window in which a partitioned-but-alive zombie can stream ghost
  deltas; they touch nothing durable, and closure ends them.

**Stated tradeoff.** A runner partitioned from Postgres for longer than the
stale threshold gets reaped while possibly still streaming tokens. Its work
is lost; its terminal commit fails; state never splits. Stated fully: until
that zombie discovers loss at a write or its observers see the closing
notification, users can watch ghost output from a run whose durable state is
already `interrupted`, and any `retry: :safe` tool it had in flight runs to
its own timeout — bounded by the deadline and `max_iterations` it carries.
A zombie that never set the effect fence cannot start its first unsafe tool
(`mark_effects` is a guarded write and fails); one that set the fence before
the partition can continue effectful work until its local deadline — the
honest worst case of trusting a stalled executor for one deadline window.
That is the chosen side: at-most-once terminal commit per run, never
split-brain, with bounded ghost work as the worst case of a full partition.

**Rejected alternatives.** `pg_advisory_lock` (lease silently dies with the
connection; hostile to PgBouncer transaction pooling). Wall-clock lease expiry
checked runner-side (trusts the runner's clock; epochs trust no one).
`SELECT ... FOR UPDATE` claiming (works — Meli proves it — but adds lock
management the optimistic CAS makes unnecessary).

## Checkpoints And Suspension

Meli's proven durability quantum is the whole rollout: a turn either commits
terminally or it never happened. Suspension necessarily breaks that quantum —
a run parked for approval is mid-rollout by definition. The design therefore
confronts what v1 deferred: **suspension is a checkpoint mechanism**, and the
checkpoint is the durable representation of rollout progress.

### Checkpoint

```elixir
defmodule Clementine.Checkpoint do
  @type t :: %__MODULE__{
          version: pos_integer(),          # format version; see Doctrine below
          rollout_id: String.t(),
          iteration: non_neg_integer(),
          messages: [Clementine.LLM.Message.t()],  # canonical, serializable
          pending: Clementine.Pending.t(),
          usage: Clementine.Usage.t(),
          cursor: {epoch :: non_neg_integer(), seq :: non_neg_integer()}
        }
end
```

`messages` is the full canonical message list accumulated so far — bounded in
practice by the model's context window, so column storage is acceptable and a
side table is an escape hatch, not a requirement. Canonical message
serialization already exists in the library and is load-bearing here (see
Normative Baseline for its guarantees).

`pending` is what execution stopped on. For the v1 approval case:

```elixir
%Clementine.Pending.ToolApproval{
  tool_use_id: "tu_abc",
  tool_name: "delete_records",
  args: %{...},
  completed_results: %{"tu_xyz" => %Clementine.ToolResult{...}}
}
```

`completed_results` handles parallel tool batches cleanly: when one call in a
batch is gated, the ungated siblings execute and their results ride in the
checkpoint. Nothing is discarded, and nothing unsafe re-executes on resume.

### Suspension And ResumeToken

```elixir
%Clementine.Suspension{
  reason:
    {:approval, %Clementine.ApprovalRequest{...}}
    | {:external, tag :: term()}
    | {:until, DateTime.t()},
  checkpoint: Clementine.Checkpoint.t(),
  token: %Clementine.ResumeToken{
    run_ref: term(),
    epoch: non_neg_integer(),      # the suspending execution's epoch
    reason_type: :approval | :external | :until
  }
}
```

Assembly is split by who knows what. The **rollout** produces a
`%Clementine.Suspension.Request{}` — reason, pending operation, messages,
iteration, usage — because only it knows the loop state; it never sees the
lease. The **runner** completes the checkpoint's `cursor` from its event
stamper. **`Protocol.suspend`** derives the token from the lease and
persists the assembled `%Suspension{}`. The token is computed at that
moment, not separately stored — it lives inside the suspension it
authorizes.

The token is a *staleness* defense, not an authorization mechanism.
`Protocol.resume` validates it against current facts — the run is `waiting`,
the suspension exists, the epochs match, the reason type matches — so stale
approvals, double-fires, and cross-wired references die with precise errors
(`:stale_reference`, `:already_resumed`, `:run_not_waiting`,
`:wrong_reference_type`) instead of corrupting state. But its fields
(`run_ref`, epoch, reason type) are guessable, it carries no secret, and it
must never be treated as permission: *who may resume* is app meaning,
enforced by the app before it calls `resume` — and for that reason the token
is not broadcast in the event stream (see Event Taxonomy). Apps read it from
the stored suspension when building their approval surface. This is the
load-bearing kernel of v1's execution-graph section, extracted and kept; the
rest of that section moved to the appendix.

Reason-type scope for this epic: rollouts produce only `{:approval, _}`
(gated tools). `{:external, tag}` is reserved for app- and loop-initiated
waits (next epic); `{:until, t}` is reserved for scheduled waits, and its
wake-up is app-scheduled — the app schedules its own job for `t` that calls
`resume(token, :elapsed)`; nothing in Clementine owns a timer. The reaper's
`:suspension_expired` is the policy ceiling over *all* waits, distinct from
the wake-up path. Pending shapes beyond `Pending.ToolApproval` are
deliberately unspecified until those reasons activate.

### The Resume Flow

1. Rollout execution reaches a point requiring external completion (a gated
   tool call). It returns `{:suspend, %Suspension.Request{}}` to the runner.
2. The runner completes the checkpoint cursor and calls
   `Protocol.suspend(lease, request)`: `running -> waiting`, assembled
   suspension stored via the app's `apply` (whose transition notification
   is the app's cue to build its approval surface), heartbeat stops, job
   completes normally. **No finish occurs.** Only after the suspend commits
   does the runner emit the advisory `approval_requested` event — an
   approval UI must never precede a durable suspension.
3. The app notifies its approvers however it likes; the suspension facts —
   including the token — are queryable from its own storage.
4. A decision arrives. The app authorizes the caller (its meaning, its
   rules), then calls
   `Protocol.resume(lifecycle, token, {:approved, %{by: user_id}})`
   (or a `{:denied, meta}` payload): `waiting -> queued`, payload stamped.
5. The app enqueues a new job — explicitly; Clementine never hides an
   enqueue.
6. The new job's runner claims the run (`queued -> running`, epoch `E + 1`).
   The lease carries `resume: {checkpoint, payload}`.
7. `Rollout.execute(rollout, resume: {checkpoint, payload}, ...)` restores the
   loop: messages from the checkpoint, iteration counter preserved, and the
   pending operation resolved by the payload — approved: execute the tool now,
   merge with `completed_results`, feed the tool-result message, continue
   gathering; denied: synthesize an error tool result carrying the denial and
   let the model react (apologize, propose alternatives).
8. The rollout proceeds to a terminal result; the runner finishes normally.

Denial semantics are app meaning: the payload decides whether denial becomes a
tool result the model sees (default), or the app instead cancels the waiting
run outright via `Protocol.request_cancel/3`. Approval timeout is likewise app
policy: resume-with-denial, cancel, or admin interrupt (`:suspension_expired`)
— Clementine supplies the levers, not the policy.

The current library's `Loop.continue/3` (re-enter the loop from prior
messages) is the direct ancestor of step 7 and should be absorbed by it.

### Doctrine: Snapshot, Not Replay

Clementine restores checkpoints; it does not replay history to re-derive
state. This is the deliberate anti-Temporal position, and it has one honest
cost: a deploy can change the checkpoint format or tool semantics between
suspend and resume. Hence `version` on the checkpoint. When the version (or
a named tool) is no longer understood, `Rollout.execute/2` surfaces it
through its normal error channel —
`{:error, %Clementine.Error{kind: :rollout, code: :incompatible_checkpoint,
retryable?: false}}` — never a bare atom, never a crash; decode failures
take the same path. The app chooses the recovery: accept the `failed`
terminal, or start a fresh rollout from the original spec.

### One Mechanism, Two Frequencies

Checkpoint-on-suspend (this epic) and checkpoint-every-iteration (the future
tool-call ledger, enabling resume-from-last-checkpoint retries) are the same
mechanism at different cadences. Nothing in `Checkpoint` assumes suspension —
it is loop state at a boundary, `pending` merely records which boundary.
Implementers extending toward the ledger should add frequency, not structs.

## Events And Observation

### Ordering: `(epoch, seq)`

The stream carries **execution events only** — things an executor observes
while animating a rollout. Lifecycle transitions travel a different road
(Transition Notifications, below), because three of them — resume, reaper
interrupt, direct cancel — happen with no execution alive to stamp a
sequence number, and inventing one would break the single-writer rule.

An execution event's identity is `{epoch, seq}`: the epoch of the execution
that emitted it, and a runner-local sequence number, gapless and monotonic
within the epoch. Total order is lexicographic. This is Raft's
`(term, index)` applied to observation, and it buys three properties at once:

- **Ordering across suspend/resume** without any durable counter: each
  execution numbers its own events; the epoch orders executions.
- **Superseded-executor fencing for free**: consumers drop events from any
  epoch lower than the highest they have seen, so once a successor execution
  speaks, the old executor's stragglers vanish without a database check. (A
  *reaped* run never mints a successor — those zombies are silenced by fold
  closure instead; see Transition Notifications.)
- **Reconnect cursors**: an observer resumes from `{epoch, seq}` and discards
  anything at or below it.

Sequence numbers are assigned by the single active execution (the runner owns
a stamper closed over a counter). Gaps *across* epochs are expected and
meaningless; gaps *within* an epoch indicate loss in the transport, which
live observers may ignore and the RunView fold tolerates.

### The Sink

```elixir
defmodule Clementine.Events do
  @callback emit(Clementine.Lease.t(), Clementine.Event.t()) ::
              :ok | {:error, term()}
end
```

Delivery is separate from lifecycle storage. Apps implement `emit` with
PubSub, an ETS draft cache, a durable log, a trace exporter, or any
combination. Emit is advisory by invariant 1: the runner ignores error
returns, isolates raises (rescue + log), and never lets delivery affect
execution. `Clementine.Events.Null` ships for the ephemeral path.

Durability tiers remain the app's choice: live-only; live plus RunView cache;
durable event log. Nothing in the protocol requires persistence, because
nothing derived from events is truth.

### Transition Notifications

Every lifecycle transition — runner-driven or not — flows through the app's
`apply`. That makes `apply` the one universal observation point, and the
Ecto adapter exposes it:

```elixir
@callback after_transition(Facts.t(), Transition.t(), ctx :: term()) :: any()
# invoked post-commit, outside the transaction; failures logged, never raised
```

Apps broadcast transition notifications from this hook over their own
channels (in Meli: the same PubSub topics the SSE and Channel layers already
consume). Notifications need no sequence numbers — a notification *is* the
new facts, and `(status, epoch)` orders itself; a consumer holding facts at
epoch 5/`waiting` simply replaces them with epoch 6/`running`. This is how
observers learn about resume, reap, and direct cancel — transitions no
executor was alive to announce — and it is the mechanism that **closes** a
RunView (below) when the terminal transition lands. Hand-written lifecycles
get the same effect by broadcasting inside their own `apply` wrapper.

### Event Taxonomy

Execution events, grounded in the current library's de facto vocabulary,
stamped with `{epoch, seq}`:

```text
iteration_start {n}
text_delta {content}
tool_use_start {tool_use_id, name}
tool_input_delta {tool_use_id, content}
tool_result {tool_use_id, result, is_error}
approval_requested {tool_use_id, name, args}    # no token — see ResumeToken
usage_delta {input_tokens, output_tokens}
error {normalized}
```

There are deliberately no `run_started`/`run_finished` events in this
stream: lifecycle facts travel as transition notifications, so a single app
subscription is typically "this run's execution events + this run's
transition notifications" on one topic. `approval_requested` carries no
resume token — the token is a control-plane reference read from stored
facts by authorized code, not broadcast to every observer. Exact payload
fields are non-final; the identity/ordering envelope and the
execution/transition split are decided.

### RunView: The Canonical Fold

Clementine owns the event taxonomy, therefore Clementine owns the canonical
reduction from events to a live view:

```elixir
view = Clementine.RunView.new(run_ref)
view = Clementine.RunView.apply(view, event)   # pure; drops stale epochs/seqs
view = Clementine.RunView.close(view, facts)   # terminal notification arrived
```

`RunView` carries: status hint, current epoch, last seq (the cursor),
in-progress content blocks (assembled text per index), tool calls in flight,
usage so far, and last-event timestamp. `close/2` pins the terminal facts;
a closed view rejects every further event at or below its final epoch —
which, since a reaped run never has a higher epoch, is what finally silences
a post-reap zombie's stream. The reconnect story becomes uniform: snapshot
the stored RunView, subscribe to events and notifications, apply and close
as they arrive, let the fold discard duplicates, stale epochs, and
post-closure ghosts.

Meli's `ActiveRunCache` shrinks to storage and transport of a library-computed
value — which is the point: the fold was the subtle part, and it was being
rebuilt per app.

## Errors And Results

One normalized error shape, produced at the provider boundary and at the
runner's rescue site, carried in `Result.Failed` and in error events:

```elixir
%Clementine.Error{
  kind: :provider | :tool | :rollout | :runtime,
  code: atom(),          # :rate_limited | :overloaded | :auth | :invalid_request
                         # | :deadline_exceeded | :max_iterations
                         # | :incompatible_checkpoint | :exception | ...
  provider: :anthropic | :openai | nil,
  message: String.t(),   # safe for operators; apps decide user-facing copy
  retryable?: boolean(),
  raw: term()            # original payload, for logs; never for display
}
```

Retryability is decided at normalization time using the knowledge currently
buried in the provider clients (429/529/5xx retryable; auth and invalid
request not). Meli's provider-specific normalizers (message/code extraction,
user-copy overrides for auth and rate-limit) fold into the library as the
Anthropic/OpenAI normalization tables; the app keeps only presentation.

Results, restated with their obligations:

- `Completed{input_message, messages, output, usage}` — canonical structs.
  `input_message` is the run's prompt materialized as a `UserMessage`;
  `messages` are the generated assistant/tool-result messages. The
  history-as-fold formula is
  `history ++ [input_message] ++ messages` — stated this way so the fold
  cannot silently drop user input. Apps that persist the user message at
  enqueue time (Meli does) append `messages` only and treat their own row as
  the input; both conventions are supported because the two parts are
  separate fields. This — not the event stream — is the source of truth.
- `Failed{error, usage}` — always a normalized `Error`.
- `Cancelled{reason, usage}` — reason is whatever `request_cancel` recorded.
- `Interrupted{reason, usage}` — reason from the standard taxonomy below.

Every variant carries `usage`. Terminal results carry exact numbers for
everything the runner finishes; reaped runs carry the heartbeat-piggybacked
approximation, which trails by at most one heartbeat interval — the honest
floor for a run whose executor vanished.

## Cancellation

Cancellation intent is a fact (`Facts.cancel`); terminal `cancelled` is an
outcome. The path between them is cooperative:

- The rollout checks cancellation at iteration boundaries — before each
  provider call and after each tool batch — through a closure the runner
  supplies over `Protocol.cancellation/1`. Worst-case latency: one model
  response.
- For token-latency stops, an optional push channel: the adapter exposes
  `subscribe_cancel(lease)` (Phoenix.PubSub where available); the notification
  lands in the runner's mailbox and the rollout's blocking points treat it
  like the poll result, aborting the in-flight provider stream. Push is an
  optimization; the poll is the guarantee.
- During a tool batch: tools marked `retry: :safe` (tool metadata — see
  Attempts, Retries, And The Effect Fence) are killed immediately; unsafe
  tools run to their own timeout (killing an effectful tool mid-flight
  creates unknowable external state), then the runner stops before the next
  gather and finishes with `Result.Cancelled`.
- Cancelling a run nobody owns (`queued`, `waiting`) is a direct terminal
  transition — see `Protocol.request_cancel/3`.

Honesty tag: Meli never exercised cooperative cancellation in production; this
protocol is designed, not proven, and is called out accordingly in Proven
Versus Designed.

## Deadlines, Budgets, And Usage

Heartbeat proves liveness, not progress (invariant 9). A run looping
agreeably forever would heartbeat forever. Progress is bounded twice:

- `max_iterations` on the rollout (exists today; kept).
- A wall-clock **deadline** per execution. Its source is the rollout's
  limits — `Rollout.new(..., limits: [max_iterations: 25, max_duration:
  :timer.minutes(10)])` — and `claim` mints the window fresh each time
  (`{:now_plus, max_duration}`, storage clock), so a run that waited days in
  `waiting` is not born dead on resume. `suspend` and `requeue` clear it: a
  deadline is a fact about an execution, and no execution exists in
  `waiting` or `queued`. The runner checks it at iteration boundaries and
  caps provider/tool timeouts to the remaining budget; exceeding it finishes
  as `Failed{error: %Error{code: :deadline_exceeded, retryable?: false}}`.
  The reaper independently interrupts **running** runs past
  `deadline + grace` whose heartbeat is still fresh — the belt for a buggy
  runner's suspenders, and scoped to `running` because that is the only
  status where a deadline exists at all.

Token/cost budgets are deliberately deferred: they are enforceable at the same
two checkpoints (iteration boundary, reaper) once product pressure defines
them, and `usage` is already accumulated everywhere they would need to read.

## Attempts, Retries, And The Effect Fence

Run and execution attempt are distinct: the epoch already counts executions.
The retry bias, now with its safety condition stated:

- **Infra retry before terminal commit** — same run, next epoch, via the
  `requeue` transition (`running -> queued`, then a fresh claim). Safe only
  when nothing external happened, which is exactly what the **effect fence**
  records: `Protocol.mark_effects/1` durably sets `Facts.effects?` before
  the first non-`:safe` tool executes, and `Protocol.requeue` refuses when
  the fence is set. The mechanism has two entry points: the reaper, on the
  same stale-heartbeat evidence as an interrupt, when policy opts in
  (`retry: {:requeue, max_claims: 3}`; epoch is the attempt counter); and
  the drain path, when a shutting-down runner holds a fence-unset run.
  Default policy is `retry: :never` — Meli's `max_attempts: 1` posture —
  until an app opts in; with the fence, read-only turns become safely
  retryable. The in-library precedent is `ProviderStream`, which already
  retries a provider call only if no bytes reached the consumer — the same
  principle one level down.
- **User regenerate** — new run, same rollout.
- **User edited input** — new rollout, new run.
- **Semantic retry inside an outer loop** — new rollout, new run.

With checkpoints (future ledger cadence), infra retry upgrades from
"from-scratch iff fence unset" to "from-last-checkpoint always"; the fence
remains the discriminator for the un-checkpointed tail.

Tool metadata stays minimal and non-final beyond these two fields:

```elixir
approval: :never | :required | {:policy, term()}   # v1 honors :never/:required
retry:    :safe | :unsafe | :unknown               # :unknown treated as :unsafe
```

`{:policy, term}` is reserved; resolving it (an app callback at rollout
construction) is non-final until a real policy engine demands a shape.

## The Reaper

Reconciliation is half of the liveness story and is standardized mechanism —
but the app owns its run table, so the app owns the sweep query, and the
library owns the judgment and the transition:

```elixir
lifecycle = MyApp.ClementineLifecycle
now = MyApp.Runs.db_now!()          # storage clock — same source the stamps use

for facts <- MyApp.Runs.active_run_facts() do
  case Clementine.Reconciler.judge(facts, now, policy) do
    :healthy ->
      :ok

    {:interrupt, %Clementine.InterruptReason{} = reason} ->
      Clementine.Lifecycle.Protocol.interrupt(lifecycle, facts, reason)

    {:requeue, reason} ->
      Clementine.Lifecycle.Protocol.requeue(lifecycle, facts, reason)
      # then re-enqueue the job, exactly as after a resume
  end
end
```

`judge/3` is pure and **status-scoped** — each check applies only where its
evidence means something:

- `running`: stale heartbeat (older than threshold) → `:lease_expired`, or —
  when `policy.retry` opts in and `facts.effects?` is unset and
  `facts.epoch < max_claims` — `{:requeue, ...}` instead. Deadline-plus-grace
  exceeded (fresh heartbeat, buggy runner) → `:deadline_exceeded`.
- `queued`: `queued_at` older than the claim timeout → `:claim_timeout`
  (the job that should have claimed it is gone or wedged). `queued_at` is
  stamped at every entry into an unowned state (enqueue, suspend, resume,
  requeue); for a queued run it always reads as the time it entered
  `queued` — resume and requeue re-stamp it — so one check covers all
  three entries into `queued`.
- `waiting`: only the policy ceiling — a suspension older than
  `policy.max_wait` (or past its own expiry) → `:suspension_expired`,
  with age measured from the `queued_at` stamp the suspend wrote: each
  suspension gets its own window, never charged for pre-claim queue time.
  Nothing else about a waiting run is the reaper's business: it has no
  heartbeat, no deadline, and no executor *by design*.

`policy` carries the thresholds (defaults: Meli's 60-second sweep, 2-minute
stale threshold; `retry: :never`). `now` must come from the storage clock —
the same source that stamped the facts — or be compared in the database;
node-local `DateTime.utc_now()` reintroduces the two-clock problem the
symbolic stamps removed. Concurrent sweeps on multiple nodes need no
coordination: every verdict lands as a CAS guarded by the exact observed
`(status, epoch)`, so a reaper racing a live finish — or another reaper —
loses cleanly.

For Oban apps, the executor cross-check that Meli learned the hard way ships
as a helper, and it is scoped the same way:

```elixir
Clementine.Lifecycle.Ecto.Oban.judge_job(facts, oban_job_or_nil)
# running: job missing | cancelled | discarded | completed-without-terminal
#          -> {:interrupt, reason}
# queued:  job missing | cancelled | discarded -> {:interrupt, reason}
#          (or requeue per policy); a COMPLETED job is healthy — a drain
#          requeue's fresh queued row briefly correlates to the old,
#          legitimately completed job until the app re-links its job
#          column, and the claim-timeout check covers the pathological
#          completed-without-claiming case (Meli adoption finding)
# waiting: always :healthy — the job COMPLETED legitimately at suspend;
#          a completed job is the NORMAL state of a suspended run, not
#          evidence of failure
```

The `waiting` line is load-bearing: a suspended run's job finished on
purpose, and a resumed run sitting in `queued` has a *new* job. The app
correlates run to job through its own column (Meli keeps `oban_job_id` on
the run row, updated at enqueue and re-enqueue); `executor_id` is a
human/telemetry string, never parsed for correlation.

The interruption-reason taxonomy is library vocabulary (mechanism, not
meaning), closed with an escape hatch:

```elixir
%Clementine.InterruptReason{
  code:
    :lease_expired                    # heartbeat went stale (né "stale_run")
    | :claim_timeout                  # queued too long; claimer never came
    | :job_missing                    # executor's job vanished
    | :job_cancelled
    | :job_discarded
    | :job_completed_without_terminal # job "succeeded" but never finished the run
    | :drain                          # graceful shutdown self-interrupt
    | :deadline_exceeded              # reaper-enforced variant
    | :suspension_expired             # waiting past its policy window
    | {:app, term()},                 # app-defined, namespaced by the tuple
  detail: String.t() | nil
}
```

## Runner Algorithm

The complete algorithm. Every path is present: rescue, suspend, cancel, lost
lease, drain, and a defensive catch-all — and the heartbeat outlives the
rollout so the terminal write commits under a live lease.

```elixir
defmodule Clementine.Runner do
  alias Clementine.{Error, Events, Heartbeat, Result, Rollout, Suspension}
  alias Clementine.Lifecycle.Protocol

  @type outcome ::
          {:finished, Clementine.Lifecycle.Facts.t()}
          | {:suspended, Clementine.ResumeToken.t()}
          | {:discard, reason :: term()}
          | {:error, term()}

  @spec execute(Clementine.Run.t(), keyword()) :: outcome()
  def execute(%Clementine.Run{} = run, opts) do
    lifecycle = Keyword.fetch!(opts, :lifecycle)
    sink = Keyword.get(opts, :events, Clementine.Events.Null)
    executor = Keyword.fetch!(opts, :executor_id)
    ctx = Keyword.get(opts, :ctx)

    # The lease is the runtime handle: it carries lifecycle + ctx from here on.
    case Protocol.claim(lifecycle, run.ref, executor: executor, ctx: ctx) do
      {:ok, lease} -> run_leased(run, lease, sink)
      {:error, reason} -> {:discard, reason}
    end
  end

  defp run_leased(run, lease, sink) do
    stamper = Events.stamper(sink, lease)      # (epoch, seq) + usage counter
    {:ok, hb} = Heartbeat.start_link(lease, notify: self(), usage: stamper)

    rollout_result =
      try do
        Rollout.execute(run.rollout,
          resume: lease.resume,
          emit: stamper,
          cancel?: fn -> Protocol.cancellation(lease) end,
          mark_effects: fn -> Protocol.mark_effects(lease) end,
          deadline: lease.deadline
        )
      rescue
        e -> {:error, Error.from_exception(:error, e, __STACKTRACE__)}
      catch
        kind, reason -> {:error, Error.from_exception(kind, reason, __STACKTRACE__)}
      end

    # Heartbeat still live: the terminal/suspend write retries transient
    # storage errors without racing the reaper.
    outcome =
      case rollout_result do
        {:ok, %Result.Completed{} = result} ->
          finish(lease, result)

        {:suspend, %Suspension.Request{} = request} ->
          case Protocol.suspend(lease, request) do
            {:ok, token} -> {:suspended, token}        # waiting; NO finish
            {:cancelled, facts} -> {:finished, facts}  # cancel won the race
            {:error, :lost_lease} -> {:discard, :lost_lease}
            {:error, reason} -> {:error, reason}
          end

        {:cancelled, reason} ->
          finish(lease, Result.cancelled(reason))

        :drained ->
          # requeue if no effects yet; its :effects_present guard is the branch
          requeue(lease)

        {:error, %Error{} = error} ->
          finish(lease, Result.failed(error))

        :lost_lease ->
          {:discard, :lost_lease}                      # nothing we may write

        other ->
          # Contract violation from the rollout: fail loudly, never crash.
          finish(lease, Result.failed(Error.invalid_return(other)))
      end

    Heartbeat.stop(hb)
    outcome
  end

  defp finish(lease, result) do
    case Protocol.finish(lease, result) do
      {:ok, facts} -> {:finished, facts}
      {:error, :lost_lease} -> {:discard, :lost_lease}
      {:error, :already_terminal} -> {:discard, :already_terminal}
      {:error, reason} -> {:error, reason}    # retries exhausted; reaper will act
    end
  end

  defp requeue(lease) do
    case Protocol.requeue(lease, :drain) do
      {:ok, facts} -> {:finished, facts}      # app re-enqueues on this signal
      {:error, :effects_present} -> finish(lease, Result.interrupted(:drain))
      {:error, _} = e -> e
    end
  end
end
```

Semantics pinned by this shape:

- **`Rollout.execute/2` returns a closed set**:
  `{:ok, Completed} | {:suspend, Suspension.Request} | {:cancelled, reason} |
  :drained | {:error, %Error{}} | :lost_lease`. The suspend branch skips
  finish: finish fires at most once per run *lifetime*, and never on
  suspend. The defensive `other ->` clause exists because a contract
  violation from a buggy rollout must become `finish(failed)`, never a
  `CaseClauseError` crash that turns into a two-minute reaped mystery.
- **`Runner.execute/2` returns a closed set too** — the `outcome` type at
  the top: `{:finished, facts} | {:suspended, token} | {:discard, reason} |
  {:error, term}`. `{:finished, facts}` covers every terminal *and* a drain
  requeue (the facts say which; on requeue the worker re-enqueues).
  Lost-lease is always `{:discard, :lost_lease}` no matter where it was
  discovered — mid-rollout or at the terminal write — one condition, one
  shape. Workers map this union; see the Host Integration Walkthrough.
- **The heartbeat outlives the rollout.** It is started after claim, linked,
  and stopped only after the terminal (or suspend) write returns — so those
  writes retry transient storage errors under a live lease instead of racing
  the reaper (failure matrix row 16). If the runner process dies outright,
  the link takes the heartbeat with it — by design, so the reaper's signal
  is clean.
- **Two-tier failure** (invariant 7): the `rescue`/`catch` maps any
  in-process exception — tool crash, provider client bug, checkpoint decode
  failure — to an immediate `finish(failed)` with a normalized error.
  Process death (OOM, `kill -9`) executes nothing here; the reaper
  interrupts after the stale threshold. This asymmetry is deliberate:
  exceptions are cheap to catch and users should not wait two minutes to
  learn about them; vanished processes are exactly what the reaper exists
  for.
- **How signals reach a busy rollout**: the rollout's blocking points — the
  provider-stream receive loop and the tool-await loop — additionally match
  runner-directed messages. The heartbeat sends
  `{:clementine, :lease_lost, lease}` on `:stale`; the worker sends
  `{:clementine, :drain}` when it traps shutdown; the optional cancel push
  arrives the same way. Each unwinds the rollout to the matching return
  (`:lost_lease`, `:drained`, `{:cancelled, reason}`), aborting the
  in-flight HTTP stream.
- **Graceful drain**: on `{:clementine, :drain}` the rollout unwinds to
  `:drained` and the runner attempts `Protocol.requeue(lease, :drain)` — if
  no effect has fired, the run simply re-queues and survives the deploy;
  if the fence is set, it finishes as `interrupted(:drain)`, the one
  sanctioned runner-side `Interrupted` — an immediate, labeled outcome
  instead of a reaped mystery. The reaper remains the fallback when drain
  never runs. (Draining *to a checkpoint* — suspending instead of
  interrupting when effects exist — is the designed evolution once the
  ledger lands; see Deferred.)
- `Events.stamper(sink, lease)` returns the emit closure that assigns
  `(epoch, seq)` and accumulates `usage_delta` events into a counter the
  heartbeat samples for its usage piggyback — one source, two consumers,
  no extra wiring.

## Deliverables: Adapter, Recipe, Conformance

Three artifacts turn the contract from "specified" to "hard to get wrong."
They are v1 deliverables, not future options — without them the design fails
its own first evaluation criterion.

### The Ecto Adapter

For the common Phoenix/Ecto case, even `fetch`/`apply` is mechanical:

```elixir
defmodule Meli.ClementineLifecycle do
  use Clementine.Lifecycle.Ecto,
    repo: Meli.Repo,
    schema: Meli.Conversations.ConversationRun
    # column names default to the recipe's; override only when yours differ:
    # fields: [epoch: :run_epoch, status: :run_status]

  @impl true
  def project(%Clementine.Result.Completed{} = result, run, _ctx) do
    Meli.Conversations.append_run_messages!(run, result.messages)
  end

  def project(_result, _run, _ctx), do: :ok

  @impl true
  def after_transition(facts, transition, _ctx) do
    # post-commit, outside the transaction; this is where transition
    # notifications fan out (and where a terminal closes RunViews)
    MeliWeb.RunBroadcasts.transition(facts, transition)
  end
end
```

The app writes the projection — the one genuinely product-meaning function
in the entire lifecycle — plus, optionally, the `after_transition/3`
notification hook. (`project/3` here is exactly the private clause of the
hand-written implementation above, extracted into a callback; same function,
one level up.) The macro is legitimate under the ethos test: it removes
column mapping, not the mental model; the de-sugared two-function
implementation is public, documented, and the escape hatch. The adapter
special-cases `:heartbeat` (single guarded `UPDATE`, no transaction,
touching only small columns — a heartbeat must never rewrite a large jsonb),
resolves symbolic `:now`/`{:now_plus, ms}` stamps with `fragment("now()")`,
and stores `suspension` in a jsonb column by default with a documented
side-table option for large checkpoints.

### The Column Recipe

Not a managed table — a function the app calls inside its own migration, on
its own table:

```elixir
def change do
  alter table(:conversation_runs) do
    Clementine.Lifecycle.Ecto.Migration.run_columns()
  end

  Clementine.Lifecycle.Ecto.Migration.single_active_index(
    :conversation_runs, scope: :conversation_id
  )
end
```

The recipe adds columns that round-trip `Facts` exactly — every field the
protocol layer types demands is reconstructible by `fetch`:

```text
status        text                     lease_epoch  bigint default 0
executor_id   text                     heartbeat_at timestamptz
deadline      timestamptz              queued_at    timestamptz
cancel        jsonb   (reason, requested_at)
suspension    jsonb   (reason, checkpoint, token)
resume        jsonb   (payload, resumed_at)
effects       boolean default false    usage        jsonb
error         jsonb   (normalized Error, :failed runs)
interrupt     jsonb   (InterruptReason, :interrupted runs)
finished_at   timestamptz
```

Apps wanting an indexable denormalization (an `error_code` text column, say)
add their own generated column; the recipe's columns are the contract. The
partial unique index enforces one active (`queued`/`waiting`/`running`) run
per scope — Meli's single-flight guard, generalized. Note the product
consequence, deliberately defaulted: a run parked in `waiting` for days
blocks new runs in its scope; a product that wants "chat continues while an
approval is parked" scopes the index to `queued`/`running` only and owns the
resulting concurrency. The app keeps the table name, its foreign keys, its
product columns (Meli adds `oban_job_id` for job correlation), and its
migration history. Clementine ships the recipe and the code that speaks it.

Write-load note: steady state is one small `UPDATE` per active run per
heartbeat interval (15s) — HOT-update friendly since the recipe keeps hot
columns small and the heartbeat never touches jsonb. The `suspension` write
happens once per suspension and is bounded by context-window size; use the
side table if your checkpoints run large.

### The Conformance Suite

```elixir
defmodule Meli.ClementineLifecycleTest do
  use Clementine.LifecycleCase,
    lifecycle: Meli.ClementineLifecycle,
    create_run: &Meli.Factory.queued_conversation_run/1
end
```

Generated battery, at minimum:

- N concurrent claimers; exactly one wins; losers get `{:not_claimable, _}`.
- Writes from a superseded epoch return `:stale` (zombie fencing), including
  after a suspend/resume/re-claim cycle where status is `running` again.
- Double finish rejected; finish after reap maps to `:already_terminal`.
- Heartbeat after epoch bump returns `:lost_lease`.
- A projection that raises leaves status and epoch unchanged (atomicity).
- The projection fires for every terminal transition — finish, reaper
  interrupt, and direct cancel — with the correct `Result` variant.
- Suspend stores a round-trippable suspension; resume validates tokens and
  rejects each stale-reference variant with the precise error.
- Cancel-request on running sets the flag; on queued/waiting finishes
  directly; on terminal returns `:already_terminal`.
- **Cancel racing suspend, both orders**: flag-then-suspend converges to
  `cancelled` via suspend's post-CAS check; suspend-then-cancel converges
  via request_cancel's direct flavor. No order strands a flagged run in
  `waiting`.
- Requeue refused with `:effects_present` when the fence is set; permitted
  and `queued_at`-stamped when unset; epoch unchanged until the next claim.
- Symbolic `:now`/`{:now_plus, ms}` stamps resolve against the storage
  clock (asserted by comparing to the database's `now()`, not the node's).
- Field hygiene: suspend and requeue leave no `executor_id`, `deadline`, or
  `heartbeat_at` behind.
- Reaper interrupt guarded by observed facts loses cleanly to a concurrent
  finish.

Operational note for Ecto users: the concurrency battery runs genuinely
racing writers, which `Ecto.Adapters.SQL.Sandbox` cannot host in its default
checkout mode. `LifecycleCase` tags those tests and documents the setup: a
dedicated non-sandbox repo (or `:shared` mode with `async: false`) pointed
at the test database. This is fiddly exactly once, in the generated file.

An app that hand-writes its lifecycle and forgets half the guard fails this
suite on day one. This is the design's real answer to "apps get subtle
concurrency wrong" — not prose, a test kit.

## Runtime Construction

Runtime construction is first-class. Multi-tenant apps resolve models, tools,
instructions, identity, secrets, budgets, and policies at execution time;
agents and rollouts are ordinary values, not compile-time modules.

```elixir
agent =
  Clementine.Agent.new(
    id: agent_config.id,
    model: agent_config.model,
    instructions: agent_config.system_prompt,
    tools: Meli.Clementine.ToolRegistry.resolve(agent_config, user),
    defaults: [max_iterations: agent_config.max_iterations]
  )

rollout =
  Clementine.Rollout.new(
    agent: agent,
    input: prompt,
    messages: Meli.Clementine.SessionBridge.load_messages(conversation.id),
    context: %{request_user_id: user.id, workspace_id: conversation.workspace_id}
  )

run = Clementine.Run.new(ref: conversation_run.id, rollout: rollout)
```

Snapshot timing — what is frozen at enqueue versus resolved at claim — remains
non-final, with one hard requirement inherited from the checkpoint design: a
suspended run must resume against tool and model *references* that still
resolve, and the checkpoint records enough (`rollout_id`, tool names, model
id) for the app to audit what actually ran. A practical default: freeze the
rollout spec at enqueue; resolve secrets and clients at claim.

## Host Integration Walkthrough

The complete path from "I have a Phoenix app" to "runs execute durably,
survive deploys, and can pause for approval." Every step is ordinary host
code; nothing here is hidden behind a macro.

### Step 0 — Migration

```elixir
def change do
  alter table(:conversation_runs) do
    Clementine.Lifecycle.Ecto.Migration.run_columns()
    add :oban_job_id, :bigint          # app's own job correlation
  end

  Clementine.Lifecycle.Ecto.Migration.single_active_index(
    :conversation_runs, scope: :conversation_id
  )
end
```

### Step 1 — Enqueue, atomically

The run row and its job insert in one transaction; the partial unique index
is the double-send guard, and its violation is a normal user-facing outcome,
not an exception:

```elixir
def start_turn(conversation, user_message) do
  Multi.new()
  |> Multi.insert(:run, ConversationRun.queued_changeset(conversation, user_message))
  |> Oban.insert(:job, fn %{run: run} ->
    AgentRunWorker.new(%{run_id: run.id})
  end)
  |> Multi.update(:linked, fn %{run: run, job: job} ->
    ConversationRun.link_job_changeset(run, job.id)
  end)
  |> Repo.transaction()
  |> case do
    {:ok, %{run: run}} -> {:ok, run}
    {:error, :run, %{errors: [conversation_id: {_, [constraint: :unique]}]}, _} ->
      {:error, :active_run_exists}     # surface as "agent is already working"
    {:error, _step, reason, _} -> {:error, reason}
  end
end
```

`queued_at` stamps here (the recipe defaults it to `now()`); the reaper's
claim-timeout check counts from it.

### Step 2 — The worker

```elixir
defmodule Meli.Workers.AgentRunWorker do
  use Oban.Worker, queue: :agents, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}} = job) do
    with {:ok, data} <- Meli.ClementineRuns.load(run_id) do
      run = Meli.ClementineRuns.build_run(data)   # Agent/Rollout/Run values

      case Clementine.Runner.execute(run,
             lifecycle: Meli.ClementineLifecycle,
             events: Meli.ClementineEvents,
             executor_id: "oban:#{job.id}:#{node()}"
           ) do
        {:finished, %{status: :queued} = facts} ->
          Meli.ClementineRuns.re_enqueue!(facts)   # drain requeued it
          :ok

        {:finished, _facts} -> :ok                 # any terminal
        {:suspended, _token} -> :ok                # parked; approval owns it now
        {:discard, reason} -> {:cancel, inspect(reason)}
        {:error, reason} -> {:cancel, inspect(reason)}  # reaper finishes the story
      end
    end
  end
end
```

`max_attempts: 1` remains correct as the app's default: retry is the
*reaper's* decision through requeue policy, never Oban's blind re-perform.
The `{:error, _}` arm (terminal-write retries exhausted) cancels the job and
leaves the run to the reaper — re-performing could double-execute effects.
Resume and requeue re-enqueue this same worker; the runner discovers the
resume payload through the lease, so the worker never branches on it.

### Step 3 — The reaper, scheduled

```elixir
# config.exs
config :meli, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"* * * * *", Meli.Workers.RunReaperWorker}]}
  ]

defmodule Meli.Workers.RunReaperWorker do
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @impl Oban.Worker
  def perform(_job), do: Meli.ClementineRuns.sweep()   # the loop from The Reaper
end
```

Multiple nodes may sweep concurrently without coordination — every verdict
is a CAS. The sweep's `now` comes from the database.

### Step 4 — Drain

```elixir
config :meli, Oban,
  queues: [agents: [limit: 10]],
  shutdown_grace_period: :timer.seconds(25)
```

On shutdown the runner's process receives `{:clementine, :drain}` (the
runner registers for the host's shutdown notification at claim), the rollout
unwinds, and the run either requeues — no effects yet; it survives the
deploy invisibly — or finishes as `interrupted(:drain)`. Deploys stop being
run-killers for read-only phases on day one.

### Step 5 — Approval round trip

Covered in The Resume Flow; the app-side surface is three calls:

```elixir
# building the approval UI: the token comes from the app's own storage
%{suspension: %{token: token, reason: {:approval, req}}} = Runs.facts!(run_id)

# on decision — after the app's own authorization check:
{:ok, _facts} =
  Protocol.resume(Meli.ClementineLifecycle, token, {:approved, %{by: user.id}})

:ok = Meli.ClementineRuns.re_enqueue!(run_id)
```

### Step 6 — Observe

`after_transition/3` broadcasts facts changes; the runner's execution events
stream over the app's PubSub; a `RunView` per active run lives wherever the
app already caches (Meli: ETS), fed by `RunView.apply/2` and closed by
`RunView.close/2` on terminal notifications. Reconnect = snapshot + cursor.

What Meli deletes by adopting this: its claim SQL and transition table, the
heartbeat GenServer, the reconciler's judgment logic, the draft cache's
accumulation logic, and its error normalizers. What it keeps: its table, its
projection, its sweep query, its worker, its channels.

## Other Runners

The same semantics interpret into different substrates:

- **Oban** — durable, cross-node, the production Phoenix/Postgres path.
  Everything above.
- **Ephemeral** — `Clementine.Lifecycle.Ephemeral`: facts held in the calling
  process, `apply` always matches (single-writer by construction). Powers
  `Clementine.run/3` and `Clementine.stream/3` for scripts, evals, and IEx.
  It runs the *same* runner algorithm with two honest substitutions: no
  heartbeat process (lease loss is impossible in a single process) and no
  reaper (a crash is the caller's crash). Deadline and `max_iterations` are
  enforced identically; executor id is auto-generated. Contracts:

  ```elixir
  Clementine.run(agent, prompt, opts \\ []) ::
    {:ok, %Result.Completed{}}
    | {:error, %Result.Failed{} | %Result.Cancelled{} | %Result.Interrupted{}}
  # opts: messages: history, context: map, limits: [...], events: sink

  Clementine.stream(agent, prompt, opts \\ []) :: Enumerable.t()
  # execution events in (epoch, seq) order, ending with {:result, Result.t()}
  ```

  `stream/3` is caller-owned deliberately: a script *is* the rightful owner
  of its execution. The original sin was making consumer-owned streams the
  production default, not their existence.
- **Test** — a deterministic lifecycle plus provider/tool doubles that record
  every transition, event, and result for assertions; ships with the
  conformance suite's internals reused as public test helpers. Meli's eval
  harness is the intended first consumer.
- **In-memory server** — the current GenServer agent survives as an optional
  convenience wrapper over Agent/Rollout/Run/Runner with the ephemeral
  lifecycle, for interactive local use. It is a porch, not the house.

## Verifiers And The Inner/Outer Boundary

The current loop is Gather → Act → Verify: a verifier can reject a final
answer and force a retry with feedback inside the same loop. Decision:
**verifiers exit the rollout core.** The inner loop becomes Gather → Act,
and verification becomes the first worked example of outer control:

```elixir
# A judge loop, in ordinary code (the Loop primitive arrives next epic):
def run_judged(agent, prompt, judge, attempts \\ 3) do
  Enum.reduce_while(1..attempts, {agent, prompt, []}, fn _, {agent, input, history} ->
    {:ok, %Result.Completed{} = result} =
      Clementine.run(agent, input, messages: history)

    case judge.(result) do
      :ok ->
        {:halt, {:ok, result}}

      {:retry, feedback} ->
        # thread the FULL suffix: input + generated (see Errors And Results)
        {:cont, {agent, feedback, history ++ [result.input_message | result.messages]}}
    end
  end)
end
```

Rationale: verify-and-retry is control, and control belongs one floor up,
where it can also fan out, compare candidates, or escalate to a human — none
of which fit inside a rollout. This also repairs the algebra: "rollout = one
attempt spec" was never quite true while a verifier could mutate the attempt
from within. What in-loop verifiers bought — retry within accumulated context
— survives as the message-threading pattern above, at the cost of one extra
provider round-trip per retry, which is the honest price of the boundary.

The `Verifier` behaviour itself (a `verify/2` returning `:ok | {:retry,
reason}`) is worth keeping as a shape for judge functions; it simply no longer
lives inside `Rollout`.

## Telemetry

The library already has a good telemetry story
(`[:clementine, :loop | :llm | :tool, ...]` with token usage); the redesign
extends rather than discards it. In-scope for the first epic:

```text
[:clementine, :rollout, :start | :stop | :exception]    (renamed from :loop)
[:clementine, :llm,     :start | :stop | :exception]    (unchanged)
[:clementine, :tool,    :start | :stop | :exception]    (unchanged)

[:clementine, :run, :claimed]     %{epoch}          %{run_ref, executor_id}
[:clementine, :run, :heartbeat]   %{}               %{run_ref, epoch}
[:clementine, :run, :suspended]   %{}               %{run_ref, epoch, reason_type}
[:clementine, :run, :resumed]     %{}               %{run_ref, epoch}
[:clementine, :run, :finished]    %{duration}       %{run_ref, epoch, terminal, usage}
[:clementine, :run, :requeued]    %{}               %{run_ref, epoch, reason}
[:clementine, :run, :lease_lost]  %{}               %{run_ref, epoch}
[:clementine, :run, :reaped]      %{}               %{run_ref, epoch, code}
```

`Clementine.Telemetry.metrics/0` grows matching metric definitions. The
`:loop` → `:rollout` event rename is a breaking change and is simply
documented; compatibility is a non-goal.

## Failure Matrix

The spec's proof obligation: every failure resolves to exactly one terminal
writer, decided by a CAS. An implementation is complete when each row is a
passing test.

| # | Scenario | Mechanism | Outcome |
|---|----------|-----------|---------|
| 1 | Pod OOM mid-stream | heartbeat dies with the process; reaper threshold passes | `interrupted(:lease_expired)`; RunView goes quiet, then the transition notification closes it |
| 2 | Zombie wakes after reap and writes | epoch/status guard; fold closure | every write `:stale`; runner exits `:lost_lease`; ghost events possible until the terminal notification closes the fold, then rejected (no successor epoch ever exists after a reap — closure, not epoch comparison, is the silencer) |
| 3 | Reaper races a live finish | both CAS on the same `(status, epoch)` | exactly one wins; loser is a no-op with a precise error |
| 4 | User cancels during token stream | cancel flag; push signal or next poll | provider stream aborted; `finish(cancelled)`; latency ≤ one iteration (≈ instant with push). If the flag loses the race to an already-committing terminal, the completed work stands — stated in `request_cancel` |
| 5 | User cancels during an unsafe tool | tool runs to its own timeout; safe siblings killed | `finish(cancelled)` after the batch settles; no half-known external state |
| 6 | Double-click sends two messages | app's single-active partial index (per-scope); claim CAS (per-run) | second run uninsertable at enqueue; single-flight preserved |
| 7 | Approval granted twice / stale token replay | `ResumeToken` epoch + status validation | second resume gets `:already_resumed` / `:stale_reference` |
| 8 | Deploy changes checkpoint format mid-suspension | checkpoint `version` | `failed` with `%Error{code: :incompatible_checkpoint}` or app-chosen fresh restart; never a crash |
| 9 | Model loops agreeably forever | deadline at iteration boundary; reaper grace backstop (`running` only) | `failed(:deadline_exceeded)` despite a perfectly healthy heartbeat |
| 10 | Oban discards/cancels the job silently | `judge_job/2` cross-check, status-scoped to `running`/`queued` | `interrupted` with `:job_discarded` or `:job_cancelled`; a `waiting` run's completed job is normal and judged `:healthy` |
| 11 | Tool raises mid-batch | `ToolRunner` (the tool execution layer) normalizes; runner rescue as backstop | tool error becomes an error tool-result or `finish(failed)`; never a hung run |
| 12 | Postgres briefly unreachable | heartbeat treats non-`:stale` errors as transient; generous threshold | run continues; no false reap within 8 missed beats |
| 13 | Node drains during a run | drain signal; requeue-or-interrupt | fence unset: `requeue` — the run silently survives the deploy; fence set: `finish(interrupted(:drain))` immediately; reaper is the fallback |
| 14 | Runner process killed between claim and first heartbeat | `heartbeat_at` stamped at claim (storage clock); reaper | `interrupted(:lease_expired)` after threshold from claim time |
| 15 | Suspension never resolved | app policy via reaper (`:suspension_expired`) or cancel | run leaves `waiting` by explicit policy, never by accident |
| 16 | Transient storage failure at the terminal write | bounded retry under a still-live heartbeat | commit succeeds on retry; if retries exhaust, run is reaped and generated messages are lost — the acknowledged residual, shrunk later by the ledger |
| 17 | Cancel request lands just before a suspend commits | `suspend`'s post-CAS flag re-check | run converges to `cancelled`, never a flagged run stranded in `waiting`; opposite order converges via `request_cancel`'s direct flavor |
| 18 | Worker crashes before any effect; policy opts into retry | stale heartbeat + fence unset → reaper `{:requeue, _}` | same run re-queues and re-executes from scratch at the next epoch; attempt count capped by `epoch < max_claims` |

## Proven Versus Designed

Design pressure came from one production app; this table keeps the epistemics
honest about which mechanisms are battle-tested and which are extrapolated.
Reviewers should spend their skepticism on the right column.

| Mechanism | Status |
|-----------|--------|
| Claim / single-flight guard | Proven in Meli (row lock variant; CAS variant is new but conformance-tested) |
| Heartbeat + stale-run reaping | Proven in Meli (15s/2min in production) |
| Executor cross-check taxonomy | Proven in Meli for the pre-suspension world; the status-scoping (`waiting` is `:healthy`) is a designed revision |
| Atomic terminal commit with projection | Proven in Meli (messages + completion in one transaction) |
| Draft view for reconnects | Proven in Meli (ETS cache + sequence numbers); the RunView fold standardizes it |
| Provider error normalization | Proven in Meli + library clients; retryability field is new |
| Epoch fencing as explicit mechanism | New (Meli fences implicitly via terminal dead-ends); classical construction |
| Cooperative cancellation | Designed; Meli never wired it end to end |
| Suspension / checkpoint / resume | Designed; `Loop.continue/3` is the only existing ancestor |
| Effect fence | Designed; `ProviderStream`'s no-bytes-sent retry is the in-library precedent |
| Requeue / fence-gated same-run retry | Designed; default-off policy preserves the proven `max_attempts: 1` posture |
| Transition notifications + fold closure | Designed; replaces v2.0's epoch-only zombie rule, which could not silence post-reap zombies |
| Deadline enforcement | Designed |
| RunView fold | Designed (extraction of proven Meli behavior into the library) |

The designed rows are the validation burden of the first epic: Meli adopts
each and reports back before any is declared stable.

## Design Evaluation Scorecard

The criteria from v1, scored against this revision:

- **Can a Phoenix/Oban app delete meaningful runtime glue?** Yes, now. Meli
  deletes its claim SQL, transition table, heartbeat process, draft-cache
  accumulation logic, reaper judgment, and error normalizers; it keeps its
  table, its projection, its sweep query, and its worker. Under v1's
  five-callback shape the honest answer was "not much."
- **Can a non-Oban app use the same concepts honestly?** Yes: the ephemeral
  lifecycle says what it is (single-process, advisory) instead of pretending
  to lease, and `Clementine.run/2` is one line.
- **Is execution ownership explicit?** Yes: epoch = execution; claim is the
  only mint; every write proves ownership or learns otherwise.
- **Runtime-defined agents/tools natural?** Yes; values throughout.
- **Host schema preserved?** Yes; column recipe on the app's table, app-owned
  projection, no Clementine tables.
- **Terminal states unambiguous?** Yes: closed sum, dead-end statuses,
  at-most-once finish, exactly one terminal writer per run (matrix rows 3, 7).
- **Retries/regenerations/edited inputs distinguishable?** Yes: epoch vs new
  run vs new rollout — and the first is now mechanically real (`requeue`
  exists in the state machine), with the effect fence making it safe and the
  epoch doubling as its attempt cap.
- **Approval pause/resume safe?** Yes by design (checkpoint + epoch-stamped
  token); *designed, not proven* — flagged above.
- **Can future outer loops reuse the primitives?** Yes: loops produce
  rollouts and consume results; suspension already models `{:wait, _}`; the
  judge-loop example runs on today's surface.
- **Understandable without private macros or hidden processes?** The one
  macro (Ecto adapter) has a documented 60-line de-sugared form; the runner,
  protocol, and fold are plain functions over plain values.

## Alternatives Considered

### Five-Callback Lifecycle Protocol (v1's shape)

Rejected in favor of the CAS grain — this is the headline change of the
revision.

V1 asked apps to implement `claim`, `heartbeat`, `cancellation`, `suspend`,
and `finish`, each with its own guard subtleties. That distributes the
concurrency-sensitive logic across five app-owned functions and n apps —
precisely the code the design ethos says apps should not write. The CAS grain
centralizes legality, epoch rules, and race interpretation in a pure,
property-testable core, and reduces the app to one conditional write plus one
projection. The five operations survive as library-internal `Protocol`
functions, so the vocabulary loses nothing. (Analogy for the fluent: class
lifecycle methods versus a reducer — the reducer's rules ship in the library;
the app supplies only the store.)

### Keep Current `Clementine.Agent` As The Primary Abstraction

Rejected. The GenServer agent conflates capability definition, process
ownership, conversation memory, and execution lifecycle; Meli's production
path already bypasses it. It survives as an optional interactive wrapper (see
Other Runners), not the ontology.

### Keep `Loop` As The Inner Model/Tool Loop Name

Rejected. The word is needed for the outer control primitive; the inner unit
becomes `Rollout`.

### Ship Clementine-Owned Database Tables

Rejected as the default. Runs overlap with host product rows (conversation
runs, eval runs, workflow runs); a `clementine_runs` table would force
duplication and reconciliation. The column recipe delivers the standardization
benefit without the ownership grab. A packaged starter schema for greenfield
apps remains a possible future convenience on top of the recipe — nothing in
the core may require it.

### Expose A Generic Store Abstraction

Rejected. "Store" pulls attention toward database shape; the contract that
matters is which transitions must be safe, atomic, and guarded. The lifecycle
behaviour *is* that contract; storage is its implementation detail.

### Hide Oban Integration Behind A `use Clementine.Executor.Oban` Macro

Rejected. A macro-owned worker would obscure the most important boundary: the
app owns the worker and product data; Clementine owns the runner algorithm.
Workers stay ordinary Oban workers. (Contrast with the Ecto adapter macro,
which is accepted because it hides column mapping, not the model — the ethos
section states the rule.)

### Model Everything As A General Graph API

Rejected for v1. The one load-bearing graph idea — references that validate
target, type, and epoch — ships inside `ResumeToken`. The rest waits for the
outer-loop epic; see the appendix.

### Build Full Durable Tool-Call Replay First

Rejected for the first epic. Whole-rollout durability with
checkpoint-on-suspend is the proven balance; the ledger is the same checkpoint
mechanism at higher cadence and can follow without redesign (see One
Mechanism, Two Frequencies).

## Design Decisions

Decided:

- Inner `Loop` becomes `Rollout`; `Loop` is reserved for outer control.
- Verifiers exit the rollout core; verification is outer control.
- Existing Clementine compatibility is not a constraint.
- Agents and rollouts are inert data; runtime construction is first-class.
- The lifecycle contract is the two-function CAS behaviour; the five
  operations are library-internal protocol functions.
- Epoch fencing: epoch identifies an execution; claim is the sole increment;
  every write is guarded by `(status, epoch)`.
- Lease loss is discovered at write time; heartbeat bounds discovery latency.
- Suspension is a durable checkpoint; resume is snapshot restoration by
  epoch-stamped token, re-entering through `queued`.
- Resume references are epoch-stamped, type-checked capabilities.
- Two-tier failure handling; finish at most once per run; terminal states are
  dead ends; exactly one terminal writer; every terminal transition carries
  its `Result`, so the projection fires uniformly (reaps included).
- Events are advisory; execution events are identified by `(epoch, seq)`;
  lifecycle transitions reach observers as notifications through the
  lifecycle's own `apply` (post-commit hook); a terminal notification closes
  the RunView fold; Clementine owns the fold; the terminal result is truth.
- The lease is a runtime handle (lifecycle + ctx inside); transition
  timestamps are symbolic and resolve against the storage clock; transitions
  clear fields whose meaning does not survive the target status.
- The reaper judgment is status-scoped; the interruption taxonomy and Oban
  cross-check are library mechanism; the sweep query is app-owned.
- `requeue` (`running -> queued`) is the same-run retry path, gated by the
  effect fence and capped by epoch count; `max_attempts: 1` and
  `retry: :never` remain the app defaults until it opts in. Drain requeues
  fence-unset runs.
- `Completed` separates `input_message` from generated `messages`, so
  history-as-fold never drops user input.
- Deadline is a core run limit, enforced at iteration boundaries and by the
  reaper.
- Usage is carried on every terminal result and piggybacked on heartbeats.
- Ecto adapter, column recipe, and conformance suite are v1 deliverables.
- Oban is a canonical runner substrate, not the ontology; workers are
  ordinary app code.
- Telemetry extends the existing taxonomy with `[:clementine, :run, ...]`.

Non-final:

- Exact event payload fields and durability tiers beyond live-only.
- `{:policy, term}` approval resolution shape.
- Token/cost budget enforcement (deadline pattern is the template).
- Checkpoint cadence beyond suspend (the ledger), retry-from-checkpoint, and
  drain-to-checkpoint.
- Requeue policy defaults (`max_claims`, backoff between claims) beyond
  `retry: :never`.
- Terminal-write retry parameters (attempt count, backoff curve).
- `after_transition` delivery semantics beyond post-commit best-effort
  (whether apps need an outbox for guaranteed notification is app-observable
  today and revisitable).
- Snapshot timing detail (freeze-at-enqueue default proposed, not mandated).
- Outer `Loop`/`Step` model and parent-child cancellation cascades.
- Push-cancellation transport beyond the adapter's PubSub option.
- Attempt metadata beyond the epoch (e.g., recording executor history).

## Initial Epic Shape

Durable single-rollout execution, approval-ready, in dependency order:

1. **Core data**: `Agent`, `Rollout` (from `Loop`, verifiers extracted),
   `Run`, `Facts`, `Transition`, `Lease`, `Result` (usage on all variants),
   `Error` (with retryability), `Event`, `Checkpoint`, `Suspension`,
   `ResumeToken`, `InterruptReason`.
2. **Pure protocol core**: transition computation, legality, epoch rules,
   race interpretation — property-tested exhaustively; this module is the
   design.
3. **Runner + ephemeral path**: `Runner.execute/2` with the full outcome
   union (finished/suspended/discard/error) and every rollout branch
   (completed, suspend, cancelled, drained, error, lost-lease, defensive
   catch-all); `Lifecycle.Ephemeral`; `Clementine.run/3` and
   `Clementine.stream/3`; two-tier failure handling; heartbeat-outlives-
   rollout ordering.
4. **Ecto adapter + column recipe + conformance suite** (`LifecycleCase`):
   the `after_transition/3` hook, symbolic timestamp resolution, and the
   full battery — including suspend/resume zombie fencing, cancel-racing-
   suspend in both orders, requeue guards, and field hygiene.
5. **Events**: `(epoch, seq)` stamping, sink behaviour, taxonomy, transition
   notifications, `RunView` fold with `close/2`, reconnect cursor semantics.
6. **Cancellation, deadline, effect fence, usage piggyback, drain** in
   runner and protocol.
7. **Reaper**: status-scoped `Reconciler.judge/3`, interruption taxonomy,
   `Ecto.Oban.judge_job/2`, `Protocol.requeue` with default-off policy.
8. **Suspension end to end**: gated tools (`approval: :required`), checkpoint
   build (including parallel-batch partial results), `Protocol.suspend/2`,
   `Protocol.resume/3` with normative approval payloads, rollout resume,
   checkpoint versioning.
9. **Telemetry, the Host Integration Walkthrough as shipped docs, and Meli
   adoption** as the validation pass — every "Designed" row in Proven Versus
   Designed graduates or gets revised.

Deferred: outer `Loop` implementation; fan-out/fan-in steps; tool-call ledger,
retry-from-checkpoint, and drain-to-checkpoint; durable event log; graph
introspection; token/cost budgets; push-cancellation transports beyond
PubSub.

## Appendix: Execution Graph (Future Work)

Durable execution is graph-shaped once agents spawn child work, fan out, fan
in, and pass messages: nodes (loop, step, rollout, run, suspension, approval,
artifact) and typed edges (owns, spawned, awaits, resumes, approved-by,
produced). A future `Clementine.Graph.snapshot(root_ref)` could power UI views
of growing loop topology.

None of that is v1 surface area. What v1 keeps from the graph model is its
one load-bearing safety idea, already shipped in `ResumeToken`: references
that validate the target, its type, and its epoch, so control actions cannot
apply to stale or unrelated state. The rest — node/edge taxonomies,
traversal, cascade semantics for parent-child cancellation (`:spawned` vs
`:awaits` vs `:observes` edges) — waits for the outer-loop epic, where real
fan-out will sharpen it. The design keeps the door open by making every
reference epoch-stamped and typed from day one.
