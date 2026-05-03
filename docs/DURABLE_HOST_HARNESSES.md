# Durable Host Harnesses

Clementine is the provider-neutral loop, tool, message, and streaming engine.
Durable production applications need one more layer around it: a host harness
that owns accepted work, persistence, execution scheduling, reconnect behavior,
and product-visible run state.

This guide documents the recommended boundary. It uses Oban-style workers as a
useful example, but Clementine does not require Oban, Ecto, Postgres, Phoenix,
or Kubernetes.

## Short Answer

Do not put Oban or a database adapter in Clementine core right now.

Clementine should pair cleanly with an Oban-backed host, but it should not own
the host's transaction boundaries, locks, schemas, queues, or retry policy.
Those choices are application semantics. A future optional adapter may make
sense if repeated host apps converge on the same shape, but the core library
should remain backend-neutral.

## Ownership Boundary

| Concern | Clementine owns | Host app owns |
| --- | --- | --- |
| LLM loop | `Clementine.Loop.run/2` and `run_stream/3` | When and where to run it |
| Messages | Provider-neutral message structs | Durable serialization and ordering |
| Tools | Tool schema, validation, execution contract | Tool availability, auth, tenant context |
| Streaming | Ephemeral loop/provider events | Transport, fan-out, reconnect, active draft cache |
| Run state | Return values and telemetry | Queued/running/completed/failed/canceled/interrupted |
| Concurrency | In-process task safety | Cross-node single-active-run enforcement |
| Replay | Deterministic message input/output contracts | Product retry policy and idempotency |

The durable source of truth should be host-owned state. Clementine processes are
executors and caches, not durable session authority.

## Core Invariants

A production host should make these states explicit and hard to violate:

- Every accepted user submission has a durable record before LLM execution.
- At most one active run exists for a conversation unless the product
  intentionally supports parallel branches.
- Generated assistant and tool messages are appended in deterministic order.
- A terminal run state is recorded: completed, failed, canceled, interrupted,
  or superseded.
- Client connections observe a run; they do not own it.
- A pod or process death cannot leave an invisible active turn forever.

## Minimal Durable Model

Exact schemas are host-specific, but most durable harnesses need these concepts:

- `conversations` or sessions.
- `messages`, ordered by a host-controlled sequence.
- `runs` or turns, linked to the accepted user message.
- A uniqueness rule for active runs per conversation.
- Optional executor metadata, such as job id, node id, heartbeat, attempt id,
  or execution id.

Typical run states:

```text
queued -> running -> completed
queued -> running -> failed
queued -> running -> canceled
queued -> running -> interrupted
```

Use `interrupted` for infrastructure loss such as pod death, stale heartbeat,
or a vanished executor. This is different from a user canceling a run and
different from an application-level failure returned by Clementine.

## Accepted Work

Persist accepted user input and create the run before execution starts. If the
host uses a queue, enqueue the executor in the same transaction.

```elixir
transaction(fn ->
  user_message =
    insert_message!(conversation_id,
      role: :user,
      content: %{"text" => prompt}
    )

  run =
    insert_run!(conversation_id,
      user_message_id: user_message.id,
      status: :queued
    )

  job = enqueue_executor!(conversation_id: conversation_id, run_id: run.id, prompt: prompt)
  attach_executor!(run, job.id)

  {user_message, run, job}
end)
```

If the active-run uniqueness rule rejects the run, roll back the accepted user
message too. A rejected submission should not look like accepted work.

## Execution

Durable hosts should prefer `Clementine.Loop` as the execution boundary. It is
stateless apart from the message list and configuration passed to it, which
makes it easier to treat host persistence as the durable session state.

Load the context window that should be sent to the model. Do not include the
new prompt in that context, because `run/2` and `run_stream/3` append the prompt
themselves.

```elixir
messages = load_context_messages(conversation_id)
run_messages = messages ++ [Clementine.LLM.Message.UserMessage.new(prompt)]

config = [
  model: model,
  system: system,
  tools: tools,
  context: tool_context,
  messages: messages
]

case Clementine.Loop.run_stream(config, prompt, &broadcast_stream_event(run.id, &1)) do
  {:ok, _text, completed_messages} ->
    append_generated_messages_and_complete_run!(
      conversation_id,
      run.id,
      run_messages,
      completed_messages
    )

  {:error, reason} ->
    mark_run_failed!(run.id, reason)
end
```

The `run_messages` value is the append baseline. The accepted user message is
already durable, so terminal persistence should append only the messages after
that baseline.

The same baseline rule applies to non-streaming execution:

```elixir
case Clementine.Loop.run(config, prompt) do
  {:ok, _text, completed_messages} ->
    append_generated_messages_and_complete_run!(
      conversation_id,
      run.id,
      run_messages,
      completed_messages
    )

  {:error, reason} ->
    mark_run_failed!(run.id, reason)
end
```

## Streaming Events

Streaming callbacks are for live presentation and observability:

- `{:text_delta, text}` is an ephemeral draft token.
- `{:tool_use_start, id, name}` is an ephemeral UI event.
- `{:input_json_delta, id, json}` is an ephemeral UI/debug event.
- `{:tool_result, id, result}` is useful for UI, but durable history should
  still be derived from final returned messages.
- `{:error, reason}` means the active stream failed before a completed message
  history was returned.
- `{:loop_event, event}` is internal loop progress suitable for logging or
  telemetry.

Do not treat streamed token deltas as durable history unless your application
intentionally stores drafts. The durable output of a successful turn is the
`messages` value returned by `run_stream/3`.

## Reconnects

For a reconnectable UI, keep durable state and active draft state separate.

One practical flow:

1. Client subscribes to the conversation stream and starts buffering new deltas.
2. Client requests a snapshot.
3. Server returns persisted messages, current run state, and any active draft
   text from an ephemeral cache.
4. Client discards buffered deltas that are older than the snapshot.
5. Client applies the remaining deltas.

The active draft cache can be tiny: one current turn per conversation or run,
with a monotonic sequence number. Losing that cache is acceptable if the run can
still complete and persist final messages. The user may miss in-flight draft
text until completion, but durable conversation history remains correct.

## Pod Lifecycle

Kubernetes and other orchestrators should give executors a drain window:

1. Stop routing new client traffic to the pod.
2. Let live clients disconnect or reconnect elsewhere.
3. Send shutdown to the application.
4. Give active executors time to finish.
5. Terminate the pod.

If a run finishes during the grace window, persist it normally. If the executor
dies first, the host should detect the missing heartbeat or abandoned job and
mark the run `interrupted`.

Clementine does not transparently move an active stream from one process to
another. The host can resume the conversation from persisted messages, but an
unfinished turn should have an explicit product state.

## Retry And Replay

Do not automatically replay a whole interrupted turn by default.

Agent turns can call tools, mutate external systems, spend budget, and expose
partial output to users. Replaying the entire turn after infrastructure loss can
duplicate effects unless the host has a durable step ledger.

A durable step or tool-call ledger would record at least:

- run id and attempt id
- LLM request boundaries
- tool call ids, names, inputs, and results
- idempotency keys for effectful tools
- terminal state for each step

With that ledger, a host can consider retrying individual safe steps. Without
it, the pragmatic default is to mark the run `interrupted` and let the user or
product choose whether to retry from the persisted conversation state.

## Message Serialization

Persist Clementine messages as provider-neutral data, not as provider wire
payloads.

Current message variants:

- `%Clementine.LLM.Message.UserMessage{}`
- `%Clementine.LLM.Message.AssistantMessage{}`
- `%Clementine.LLM.Message.ToolResultMessage{}`
- `%Clementine.LLM.Message.Content.Text{}`
- `%Clementine.LLM.Message.Content.ToolUse{}`
- `%Clementine.LLM.Message.Content.ToolResult{}`

Store a role plus content block type and fields. Rehydrate those records back
into Clementine structs before passing them as `:messages`.

Avoid atomizing arbitrary model or tool JSON while loading persisted content.
Tool inputs are maps and should remain data from the model, usually with string
keys.

## `Clementine.Agent` In Durable Hosts

`Clementine.Agent` is a useful in-memory GenServer abstraction for local agents,
experiments, and simple applications. It owns in-process conversation history.

For durable host harnesses, prefer the lower-level `Clementine.Loop` boundary.
The host can load persisted messages, execute a run in any process or job
system, and persist the returned messages. This avoids making a local GenServer
the durable owner of a conversation that may outlive a pod.

## Checklist

- Persist accepted user messages before execution.
- Use one accepted-work path for sync and streaming transports.
- Enforce one active run per conversation, unless branching is intentional.
- Pass prior context messages to Clementine and use
  `prior_messages ++ [UserMessage.new(prompt)]` as the append baseline.
- Persist generated messages and terminal run state together where possible.
- Treat stream deltas as presentation state.
- Use an ephemeral active-draft cache for reconnect UX, not as durable truth.
- Mark infrastructure loss as `interrupted`.
- Avoid automatic whole-turn replay until you have step/tool idempotency.
- Keep Oban, Ecto, and web transport choices in the host app.
