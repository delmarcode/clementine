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

### 1. Configure your API key(s)

```elixir
# config/config.exs
config :clementine,
  anthropic_api_key: {:system, "ANTHROPIC_API_KEY"},
  openai_api_key: {:system, "OPENAI_API_KEY"}
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
{:ok, agent} =
  MyApp.CodingAgent.start_link(
    working_dir: File.cwd!(),
    context: %{capabilities: %{read: true, write: true, shell: true}}
  )

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

Tools can also return `{:ok, content, is_error: true}` to signal a command-level failure (like a non-zero exit code) while still delivering the output to the model. Use `{:error, reason}` only for invocation failures (timeouts, crashes, bad args). See `docs/TOOL_AUTHORING.md` for the full guide.

Built-in filesystem and shell tools require explicit capabilities in the tool context:

```elixir
context: %{
  capabilities: %{read: true, write: true, shell: false}
}
```

Filesystem paths are scoped to the agent's `:working_dir` or `:workspace_root`; parent traversal and symlink escapes outside that root return an error.

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

Stream a run's execution events as they happen. `Clementine.stream/3` takes an
agent value and returns a lazy enumerable of `(epoch, seq)`-stamped
`Clementine.Event` structs, ending with `{:result, result}` carrying the
terminal `Clementine.Result`:

```elixir
agent =
  Clementine.Agent.new(
    model: :claude_sonnet,
    instructions: "You have tools. Use them when asked. Be brief.",
    tools: [Clementine.Tools.ListDir]
  )

Clementine.stream(agent, "What files are in the current directory?")
|> Enum.each(fn
  %Clementine.Event{type: :text_delta, payload: %{content: text}} ->
    IO.write(text)

  %Clementine.Event{type: :tool_use_start, payload: %{name: name}} ->
    IO.write("\n[calling #{name}...] ")

  %Clementine.Event{type: :tool_result, payload: %{is_error: is_error}} ->
    IO.puts(if is_error, do: "[tool error]", else: "[done]")

  {:result, %Clementine.Result.Completed{}} ->
    IO.puts("")

  {:result, %Clementine.Result.Failed{error: error}} ->
    IO.puts("\nrun failed: #{error.message}")

  _ ->
    :ok
end)
```

The stream is caller-owned: consuming it runs the rollout, and abandoning it
aborts the run. Event types are the closed taxonomy in `Clementine.Event`
(`iteration_start`, `text_delta`, `tool_use_start`, `tool_input_delta`,
`tool_result`, `approval_requested`, `usage_delta`, `error`). Advisory deltas —
including `error` events — may precede the terminal `{:result, _}` element;
the result is truth.

`Clementine.AgentServer.stream/2` yields the same vocabulary for interactive
agent processes and folds a completed turn into the agent's history.

For production hosts that need conversations to survive deploys, pod exits, or
client reconnects, keep durable run state in the host application and drive the
runner from a host-owned worker. See
[`docs/DURABLE_EXECUTION_RFC.md`](docs/DURABLE_EXECUTION_RFC.md) and
[`docs/DURABLE_HOST_HARNESSES.md`](docs/DURABLE_HOST_HARNESSES.md).

#### Streaming in Phoenix LiveView

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  def handle_event("submit", %{"prompt" => prompt}, socket) do
    pid = self()
    agent = MyApp.Agents.assistant()   # a %Clementine.Agent{} value

    Task.start(fn ->
      Clementine.stream(agent, prompt)
      |> Enum.each(fn
        %Clementine.Event{type: :text_delta, payload: %{content: text}} ->
          send(pid, {:stream, text})

        %Clementine.Event{type: :tool_use_start, payload: %{name: name}} ->
          send(pid, {:tool, name})

        {:result, result} ->
          send(pid, {:done, result})

        _ ->
          :ok
      end)
    end)

    {:noreply, assign(socket, :streaming, true)}
  end

  def handle_info({:stream, text}, socket) do
    {:noreply, update(socket, :response, &(&1 <> text))}
  end

  def handle_info({:tool, name}, socket) do
    {:noreply, assign(socket, :current_tool, name)}
  end

  def handle_info({:done, %Clementine.Result.Completed{}}, socket) do
    {:noreply, assign(socket, :streaming, false)}
  end

  def handle_info({:done, result}, socket) do
    {:noreply, assign(socket, :streaming, false) |> assign(:error, inspect(result))}
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
  anthropic_api_key: {:system, "ANTHROPIC_API_KEY"},
  openai_api_key: {:system, "OPENAI_API_KEY"},
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
    id: "claude-sonnet-4-20250514",
    defaults: [max_tokens: 8192],
    reasoning: [thinking: :adaptive, effort: :high]
  ],
  claude_opus: [
    provider: :anthropic,
    id: "claude-opus-4-20250514",
    defaults: [max_tokens: 8192]
  ],
  gpt_5: [
    provider: :openai,
    id: "gpt-5",
    defaults: [max_output_tokens: 4096],
    reasoning: [effort: :medium]
  ],
  gpt_5_codex: [
    provider: :openai,
    id: "gpt-5-codex",
    defaults: [max_output_tokens: 4096]
  ],
  deepseek: [
    provider: :openrouter,
    id: "deepseek/deepseek-v3.2",
    reasoning: [effort: :high]
  ],
  qwen_bedrock: [
    provider: :bedrock,
    id: "qwen.qwen3-235b-a22b-2507-v1:0"
  ],
  glm_vertex: [
    provider: :vertex,
    id: "zai/glm-4.7-maas"
  ],
  qwen_finetune: [
    provider: :openai_compatible,
    base_url: "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1",
    api_key: {:system, "TINKER_API_KEY"},
    id: "tinker://my-run:train:0/sampler_weights/000080"
  ]
```

The optional `reasoning:` key is provider-neutral: a bare effort level
(`reasoning: :high`) works for every provider, and richer keyword forms map
to each provider's own controls — `effort`/`summary` for OpenAI,
`thinking`/`effort`/`budget_tokens`/`display` for Anthropic, the unified
`reasoning` object for OpenRouter, and `reasoning_effort` for the other
chat-completions providers. Configure one alias per reasoning level to run
the same model id at several levels. See `Clementine.LLM.Reasoning` for the
full mapping.

### Open models and fine-tunes

Beyond the first-party Anthropic and OpenAI clients, four provider atoms
route through a shared OpenAI-compatible Chat Completions client
(`Clementine.LLM.ChatCompletions`) — the dialect every open-model and
fine-tune serving lane speaks:

- `provider: :openrouter` — DeepSeek, Qwen, GLM, and hundreds of other
  models behind one key. Configure `openrouter_api_key`.
- `provider: :bedrock` — Amazon Bedrock's Chat Completions endpoint with a
  Bedrock API key (bearer token, no SigV4). Configure `bedrock_api_key`
  and `bedrock_region` (or `bedrock_base_url`).
- `provider: :vertex` — Google Vertex AI's OpenAI-compatible MaaS endpoint.
  Configure `vertex_project`, `vertex_region` (or `vertex_base_url`), and
  `vertex_access_token` — typically an MFA tuple like
  `{MyApp.GcpAuth, :access_token, []}` since OAuth tokens are short-lived.
- `provider: :openai_compatible` — anything else that speaks the dialect:
  Tinker (Thinking Machines) checkpoint inference, Together, Fireworks, or
  self-hosted vLLM/SGLang. Set `base_url:` (and optionally `api_key:`) per
  model; `api_key` may be omitted for keyless local servers.

You can also bypass aliases and pass provider model IDs directly:

```elixir
agent = Clementine.Agent.new(model: {:openai, "gpt-5"})
{:ok, result} = Clementine.run(agent, "Hi")
```

See [docs/MODELS.md](docs/MODELS.md) for the full catalog reference:
per-provider recipes, endpoint/credential configuration, the reasoning
mapping table, and the checklist for adding any model or provider.

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
