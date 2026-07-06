# CLAUDE.md

Instructions for Claude Code when working on this codebase.

## Project Overview

Clementine is an Elixir agent framework that models agent work as inert
definitions animated by explicit execution machinery. The inner loop is
Gather → Act (call the model, execute tools, feed results back); durability,
cancellation, suspension, and observation are the runner and lifecycle
layers around it. The spec is `docs/DURABLE_EXECUTION_RFC.md` (v2.1) — when
code and RFC disagree, the RFC wins.

## Architecture

The nouns (see the RFC's Vocabulary section): an `Agent` is a capability
definition, a `Rollout` is one execution spec, a `Run` is one durable
attempt, the `Runner` animates it against a host-owned `Lifecycle`, and a
`Result` is the terminal truth.

```
lib/
├── clementine.ex                    # Facade: Clementine.run/3, stream/3 (ephemeral path)
├── clementine/
│   ├── application.ex               # OTP Application, starts TaskSupervisor
│   ├── agent.ex                     # Agent struct (inert capability definition)
│   ├── rollout.ex                   # Rollout spec + the Gather → Act engine (execute/2)
│   ├── run.ex                       # Run struct (one durable attempt)
│   ├── runner.ex                    # Claim → execute → finish/suspend, exactly once
│   ├── heartbeat.ex                 # Liveness process; discovers lease loss
│   ├── lifecycle.ex                 # Two-function host behaviour (fetch/apply, CAS)
│   ├── lifecycle/
│   │   ├── protocol.ex              # Pure protocol core: claim/suspend/resume/finish/...
│   │   ├── facts.ex                 # Normalized lifecycle state
│   │   ├── transition.ex            # One guarded write, as a value
│   │   ├── ephemeral.ex             # In-memory lifecycle (scripts, evals, AgentServer)
│   │   └── ecto*.ex                 # Ecto adapter, column recipe, Oban judge
│   ├── result.ex                    # Terminal outcome: Completed/Failed/Cancelled/Interrupted
│   ├── error.ex                     # Normalized error shape with retryability
│   ├── event.ex / events*.ex        # (epoch, seq)-stamped execution events + sinks
│   ├── run_view.ex                  # Canonical fold of events into a live view
│   ├── checkpoint.ex / suspension.ex / resume_token.ex   # Suspend/resume machinery
│   ├── agent_server.ex              # Interactive GenServer wrapper (porch, not house)
│   ├── verifier.ex                  # Judge-function shape for outer control
│   ├── tool.ex                      # Tool behaviour & macro
│   ├── tool_runner.ex               # Supervised tool execution
│   ├── llm/                         # Provider clients, stream parsers, model registry
│   └── tools/                       # Built-in tools
```

## Key Patterns

### The One Engine

`Clementine.Rollout.execute/2` is the only Gather → Act loop. Its surface is
`new/1`, `limits/1`, `execute/2`; it returns a closed set the runner maps
(`{:ok, Completed} | {:suspend, req} | {:cancelled, reason} | :drained |
{:error, %Error{}} | :lost_lease`). Every consumer reaches it through
`Clementine.Runner.execute/2`:

- Scripts/evals: `Clementine.run/3` and `Clementine.stream/3` (ephemeral
  in-memory lifecycle, same runner algorithm).
- Interactive processes: `Clementine.AgentServer` (GenServer holding
  conversation history; each turn is an ephemeral run).
- Production: a host-owned worker calls `Runner.execute/2` with a durable
  `Clementine.Lifecycle` implementation (see the RFC's Host Integration
  Walkthrough).

Verification is not part of the inner loop: judge a `Result.Completed` and
retry with feedback one floor up (see `Clementine.Verifier`).

### Tool Definition

Tools use a macro that generates JSON Schema from Elixir parameter definitions:

```elixir
defmodule MyTool do
  use Clementine.Tool,
    name: "my_tool",
    description: "Does something",
    parameters: [
      param: [type: :string, required: true, description: "A param"]
    ]

  @impl true
  def run(%{param: param}, context) do
    {:ok, "result"}
  end
end
```

### Agent Definition

Agents are runtime-constructed values, not compile-time modules:

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

For an interactive process that accumulates history, wrap the same machinery
in `use Clementine.AgentServer, name: "my_agent", model: :claude_sonnet,
tools: [MyTool], system: "System prompt"`.

## Testing

- Tests use Mox for mocking the LLM client (`Clementine.LLM.MockClient`,
  defined in `test/test_helper.exs`); the engine always streams, so mock
  `:stream` with provider-event lists
- AgentServer and facade tests use `set_mox_global` because runs execute in
  separate processes
- Test tools are in `test/support/test_tools.ex`, fixtures in
  `test/support/fixtures.ex`, in-memory lifecycles in
  `test/support/memory_lifecycle.ex`
- The RFC's 18-row failure matrix is the proof obligation: matrix rows are
  named tests (`test "matrix row 3: ..."`)
- Ecto lifecycle tests need Postgres; they are tagged and skippable

Run tests: `mix test`

## Configuration

Configuration is in `config/`:
- `config.exs` - Default settings, model definitions
- `dev.exs` - Development overrides
- `test.exs` - Test settings (mock LLM client)
- `prod.exs` - Production settings

Key config:
```elixir
config :clementine,
  anthropic_api_key: {:system, "ANTHROPIC_API_KEY"},  # or literal string
  default_model: :claude_sonnet,
  max_iterations: 10

config :clementine, :models,
  claude_sonnet: [
    provider: :anthropic,
    id: "claude-sonnet-4-20250514",
    defaults: [max_tokens: 8192]
  ]
```

## Common Tasks

### Adding a New Tool

1. Create `lib/clementine/tools/my_tool.ex`
2. Use the `Clementine.Tool` macro
3. Implement the `run/2` callback
4. Tool results must be `{:ok, string}`, `{:ok, string, opts}`, or `{:error, string}`
   - Use `{:ok, content, is_error: true}` for command-level failures (e.g. non-zero exit)
   - See `docs/TOOL_AUTHORING.md` for the full result contract

### Adding a New LLM Provider

1. Create `lib/clementine/llm/provider_name.ex`
2. Implement `Clementine.LLM.ClientBehaviour`
3. Add model config to `config/config.exs`
4. Update `Clementine.LLM` to route to the new provider

### Debugging Agent Issues

- The inner loop is `Clementine.Rollout.execute/2`; the execution machinery
  around it is `Clementine.Runner.execute/2`
- Observe execution through an events sink (`Clementine.Events` behaviour);
  `Clementine.stream/3` is the quickest way to watch a run
- Lifecycle writes flow through `Clementine.Lifecycle.Protocol` — every
  write is a CAS on `(status, epoch)`, and `{:error, :stale}` means the
  guard worked, not that something broke
- Tool execution happens in `Clementine.ToolRunner`
- Provider calls happen in `Clementine.LLM.Anthropic` / `Clementine.LLM.OpenAI`

## Dependencies

- `req` - HTTP client (supports streaming)
- `jason` - JSON encoding/decoding
- `nimble_options` - Schema validation (used internally)
- `mox` - Test mocking (test only)

## Code Style

- Functions that can fail return `{:ok, result}` or `{:error, reason}`
- Tool results are always strings (LLM consumes text)
- Prefer pattern matching over conditionals
- Keep modules focused - one responsibility per module
- Use typespecs for public functions
