# Roadmap Ideas

Future enhancements and features for Clementine. These are ideas, not commitments.

## High Priority

### True Streaming Support

Currently `Clementine.stream/2` wraps `run/2` and emits the full result. True streaming would:

- Stream text deltas from the LLM in real-time
- Emit tool use events as they happen
- Allow UI to show typing indicators and progress

```elixir
# Desired API
Clementine.stream(agent, "Explain this")
|> Enum.each(fn
  {:text_delta, chunk} -> IO.write(chunk)
  {:tool_use_start, id, name} -> IO.puts("\n[Calling #{name}...]")
  {:tool_result, id, result} -> IO.puts("[Done]")
  {:done, :success} -> :ok
end)
```

**Implementation notes:**
- `Clementine.LLM.Anthropic.stream/5` already returns a stream of events
- Need to integrate streaming into `Clementine.Loop`
- Tool execution would interrupt the stream, execute, then resume

### Context Compaction / Summarization

Long-running agents accumulate large message histories. Add automatic compaction:

```elixir
config :clementine,
  compaction: [
    enabled: true,
    threshold_tokens: 50_000,
    strategy: :summarize  # or :truncate, :sliding_window
  ]
```

**Implementation notes:**
- Track token usage from API responses
- When threshold approached, summarize older messages
- Could use a smaller/faster model for summarization

### Persistence

Optional history persistence for long-running or resumable agents:

```elixir
config :clementine, :persistence,
  adapter: Clementine.Persistence.ETS,  # or :redis, :postgres
  ttl: :timer.hours(24)

# Resume a conversation
{:ok, agent} = MyAgent.start_link(conversation_id: "abc123")
```

**Adapters to consider:**
- ETS (in-memory, fast, no deps)
- Redis (distributed, TTL support)
- PostgreSQL (durable, queryable)
- File-based (simple, portable)

## Medium Priority

### Multi-Agent Orchestration

Following Anthropic's guidance: "give each subagent one job, let an orchestrator coordinate."

```elixir
defmodule MyOrchestrator do
  use Clementine.Orchestrator,
    agents: [
      planner: MyPlannerAgent,
      coder: MyCodingAgent,
      reviewer: MyReviewerAgent
    ],
    strategy: :sequential  # or :parallel, :dynamic
end
```

**Implementation notes:**
- Orchestrator is itself an agent with read-only tools
- Each subagent handles a specific domain
- Results flow back through orchestrator
- Subagents can run in parallel for independent tasks

### OpenAI Provider

Add OpenAI/GPT-4 support:

```elixir
config :clementine, :models,
  gpt4: [
    provider: :openai,
    model: "gpt-4-turbo",
    max_tokens: 4096
  ]
```

**Implementation notes:**
- Create `Clementine.LLM.OpenAI` module
- Handle different tool_call format
- Add streaming support for OpenAI's SSE format
- Consider function calling vs tool_use differences

### Better Error Recovery

Smarter handling of transient errors:

```elixir
config :clementine,
  error_recovery: [
    # Retry on these errors
    retryable: [:rate_limited, :overloaded, :timeout],
    # Max retries per error type
    max_retries: %{rate_limited: 5, overloaded: 3},
    # Custom backoff strategies
    backoff: :exponential_with_jitter
  ]
```

### Tool Timeout Configuration

Per-tool timeout settings:

```elixir
defmodule SlowTool do
  use Clementine.Tool,
    name: "slow_operation",
    timeout: :timer.minutes(5),  # Override default
    # ...
end
```

### Structured Output / JSON Mode

Support for forcing structured JSON responses:

```elixir
{:ok, result} = Clementine.run(agent, "Analyze this data",
  response_format: %{
    type: :json_schema,
    schema: %{
      type: "object",
      properties: %{
        sentiment: %{type: "string", enum: ["positive", "negative", "neutral"]},
        confidence: %{type: "number"}
      }
    }
  }
)
```

## Lower Priority

### Telemetry Integration

Add telemetry events for monitoring:

```elixir
# Events emitted:
[:clementine, :llm, :call, :start]
[:clementine, :llm, :call, :stop]
[:clementine, :tool, :execute, :start]
[:clementine, :tool, :execute, :stop]
[:clementine, :loop, :iteration, :start]
[:clementine, :loop, :iteration, :stop]
```

### Cost Tracking

Track and report API costs:

```elixir
{:ok, result, metadata} = Clementine.run_with_metadata(agent, prompt)
IO.inspect(metadata.usage)
# %{input_tokens: 1234, output_tokens: 567, estimated_cost_usd: 0.02}
```

### MCP (Model Context Protocol) Support

Support for MCP tools:

```elixir
defmodule MyAgent do
  use Clementine.Agent,
    tools: [
      {:mcp, "filesystem"},  # MCP server
      MyCustomTool           # Regular tool
    ]
end
```

### Caching Layer

Cache tool results and LLM responses:

```elixir
config :clementine, :cache,
  enabled: true,
  adapter: Clementine.Cache.ETS,
  ttl: :timer.minutes(15),
  # Cache identical prompts
  cache_llm_responses: true,
  # Cache tool results with same inputs
  cache_tool_results: true
```

### Agent Introspection / Debugging

Tools for debugging agent behavior:

```elixir
# Replay a conversation with detailed logging
Clementine.Debug.replay(agent, conversation_id: "abc123")

# Visualize the decision tree
Clementine.Debug.visualize(agent)

# Export conversation for analysis
Clementine.Debug.export(agent, format: :json)
```

### Rate Limiting

Built-in rate limiting for API calls:

```elixir
config :clementine, :rate_limit,
  requests_per_minute: 50,
  tokens_per_minute: 100_000,
  strategy: :sliding_window
```

## Experimental Ideas

### Memory / Knowledge Base

Long-term memory across conversations:

```elixir
defmodule MyAgent do
  use Clementine.Agent,
    memory: [
      adapter: Clementine.Memory.Vector,
      embeddings: :voyage,
      auto_store: true  # Store important facts automatically
    ]
end
```

### Planning Mode

Explicit planning before execution:

```elixir
{:ok, plan} = Clementine.plan(agent, "Refactor the auth system")
# Review plan...
{:ok, result} = Clementine.execute_plan(agent, plan)
```

### Human-in-the-Loop

Pause for human approval on certain operations:

```elixir
defmodule DangerousTool do
  use Clementine.Tool,
    requires_approval: true,
    approval_prompt: "This will delete files. Continue?"
end

# In usage:
Clementine.run(agent, prompt,
  on_approval_needed: fn tool, args ->
    IO.gets("Approve #{tool.name}? [y/n] ") == "y\n"
  end
)
```

### Agent Composition

Combine agents dynamically:

```elixir
# Create a new agent by combining capabilities
combined = Clementine.compose([
  {CodingAgent, weight: 0.7},
  {ReviewerAgent, weight: 0.3}
])
```

## Non-Goals

Things we explicitly don't want to add:

- **Complex orchestration graphs**: Keep the loop simple
- **Plugin systems**: Just use Elixir modules
- **GUI/Dashboard**: Use existing observability tools
- **Proprietary formats**: Stick to standard Elixir patterns
- **Heavy dependencies**: Keep the dep tree minimal

## Contributing Ideas

Have an idea? Consider:

1. Does it fit the "simple loop with tools" philosophy?
2. Can it be implemented without breaking existing APIs?
3. Does it have clear use cases beyond "might be cool"?
4. Can it be optional/configurable rather than default?

Open an issue to discuss before implementing.
