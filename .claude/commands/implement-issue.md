---
description: Implement a SKUNK issue from the Clementine durable-execution RFC (v2.2)
---

You are implementing **$ARGUMENTS** in this repo (the Clementine Elixir library).

## Orientation — do all of this before writing any code

1. Fetch **$ARGUMENTS** from Linear (`get_issue`). Its **Scope** and **Acceptance** sections are your work order; its parent epic carries lineage context. If the Linear MCP is not connected in this session, stop and ask for the issue text.
2. Read the spec: **the RFC your issue cites** — `docs/LOOP_RFC.md` for the durable-loops epic (SKUNK-142), `docs/DURABLE_EXECUTION_RFC.md` for the durable-execution layer — plus every section the issue names. `docs/DURABLE_EXECUTION_RFC.md` is always the normative baseline beneath the loop RFC; read its **Governing Invariants**, **Vocabulary**, **Run State Machine**, and **The Lifecycle Contract** regardless. Each RFC's **Failure Matrix** is its proof obligation — acceptance criteria reference rows by number (L-rows for loops).
3. Read the cited RFC's **Normative Baseline** / **Amendments** sections, then the existing modules they list. You inherit shipped machinery; where your issue implements a named Amendment, that is the only sanctioned change to shipped behavior — anything else you think needs changing is a rule-1 finding, not a license.
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
