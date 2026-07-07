# Getting Started

Clementine is an Elixir agent framework that models agent work as inert
definitions animated by explicit execution machinery. An agent is data, not
a process. Executing one is a deliberate act, and the machinery that
executes it — durably, observably, and safely under concurrency — is the
library's actual product.

The vocabulary is small and load-bearing:

- **`Clementine.Agent`** — a reusable capability definition: model,
  instructions, tools, defaults. Inert.
- **`Clementine.Rollout`** — one inner execution spec: agent + input +
  history + limits. The inner loop is Gather → Act (call the model, execute
  tool calls, feed results back), repeated until a terminal answer or
  limit. Inert.
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
    {:clementine, "~> 0.1.0"}
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
    id: "claude-sonnet-4-20250514",
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

There is no verifier inside the inner loop. Judging a completed result and
retrying with feedback happens one floor up, in ordinary code — where it
can also fan out, compare candidates, or escalate to a human:

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
exactly-one-terminal-writer semantics.

Continue with [Durable Execution](durable-execution.md).
