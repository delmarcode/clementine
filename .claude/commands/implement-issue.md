---
description: Implement a Linear issue in the Clementine library
---

You are implementing **$ARGUMENTS** in this repo (the Clementine Elixir library). If you have the `ticket` skill, work the issue with it; this command adds what is specific to Clementine.

## Orientation — before writing any code

1. Read **$ARGUMENTS** in Linear (`get_issue` with its relations, then its comments). Its **Done when** (or **Scope** and **Acceptance**) is your work order, and decisions in its comments bind too. If the Linear MCP is not connected in this session, stop and ask for the issue text.
2. Read `CLAUDE.md`, then the current docs for the area you touch: the README, the guide in `guides/`, `usage-rules.md` for anything a host app sees, `docs/TOOL_AUTHORING.md` for tools, `docs/MODELS.md` for providers.
3. For lifecycle, runner, reaper, or loop work, read the design record behind it for the rationale and the failure-matrix rows: `docs/DURABLE_EXECUTION_RFC.md` (numbered rows) or `docs/LOOP_RFC.md` (L-rows). Both predate the durable runtime and the loop rewrite: where they and the code disagree, the code and the current docs win, and the issue decides what changes.
4. Check that every issue in your `blockedBy` relations is merged to `main`. If one isn't, build on its branch only when told to; otherwise stop and report.

## Ground rules

1. **Scope is your issue.** No adjacent refactors and no drive-by API changes. Work that belongs elsewhere becomes a new issue, related to yours.
2. If the issue contradicts the code or the docs in a way that changes behavior others rely on, comment on the issue with the concrete problem and a minimal proposed resolution instead of improvising around it.
3. A change to the public surface (the child spec's options, `Clementine.Runs`, `Clementine.Host`, `use Clementine.Agent`, `use Clementine.Loop`, the tool macro) updates `priv/templates/`, `usage-rules.md`, the guides, and the README in the same commit.
4. A change to the runtime's tables is a new `Clementine.Migration` version, never an edit to a frozen one; the installer template moves to it in the same commit.

## Quality bar

- Tests are the deliverable as much as code, and would fail if the behavior broke. Every failure-matrix row your issue cites becomes a named test (e.g. `test "matrix row 17: cancel racing suspend, flag-first order"`).
- The pure cores (the lifecycle protocol, the loop step) are property-tested with no database involved.
- Match the existing codebase's idiom and comment density. Comments state constraints code can't show — never narration.
- Gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `PGDATABASE=clementine_test_<issue> mix test` (your own database: the test helper drops and recreates it).

## Workflow

- Branch with the issue's `gitBranchName` from Linear, in a git worktree of your own.
- Open the PR with the `dmcc-pr-compliance` skill, never a hand-rolled `gh pr create`. The body links the issue, lists the failure-matrix rows implemented, and records each choice you made where the issue was silent ("none" is a good answer).
- Move the issue to In Review and comment with the PR's link.
