# Planned Engine Issues — Streaming & Durability

These are the issue specs for the engine changes that came out of the
"loops → queues → durable execution" design thread (validated against a real
Oban-backed consumer). They are mirrored here as the source of truth and are
intended to be filed as Linear issues under **Skunk Works → Clementine**.

**Guiding boundary:** the engine owns *ordered, observable, consumer-independent
event production* and *canonical, round-trippable state*; the host app owns
*durability, transport, liveness, and domain lifecycle*. Each issue below moves
one thing across that line into the engine; everything else (draft caches,
heartbeats, reconciliation, PubSub, the run/job split, a step ledger table)
stays in the host by design.

| # | Change | Branch | PR |
|---|--------|--------|----|
| 0 | CI workflow (supporting) | `claude/ci-workflow` | #26 |
| 1 | Canonical message/content (de)serialization | `claude/msg-serialization` | #27 |
| 2 | Streaming-seam docs | `claude/streaming-seam-docs` | #28 |
| 3 | Per-run stream `seq` | `claude/stream-seq` | _pending_ |
| 4 | Cooperative cancellation token | `claude/cancel-token` | _pending_ |

> Note on testing: these changes were developed in an environment that cannot
> reach hex to fetch deps, so `mix test` could not run locally — they were
> verified via standalone `elixirc` compile, `Code.format_string!`, and logic
> harnesses. Issue #0 (CI) exists so the change PRs get real suite execution on
> GitHub, where hex is reachable.

---

## Issue 1 — Canonical (de)serialization for message & content structs

**Labels:** engine, durability · **Implements:** PR #27 · **Branch:** `claude/msg-serialization`

### Problem
Conversation history can't cleanly round-trip through JSON / Oban args /
Postgres `jsonb`. `Clementine.LLM.Message.UserMessage` and `ToolResultMessage`
both have `role: :user`, so role alone can't reconstruct the struct — durable
hosts (e.g. Meli's `SessionBridge`) hand-roll bidirectional mappers and tolerate
dual struct shapes as a result.

### Proposed change
Add `to_map/1` + `from_map/1` to `Clementine.LLM.Message` and
`Clementine.LLM.Message.Content`:
- Content blocks tagged by a `"type"` discriminator (`text` / `tool_use` / `tool_result`).
- Messages tagged by an explicit `"kind"` discriminator (`user` / `assistant` / `tool_result`).
- JSON-safe, string-keyed maps only.
- `UserMessage.content` string-vs-list polymorphism preserved through the round trip.

### Acceptance criteria
- [ ] `from_map(to_map(x)) == x` for every content and message variant.
- [ ] Equality also holds through `Jason.encode!/decode!` (with string-keyed `ToolUse.input`).
- [ ] `from_map/1` raises `ArgumentError` on unknown/missing `"type"`/`"kind"` and on non-maps.
- [ ] New `test/clementine/llm/message_serialization_test.exs`; CI green.

### Notes
`ToolUse.input` is passed through unchanged. Direct round trip is always exact;
the Jason round trip is exact when `input` keys are strings (atom keys atomize
under Jason). The Anthropic decoder already produces string-keyed inputs.

---

## Issue 2 — Document the streaming seam (run_stream vs Agent.stream)

**Labels:** engine, docs · **Implements:** PR #28 · **Branch:** `claude/streaming-seam-docs`

### Problem
`Clementine.Agent.stream/2` is consumer-owned: the run is canceled if the
consumer stops iterating or the agent goes down. The only real production
consumer bypasses it and drives `Clementine.Loop.run_stream/3` directly for
durable, multi-observer ("observe, don't own") streaming — but nothing in the
docs signals which API is which, so the wrong one is the easy default.

### Proposed change (docs only)
- `@doc` on `run_stream/3`: bless it as the ownership-neutral, server-owned
  streaming seam (runs in the caller's process, pushes events to a callback,
  spawns nothing, no consumer coupling); the right primitive for broadcasting
  to zero-or-more observers via PubSub.
- `@doc` on `Agent.stream/2`: mark it consumer-owned / interactive-only and
  point durable/multi-observer needs at `run_stream/3`.
- New `docs/STREAMING.md` with a comparison table + rationale.

### Acceptance criteria
- [ ] No behavior change.
- [ ] Edited files parse and are formatter-clean.
- [ ] Every documented claim verified against the implementation.

---

## Issue 3 — Monotonic per-run sequence number on all streamed events

**Labels:** engine, streaming · **Branch:** `claude/stream-seq`

### Problem
`run_stream/3` emits bare event tuples (`{:text_delta, _}`, `{:tool_use_start,
_, _}`, `{:loop_event, _}`, …) with no ordering token, so a downstream observer
can only dedupe/reorder *text* on reconnect — tool and loop events have no
ordinal. (Meli assigns `seq` itself, per-run, but only for text deltas.)

### Proposed change
Deliver `{seq, event}` from `run_stream/3`, where `seq` is a per-run, strictly
monotonic ordinal (from 0) covering **all** event types. Not opt-in (alpha):
update existing consumers (`Agent.stream/2`, `Clementine.stream/2`) and their
tests to the new contract. `run/2` (non-streaming) is unchanged.

### Acceptance criteria
- [ ] Every forwarded event carries a strictly increasing per-run `seq`.
- [ ] Public stream contract + `@doc` examples updated.
- [ ] `loop_test`/`agent_test` updated and assert monotonic `seq` across text
      and non-text events.
- [ ] CI green.

---

## Issue 4 — Cooperative cancellation token for runs

**Labels:** engine, durability · **Branch:** `claude/cancel-token` (stacked on `claude/stream-seq`)

### Problem
Teardown today is process-death only. A user-initiated cancel can't interrupt a
mid-flight run / provider stream — it can only record intent and reject the late
write. (Meli: "a cooperative cancellation token is the one thing worth asking
the engine for.")

### Proposed change
Accept a `:cancel_token` in `Loop.run/2` and `Loop.run_stream/3`, checked at
iteration boundaries and inside the streaming reduce. On cancel, stop promptly
and return `{:error, :cancelled}` (with partial state where available). The
token is a small, process-safe primitive (an atomics ref or a 0-arity
predicate fun) — final shape chosen in implementation.

### Acceptance criteria
- [ ] A token tripped between iterations stops before the next LLM call.
- [ ] A token tripped mid-stream halts the reduce and returns `{:error, :cancelled}`.
- [ ] No token / untripped token → behavior identical to today.
- [ ] Tests cover both boundaries; CI green.

---

## Explicitly out of scope for the engine (stays in the host)

Drawn from the same analysis, these were considered and deliberately left in the
application layer:

- **Draft/active-run cache** (ETS, clustering, cross-node lookup) — deployment
  topology. The engine provides the `seq` ordinal (Issue 3); the host owns the buffer.
- **Heartbeat + reconciliation + `interrupted` domain state** — liveness and
  domain lifecycle; "the job is an executor, not product truth."
- **PubSub topics / channels / wire format** — transport.
- **Run-vs-job split, rollout/outer-loop orchestration, single-flight** — host concerns.
- **Step/tool-call idempotency ledger table** — host persistence. (The engine
  may later grow a *hook* for a tool to declare a dedup key; the table itself stays in the host.)
