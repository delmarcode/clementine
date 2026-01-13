# Clementine

> A simple, process-oriented agent framework for Elixir inspired by Claude Code's architecture

## Philosophy

**The best agent framework is barely a framework at all.**

Clementine rejects the over-abstraction of LangChain-style frameworks in favor of the pattern that actually works in production: a simple loop with tools.

```
gather context → act → verify → repeat
```

This is how Claude Code works. This is how humans work. This is how Clementine works.

### Core Beliefs

1. **Tools are just functions** - No special DSL, no complex registration. A tool is a function with a schema.

2. **The model is smart** - Stop trying to outsmart the LLM with elaborate orchestration graphs. Give it tools, let it work.

3. **Processes are the right abstraction** - Elixir's process model maps perfectly to agents. An agent is a process. Supervision, messaging, and state management come free.

4. **Verification beats planning** - Don't predict failures, detect them. Run the code, check the output, fix if needed.

5. **Direct beats indirect** - Call the LLM API directly. No middleware layers, no adapter abstractions. HTTP in, JSON out.

---

## Architecture

### The Loop

Every Clementine agent runs the same core loop:

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐           │
│   │ Gather  │───▶│   Act   │───▶│ Verify  │───┐       │
│   │ Context │    │         │    │         │   │       │
│   └─────────┘    └─────────┘    └─────────┘   │       │
│        ▲                                       │       │
│        └───────────────────────────────────────┘       │
│                                                         │
│                    until done                           │
└─────────────────────────────────────────────────────────┘
```

**Gather**: Read files, search, query databases, call APIs
**Act**: Call the LLM, execute tool calls, write files
**Verify**: Run tests, check output, validate results

The loop continues until:
- The model returns a final response (no tool calls)
- A verification step confirms success
- Max iterations reached
- An unrecoverable error occurs

### Process Model

```
┌─────────────────────────────────────────────────────────┐
│                    Application                          │
│  ┌───────────────────────────────────────────────────┐ │
│  │               Clementine.Supervisor               │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐          │ │
│  │  │ Agent 1 │  │ Agent 2 │  │ Agent N │          │ │
│  │  │ (GenServer)│ (GenServer)│ (GenServer)        │ │
│  │  └────┬────┘  └────┬────┘  └────┬────┘          │ │
│  │       │            │            │                │ │
│  │       ▼            ▼            ▼                │ │
│  │  ┌─────────────────────────────────────────┐    │ │
│  │  │           Tool Execution Pool           │    │ │
│  │  │  (Task.Supervisor for parallel tools)   │    │ │
│  │  └─────────────────────────────────────────┘    │ │
│  └───────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

Each agent is a `GenServer` that:
- Maintains conversation history
- Executes the gather→act→verify loop
- Can spawn supervised tasks for tool execution
- Can be supervised, restarted, and monitored

---

## Core Concepts

### Tools

A tool is a module with two things: a schema and a run function.

```elixir
defmodule MyApp.Tools.ReadFile do
  use Clementine.Tool,
    name: "read_file",
    description: "Read the contents of a file",
    parameters: [
      path: [type: :string, required: true, description: "Path to the file"]
    ]

  @impl true
  def run(%{path: path}, _context) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end
end
```

That's it. No registration, no chains, no callbacks. The `use Clementine.Tool` macro:
- Validates the schema at compile time
- Generates the JSON schema for the LLM automatically
- Provides a consistent interface

**Tool results are always strings or errors.** The LLM consumes text. Don't make it complicated.

### Agents

An agent is a process that runs the loop with a set of tools.

```elixir
defmodule MyApp.CodingAgent do
  use Clementine.Agent,
    name: "coding_agent",
    model: :claude_sonnet,
    tools: [
      MyApp.Tools.ReadFile,
      MyApp.Tools.WriteFile,
      MyApp.Tools.RunCommand,
      MyApp.Tools.Search
    ],
    system: """
    You are a coding assistant. You have access to the filesystem and can run commands.
    Always verify your changes by running tests or checking the output.
    """
end

# Start it
{:ok, agent} = MyApp.CodingAgent.start_link()

# Send a task
{:ok, result} = MyApp.CodingAgent.run(agent, "Add a function that calculates fibonacci numbers to lib/math.ex")
```

### Verifiers

Verifiers are optional checks that run after each action. They can trigger re-attempts.

```elixir
defmodule MyApp.Verifiers.TestsPassing do
  use Clementine.Verifier

  @impl true
  def verify(_action_result, context) do
    case System.cmd("mix", ["test"], cd: context.working_dir) do
      {_, 0} -> :ok
      {output, _} -> {:retry, "Tests failed:\n#{output}"}
    end
  end
end
```

When a verifier returns `{:retry, reason}`, the reason is fed back to the model as context for the next iteration.

---

## API Design

### Starting an Agent

```elixir
# With defaults from module definition
{:ok, agent} = MyApp.CodingAgent.start_link()

# With runtime overrides
{:ok, agent} = MyApp.CodingAgent.start_link(
  model: :claude_opus,
  max_iterations: 20,
  timeout: :timer.minutes(5)
)

# Under a supervisor
children = [
  {MyApp.CodingAgent, name: :coding_agent}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

### Running Tasks

```elixir
# Synchronous (blocks until complete)
{:ok, result} = Clementine.run(agent, "Fix the bug in user authentication")

# Asynchronous (returns immediately)
{:ok, task_id} = Clementine.run_async(agent, "Refactor the database module")

# Check status
{:running, %{iterations: 3, last_action: "write_file"}} = Clementine.status(agent, task_id)

# Wait for completion
{:ok, result} = Clementine.await(agent, task_id, timeout: :timer.minutes(10))

# Stream updates
Clementine.stream(agent, "Explain this codebase") |> Enum.each(&IO.write/1)
```

### Conversation Management

```elixir
# Continue a conversation
{:ok, result} = Clementine.run(agent, "Now add tests for that function")

# Clear history
Clementine.clear_history(agent)

# Fork a conversation (creates new agent with same history)
{:ok, forked} = Clementine.fork(agent)
```

### Direct Tool Execution

Sometimes you want to run a tool directly without the LLM:

```elixir
# Execute a tool directly
{:ok, content} = Clementine.Tool.run(MyApp.Tools.ReadFile, %{path: "README.md"})
```

---

## Configuration

### Global Config

```elixir
# config/config.exs
config :clementine,
  default_model: :claude_sonnet,
  api_key: {:system, "ANTHROPIC_API_KEY"},  # or literal string
  max_iterations: 10,
  timeout: :timer.minutes(5),
  log_level: :info
```

### Model Configuration

```elixir
config :clementine, :models,
  claude_sonnet: [
    provider: :anthropic,
    model: "claude-sonnet-4-20250514",
    max_tokens: 8192
  ],
  claude_haiku: [
    provider: :anthropic,
    model: "claude-haiku-4-5-20250514",
    max_tokens: 4096
  ],
  gpt4: [
    provider: :openai,
    model: "gpt-4-turbo",
    max_tokens: 4096
  ]
```

---

## The Loop in Detail

### 1. Message Construction

Each iteration constructs a message for the LLM:

```elixir
%{
  system: agent.system_prompt,
  messages: agent.history ++ [
    %{role: "user", content: current_task},
    # ... previous assistant responses and tool results
  ],
  tools: Enum.map(agent.tools, &Clementine.Tool.to_schema/1)
}
```

### 2. LLM Call

Direct HTTP to the provider API. No middleware.

```elixir
defmodule Clementine.LLM do
  def call(model, messages, tools, opts \\ []) do
    provider = get_provider(model)

    request = build_request(provider, messages, tools, opts)

    case Req.post(provider.endpoint, json: request, headers: headers(provider)) do
      {:ok, %{status: 200, body: body}} -> parse_response(provider, body)
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### 3. Response Handling

```elixir
case response do
  # Model wants to call tools
  {:tool_calls, calls} ->
    results = execute_tools(calls, context)
    loop(agent, add_tool_results(messages, calls, results))

  # Model returned final text
  {:text, content} ->
    case run_verifiers(agent.verifiers, content, context) do
      :ok -> {:ok, content}
      {:retry, reason} -> loop(agent, add_retry_context(messages, reason))
    end

  # Error from LLM
  {:error, reason} ->
    {:error, reason}
end
```

### 4. Tool Execution

Tools run in supervised tasks for isolation:

```elixir
defmodule Clementine.ToolRunner do
  def execute(tools, calls, context) do
    calls
    |> Enum.map(fn call ->
      Task.Supervisor.async_nolink(Clementine.TaskSupervisor, fn ->
        tool = find_tool(tools, call.name)
        {call.id, Clementine.Tool.run(tool, call.arguments, context)}
      end)
    end)
    |> Task.await_many(timeout())
  end
end
```

---

## Error Handling

### Retries

Transient errors (rate limits, network issues) are retried with exponential backoff:

```elixir
config :clementine,
  retry: [
    max_attempts: 3,
    base_delay: 1000,
    max_delay: 30_000
  ]
```

### Tool Errors

Tool errors are returned to the model as context, not raised:

```elixir
# If a tool returns {:error, reason}
%{
  role: "tool",
  tool_call_id: call.id,
  content: "Error: #{reason}"
}
```

The model can then decide to retry differently or report the error.

### Agent Crashes

Agents are supervised. If an agent crashes:
1. The supervisor restarts it
2. In-flight tasks receive `{:error, :agent_restarted}`
3. History is lost unless persistence is configured

---

## Comparison to Existing Solutions

| Feature | Clementine | Jido | LangChain |
|---------|------------|------|-----------|
| Core abstraction | Tool loop | Actions + Signals | Chains + Agents |
| Process model | GenServer per agent | GenServer + complex state | None (Python) |
| LLM integration | Direct HTTP | Via LangChain wrapper | Native |
| Tool definition | Simple module | Action with schema | Tool classes |
| Verification | Built-in verifiers | Manual | Callbacks |
| Learning curve | Minimal | Moderate | Steep |
| Debugging | Transparent loop | Signal tracing | Black box |

### vs Jido

**What we keep from Jido:**
- Process-oriented design (GenServers, supervision)
- Actions as the unit of work (simplified to Tools)
- Schema validation with NimbleOptions

**What we change:**
- Remove LangChain dependency entirely
- Simplify to single loop pattern (no chains, no complex orchestration)
- Direct LLM calls instead of adapter layers
- Built-in verification step

### vs Claude Agent SDK (TypeScript)

**What we adopt:**
- The gather→act→verify loop
- Tools as simple functions
- Direct model communication
- Verification-driven iteration

**What we add:**
- Elixir process model (supervision, distribution)
- Native concurrency for parallel tool execution
- OTP patterns for reliability

---

## Example: A Coding Agent

```elixir
defmodule MyCodingAgent do
  use Clementine.Agent,
    name: "coder",
    model: :claude_sonnet,
    tools: [
      Clementine.Tools.ReadFile,
      Clementine.Tools.WriteFile,
      Clementine.Tools.ListDir,
      Clementine.Tools.Bash,
      Clementine.Tools.Search
    ],
    verifiers: [
      MyCodingAgent.Verifiers.TypeCheck,
      MyCodingAgent.Verifiers.TestsPassing
    ],
    system: """
    You are an expert Elixir developer. You have access to the filesystem and can run commands.

    Guidelines:
    - Always read existing code before modifying
    - Run `mix format` after writing Elixir files
    - Run tests to verify your changes
    - If tests fail, analyze the output and fix the issues
    """

  defmodule Verifiers.TypeCheck do
    use Clementine.Verifier

    def verify(_result, ctx) do
      case System.cmd("mix", ["dialyzer"], cd: ctx.working_dir, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, _} -> {:retry, "Type errors found:\n#{output}"}
      end
    end
  end

  defmodule Verifiers.TestsPassing do
    use Clementine.Verifier

    def verify(_result, ctx) do
      case System.cmd("mix", ["test"], cd: ctx.working_dir, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, _} -> {:retry, "Tests failed:\n#{output}"}
      end
    end
  end
end

# Usage
{:ok, agent} = MyCodingAgent.start_link(working_dir: "/path/to/project")

{:ok, result} = Clementine.run(agent, """
Add a GenServer module at lib/my_app/cache.ex that implements a simple TTL cache.
Include tests.
""")
```

---

## Future Considerations

### Multi-Agent Coordination

Following Anthropic's guidance: "give each subagent one job, let an orchestrator coordinate."

```elixir
defmodule MyOrchestrator do
  use Clementine.Orchestrator,
    agents: [
      planner: MyPlannerAgent,
      coder: MyCodingAgent,
      reviewer: MyReviewerAgent
    ]

  # Orchestrator has read-only tools, delegates to specialists
end
```

### Persistence

Optional history persistence for long-running agents:

```elixir
config :clementine, :persistence,
  adapter: Clementine.Persistence.ETS,  # or Redis, Postgres
  ttl: :timer.hours(24)
```

### Streaming

First-class streaming support:

```elixir
Clementine.stream(agent, "Explain this code")
|> Stream.each(fn
  {:text, chunk} -> IO.write(chunk)
  {:tool_call, call} -> IO.puts("\n[Calling #{call.name}...]")
  {:tool_result, result} -> IO.puts("[Done]\n")
end)
|> Stream.run()
```

---

## Summary

Clementine is:
- **Simple**: One loop, tools in, results out
- **Transparent**: No black boxes, direct API calls
- **Elixir-native**: Processes, supervision, OTP patterns
- **Verification-first**: Built-in retry on failure

It's what you'd build if you started from Claude Code's architecture and wanted it in Elixir.
