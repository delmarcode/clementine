# Repository Guidelines

Clementine is an Elixir library that runs LLM agents: in process for
scripts, evals, and tests, and durably on a host app's Postgres and Oban.
`CLAUDE.md` has its vocabulary, architecture, and production path; read
it before changing code.

## Layout
- `lib/clementine.ex` is the facade. Under `lib/clementine/`: agents and the engine (`agent.ex`, `rollout.ex`, `runner.ex`, `lifecycle*`), the durable runtime (`runs.ex`, `runs/`, `host.ex`, `migration.ex`), loops (`loop.ex`, `loop/`, `thread.ex`), tools (`tool*.ex`, `tools/`), and providers (`llm/`). The generators are in `lib/mix/` and render `priv/templates/`.
- `test/` mirrors `lib/`; shared helpers are in `test/support/`.
- The current docs are `README.md`, `guides/`, `usage-rules.md`, `docs/TOOL_AUTHORING.md`, and `docs/MODELS.md`. `docs/DURABLE_EXECUTION_RFC.md`, `docs/LOOP_RFC.md`, and `docs/STREAMING_CHAT_DESIGN.md` are design records; each says at its top what it records and what has changed since.

## Commands
Run Elixir through mise (`mise exec -- mix ...`).
- `mix deps.get` fetches dependencies.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix test` are CI's gates; all three pass before a PR.
- The test helper drops and recreates the test database on every run, so give each checkout its own: `PGDATABASE=clementine_test_<issue> mix test`. Without a reachable Postgres, `:postgres` tests are excluded.
- `scripts/installer-smoke.sh` installs Clementine into a fresh Phoenix app; CI runs it. Locally, run it one at a time after changing a template: it drops `clementine_smoke_test`.
- `mix docs` writes the API docs to `doc/`.

## Docs
- A change to the public surface (the child spec's options, `Clementine.Runs`, `Clementine.Host`, `use Clementine.Agent`, `use Clementine.Loop`, the tool macro) updates `priv/templates/`, `usage-rules.md`, and the guides in the same commit.
- `test/clementine/guides_test.exs` checks the README, `guides/`, and `usage-rules.md`: every `elixir` fence parses, every `defmodule` compiles, every relative link and anchor resolves, and a sample marked `<!-- guide-sample: run -->` runs in process against a scripted model.
- Write in the library's terms: Agent, Rollout, Run, Runner, Lifecycle, Result. "Loop" means `Clementine.Loop`, a standing controller; the cycle of model calls and tool calls inside a run is the model–tool cycle.

## Coding Style & Naming Conventions
- Use `mix format` and follow Elixir defaults (2-space indentation, trailing commas in multi-line lists).
- Keep modules in `CamelCase` and files in `snake_case` (e.g., `Clementine.ToolRunner` in `lib/clementine/tool_runner.ex`).
- Prefer small, focused modules under `lib/clementine/` rather than large, monolithic files.
- Comments state constraints the code can't show, never narration.

## Testing Guidelines
- ExUnit, with Mox for the model client (`Clementine.LLM.MockClient`, defined in `test/test_helper.exs`), StreamData for properties, and Bypass for provider HTTP. No test calls a live provider.
- Name test files `*_test.exs`, in the directory that mirrors the code's.
- Tests come with the change: tools, the engine, the runtime, loops, providers, and doc samples.

## Commit & Pull Request Guidelines
- Commit subjects are short, imperative, and sentence-cased, ending with the Linear issue in parentheses when there is one (e.g., "Say Bash starts in working_dir but is not confined to it (OPS-159)"). The body says why.
- Open PRs with the `dmcc-pr-compliance` skill: a summary, the rationale, and testing notes (commands and results). Update the docs when behavior changes.

## Configuration & Security Tips
- Store API keys in environment variables and reference them in config (`anthropic_api_key: {:system, "ANTHROPIC_API_KEY"}`).
- Never commit secrets or generated artifacts (`_build/`, `deps/`, `doc/`).
