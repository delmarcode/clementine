# CLAUDE.md

Instructions for Claude Code when working on this codebase.

## Project Overview

Clementine is a process-oriented agent framework for Elixir inspired by Claude Code's architecture. It implements the gather→act→verify loop pattern using Elixir's process model.

## Architecture

```
lib/
├── clementine.ex                    # Public API (delegates to Agent)
├── clementine/
│   ├── application.ex               # OTP Application, starts TaskSupervisor
│   ├── tool.ex                      # Tool behaviour & macro
│   ├── agent.ex                     # Agent behaviour & GenServer macro
│   ├── verifier.ex                  # Verifier behaviour
│   ├── loop.ex                      # Core agentic loop (pure functions)
│   ├── tool_runner.ex               # Supervised tool execution
│   ├── llm/
│   │   ├── client_behaviour.ex      # Behaviour for LLM clients (for mocking)
│   │   ├── llm.ex                   # LLM interface module
│   │   ├── anthropic.ex             # Anthropic API client
│   │   ├── stream_parser.ex         # SSE stream parsing
│   │   └── message.ex               # Message type structs
│   └── tools/                       # Built-in tools
│       ├── read_file.ex
│       ├── write_file.ex
│       ├── list_dir.ex
│       ├── bash.ex
│       └── search.ex
```

## Key Patterns

### The Agentic Loop

The core loop in `lib/clementine/loop.ex` follows this pattern:
1. Send messages to LLM
2. If response contains tool_use → execute tools, add results, continue
3. If response is final text → run verifiers
4. If verifiers fail → add retry context, continue
5. If verifiers pass → return result

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

Agents are GenServers defined via macro:

```elixir
defmodule MyAgent do
  use Clementine.Agent,
    name: "my_agent",
    model: :claude_sonnet,
    tools: [MyTool],
    verifiers: [],
    system: "System prompt"
end
```

## Testing

- Tests use Mox for mocking the LLM client
- The mock is defined in `test/test_helper.exs`
- Agent tests use `set_mox_global` because GenServers run in separate processes
- Test tools are in `test/support/test_tools.ex`
- Test fixtures in `test/support/fixtures.ex`

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
  api_key: {:system, "ANTHROPIC_API_KEY"},  # or literal string
  default_model: :claude_sonnet,
  max_iterations: 10

config :clementine, :models,
  claude_sonnet: [provider: :anthropic, model: "claude-sonnet-4-20250514", max_tokens: 8192]
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

- Check `Clementine.Loop` for the core logic
- Use the `on_event` callback to trace execution
- Tool execution happens in `Clementine.ToolRunner`
- LLM calls happen in `Clementine.LLM.Anthropic`

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
