# Getting Started

Clementine is an Elixir agent framework that models agent work as inert
definitions animated by explicit execution machinery. An agent is data, not
a process. Executing one is a deliberate act, and the machinery that
executes it — durably, observably, and safely under concurrency — is the
library's actual product.

The vocabulary is small and load-bearing:

- **`Clementine.Agent`** — a reusable capability definition: model,
  instructions, tools, defaults. Inert.
- **`Clementine.Rollout`** — one execution spec: agent + input +
  history + limits. Executing it is the model–tool cycle (call the model,
  execute its tool calls, feed the results back), repeated until a
  terminal answer or a limit. Inert.
- **`Clementine.Run`** — one durable attempt to execute a rollout.
- **`Clementine.Runner`** — the interpreter that animates a run against a
  `Clementine.Lifecycle` (the host storage contract).
- **`Clementine.Result`** — the terminal outcome, a closed sum:
  `Completed`, `Failed`, `Cancelled`, or `Interrupted`. Every variant
  carries usage.

This guide covers the in-process path: scripts, evals, IEx, and tests. The
same nouns run durably in production — Postgres-backed, deploy-surviving,
approval-capable — with the machinery documented in
[Durable Execution](durable-execution.md).

## Installation

Add `clementine` to your dependencies:

<!-- guide-sample: parse-only -->
```elixir
def deps do
  [
    {:clementine, github: "delmarcode/clementine"}
  ]
end
```

Configure an API key and, optionally, your model registry:

<!-- guide-sample: parse-only -->
```elixir
# config/config.exs
import Config

config :clementine,
  anthropic_api_key: {:system, "ANTHROPIC_API_KEY"},
  default_model: :claude_sonnet

config :clementine, :models,
  claude_sonnet: [
    provider: :anthropic,
    id: "claude-sonnet-5",
    defaults: [max_tokens: 8192]
  ]
```

## One line

The simplest consumption stays one line:

<!-- guide-sample: parse-only -->
```elixir
agent =
  Clementine.Agent.new(
    model: :claude_sonnet,
    instructions: "You are a concise research assistant."
  )

{:ok, %Clementine.Result.Completed{} = result} =
  Clementine.run(agent, "What is the tallest mountain in Europe?")

result.output
```

Under that line sit the same nouns production uses: `Clementine.run/3`
builds a `Clementine.Rollout` from the agent and prompt, wraps it in a
`Clementine.Run`, and hands it to the `Clementine.Runner` against an
ephemeral in-memory lifecycle. Deadlines and iteration limits are enforced
exactly as in production; there is no heartbeat and no reaper because a
single process cannot lose a lease, and a crash is the caller's crash.

`run/3` returns `{:ok, %Clementine.Result.Completed{}}` on success. Every
other terminal comes back as `{:error, result}` carrying the matching
`Clementine.Result` variant — a `Failed` with a normalized
`Clementine.Error` (including whether it is retryable), a `Cancelled`, or
an `Interrupted`. All variants carry `usage`; tokens burn on failures too.
`Clementine.Cost.of(result.usage, :claude_sonnet)` prices it, once the
model's catalog entry has prices (`pricing:` in
[`docs/MODELS.md`](../docs/MODELS.md#pricing)).

Prompt caching is on by default: each step of a run reads the prompt
the step before it sent from the provider's cache instead of paying for
it again. `usage.input_tokens` counts every input token, and
`cache_read_tokens` and `cache_write_tokens` are the parts of it the
provider read from its cache and wrote to it. A catalog entry's `cache:`
key turns caching off or changes how long a write lives; the table of
what each provider does is in
[`docs/MODELS.md`](../docs/MODELS.md#prompt-caching).

## Tools

Tools are modules. The `Clementine.Tool` macro generates the JSON Schema
the model sees from an Elixir parameter list, and validates arguments
before your code runs:

```elixir
defmodule MyApp.Tools.Weather do
  use Clementine.Tool,
    name: "get_weather",
    description: "Get the current weather for a city",
    parameters: [
      city: [type: :string, required: true, description: "City name"]
    ]

  @impl true
  def run(%{city: city}, _context) do
    {:ok, "Sunny and 22°C in #{city}"}
  end
end
```

Tool results are strings — the model consumes text. Return `{:ok, content}`
for success, `{:error, message}` for invocation-level failures, or
`{:ok, content, is_error: true}` for command-level failures the model
should see and react to (a non-zero exit, a lint failure). The full result
contract is documented in `Clementine.Tool`.

Wire tools into the agent, and pass request-scoped data through
`:context` — it arrives as your tool's second argument:

<!-- guide-sample: parse-only -->
```elixir
agent =
  Clementine.Agent.new(
    model: :claude_sonnet,
    instructions: "You are a weather assistant.",
    tools: [MyApp.Tools.Weather]
  )

{:ok, result} =
  Clementine.run(agent, "How's Lisbon today?",
    context: %{user_id: 42}
  )
```

Two metadata fields on the tool macro matter for production and are
covered in the durable guides: `approval:` (gate a tool call on a human
decision — see [Approvals](approvals.md)) and `retry:` (declare a tool
safe to re-execute — see the effect fence in
[Durable Execution](durable-execution.md)).

### Many tools

The model chooses among a few tools well and among dozens badly, and
every tool's schema costs context on every call. When an agent needs a
large catalog (several MCP servers, say), keep the few it always uses in
`tools:` and list the rest as `deferred:`:

<!-- guide-sample: parse-only -->
```elixir
agent =
  Clementine.Agent.new(
    model: :claude_sonnet,
    instructions: "You help customers with their orders.",
    tools: [MyApp.Tools.LookupOrder],
    deferred: [MyApp.Tools.IssueRefund, MyApp.Tools.ChangeAddress, MyApp.Tools.CancelOrder]
  )
```

On an Anthropic model the deferred tools go to the Messages API's tool
search: the model starts out seeing `tools:` and searches the deferred
tools' names and descriptions for the few it needs, which then load
into its context. A found tool runs like any other, approval gate and
all. The search itself is part of the turn's messages
(`Clementine.LLM.Message.Content.ServerToolUse` and `ServerToolResult`),
so history that stores and replays a turn's messages keeps the tools it
found. Providers without tool search get deferred tools as ordinary
tools.

## Structured output

When code reads the answer (a grader's verdict, a classifier's label, a
planner's next steps), give the agent the answer's JSON schema as
`output_schema:`, and `result.output` is the decoded map instead of
text:

<!-- guide-sample: parse-only -->
```elixir
agent =
  Clementine.Agent.new(
    model: :claude_sonnet,
    instructions: "Classify the support ticket.",
    tools: [MyApp.Tools.LookupCustomer],
    output_schema: %{
      "type" => "object",
      "properties" => %{
        "queue" => %{"type" => "string", "enum" => ["billing", "bugs", "other"]},
        "urgent" => %{"type" => "boolean"}
      },
      "required" => ["queue", "urgent"],
      "additionalProperties" => false
    }
  )

{:ok, %Clementine.Result.Completed{output: %{"queue" => queue, "urgent" => urgent}}} =
  Clementine.run(agent, ticket_text)
```

The run calls its tools as it likes; only the answer that ends it is
constrained. The schema goes to the provider as its own structured
output (Anthropic's `output_config.format`, OpenAI's `text.format`),
which constrains the model to it, so write it in the subset providers
accept: an object at the root, `"additionalProperties": false` on every
object, and, for OpenAI, every property listed in `required` (type an
optional one `["string", "null"]`). The engine decodes the answer and
checks it against the schema too. An answer that does not decode or
match, as when the model refuses or runs out of tokens, fails the run
with a `Clementine.Error` of code `:invalid_output`; whether to try
again is outer control (below).

## Streaming

`Clementine.stream/3` returns a lazy enumerable of `Clementine.Event`
structs, ending with `{:result, result}`. The stream is caller-owned
deliberately: a script is the rightful owner of its execution — consuming
the stream runs the rollout, and abandoning it aborts the run.

<!-- guide-sample: parse-only -->
```elixir
Clementine.stream(agent, "Explain OTP supervision in one paragraph")
|> Enum.each(fn
  %Clementine.Event{type: :text_delta, payload: %{content: text}} ->
    IO.write(text)

  {:result, %Clementine.Result.Completed{}} ->
    IO.puts("\n[done]")

  _other ->
    :ok
end)
```

Events are stamped with `(epoch, seq)` identity — the ordering scheme that
matters once runs survive restarts; see
[Observing Runs](observation.md).

## Limits

Progress is bounded twice, and both bounds ride on the rollout:

<!-- guide-sample: parse-only -->
```elixir
{:ok, result} =
  Clementine.run(agent, "Audit every file in this repository",
    limits: [max_iterations: 25, max_duration: :timer.minutes(10)]
  )
```

`max_iterations` caps Gather → Act cycles; `max_duration` is a wall-clock
deadline enforced at iteration boundaries (and, in production, minted
fresh at every claim). Exceeding either returns
`{:error, %Clementine.Result.Failed{}}` with error code `:max_iterations`
or `:deadline_exceeded`. Unset keys fall back to the agent's `defaults:`.

## Skills

An agent that handles several kinds of task need not carry every
procedure in its system prompt and every tool from the first call. Give
each kind of task a skill: instructions, and the tools they need.

```elixir
defmodule MyApp.Skills.Forecasts do
  use Clementine.Skill,
    name: "forecasts",
    description: "Answer questions about the weather to come. Use for anything past today.",
    tools: [MyApp.Tools.Weather]

  @impl true
  def body(_context) do
    """
    Look the city up before you answer, and give the forecast day by day.
    Say how sure the forecast is.
    """
  end
end
```

<!-- guide-sample: parse-only -->
```elixir
agent =
  Clementine.Agent.new(
    model: :claude_sonnet,
    instructions: "You are a weather assistant.",
    skills: [MyApp.Skills.Forecasts]
  )
```

The model sees a `use_skill` tool whose description lists each skill's
name and description. When it loads one, the body comes back as that
call's result, and the skill's tools are offered from its next call on.
The system prompt never changes. Loading a skill twice changes nothing,
and a name the agent does not offer is an error the model reads.
`body/1` receives the context the run's tools see, so it may differ by
subject or actor; skills an app keeps as data are built with
`Clementine.Skill.new/1`, with the body as a string.

A skill's tools are ordinary tools: a gated one parks the run like any
other, and the resume offers the loaded skills' tools again. The trace
records each load (`:skill_load`).

## Conversation history

A completed result separates the materialized `input_message` from the
generated `messages`, so history is a fold that can never silently drop
user input:

<!-- guide-sample: parse-only -->
```elixir
{:ok, first} = Clementine.run(agent, "Pick a color.")

history = [first.input_message | first.messages]

{:ok, second} =
  Clementine.run(agent, "Why that one?", messages: history)
```

## Verification is outer control

There is no verifier inside the model–tool cycle. Judging a completed
result and retrying with feedback happens one floor up, in ordinary code —
where it can also fan out, compare candidates, or escalate to a human:

```elixir
defmodule MyApp.JudgedRun do
  alias Clementine.Result

  def run_judged(agent, prompt, judge, attempts \\ 3) do
    Enum.reduce_while(1..attempts, {prompt, []}, fn _n, {input, history} ->
      {:ok, %Result.Completed{} = result} =
        Clementine.run(agent, input, messages: history)

      case judge.(result) do
        :ok ->
          {:halt, {:ok, result}}

        {:retry, feedback} ->
          {:cont, {feedback, history ++ [result.input_message | result.messages]}}
      end
    end)
  end
end
```

`Clementine.Verifier` keeps the judge-function shape
(`verify/2` returning `:ok | {:retry, reason}`) if you want a named
behaviour for it.

## Interactive processes

For a long-lived conversational process that accumulates history — an IEx
session, a local assistant — `Clementine.AgentServer` wraps the same
machinery in a GenServer. It is a porch, not the house: each turn is an
ephemeral run under the hood, and production apps should not make a local
GenServer the durable owner of a conversation that may outlive a pod.

## When you need durability

Everything above ties execution lifetime to the calling process. The
moment agent work must survive browser disconnects, deploys, worker
restarts, or approval pauses, the same `Runner.execute/2` runs against a
durable `Clementine.Lifecycle` backed by your own database table — with
claims, lease fencing, heartbeats, a reaper, checkpointed suspension, and
exactly-one-terminal-writer semantics. An agent that asks other agents
and waits for their answers (`delegates:`, `Clementine.Delegation`)
needs it too.

Continue with [Durable Execution](durable-execution.md).
