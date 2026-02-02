# Streaming Agent Application Design Doc

A Phoenix + Next.js application with real-time streaming, tool visualization, and interactive UI blocks—powered by Clementine.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Two Modes: Driving vs Watching](#two-modes-driving-vs-watching)
3. [API Contract](#api-contract)
4. [UI Blocks System](#ui-blocks-system)
5. [Backend Implementation](#backend-implementation)
6. [Frontend Implementation](#frontend-implementation)
7. [Security & Error Handling](#security--error-handling)
8. [Testing](#testing)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                           Next.js App                                │
├─────────────────────────────────────────────────────────────────────┤
│  GraphQL Queries/Mutations          │  Streaming (SSE + Channels)   │
│  - Create conversation              │  - Chat stream (SSE)          │
│  - Load history                     │  - Background agent (Channel) │
│  - Start background job             │  - Interactive blocks         │
│  - List agents/jobs                 │                               │
└───────────────┬─────────────────────┴───────────────┬───────────────┘
                │                                     │
                ▼                                     ▼
┌───────────────────────────────┐     ┌───────────────────────────────┐
│         Absinthe              │     │     Phoenix Channels          │
│     /api/graphql              │     │     /socket                   │
└───────────────┬───────────────┘     └───────────────┬───────────────┘
                │                                     │
                └──────────────┬──────────────────────┘
                               │
                               ▼
                ┌───────────────────────────────┐
                │     Clementine Agents         │
                │     (Supervised Processes)    │
                └───────────────────────────────┘
                               │
                               ▼
                ┌───────────────────────────────┐
                │       Anthropic API           │
                └───────────────────────────────┘
```

---

## Two Modes: Driving vs Watching

### Mode 1: "Driving" (Interactive Chat)

User directly controls the agent in a request-response pattern.

```
User ──POST──▶ Agent starts ══SSE══▶ User watches
                    │                     │
                    ▼                     ▼
               Agent works ◀──────── User responds
                    │              (to permission block)
                    ▼
                  Done
```

**Characteristics:**
- 1:1 relationship between user and agent execution
- Agent lifecycle tied to the request
- SSE stream (simple HTTP, stateless)
- User can respond to permission blocks mid-stream

**Best for:** Chat interfaces, interactive assistants, pair programming

### Mode 2: "Watching" (Background Agent)

Agent runs independently; users observe and occasionally interact.

```
                         ┌──▶ Viewer A (joins t=0, sees everything)
Job starts ══Channel══▶──┼──▶ Viewer B (joins t=5, replays history)
     │                   └──▶ Viewer C (joins t=10, replays history)
     │                              │
     ▼                              ▼
Agent works ◀─────────────── Approve/Deny/Stop
     │
     ▼
  Completes (or errors)
```

**Characteristics:**
- Agent lifecycle independent of viewers
- Multiple concurrent viewers
- Viewers need historical replay on join
- Phoenix Channel for pub/sub fan-out
- Events persisted for replay

**Best for:** Long-running tasks, build pipelines, data processing, autonomous agents

### Comparison

| Aspect | Driving (Chat) | Watching (Background) |
|--------|---------------|----------------------|
| Transport | SSE | Phoenix Channel |
| Lifecycle | Request-scoped | Independent process |
| Viewers | Single | Multiple |
| History | N/A | Replay on join |
| Start | `POST /api/chat/stream` | GraphQL `startJob` mutation |
| Interact | Response in same stream | Channel push events |
| Persistence | Optional | Required |

---

## API Contract

### GraphQL Schema (Absinthe)

```graphql
type Query {
  # Conversations (Chat mode)
  conversation(id: ID!): Conversation
  conversations(limit: Int = 20, cursor: String): ConversationConnection!

  # Jobs (Background mode)
  job(id: ID!): Job
  jobs(status: JobStatus, limit: Int = 20): [Job!]!
}

type Mutation {
  # Conversations
  createConversation(input: CreateConversationInput!): Conversation!
  deleteConversation(id: ID!): Boolean!

  # Jobs
  startJob(input: StartJobInput!): Job!
  cancelJob(id: ID!): Job!

  # Block interactions (works for both modes)
  respondToBlock(input: BlockResponseInput!): BlockResponse!
}

type Conversation {
  id: ID!
  title: String
  messages: [Message!]!
  createdAt: DateTime!
  updatedAt: DateTime!
}

type Message {
  id: ID!
  role: Role!
  content: String!
  blocks: [Block!]!
  toolCalls: [ToolCall!]!
  createdAt: DateTime!
}

type Job {
  id: ID!
  status: JobStatus!
  agentType: String!
  events: [AgentEvent!]!
  result: String
  error: String
  startedAt: DateTime!
  completedAt: DateTime
}

enum JobStatus {
  PENDING
  RUNNING
  WAITING_FOR_INPUT
  COMPLETED
  FAILED
  CANCELLED
}

type Block {
  id: ID!
  type: String!
  props: JSON!
  status: BlockStatus!
  response: JSON
}

enum BlockStatus {
  PENDING
  RESPONDED
  EXPIRED
}

input BlockResponseInput {
  blockId: ID!
  response: JSON!
  # For chat mode, include conversation context
  conversationId: ID
  # For background mode, include job context
  jobId: ID
}
```

### SSE Events (Chat Mode)

**Endpoint:** `POST /api/chat/stream`

**Request:**
```json
{
  "conversation_id": "uuid",
  "message": "What files are in the project?"
}
```

**Response:** `text/event-stream`

```
event: message_start
data: {"message_id": "msg_1"}

event: text_delta
data: {"text": "Let me check"}

event: text_delta
data: {"text": " the files."}

event: tool_start
data: {"id": "t1", "name": "list_dir", "input": {}}

event: tool_end
data: {"id": "t1", "result": "lib/\ntest/", "error": null}

event: block_start
data: {"id": "b1", "type": "permission", "props": {"action": "run_bash", "command": "rm -rf tmp/"}}

event: block_waiting
data: {"id": "b1"}

... stream pauses, waiting for user response via GraphQL mutation ...

event: block_resolved
data: {"id": "b1", "response": {"approved": true}}

event: text_delta
data: {"text": "Done! I've cleaned up."}

event: message_end
data: {"conversation_id": "uuid", "message_id": "msg_1"}
```

### Channel Events (Background Mode)

**Channel:** `agent:{job_id}`

**Join → Receive history:**
```javascript
channel.join()
  .receive("ok", ({ events }) => {
    // events = array of all past events for replay
  })
```

**Live events (same format as SSE):**
```javascript
channel.on("text_delta", ({ text }) => ...)
channel.on("tool_start", ({ id, name, input }) => ...)
channel.on("tool_end", ({ id, result, error }) => ...)
channel.on("block_start", ({ id, type, props }) => ...)
channel.on("block_waiting", ({ id }) => ...)
channel.on("job_complete", ({ result }) => ...)
channel.on("job_error", ({ error }) => ...)
```

**Push events (viewer → agent):**
```javascript
// Respond to a block
channel.push("block_response", { block_id: "b1", response: { approved: true } })

// Cancel the job
channel.push("cancel", {})
```

---

## UI Blocks System

Blocks are structured outputs that render as interactive React components. The agent knows about available blocks via its system prompt.

### Block Lifecycle

```
Agent outputs block ──▶ Frontend renders ──▶ User interacts
                                                   │
                                                   ▼
                              Agent receives response, continues
```

### System Prompt (Block Definitions)

```markdown
## Available UI Blocks

You can output special blocks that render as interactive UI components.
Use XML-style syntax within your response:

### Permission Block
Request user approval before taking an action.
<block:permission action="description" risk="low|medium|high">
  Detailed explanation of what you want to do
</block:permission>

### Map Block
Display a location on an interactive map.
<block:map lat="37.7749" lng="-122.4194" zoom="12" label="San Francisco" />

### Code Block
Display syntax-highlighted code with copy button.
<block:code language="python" filename="optional.py">
def hello():
    print("world")
</block:code>

### Chart Block
Display data as a chart.
<block:chart type="bar" title="Sales by Region">
[{"label": "North", "value": 100}, {"label": "South", "value": 80}]
</block:chart>

### Form Block
Collect structured input from the user.
<block:form id="user_details">
  <field name="email" type="email" required="true" label="Email Address" />
  <field name="plan" type="select" options="free,pro,enterprise" label="Plan" />
</block:form>

### Link Card Block
Display a rich link preview.
<block:link_card url="https://example.com" />

When you need user input or approval, USE THESE BLOCKS rather than asking
in plain text. The user can interact with them directly.
```

### Block Event Flow

**1. Agent outputs block syntax in text stream:**
```
event: text_delta
data: {"text": "<block:permission action=\"delete files\""}

event: text_delta
data: {"text": " risk=\"high\">"}

event: text_delta
data: {"text": "I want to delete the tmp/ directory"}

event: text_delta
data: {"text": "</block:permission>"}
```

**2. Frontend parser detects complete block, emits:**
```
event: block_start
data: {"id": "b1", "type": "permission", "props": {"action": "delete files", "risk": "high", "content": "I want to delete the tmp/ directory"}}
```

**3. If block requires response, agent signals waiting:**
```
event: block_waiting
data: {"id": "b1"}
```

**4. User responds via GraphQL mutation:**
```graphql
mutation {
  respondToBlock(input: {
    blockId: "b1"
    conversationId: "conv_123"
    response: { approved: true }
  }) {
    success
  }
}
```

**5. Agent receives response, continues:**
```
event: block_resolved
data: {"id": "b1", "response": {"approved": true}}

event: text_delta
data: {"text": "Deleting the files now..."}
```

### Block Type Registry

| Block Type | Props | Response Type | Interactive |
|------------|-------|---------------|-------------|
| `permission` | `action`, `risk`, `content` | `{approved: boolean}` | Yes |
| `map` | `lat`, `lng`, `zoom`, `label`, `markers[]` | None | No |
| `code` | `language`, `filename`, `content` | None | No (copy only) |
| `chart` | `type`, `title`, `data[]` | None | No |
| `form` | `id`, `fields[]` | `{[fieldName]: value}` | Yes |
| `link_card` | `url`, `title?`, `image?` | None | No |
| `image` | `src`, `alt`, `caption?` | None | No |
| `table` | `headers[]`, `rows[][]` | None | No |
| `progress` | `percent`, `label`, `status` | None | No |

---

## Backend Implementation

### Project Structure

```
lib/
├── my_app/
│   ├── agents/
│   │   ├── chat_agent.ex          # Chat mode agent config
│   │   ├── background_agent.ex    # Background mode agent
│   │   └── tools/                 # Custom tools
│   ├── jobs/
│   │   ├── job.ex                 # Job schema
│   │   ├── job_server.ex          # GenServer for background jobs
│   │   ├── job_registry.ex        # Registry for running jobs
│   │   └── event_store.ex         # Persist events for replay
│   └── conversations/
│       ├── conversation.ex        # Conversation schema
│       └── message.ex             # Message schema
├── my_app_web/
│   ├── channels/
│   │   └── agent_channel.ex       # Background agent channel
│   ├── controllers/
│   │   └── chat_controller.ex     # SSE streaming endpoint
│   └── graphql/
│       ├── schema.ex
│       ├── resolvers/
│       └── types/
```

### Chat Controller (SSE Streaming)

```elixir
defmodule MyAppWeb.ChatController do
  use MyAppWeb, :controller

  alias MyApp.Conversations
  alias MyApp.Agents.ChatAgent

  def stream(conn, %{"conversation_id" => conv_id, "message" => message}) do
    conversation = Conversations.get_or_create!(conv_id)

    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")  # Disable nginx buffering
    |> send_chunked(200)
    |> run_stream(conversation, message)
  end

  defp run_stream(conn, conversation, message) do
    parent = self()
    block_state = %{pending_blocks: %{}, block_responses: %{}}

    # Store message
    {:ok, user_msg} = Conversations.add_message(conversation, %{
      role: :user,
      content: message
    })

    # Start streaming
    task = Task.async(fn ->
      Clementine.Loop.run_stream(
        ChatAgent.config(conversation),
        message,
        fn event -> send(parent, {:agent_event, event}) end
      )
    end)

    assistant_msg_id = Ecto.UUID.generate()
    send_event(conn, "message_start", %{message_id: assistant_msg_id})

    stream_loop(conn, %{
      task: task,
      conversation: conversation,
      message_id: assistant_msg_id,
      content: "",
      blocks: block_state
    })
  end

  defp stream_loop(conn, state) do
    receive do
      {:agent_event, event} ->
        handle_agent_event(conn, state, event)

      {:block_response, block_id, response} ->
        handle_block_response(conn, state, block_id, response)

      {ref, {:ok, result, messages}} when ref == state.task.ref ->
        Process.demonitor(ref, [:flush])
        finalize_stream(conn, state, result)

      {ref, {:error, reason}} when ref == state.task.ref ->
        Process.demonitor(ref, [:flush])
        send_event(conn, "error", %{message: inspect(reason)})
        conn

      {:DOWN, _, :process, _, reason} ->
        send_event(conn, "error", %{message: inspect(reason)})
        conn
    after
      300_000 ->
        send_event(conn, "error", %{message: "timeout"})
        conn
    end
  end

  defp handle_agent_event(conn, state, event) do
    case event do
      {:text_delta, text} ->
        send_event(conn, "text_delta", %{text: text})
        state = %{state | content: state.content <> text}

        # Check for completed blocks in accumulated content
        {blocks, remaining} = BlockParser.extract_blocks(state.content)
        state = process_new_blocks(conn, state, blocks)
        state = %{state | content: remaining}

        stream_loop(conn, state)

      {:tool_use_start, id, name} ->
        send_event(conn, "tool_start", %{id: id, name: name, input: %{}})
        stream_loop(conn, state)

      {:input_json_delta, _id, chunk} ->
        send_event(conn, "tool_delta", %{input_chunk: chunk})
        stream_loop(conn, state)

      {:tool_result, id, {:ok, result}} ->
        send_event(conn, "tool_end", %{id: id, result: result, error: nil})
        stream_loop(conn, state)

      {:tool_result, id, {:error, error}} ->
        send_event(conn, "tool_end", %{id: id, result: nil, error: inspect(error)})
        stream_loop(conn, state)

      _ ->
        stream_loop(conn, state)
    end
  end

  defp process_new_blocks(conn, state, blocks) do
    Enum.reduce(blocks, state, fn block, acc ->
      send_event(conn, "block_start", %{
        id: block.id,
        type: block.type,
        props: block.props
      })

      if block.interactive do
        send_event(conn, "block_waiting", %{id: block.id})
        put_in(acc, [:blocks, :pending_blocks, block.id], block)
      else
        acc
      end
    end)
  end

  defp handle_block_response(conn, state, block_id, response) do
    send_event(conn, "block_resolved", %{id: block_id, response: response})

    # Resume agent with block response
    # This depends on how you've structured the agent to wait for input
    state = put_in(state, [:blocks, :block_responses, block_id], response)
    stream_loop(conn, state)
  end

  defp finalize_stream(conn, state, _result) do
    Conversations.add_message(state.conversation, %{
      role: :assistant,
      content: state.content
    })

    send_event(conn, "message_end", %{
      conversation_id: state.conversation.id,
      message_id: state.message_id
    })
    conn
  end

  defp send_event(conn, event, data) do
    chunk(conn, "event: #{event}\ndata: #{Jason.encode!(data)}\n\n")
  end
end
```

### Agent Channel (Background Mode)

```elixir
defmodule MyAppWeb.AgentChannel do
  use MyAppWeb, :channel

  alias MyApp.Jobs
  alias MyApp.Jobs.JobServer

  @impl true
  def join("agent:" <> job_id, _params, socket) do
    case Jobs.get_job(job_id) do
      nil ->
        {:error, %{reason: "not_found"}}

      job ->
        # Subscribe to job events
        Phoenix.PubSub.subscribe(MyApp.PubSub, "job:#{job_id}")

        # Send historical events for replay
        events = Jobs.EventStore.get_events(job_id)

        {:ok, %{events: events, status: job.status}, assign(socket, :job_id, job_id)}
    end
  end

  @impl true
  def handle_in("block_response", %{"block_id" => block_id, "response" => response}, socket) do
    JobServer.respond_to_block(socket.assigns.job_id, block_id, response)
    {:noreply, socket}
  end

  @impl true
  def handle_in("cancel", _params, socket) do
    JobServer.cancel(socket.assigns.job_id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_event, event}, socket) do
    push(socket, event_name(event), event_payload(event))
    {:noreply, socket}
  end

  defp event_name({:text_delta, _}), do: "text_delta"
  defp event_name({:tool_start, _, _, _}), do: "tool_start"
  defp event_name({:tool_end, _, _, _}), do: "tool_end"
  defp event_name({:block_start, _}), do: "block_start"
  defp event_name({:block_waiting, _}), do: "block_waiting"
  defp event_name({:block_resolved, _, _}), do: "block_resolved"
  defp event_name({:job_complete, _}), do: "job_complete"
  defp event_name({:job_error, _}), do: "job_error"
  defp event_name(_), do: "unknown"

  defp event_payload({:text_delta, text}), do: %{text: text}
  defp event_payload({:tool_start, id, name, input}), do: %{id: id, name: name, input: input}
  defp event_payload({:tool_end, id, result, error}), do: %{id: id, result: result, error: error}
  defp event_payload({:block_start, block}), do: block
  defp event_payload({:block_waiting, id}), do: %{id: id}
  defp event_payload({:block_resolved, id, response}), do: %{id: id, response: response}
  defp event_payload({:job_complete, result}), do: %{result: result}
  defp event_payload({:job_error, error}), do: %{error: error}
  defp event_payload(_), do: %{}
end
```

### Job Server (Background Agent Process)

```elixir
defmodule MyApp.Jobs.JobServer do
  use GenServer

  alias MyApp.Jobs
  alias MyApp.Jobs.EventStore

  def start_link(job_id) do
    GenServer.start_link(__MODULE__, job_id, name: via(job_id))
  end

  def respond_to_block(job_id, block_id, response) do
    GenServer.cast(via(job_id), {:block_response, block_id, response})
  end

  def cancel(job_id) do
    GenServer.cast(via(job_id), :cancel)
  end

  defp via(job_id) do
    {:via, Registry, {MyApp.Jobs.Registry, job_id}}
  end

  @impl true
  def init(job_id) do
    job = Jobs.get_job!(job_id)
    Jobs.update_job(job, %{status: :running})

    # Start the agent in a task
    parent = self()
    task = Task.async(fn -> run_agent(job, parent) end)

    {:ok, %{job_id: job_id, task: task, pending_blocks: %{}}}
  end

  defp run_agent(job, parent) do
    config = agent_config(job)

    Clementine.Loop.run_stream(
      config,
      job.prompt,
      fn event -> send(parent, {:agent_event, event}) end
    )
  end

  @impl true
  def handle_info({:agent_event, event}, state) do
    # Persist event for replay
    EventStore.append(state.job_id, event)

    # Broadcast to all channel subscribers
    Phoenix.PubSub.broadcast(MyApp.PubSub, "job:#{state.job_id}", {:agent_event, event})

    # Handle blocks that need responses
    state = maybe_track_block(state, event)

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, {:ok, result, _messages}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Jobs.update_job(state.job_id, %{status: :completed, result: result})
    broadcast(state.job_id, {:job_complete, result})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({ref, {:error, reason}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Jobs.update_job(state.job_id, %{status: :failed, error: inspect(reason)})
    broadcast(state.job_id, {:job_error, inspect(reason)})
    {:stop, :normal, state}
  end

  @impl true
  def handle_cast({:block_response, block_id, response}, state) do
    # Resume the agent with the block response
    # This requires the agent to be waiting for input
    # Implementation depends on how you structure the blocking wait
    EventStore.append(state.job_id, {:block_resolved, block_id, response})
    broadcast(state.job_id, {:block_resolved, block_id, response})

    # Signal the waiting agent
    if pending = state.pending_blocks[block_id] do
      send(pending.waiting_pid, {:block_response, block_id, response})
    end

    {:noreply, %{state | pending_blocks: Map.delete(state.pending_blocks, block_id)}}
  end

  @impl true
  def handle_cast(:cancel, state) do
    Task.shutdown(state.task, :brutal_kill)
    Jobs.update_job(state.job_id, %{status: :cancelled})
    broadcast(state.job_id, {:job_error, "cancelled"})
    {:stop, :normal, state}
  end

  defp maybe_track_block(state, {:block_waiting, block}) do
    put_in(state, [:pending_blocks, block.id], %{
      block: block,
      waiting_pid: state.task.pid
    })
  end
  defp maybe_track_block(state, _), do: state

  defp broadcast(job_id, event) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "job:#{job_id}", {:agent_event, event})
  end

  defp agent_config(job) do
    [
      model: :claude_sonnet,
      system: job.system_prompt || default_system_prompt(),
      tools: tools_for_job(job),
      max_iterations: 50
    ]
  end
end
```

### Block Parser

```elixir
defmodule MyApp.BlockParser do
  @moduledoc """
  Parses block XML syntax from agent text output.
  """

  @block_pattern ~r/<block:(\w+)([^>]*)(?:\/>|>([\s\S]*?)<\/block:\1>)/

  defstruct [:id, :type, :props, :content, :interactive]

  @interactive_blocks ~w(permission form)

  def extract_blocks(text) do
    blocks =
      Regex.scan(@block_pattern, text)
      |> Enum.map(&parse_match/1)

    remaining = Regex.replace(@block_pattern, text, "")

    {blocks, remaining}
  end

  defp parse_match([_full, type, attrs_str, content]) do
    parse_match([nil, type, attrs_str, content])
  end

  defp parse_match([_full, type, attrs_str | rest]) do
    content = List.first(rest)
    props = parse_attrs(attrs_str)
    props = if content, do: Map.put(props, "content", String.trim(content)), else: props

    %__MODULE__{
      id: Ecto.UUID.generate(),
      type: type,
      props: props,
      content: content,
      interactive: type in @interactive_blocks
    }
  end

  defp parse_attrs(str) do
    Regex.scan(~r/(\w+)="([^"]*)"/, str)
    |> Enum.map(fn [_, key, value] -> {key, parse_value(value)} end)
    |> Map.new()
  end

  defp parse_value(str) do
    case Float.parse(str) do
      {num, ""} -> num
      _ ->
        case str do
          "true" -> true
          "false" -> false
          _ -> str
        end
    end
  end
end
```

---

## Frontend Implementation

### Types

```typescript
// types/agent.ts

// Events (shared between SSE and Channel)
export type AgentEvent =
  | { type: 'text_delta'; text: string }
  | { type: 'tool_start'; id: string; name: string; input: Record<string, unknown> }
  | { type: 'tool_delta'; id: string; input_chunk: string }
  | { type: 'tool_end'; id: string; result: string | null; error: string | null }
  | { type: 'block_start'; id: string; blockType: string; props: Record<string, unknown> }
  | { type: 'block_waiting'; id: string }
  | { type: 'block_resolved'; id: string; response: unknown }
  | { type: 'message_start'; message_id: string }
  | { type: 'message_end'; conversation_id: string; message_id: string }
  | { type: 'job_complete'; result: string }
  | { type: 'job_error'; error: string }
  | { type: 'error'; message: string };

// Blocks
export interface Block {
  id: string;
  type: string;
  props: Record<string, unknown>;
  status: 'rendering' | 'waiting' | 'resolved';
  response?: unknown;
}

// Tool calls
export interface ToolCall {
  id: string;
  name: string;
  input: string;
  result?: string;
  error?: string;
  status: 'running' | 'complete' | 'error';
}

// Messages
export interface Message {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  blocks: Block[];
  toolCalls: ToolCall[];
  timestamp: Date;
}

// Agent state
export interface AgentState {
  status: 'idle' | 'streaming' | 'waiting_for_input' | 'complete' | 'error';
  messages: Message[];
  currentMessage: Message | null;
  error: string | null;
}
```

### Event Reducer

```typescript
// lib/agentReducer.ts

export function agentReducer(state: AgentState, event: AgentEvent): AgentState {
  switch (event.type) {
    case 'message_start':
      return {
        ...state,
        status: 'streaming',
        currentMessage: {
          id: event.message_id,
          role: 'assistant',
          content: '',
          blocks: [],
          toolCalls: [],
          timestamp: new Date(),
        },
      };

    case 'text_delta':
      if (!state.currentMessage) return state;
      return {
        ...state,
        currentMessage: {
          ...state.currentMessage,
          content: state.currentMessage.content + event.text,
        },
      };

    case 'tool_start':
      if (!state.currentMessage) return state;
      return {
        ...state,
        currentMessage: {
          ...state.currentMessage,
          toolCalls: [
            ...state.currentMessage.toolCalls,
            { id: event.id, name: event.name, input: '', status: 'running' },
          ],
        },
      };

    case 'tool_delta':
      if (!state.currentMessage) return state;
      return {
        ...state,
        currentMessage: {
          ...state.currentMessage,
          toolCalls: state.currentMessage.toolCalls.map((tc) =>
            tc.id === event.id ? { ...tc, input: tc.input + event.input_chunk } : tc
          ),
        },
      };

    case 'tool_end':
      if (!state.currentMessage) return state;
      return {
        ...state,
        currentMessage: {
          ...state.currentMessage,
          toolCalls: state.currentMessage.toolCalls.map((tc) =>
            tc.id === event.id
              ? {
                  ...tc,
                  result: event.result ?? undefined,
                  error: event.error ?? undefined,
                  status: event.error ? 'error' : 'complete',
                }
              : tc
          ),
        },
      };

    case 'block_start':
      if (!state.currentMessage) return state;
      return {
        ...state,
        currentMessage: {
          ...state.currentMessage,
          blocks: [
            ...state.currentMessage.blocks,
            { id: event.id, type: event.blockType, props: event.props, status: 'rendering' },
          ],
        },
      };

    case 'block_waiting':
      if (!state.currentMessage) return state;
      return {
        ...state,
        status: 'waiting_for_input',
        currentMessage: {
          ...state.currentMessage,
          blocks: state.currentMessage.blocks.map((b) =>
            b.id === event.id ? { ...b, status: 'waiting' } : b
          ),
        },
      };

    case 'block_resolved':
      if (!state.currentMessage) return state;
      return {
        ...state,
        status: 'streaming',
        currentMessage: {
          ...state.currentMessage,
          blocks: state.currentMessage.blocks.map((b) =>
            b.id === event.id ? { ...b, status: 'resolved', response: event.response } : b
          ),
        },
      };

    case 'message_end':
      if (!state.currentMessage) return state;
      return {
        ...state,
        status: 'idle',
        messages: [...state.messages, state.currentMessage],
        currentMessage: null,
      };

    case 'job_complete':
      return { ...state, status: 'complete' };

    case 'job_error':
    case 'error':
      return { ...state, status: 'error', error: event.type === 'error' ? event.message : event.error };

    default:
      return state;
  }
}
```

### Chat Hook (SSE Mode)

```typescript
// hooks/useChat.ts

import { useReducer, useCallback, useRef } from 'react';
import { useMutation, gql } from '@apollo/client';
import { AgentState, AgentEvent, Message } from '@/types/agent';
import { agentReducer } from '@/lib/agentReducer';
import { parseSSE } from '@/lib/sseParser';

const RESPOND_TO_BLOCK = gql`
  mutation RespondToBlock($input: BlockResponseInput!) {
    respondToBlock(input: $input) {
      success
    }
  }
`;

const initialState: AgentState = {
  status: 'idle',
  messages: [],
  currentMessage: null,
  error: null,
};

export function useChat(conversationId: string) {
  const [state, dispatch] = useReducer(agentReducer, initialState);
  const abortRef = useRef<AbortController | null>(null);
  const [respondToBlock] = useMutation(RESPOND_TO_BLOCK);

  const sendMessage = useCallback(async (content: string) => {
    // Add user message optimistically
    const userMessage: Message = {
      id: crypto.randomUUID(),
      role: 'user',
      content,
      blocks: [],
      toolCalls: [],
      timestamp: new Date(),
    };
    dispatch({ type: 'message_start', message_id: '' }); // Reset state
    state.messages.push(userMessage); // Mutate for optimistic update

    abortRef.current = new AbortController();

    try {
      const response = await fetch('/api/chat/stream', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ conversation_id: conversationId, message: content }),
        signal: abortRef.current.signal,
      });

      if (!response.ok) throw new Error('Stream failed');

      const reader = response.body!.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const { events, remaining } = parseSSE(buffer);
        buffer = remaining;

        for (const event of events) {
          dispatch(event);
        }
      }
    } catch (err) {
      if ((err as Error).name !== 'AbortError') {
        dispatch({ type: 'error', message: (err as Error).message });
      }
    }
  }, [conversationId]);

  const respondToBlockFn = useCallback(async (blockId: string, response: unknown) => {
    await respondToBlock({
      variables: {
        input: { blockId, conversationId, response },
      },
    });
  }, [conversationId, respondToBlock]);

  const cancel = useCallback(() => {
    abortRef.current?.abort();
  }, []);

  return {
    ...state,
    sendMessage,
    respondToBlock: respondToBlockFn,
    cancel,
  };
}
```

### Background Job Hook (Channel Mode)

```typescript
// hooks/useBackgroundJob.ts

import { useReducer, useEffect, useCallback, useRef } from 'react';
import { Socket, Channel } from 'phoenix';
import { AgentState, AgentEvent } from '@/types/agent';
import { agentReducer } from '@/lib/agentReducer';

const initialState: AgentState = {
  status: 'idle',
  messages: [],
  currentMessage: null,
  error: null,
};

export function useBackgroundJob(jobId: string | null) {
  const [state, dispatch] = useReducer(agentReducer, initialState);
  const channelRef = useRef<Channel | null>(null);
  const socketRef = useRef<Socket | null>(null);

  useEffect(() => {
    if (!jobId) return;

    // Connect to Phoenix socket
    const socket = new Socket('/socket', { params: { token: getAuthToken() } });
    socket.connect();
    socketRef.current = socket;

    // Join the agent channel
    const channel = socket.channel(`agent:${jobId}`, {});
    channelRef.current = channel;

    channel.join()
      .receive('ok', ({ events, status }) => {
        // Replay historical events
        for (const event of events) {
          dispatch(normalizeEvent(event));
        }
        if (status === 'running') {
          dispatch({ type: 'message_start', message_id: 'replay' });
        }
      })
      .receive('error', ({ reason }) => {
        dispatch({ type: 'error', message: reason });
      });

    // Subscribe to live events
    const eventTypes = [
      'text_delta', 'tool_start', 'tool_delta', 'tool_end',
      'block_start', 'block_waiting', 'block_resolved',
      'job_complete', 'job_error'
    ];

    for (const eventType of eventTypes) {
      channel.on(eventType, (payload) => {
        dispatch({ type: eventType, ...payload } as AgentEvent);
      });
    }

    return () => {
      channel.leave();
      socket.disconnect();
    };
  }, [jobId]);

  const respondToBlock = useCallback((blockId: string, response: unknown) => {
    channelRef.current?.push('block_response', { block_id: blockId, response });
  }, []);

  const cancel = useCallback(() => {
    channelRef.current?.push('cancel', {});
  }, []);

  return {
    ...state,
    respondToBlock,
    cancel,
  };
}

function normalizeEvent(event: Record<string, unknown>): AgentEvent {
  // Convert stored event format to AgentEvent
  return event as AgentEvent;
}

function getAuthToken(): string {
  // Get auth token from your auth system
  return localStorage.getItem('token') || '';
}
```

### Block Components

```typescript
// components/blocks/index.tsx

import { Block } from '@/types/agent';
import { PermissionBlock } from './PermissionBlock';
import { MapBlock } from './MapBlock';
import { CodeBlock } from './CodeBlock';
import { ChartBlock } from './ChartBlock';
import { FormBlock } from './FormBlock';
import { ProgressBlock } from './ProgressBlock';

interface BlockRendererProps {
  block: Block;
  onRespond: (response: unknown) => void;
}

const blockComponents: Record<string, React.ComponentType<BlockRendererProps>> = {
  permission: PermissionBlock,
  map: MapBlock,
  code: CodeBlock,
  chart: ChartBlock,
  form: FormBlock,
  progress: ProgressBlock,
};

export function BlockRenderer({ block, onRespond }: BlockRendererProps) {
  const Component = blockComponents[block.type];

  if (!Component) {
    return (
      <div className="p-4 bg-yellow-50 border border-yellow-200 rounded">
        Unknown block type: {block.type}
      </div>
    );
  }

  return <Component block={block} onRespond={onRespond} />;
}
```

```tsx
// components/blocks/PermissionBlock.tsx

import { Block } from '@/types/agent';

interface Props {
  block: Block;
  onRespond: (response: unknown) => void;
}

export function PermissionBlock({ block, onRespond }: Props) {
  const { action, risk, content } = block.props as {
    action: string;
    risk: 'low' | 'medium' | 'high';
    content: string;
  };

  const riskColors = {
    low: 'border-green-300 bg-green-50',
    medium: 'border-yellow-300 bg-yellow-50',
    high: 'border-red-300 bg-red-50',
  };

  const isWaiting = block.status === 'waiting';
  const isResolved = block.status === 'resolved';

  return (
    <div className={`my-4 p-4 border-2 rounded-lg ${riskColors[risk]}`}>
      <div className="flex items-center gap-2 mb-2">
        <span className="text-lg">🔐</span>
        <span className="font-semibold">Permission Required</span>
        <span className={`text-xs px-2 py-0.5 rounded ${
          risk === 'high' ? 'bg-red-200' : risk === 'medium' ? 'bg-yellow-200' : 'bg-green-200'
        }`}>
          {risk} risk
        </span>
      </div>

      <p className="font-medium mb-2">{action}</p>
      <p className="text-sm text-gray-600 mb-4">{content}</p>

      {isWaiting && (
        <div className="flex gap-2">
          <button
            onClick={() => onRespond({ approved: true })}
            className="px-4 py-2 bg-green-500 text-white rounded hover:bg-green-600"
          >
            Approve
          </button>
          <button
            onClick={() => onRespond({ approved: false })}
            className="px-4 py-2 bg-gray-300 rounded hover:bg-gray-400"
          >
            Deny
          </button>
        </div>
      )}

      {isResolved && (
        <div className={`text-sm ${
          (block.response as { approved: boolean })?.approved
            ? 'text-green-600'
            : 'text-red-600'
        }`}>
          {(block.response as { approved: boolean })?.approved ? '✓ Approved' : '✗ Denied'}
        </div>
      )}
    </div>
  );
}
```

```tsx
// components/blocks/MapBlock.tsx

import { useEffect, useRef } from 'react';
import { Block } from '@/types/agent';

interface Props {
  block: Block;
  onRespond: (response: unknown) => void;
}

export function MapBlock({ block }: Props) {
  const { lat, lng, zoom = 12, label, markers = [] } = block.props as {
    lat: number;
    lng: number;
    zoom?: number;
    label?: string;
    markers?: Array<{ lat: number; lng: number; label?: string }>;
  };

  const mapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    // Initialize map (using your preferred library: Mapbox, Google Maps, Leaflet, etc.)
    // This is a placeholder - implement with your chosen map library
    if (mapRef.current && typeof window !== 'undefined') {
      // Example with a hypothetical map library:
      // const map = new MapLibrary(mapRef.current, { center: [lat, lng], zoom });
      // if (label) map.addMarker([lat, lng], label);
      // markers.forEach(m => map.addMarker([m.lat, m.lng], m.label));
    }
  }, [lat, lng, zoom, label, markers]);

  return (
    <div className="my-4 rounded-lg overflow-hidden border">
      {label && (
        <div className="px-3 py-2 bg-gray-100 border-b font-medium">
          📍 {label}
        </div>
      )}
      <div ref={mapRef} className="h-64 bg-gray-200 flex items-center justify-center">
        {/* Map renders here */}
        <span className="text-gray-500">
          Map: {lat.toFixed(4)}, {lng.toFixed(4)}
        </span>
      </div>
    </div>
  );
}
```

```tsx
// components/blocks/CodeBlock.tsx

import { useState } from 'react';
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter';
import { vscDarkPlus } from 'react-syntax-highlighter/dist/esm/styles/prism';
import { Block } from '@/types/agent';

interface Props {
  block: Block;
  onRespond: (response: unknown) => void;
}

export function CodeBlock({ block }: Props) {
  const { language = 'text', filename, content } = block.props as {
    language?: string;
    filename?: string;
    content: string;
  };

  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    await navigator.clipboard.writeText(content);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="my-4 rounded-lg overflow-hidden border border-gray-700">
      <div className="flex items-center justify-between px-3 py-2 bg-gray-800 text-gray-300 text-sm">
        <span>{filename || language}</span>
        <button
          onClick={handleCopy}
          className="px-2 py-1 hover:bg-gray-700 rounded"
        >
          {copied ? '✓ Copied' : 'Copy'}
        </button>
      </div>
      <SyntaxHighlighter
        language={language}
        style={vscDarkPlus}
        customStyle={{ margin: 0, borderRadius: 0 }}
      >
        {content}
      </SyntaxHighlighter>
    </div>
  );
}
```

### Main Chat Component

```tsx
// components/Chat.tsx

'use client';

import { useState } from 'react';
import { useChat } from '@/hooks/useChat';
import { Message } from '@/components/Message';
import { BlockRenderer } from '@/components/blocks';
import { ToolCallCard } from '@/components/ToolCallCard';

interface ChatProps {
  conversationId: string;
}

export function Chat({ conversationId }: ChatProps) {
  const {
    status,
    messages,
    currentMessage,
    error,
    sendMessage,
    respondToBlock,
    cancel,
  } = useChat(conversationId);

  const [input, setInput] = useState('');

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || status === 'streaming') return;
    sendMessage(input);
    setInput('');
  };

  const allMessages = currentMessage
    ? [...messages, currentMessage]
    : messages;

  return (
    <div className="flex flex-col h-screen max-w-4xl mx-auto">
      {/* Messages */}
      <div className="flex-1 overflow-y-auto p-4 space-y-4">
        {allMessages.map((message) => (
          <div key={message.id} className="space-y-2">
            <Message message={message} isStreaming={message === currentMessage} />

            {/* Tool calls */}
            {message.toolCalls.map((tool) => (
              <ToolCallCard key={tool.id} toolCall={tool} />
            ))}

            {/* Blocks */}
            {message.blocks.map((block) => (
              <BlockRenderer
                key={block.id}
                block={block}
                onRespond={(response) => respondToBlock(block.id, response)}
              />
            ))}
          </div>
        ))}

        {error && (
          <div className="p-4 bg-red-50 border border-red-200 rounded text-red-700">
            {error}
          </div>
        )}
      </div>

      {/* Input */}
      <form onSubmit={handleSubmit} className="p-4 border-t">
        <div className="flex gap-2">
          <input
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder={
              status === 'waiting_for_input'
                ? 'Respond to the block above...'
                : 'Type a message...'
            }
            disabled={status === 'streaming'}
            className="flex-1 px-4 py-2 border rounded-lg disabled:bg-gray-100"
          />
          {status === 'streaming' ? (
            <button
              type="button"
              onClick={cancel}
              className="px-4 py-2 bg-red-500 text-white rounded-lg"
            >
              Cancel
            </button>
          ) : (
            <button
              type="submit"
              disabled={status === 'waiting_for_input'}
              className="px-4 py-2 bg-blue-500 text-white rounded-lg disabled:opacity-50"
            >
              Send
            </button>
          )}
        </div>

        {status === 'streaming' && (
          <p className="text-sm text-gray-500 mt-2">Agent is responding...</p>
        )}
        {status === 'waiting_for_input' && (
          <p className="text-sm text-yellow-600 mt-2">Waiting for your input above</p>
        )}
      </form>
    </div>
  );
}
```

---

## Security & Error Handling

### Rate Limiting

```elixir
# In router or plug
plug Hammer.Plug,
  rate_limit: {"chat:stream", 60_000, 10},  # 10 streams per minute
  by: {:session, :user_id}

plug Hammer.Plug,
  rate_limit: {"job:start", 3600_000, 5},   # 5 background jobs per hour
  by: {:session, :user_id}
```

### Input Validation

```elixir
defmodule MyAppWeb.ChatController do
  @max_message_length 10_000

  def stream(conn, params) do
    with {:ok, message} <- validate_message(params["message"]),
         {:ok, conv_id} <- validate_uuid(params["conversation_id"]) do
      # proceed
    else
      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: reason})
    end
  end

  defp validate_message(nil), do: {:error, "message required"}
  defp validate_message(msg) when byte_size(msg) > @max_message_length do
    {:error, "message too long"}
  end
  defp validate_message(msg), do: {:ok, msg}
end
```

### Block Response Validation

```elixir
defmodule MyApp.BlockValidator do
  def validate_response("permission", response) do
    case response do
      %{"approved" => approved} when is_boolean(approved) -> :ok
      _ -> {:error, "permission response must have boolean 'approved' field"}
    end
  end

  def validate_response("form", response) do
    if is_map(response), do: :ok, else: {:error, "form response must be an object"}
  end

  def validate_response(_type, _response), do: :ok
end
```

### Error Recovery

```typescript
// Frontend error boundary for blocks
function BlockErrorBoundary({ children, block }: { children: React.ReactNode; block: Block }) {
  return (
    <ErrorBoundary
      fallback={
        <div className="p-4 bg-red-50 border border-red-200 rounded">
          Failed to render {block.type} block
        </div>
      }
    >
      {children}
    </ErrorBoundary>
  );
}
```

---

## Testing

### Backend: Block Parser

```elixir
defmodule MyApp.BlockParserTest do
  use ExUnit.Case

  alias MyApp.BlockParser

  test "extracts permission block" do
    text = """
    Here's what I want to do:
    <block:permission action="delete files" risk="high">
    I need to remove the tmp directory
    </block:permission>
    Should I proceed?
    """

    {blocks, remaining} = BlockParser.extract_blocks(text)

    assert length(blocks) == 1
    assert hd(blocks).type == "permission"
    assert hd(blocks).props["action"] == "delete files"
    assert hd(blocks).props["risk"] == "high"
    assert hd(blocks).interactive == true
    assert remaining =~ "Here's what I want to do:"
    assert remaining =~ "Should I proceed?"
    refute remaining =~ "<block:"
  end

  test "extracts self-closing map block" do
    text = ~s|Check this location: <block:map lat="37.7749" lng="-122.4194" label="SF" />|

    {blocks, _} = BlockParser.extract_blocks(text)

    assert length(blocks) == 1
    assert hd(blocks).type == "map"
    assert hd(blocks).props["lat"] == 37.7749
    assert hd(blocks).props["lng"] == -122.4194
    assert hd(blocks).interactive == false
  end
end
```

### Frontend: Block Rendering

```typescript
// __tests__/blocks/PermissionBlock.test.tsx

import { render, screen, fireEvent } from '@testing-library/react';
import { PermissionBlock } from '@/components/blocks/PermissionBlock';

describe('PermissionBlock', () => {
  const block = {
    id: 'b1',
    type: 'permission',
    props: { action: 'Delete files', risk: 'high', content: 'Remove tmp/' },
    status: 'waiting' as const,
  };

  it('renders action and content', () => {
    render(<PermissionBlock block={block} onRespond={() => {}} />);

    expect(screen.getByText('Delete files')).toBeInTheDocument();
    expect(screen.getByText('Remove tmp/')).toBeInTheDocument();
  });

  it('shows approve/deny buttons when waiting', () => {
    render(<PermissionBlock block={block} onRespond={() => {}} />);

    expect(screen.getByText('Approve')).toBeInTheDocument();
    expect(screen.getByText('Deny')).toBeInTheDocument();
  });

  it('calls onRespond with approval', () => {
    const onRespond = jest.fn();
    render(<PermissionBlock block={block} onRespond={onRespond} />);

    fireEvent.click(screen.getByText('Approve'));

    expect(onRespond).toHaveBeenCalledWith({ approved: true });
  });

  it('shows resolved state', () => {
    const resolvedBlock = { ...block, status: 'resolved' as const, response: { approved: true } };
    render(<PermissionBlock block={resolvedBlock} onRespond={() => {}} />);

    expect(screen.getByText('✓ Approved')).toBeInTheDocument();
    expect(screen.queryByText('Approve')).not.toBeInTheDocument();
  });
});
```

### Integration: Full Stream Flow

```elixir
defmodule MyAppWeb.ChatControllerIntegrationTest do
  use MyAppWeb.ConnCase
  import Mox

  setup :verify_on_exit!

  test "streams text with blocks", %{conn: conn} do
    Clementine.LLM.MockClient
    |> expect(:stream, fn _, _, _, _, _ ->
      [
        {:text_delta, "Let me help. "},
        {:text_delta, ~s|<block:permission action="test" risk="low">Do it?</block:permission>|},
        {:message_delta, %{"stop_reason" => "end_turn"}, %{}},
        {:message_stop}
      ]
    end)

    conn = post(conn, ~p"/api/chat/stream", %{
      conversation_id: Ecto.UUID.generate(),
      message: "Do something"
    })

    assert conn.status == 200
    body = conn.resp_body

    assert body =~ "event: text_delta"
    assert body =~ "event: block_start"
    assert body =~ ~s|"type":"permission"|
    assert body =~ "event: block_waiting"
  end
end
```
