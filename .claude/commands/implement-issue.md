---
description: Implement a SKUNK issue from the Clementine durable-execution RFC (v2.1)
---

You are implementing **$ARGUMENTS** in this repo (the Clementine Elixir library).

## Orientation — do all of this before writing any code

1. Fetch **$ARGUMENTS** from Linear (`get_issue`). Its **Scope** and **Acceptance** sections are your work order. Its parent epic **SKUNK-124** carries lineage context (this epic supersedes the SKUNK-117-era `Executor` framing — if you find leftover code from that round, flag it; do not build on it). If the Linear MCP is not connected in this session, stop and ask for the issue text.
2. Read the spec: `docs/DURABLE_EXECUTION_RFC.md` in this repo (v2.1). Non-negotiable minimum: **Governing Invariants**, **Vocabulary**, **Run State Machine**, **The Lifecycle Contract**, plus every section your issue cites. The 18-row **Failure Matrix** is the system's proof obligation — your acceptance criteria reference its rows by number.
3. Read the RFC's **Normative Baseline** section, then the existing modules it lists (canonical message structs, `Tool` contract, `ToolRunner`, `Usage`, provider clients). You inherit these; do not reinvent or re-specify them.
4. Verify every issue listed in your `blockedBy` relations is merged to `main`. If one isn't, stop and report instead of building on unmerged work.

## Ground rules

1. **The RFC is the spec.** If your issue and the RFC disagree, or the RFC seems wrong, ambiguous, or impossible as you implement it — STOP on that point and surface it: comment on the Linear issue with the concrete problem, a minimal proposed resolution, and the RFC section reference. Do not silently improvise around a spec defect; finding one is a valuable outcome of your run, not a failure.
2. Where the RFC marks something **non-final**, choose the minimal option consistent with the Governing Invariants and record the choice explicitly in your PR description.
3. **Scope = your issue.** No adjacent refactors, no drive-by API changes, no "while I'm here." If tempted, leave a comment on SKUNK-124 instead.
4. Compatibility with pre-RFC Clementine APIs is an explicit non-goal. Make the breaking changes the RFC prescribes (e.g. `Loop` → `Rollout`, `:loop` → `:rollout` telemetry) without shims.

## Quality bar

- Tests are the deliverable as much as code. Every failure-matrix row your issue cites becomes a named test (e.g. `test "matrix row 17: cancel racing suspend, flag-first order"`).
- The protocol core is pure — if it's in your scope, property-test it exhaustively with no database involved.
- `mix format` before every commit; `mix test` green; run dialyzer/credo if configured.
- Match the existing codebase's idiom and comment density. Comments state constraints code can't show — never narration.

## Workflow

- Branch: use the issue's `gitBranchName` from Linear (`jon/skunk-…`).
- When done: push and open a PR titled `$ARGUMENTS: <issue title>`. **Create every PR with the `/dmcc-pr` skill** — no hand-rolled `gh pr create`; the skill renders the compliant body (including the `dmcc:compliance` block) and validates it before creation. The PR body links the issue, lists the RFC sections and failure-matrix rows implemented, and enumerates any non-final choices made or spec questions raised ("none" is a valid and desirable answer).
- Update the Linear issue: move it to review, and leave a closing comment summarizing deviations from spec (again, "none" is the goal).
