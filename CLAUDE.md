# CLAUDE.md

Instructions for coding agents working on Clementine itself. `AGENTS.md`
has the commands, gates, and conventions; this file is the map.

## What Clementine is

An Elixir library that runs LLM agents. An agent is inert data; running
one is a separate, explicit act, done by one engine in two ways: in
process (`Clementine.run/3`, `stream/3`) for scripts, evals, and tests,
and durably on the host app's Postgres and Oban (`{Clementine, ...}` and
`Clementine.Runs`), where a run is a row that outlives the process that
started it. Apps consume it as a git dependency; it is not on Hex.

Where the truth is: the code, then the current docs (`README.md`,
`guides/*.md`, `usage-rules.md`, `docs/TOOL_AUTHORING.md`,
`docs/MODELS.md`, the moduledocs). `docs/DURABLE_EXECUTION_RFC.md` and
`docs/LOOP_RFC.md` are design records: they explain why the lifecycle
and loops work as they do, and their failure matrices name tests, but
they predate the durable runtime and the loop rewrite. Where they and
the code disagree, the code wins.

## Vocabulary

- **Agent** (`Clementine.Agent`): model, instructions, tools, skills,
  delegates, limits. Inert data, built with `Agent.new/1`, or declared
  with `use Clementine.Agent, key: ...` for the durable runtime.
- **Rollout** (`Clementine.Rollout`): one execution's spec (agent, input,
  history, limits) and the engine that executes it, the model–tool
  cycle: call the model, run the tools it asks for, send back the
  results, until it answers or hits a limit.
- **Run** (`Clementine.Run`): one durable attempt at a rollout. On the
  runtime, a row of `agent_runs` (`Clementine.Runs.AgentRun`).
- **Runner** (`Clementine.Runner`): executes a run against a
  **Lifecycle** (`Clementine.Lifecycle`, the storage contract: `fetch`
  and `apply`, every write a compare-and-swap on `(status, epoch)`). It
  claims, heartbeats, parks for approval, and writes the end exactly once.
- **Result** (`Clementine.Result`): how a run ended: `Completed`,
  `Failed`, `Cancelled`, or `Interrupted`, each with its usage.
- **Loop** (`Clementine.Loop`): a standing controller. It is itself a run
  (`kind: "loop"`) that wakes on inputs from its inbox and starts,
  cancels, and times child runs. `Clementine.Thread` is the loop that
  answers a conversation's messages one turn at a time. "Loop" never
  means the model–tool cycle.
- **Turn**: a run on a thread (`turn: true`); any other run is a
  **task**. A **lane** holds one active run: a turn's lane is its thread,
  a task's is its agent and subject.
- **Verifier** (`Clementine.Verifier`): the shape of a judge function
  used above a run, judging a `Completed` and asking for a retry with
  feedback. Agents take no verifiers.

## Architecture

```
lib/
├── clementine.ex                  # Facade: run/3, stream/3, the {Clementine, ...} child spec,
│                                  #   AgentServer delegates (run_async, await, fork, ...)
├── clementine/
│   ├── agent.ex                   # Agent struct; `use Clementine.Agent` (key, turn, agent/1, history/1)
│   ├── rollout.ex                 # Rollout spec and the engine, execute/2
│   ├── run.ex, runner.ex          # One durable attempt; claim → execute → suspend or finish, once
│   ├── result.ex, error.ex, usage.ex
│   ├── lifecycle.ex, lifecycle/   # The storage contract; Facts, Transition, Ephemeral (in process);
│   │                              #   Protocol and the Ecto adapter (internal)
│   ├── lease.ex, heartbeat.ex     # Lease fencing and liveness
│   ├── reconciler.ex, interrupt_reason.ex   # The reaper's judgment
│   ├── checkpoint.ex, suspension.ex, resume_token.ex, pending.ex, approval_request.ex
│   │                              # Parking a run and resuming it
│   ├── runs.ex                    # The durable runtime's API: start, start_loop, send, resume,
│   │                              #   cancel, purge, get, list, child, trace, ...
│   ├── runs/                      # Its internals: Worker, StepWorker, TimerWorker, Lifecycle (over
│   │                              #   agent_runs), Loops, Delegations, Reaper, drain, cancel relay
│   ├── host.ex                    # The optional host module's callbacks
│   ├── migration.ex               # agent_runs, agent_run_inbox, agent_run_trace DDL, versions 1–4
│   ├── loop.ex, thread.ex         # The loop behaviour; the thread controller
│   ├── loop/                      # The pure loop core (step, envelope, codec; internal) and Report
│   ├── skill.ex, delegation.ex, engine_tool.ex   # skills:, delegates:, and their engine tools
│   │                                             #   (use_skill, delegate)
│   ├── output_schema.ex           # output_schema: decoding and checking
│   ├── trace.ex, trace/           # A run's trace and its recorder
│   ├── event.ex, events.ex, events/, run_view.ex   # (epoch, seq)-stamped events, sinks, the
│   │                                               #   live-view fold
│   ├── telemetry.ex, telemetry/
│   ├── tool.ex, tool_runner.ex, tool_context.ex, tool_input.ex, tool_result.ex
│   │                              # Tool macro, supervised batches, context helpers, input repair
│   ├── tools/                     # Built-in tools: ReadFile, WriteFile, ListDir, Search, Bash
│   ├── llm/                       # Provider clients, stream parsers, model registry, router
│   ├── host_call.ex               # Host code run mid-execution, bounded like a tool call
│   ├── agent_server.ex            # GenServer for local interactive use; each turn an in-process run
│   ├── verifier.ex
│   ├── lifecycle_case.ex, loop_case.ex   # Conformance batteries (internal)
│   └── application.ex             # Starts Clementine.TaskSupervisor
└── mix/
    ├── clementine.ex              # Shared generator machinery (guarded child placement)
    └── tasks/                     # clementine.install, clementine.gen.agent (Igniter)
priv/templates/                    # What the generators write into a host app
```

## The one engine

`Clementine.Rollout.execute/2` is the only model–tool cycle. It returns
a closed set the runner maps (`{:ok, Completed} | {:suspend, req} |
{:cancelled, reason} | :drained | {:error, %Error{}} | :lost_lease`),
and every caller reaches it through `Clementine.Runner.execute/2`:

- In process: `Clementine.run/3` and `stream/3` run against the
  ephemeral in-memory lifecycle, with the same runner and limits. A run
  there cannot park, so an approval-gated tool raises and delegates are
  left out.
- Durably: `Clementine.Runs.Worker` runs it against
  `Clementine.Runs.Lifecycle`, the library's lifecycle over `agent_runs`.
- Locally, interactively: `Clementine.AgentServer` holds a history and
  runs each turn in process. It is for IEx and local tools, never the
  owner of a production conversation.

Judging a result and retrying happens above a run: in process with a
`Clementine.Verifier`-shaped function, durably with a loop.

## How production uses it

The durable runtime is in the library. A host writes glue, and
`mix clementine.install` writes most of it:

- `{Clementine, repo:, oban:, queue:, agents:, host:}` after Oban in the
  supervision tree. It starts `Clementine.Runs.Supervisor` (drain
  notifier, cancel relay, inline loop steps, reaper) and refuses to start
  against a table behind the code's migration version.
- One migration calling `Clementine.Migration.up(version: 4)`.
- Agent modules (`use Clementine.Agent, key: ...`) and loop controllers
  (`use Clementine.Loop, key: ...`), each listed in `agents:`.
- An optional `Clementine.Host` module: `resolve_subject/2`,
  `resolve_actor/2`, `run_finished/2` (inside the transaction that ends
  a run), `run_committed/2`, `run_transition/2`, `run_event/2`,
  `authorize_resume/2`, and `authorize_tool/3` (the tool policy).

`Runs.start/3` inserts the run and its Oban job in one transaction. The
worker claims it, builds the agent and its history at the claim
(`agent/1`, `history/1`, the host's resolutions), and executes it.
`Runs.start_loop/3` and `Runs.send/3` drive loops, which step in
`Clementine.Runs.StepWorker`; their children are ordinary runs. Apps
never write the runtime's tables or call `Clementine.Lifecycle.*`;
`usage-rules.md` is the contract they code against. An app that keeps
its own run table and worker assembles the pieces itself
(`guides/durable-execution.md`).

`Clementine.Migration` holds every version's DDL, frozen: 1 builds
`agent_runs` on version 1 of the column recipe; 2 adds the actor, the
turn flag, and the lane index; 3 the loop columns, the child tag, and
`agent_run_inbox`; 4 `agent_run_trace`. Each stamps its number on the
table. A table change is a new version, never an edit to an old one,
and the installer template moves to it in the same commit
(`test/clementine/runs/migration_test.exs` and
`test/clementine/lifecycle/ecto_migration_versions_test.exs` hold the
frozen DDL).

## Tools and agents

```elixir
defmodule MyTool do
  use Clementine.Tool,
    name: "my_tool",
    description: "Does something",
    parameters: [
      param: [type: :string, required: true, description: "A param"]
    ]

  @impl true
  def run(%{param: param}, _context) do
    {:ok, "result for #{param}"}
  end
end
```

A tool returns `{:ok, string}`, `{:ok, string, is_error: true}` for a
failure the model should see, or `{:error, string}` for a call that
could not run; `retry: :safe` and `approval:` declare how the runtime
may treat it (`docs/TOOL_AUTHORING.md`).

```elixir
agent =
  Clementine.Agent.new(
    model: :claude_sonnet,
    instructions: "System prompt",
    tools: [MyTool],
    defaults: [max_iterations: 10, max_duration: :timer.minutes(5)]
  )

{:ok, %Clementine.Result.Completed{} = result} = Clementine.run(agent, "prompt")
```

On the durable runtime the same fields go in `use Clementine.Agent,
key: "my_agent", ...`; the key is stored on every run row, so it never
changes once runs exist.

## Testing

- The model is `Clementine.LLM.MockClient` (Mox, defined in
  `test/test_helper.exs`). The engine always streams, so script
  `:stream` with provider-event lists. Facade, AgentServer, and runtime
  tests use global mode, because runs execute in other processes.
- Runtime tests use `Clementine.RunsCase` (`test/support/runs_case.ex`:
  Oban in `:manual` mode and the test agents) and run jobs with
  `perform_job/2`. Test tools are in `test/support/test_tools.ex`, test
  loops in `test/support/test_loops.ex`, in-memory lifecycles in
  `test/support/memory_lifecycle.ex` and `memory_loop_host.ex`.
- `:postgres` tests are excluded when Postgres is unreachable.
  `test/test_helper.exs` drops and recreates the test database on every
  run, so each worktree sets its own `PGDATABASE=clementine_test_<issue>`.
- The design records' failure-matrix rows are named tests
  (`test "matrix row 3: ..."`, `L` rows for loops).
- The README's samples run under `test/clementine/guides_test.exs`, with
  the guides' and `usage-rules.md`'s: every `elixir` fence parses, every
  `defmodule` compiles, every relative link and anchor resolves, and an
  in-process sample marked `<!-- guide-sample: run -->` runs against a
  scripted model.

## Configuration

`config/` configures this repo's own development and tests; a host app
configures `:clementine` itself. What the library reads:

- `:models`, the catalog of model aliases. There are no built-in
  aliases: an alias resolves only if config names it. `docs/MODELS.md`
  has every key, a recipe per provider, and the reasoning table.
- Provider credentials and endpoints: `anthropic_api_key`,
  `openai_api_key`, `openrouter_api_key`, `bedrock_region`, ...
  (a literal, or `{:system, "ENV_VAR"}`).
- `:retry`: attempts and backoff for provider calls.
- `:default_model` and `:max_iterations`: read only by
  `Clementine.AgentServer`. An agent names its own model and limits.
- `:llm_client`: `config/test.exs` points it at the mock.

## Common tasks

### Adding a built-in tool

Follow `docs/TOOL_AUTHORING.md` (or the `/create-tool` skill). A
built-in tool lives in `lib/clementine/tools/`, requires its capability
with `Clementine.ToolContext.require_capability/2`, and resolves paths
with `Clementine.ToolContext.resolve_path/2`.

### Adding a model or a provider

Follow `docs/MODELS.md`. Most new providers are OpenAI-compatible
endpoints: a `provider: :openai_compatible` catalog entry with a
`base_url`, and no code. A new wire dialect needs a
`Clementine.LLM.ClientBehaviour` implementation, the provider atom in
`Clementine.LLM.ModelRegistry`, a `Clementine.LLM.Router` mapping, and a
`Clementine.LLM.Reasoning` translation.

### Changing the public surface or the generators

`mix clementine.install` and `mix clementine.gen.agent` render
`priv/templates/` into a host app and write only glue: the child spec,
one migration, config, a test case, and agent modules. A change to the
public surface (the child spec's options, `Clementine.Runs`,
`Clementine.Host`, `use Clementine.Agent`, `use Clementine.Loop`, the
tool macro) updates the templates, `usage-rules.md`, and the guides in
the same commit. `usage-rules.md` is what coding agents in host apps
read (the `usage_rules` package copies it into their `AGENTS.md`): keep
it short and decisive.

- `test/mix/clementine_templates_test.exs` compiles the rendered code
  with zero warnings allowed, so API drift fails CI.
- `test/mix/tasks/clementine.*_test.exs` drive the tasks through
  `Igniter.Test` (via `Clementine.IgniterCase`) and prove a second run
  changes nothing.
- `scripts/installer-smoke.sh` generates a real Phoenix app, installs
  twice, generates an agent twice, adds the hand-written chat example in
  `scripts/installer-smoke/chat`, and runs the app's format, compile,
  `credo --strict` (on our files), and tests end to end on Postgres.
  CI's `installer` job runs it; locally, run it after changing a
  template, one run at a time (it drops `clementine_smoke_test`).
- Never place a supervision child with Igniter's `add_new_child/3`: use
  `Mix.Clementine.add_child/4`, which inserts beside its anchor or edits
  nothing (its moduledoc says why).

### Debugging a run

- The model–tool cycle is `Clementine.Rollout.execute/2`; the machinery
  around it is `Clementine.Runner.execute/2`.
- `Clementine.stream/3` is the quickest way to watch a run in process;
  on the runtime, `Clementine.Runs.trace/1` lists its model calls and
  tool calls, and `run_event/2` receives its events.
- Lifecycle writes go through `Clementine.Lifecycle.Protocol`. Every
  write is a CAS on `(status, epoch)`, and `{:error, :stale}` means the
  guard worked, not that something broke.
- Tools execute in `Clementine.ToolRunner`; provider calls in
  `Clementine.LLM.Anthropic`, `Clementine.LLM.OpenAI`, and
  `Clementine.LLM.ChatCompletions`.

## Dependencies

As in `mix.exs`:

- Always: `req` (HTTP, streaming), `jason`, `nimble_options`,
  `telemetry`, `telemetry_metrics`.
- Optional, compiled only when the host brings them: `ecto_sql` and
  `postgrex` (the Ecto lifecycle and the runtime), `oban` 2.18 or later
  (the runtime), `phoenix_pubsub` (the Ecto adapter's `pubsub:` cancel
  push, for apps with their own lifecycle), and `igniter` (the
  generators).
- Dev and test only: `mox`, `bypass`, `stream_data`, `ex_doc`.

## Code style

- Functions that can fail return `{:ok, result}` or `{:error, reason}`.
- Tool results are always strings; the model consumes text.
- Prefer pattern matching over conditionals.
- Keep modules focused: one responsibility per module.
- Use typespecs for public functions.
