# Clementine

A simple, process-oriented agent framework for Elixir inspired by Claude Code's architecture.

## Philosophy

**The best agent framework is barely a framework at all.**

Clementine rejects the over-abstraction of LangChain-style frameworks in favor of the pattern that actually works in production: a simple loop with tools.

```
gather context → act → verify → repeat
```

This is how Claude Code works. This is how humans work. This is how Clementine works.

## Installation

Add `clementine` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:clementine, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Configure your API key

```elixir
# config/config.exs
config :clementine,
  api_key: {:system, "ANTHROPIC_API_KEY"}
```

### 2. Define an agent

```elixir
defmodule MyApp.CodingAgent do
  use Clementine.Agent,
    name: "coding_agent",
    model: :claude_sonnet,
    tools: [
      Clementine.Tools.ReadFile,
      Clementine.Tools.WriteFile,
      Clementine.Tools.Bash
    ],
    system: """
    You are an expert Elixir developer. You have access to the filesystem
    and can run commands. Always verify your changes by running tests.
    """
end
```

### 3. Use it

```elixir
{:ok, agent} = MyApp.CodingAgent.start_link()
{:ok, result} = Clementine.run(agent, "Add a fibonacci function to lib/math.ex")
```

## Core Concepts

### Tools

Tools are functions the agent can call. They're defined with a simple macro:

```elixir
defmodule MyApp.Tools.Weather do
  use Clementine.Tool,
    name: "get_weather",
    description: "Get the current weather for a location",
    parameters: [
      location: [type: :string, required: true, description: "City name"]
    ]

  @impl true
  def run(%{location: location}, _context) do
    # Fetch weather...
    {:ok, "72°F and sunny in #{location}"}
  end
end
```

**Tool results are always strings.** The LLM consumes text. Don't make it complicated.

### Verifiers

Verifiers are optional checks that run after the model returns a final response:

```elixir
defmodule MyApp.Verifiers.TestsPassing do
  use Clementine.Verifier

  @impl true
  def verify(_result, context) do
    case System.cmd("mix", ["test"], cd: context.working_dir) do
      {_, 0} -> :ok
      {output, _} -> {:retry, "Tests failed:\n#{output}"}
    end
  end
end
```

When a verifier returns `{:retry, reason}`, the reason is fed back to the model and the loop continues.

### Agents

Agents are GenServers that run the agentic loop:

```elixir
defmodule MyApp.Agent do
  use Clementine.Agent,
    name: "my_agent",
    model: :claude_sonnet,
    tools: [MyApp.Tools.Weather],
    verifiers: [MyApp.Verifiers.TestsPassing],
    system: "You are a helpful assistant."
end
```

## API

### Running Tasks

```elixir
# Synchronous
{:ok, result} = Clementine.run(agent, "What's the weather?")

# Asynchronous
{:ok, task_id} = Clementine.run_async(agent, "Long running task")
{:ok, :running} = Clementine.status(agent, task_id)
```

### Streaming

Stream responses token-by-token as they arrive from the LLM:

```elixir
Clementine.Loop.run_stream(
  [
    model: :claude_sonnet,
    system: "You have tools. Use them when asked. Be brief.",
    tools: [Clementine.Tools.ListDir]
  ],
  "What files are in the current directory?",
  fn
    {:text_delta, text} -> IO.write(text)
    {:tool_use_start, _id, name} -> IO.write("\n[calling #{name}...] ")
    {:tool_result, _id, {:ok, result}} -> IO.puts("[got #{String.length(result)} chars]")
    {:tool_result, _id, {:error, err}} -> IO.puts("[error: #{err}]")
    _ -> :ok
  end
)
```

The callback receives events as they happen:

| Event | Description |
|-------|-------------|
| `{:text_delta, text}` | A chunk of text from the model |
| `{:tool_use_start, id, name}` | Model is calling a tool |
| `{:input_json_delta, json}` | Tool input JSON chunk |
| `{:tool_result, id, result}` | Tool finished executing |
| `{:loop_event, event}` | Internal loop events |

#### Streaming in Phoenix LiveView

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  def handle_event("submit", %{"prompt" => prompt}, socket) do
    pid = self()

    Task.start(fn ->
      Clementine.Loop.run_stream(
        [model: :claude_sonnet, tools: [Clementine.Tools.Bash]],
        prompt,
        fn
          {:text_delta, text} -> send(pid, {:stream, text})
          {:tool_use_start, _, name} -> send(pid, {:tool, name})
          _ -> :ok
        end
      )
      send(pid, :done)
    end)

    {:noreply, assign(socket, :streaming, true)}
  end

  def handle_info({:stream, text}, socket) do
    {:noreply, update(socket, :response, &(&1 <> text))}
  end

  def handle_info({:tool, name}, socket) do
    {:noreply, assign(socket, :current_tool, name)}
  end

  def handle_info(:done, socket) do
    {:noreply, assign(socket, :streaming, false)}
  end
end
```

### Conversation Management

```elixir
# Get history
history = Clementine.get_history(agent)

# Clear history (start fresh)
Clementine.clear_history(agent)

# Fork (create new agent with same history)
{:ok, forked} = Clementine.fork(agent, MyApp.Agent)
```

## Built-in Tools

| Tool | Description |
|------|-------------|
| `Clementine.Tools.ReadFile` | Read file contents with optional line ranges |
| `Clementine.Tools.WriteFile` | Write/create files |
| `Clementine.Tools.ListDir` | List directory contents |
| `Clementine.Tools.Bash` | Execute shell commands |
| `Clementine.Tools.Search` | Grep-like content search |

## Configuration

```elixir
# config/config.exs
config :clementine,
  api_key: {:system, "ANTHROPIC_API_KEY"},
  default_model: :claude_sonnet,
  max_iterations: 10,
  timeout: :timer.minutes(5),
  retry: [
    max_attempts: 3,
    base_delay: 1000,
    max_delay: 30_000
  ]

config :clementine, :models,
  claude_sonnet: [
    provider: :anthropic,
    model: "claude-sonnet-4-20250514",
    max_tokens: 8192
  ],
  claude_opus: [
    provider: :anthropic,
    model: "claude-opus-4-20250514",
    max_tokens: 8192
  ]
```

## Why Clementine?

### vs LangChain

- **Simpler**: One loop pattern, not chains of abstractions
- **Transparent**: Direct API calls, no middleware maze
- **Elixir-native**: Built on OTP, not ported from Python

### vs Building from Scratch

- **Tool schema generation**: Define params in Elixir, get JSON Schema
- **Verification built-in**: Retry on failure without custom logic
- **Process isolation**: Tool crashes don't kill the agent
- **Supervised execution**: OTP patterns for reliability

## The Loop

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

**Gather**: Tools fetch files, search, query APIs
**Act**: LLM processes context, calls tools or returns response
**Verify**: Verifiers check output, trigger retry if needed

The loop continues until:
- The model returns a final response (no tool calls) and verifiers pass
- Max iterations reached
- An unrecoverable error occurs

## License

MIT
