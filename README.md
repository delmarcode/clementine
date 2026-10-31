# Clementine

Clementine runs LLM agents in Elixir apps. An agent is data: a model,
instructions, and tools in a `%Clementine.Agent{}` struct. Running one is
a separate, explicit act, and one execution engine does it two ways: in
process, for scripts, evals, and tests; and durably, on your app's
Postgres and Oban, where a run is a row that outlives the process that
started it. A durable run can wait days for a person's approval, is never
left hanging when its node dies, and keeps a trace of what it did.

## The shape

Agent work outlives the request that starts it: the browser disconnects,
a deploy replaces the node, the approver answers tomorrow. So Clementine
keeps what an agent is apart from executing it:

- **`Clementine.Agent`**: model, instructions, tools, limits. Inert data,
  built once or per request.
- **`Clementine.Rollout`**: one execution's spec, an agent with its input
  and history. Executing it is the model–tool cycle: call the model, run
  the tools it asks for, send back the results, until it answers or hits
  a limit.
- **`Clementine.Run`**: one durable attempt at a rollout. In an app, a row
  in `agent_runs`.
- **`Clementine.Runner`**: executes a run against a `Clementine.Lifecycle`,
  the storage contract. It claims the run, heartbeats, parks it for
  approval, and writes its end exactly once.
- **`Clementine.Result`**: how a run ended. `Completed`, `Failed`,
  `Cancelled`, or `Interrupted`, each with its token usage.

No process holds an agent or a run: a run's state is its row. In an app,
Clementine owns that table, the Oban worker, the reaper that ends a dead
node's runs as `interrupted`, and the drain that requeues, at shutdown,
the runs that have not yet acted on the world. The app keeps its
conversations in its own tables and answers a few questions in callbacks.
There is no graph or chain DSL: what happens above a run is ordinary
Elixir, or a durable loop (`Clementine.Loop`) when it must outlive a
process.

## Install

Clementine is not on Hex. Depend on it from GitHub; `mix.lock` pins the
commit:

<!-- guide-sample: parse-only -->
```elixir
def deps do
  [
    {:clementine, github: "delmarcode/clementine"}
  ]
end
```

It needs Elixir 1.19. The in-process path needs nothing more than an API
key and a model alias in config (below). The durable runtime needs Ecto
on Postgres and Oban 2.18 or later in the app, typically a Phoenix app.
Two generators write its glue. They run on [Igniter](https://hexdocs.pm/igniter), so add
`{:igniter, "~> 0.8", only: [:dev, :test]}` as well. With Oban installed
(`mix igniter.install oban`):

```bash
mix clementine.install            # the child, a migration, config, a test case
mix ecto.migrate
mix clementine.gen.agent Weather  # an agent, a tool, and a test that runs them
```

`mix clementine.install` writes:

- `{Clementine, repo: MyApp.Repo, oban: Oban, queue: :agents, agents: []}`
  in the application's children, right after Oban;
- a migration calling `Clementine.Migration.up(version: 4)`, which builds
  `agent_runs`, the loop inbox `agent_run_inbox`, and the run trace
  `agent_run_trace`;
- config: an `agents` Oban queue, `anthropic_api_key: {:system,
  "ANTHROPIC_API_KEY"}`, a `:claude_sonnet` model alias, and the `run_id`
  logger metadata key;
- `MyApp.Agents.LLMMock` as the model client in `config/test.exs`,
  `MyApp.AgentsCase`, whose helpers script it in tests, and `mox`.

`mix clementine.gen.agent Weather` writes `MyApp.Agents.Weather`, a tool
for it, and a test that runs the two end to end against the scripted
model, and lists the agent in the child's `agents:`. Running either task
again changes nothing. A table on an earlier version moves up with a new
migration (`Clementine.Migration.up(from: 3, version: 4)`); the runtime
refuses to start against a table behind it, and names the migration to
write.

## Quick start: in process

Configure a key and a model alias:

```elixir
# config/config.exs
config :clementine, anthropic_api_key: {:system, "ANTHROPIC_API_KEY"}

config :clementine, :models,
  claude_sonnet: [provider: :anthropic, id: "claude-sonnet-5"]
```

Write a tool, build an agent, and run it:

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

<!-- guide-sample: run -->
```elixir
agent =
  Clementine.Agent.new(
    model: :claude_sonnet,
    instructions: "You are a weather assistant. Be brief.",
    tools: [MyApp.Tools.Weather]
  )

{:ok, %Clementine.Result.Completed{} = result} =
  Clementine.run(agent, "How's Lisbon today?")

result.output
```

`Clementine.run/3` executes the run in the calling process against an
in-memory lifecycle: the same runner and limits as production, and no
database. Any other ending comes back as `{:error, result}`, carrying the
`Failed`, `Cancelled`, or `Interrupted` result. `Clementine.stream/3`
yields the run's `Clementine.Event`s as they happen, then
`{:result, result}`. A run in process cannot wait for an approval or for
another agent, because waiting must outlive the process: an
approval-gated tool raises here, and delegates are left out.

## Quick start: durable

`mix clementine.gen.agent Weather` writes an agent module with a stable
key, the string its run rows store:

```elixir
defmodule MyApp.Agents.Weather do
  use Clementine.Agent,
    key: "weather",
    model: :claude_sonnet,
    instructions: """
    You are the weather agent. Use your tools to find what you need,
    then answer in a few sentences.
    """,
    tools: [MyApp.Agents.Weather.Tools.Lookup],
    defaults: [max_iterations: 10, max_duration: :timer.minutes(5)]
end
```

With `ANTHROPIC_API_KEY` set, start the app (`iex -S mix`) and run it:

<!-- guide-sample: parse-only -->
```elixir
{:ok, run} = Clementine.Runs.start(MyApp.Agents.Weather, "Will it rain in Lisbon tomorrow?")

Clementine.Runs.get(run.id)
#=> %Clementine.Runs.AgentRun{status: "completed", result: %{"output" => "..."}, ...}

Clementine.Runs.trace(run.id)   # its model calls and tool calls, oldest first
```

`Runs.start/3` inserts the run and its Oban job in one transaction, and
a worker on any node executes it. It also takes `subject:` (what the run
is about, `{"ticket", id}`), `actor:` (whose authority it acts with,
`{"user", id}`), and `metadata:`. `Runs.cancel/1` stops a run on
whichever node runs it.

What a run means to the app goes in an optional host module
(`Clementine.Host`, the child's `host:`): `run_finished/2` commits with
the run's end, `run_committed/2` and `run_transition/2` hear of changes
after they commit, `run_event/2` streams tokens to a UI, and
`resolve_subject/2` and `resolve_actor/2` load the run's subject and
actor at every claim, where a refusal cancels the run. The generated
test shows how to run an agent in a test: script the model with
`expect_turn/1`, then
`perform_job(Clementine.Runs.Worker, %{"run_id" => run.id})`.
[The Durable Runtime](guides/runtime.md) covers all of this.

## Conversations are threads

A conversation is a thread. Its messages live in the app's tables, and
each answer is a **turn**: a run whose subject is the thread. A turn
agent says `turn: true` and reads the thread back in `history/1`. The
host stores what each turn said in `run_finished/2`, which commits with
the turn's end. `trace: :facts` keeps the turn's trace to names,
arguments, and timing, since the app already holds the text.

```elixir
defmodule MyApp.Agents.Chat do
  use Clementine.Agent,
    key: "chat",
    turn: true,
    trace: :facts,
    model: :claude_sonnet,
    instructions: "You are a helpful assistant. Be brief."

  @impl true
  def history(run), do: MyApp.Chat.messages(run.subject_id)
end
```

A thread holds one active turn: a second `Runs.start/3` on a busy thread
returns `{:error, :active_run_exists}`. To answer every message, in
order, give the thread a loop. `Clementine.Thread` is the controller that
ships with the runtime. List it in `agents:` beside the turn agent, start
one per conversation, and send it each message:

<!-- guide-sample: parse-only -->
```elixir
{:ok, loop} =
  Clementine.Runs.start_loop(Clementine.Thread, %{"agent" => "chat"},
    subject: {"conversation", conversation.id},
    actor: {"user", user.id}
  )

{:ok, :appended} =
  Clementine.Runs.send(loop.id, %{"prompt" => content, "id" => message.id},
    dedup_key: message.id
  )
```

The thread starts one turn at a time and queues the messages that arrive
during one; with `"busy" => "interrupt"` in its args, a new message
cancels the running turn and is answered in its place. It keeps no
transcript; `history/1` reads it. `Runs.child(loop.id, {:turn,
message.id})` is a message's turn once it starts, and
`Clementine.Thread.waiting(loop.id)` the ids of the messages queued. In
process, history is a list you pass: `Clementine.run(agent, prompt,
messages: history)`.

## Tools

`use Clementine.Tool` turns a parameter list into the JSON Schema the
model sees, and checks arguments before `run/2`. A tool returns text:
`{:ok, content}`; `{:ok, content, is_error: true}` for a failure the
model should see and react to, such as a non-zero exit; or
`{:error, reason}` for a call that could not run. Its second argument is
the context: in process, what `Clementine.run/3`'s `context:` passed; on
the durable runtime, the run's `run_id`, `subject`, `actor`, and
`metadata`, plus what the agent's `tool_context:` adds.

Two declarations matter once runs are durable:

- `approval: :required` parks the run before the call executes, until
  `Clementine.Runs.resume(run.id, {:approved, meta})` runs it or
  `{:denied, meta}` tells the model no. `approval: {:policy, term}` asks
  the host's `authorize_tool/3` about each call instead, and it answers
  `:allow`, `:require_approval`, or `{:deny, reason}`.
- `retry: :safe` declares a tool free of external effects: running it
  twice is as good as once, so a run that has called only safe tools
  has not acted on the world, and a drain may still requeue it. Any
  other tool counts as unsafe.

The built-in tools, `Clementine.Tools.ReadFile`, `WriteFile`, `ListDir`,
`Search`, and `Bash`, refuse unless the context grants their capability
(`capabilities: %{read: true, write: false, shell: false}`), and stay
inside its `working_dir`. On the durable runtime that directory comes
only from the agent's `tool_context:`. An agent with many tools lists
the ones it rarely needs as `deferred:`, and on Anthropic models the
model searches for them. [docs/TOOL_AUTHORING.md](docs/TOOL_AUTHORING.md)
has the full contract.

## What else it does

| You want | Use | Read |
| --- | --- | --- |
| A person to approve a call, or a policy to decide | `approval:`, `authorize_tool/3`, `Runs.resume/2` | [Approvals & Suspension](guides/approvals.md) |
| To see what a run did | `Clementine.Runs.trace/1`, `trace: :facts` | [The trace](guides/runtime.md#the-trace) |
| Instructions and tools loaded only when a task needs them | `Clementine.Skill`, `skills:` | [Skills](guides/getting-started.md#skills) |
| An agent that asks other agents and waits for their answers | `delegates:` | [Asking other agents](guides/runtime.md#asking-other-agents) |
| More tools than a model chooses among well | `deferred:` | [Many tools](guides/getting-started.md#many-tools) |
| An answer code reads, not text | `output_schema:` | [Structured output](guides/getting-started.md#structured-output) |
| Who a run acts for, checked at every claim | `actor:`, `resolve_actor/2` | [Subject, actor, and the lane](guides/runtime.md#subject-actor-and-the-lane) |
| A thread, a judge, or a watcher that lives for months | `Clementine.Thread`, `Clementine.Loop` | [Durable Loops](guides/durable-loops.md) |
| To run loops at scale | telemetry, the loop doctor | [Loop Operations](guides/loop-operations.md) |
| Live tokens and status in a UI | `run_event/2`, `run_transition/2`, `Clementine.RunView` | [The host module](guides/runtime.md#the-host-module), [Observing Runs](guides/observation.md) |
| Your own run table and worker | `Clementine.Runner`, `Clementine.Lifecycle` | [Durable Execution](guides/durable-execution.md) |
| To judge a result and try again | `Clementine.Verifier` in process, a loop when durable | [Verification](guides/getting-started.md#verification-is-outer-control), [the judge loop](guides/durable-loops.md#the-judge-loop) |
| A conversation held in an IEx process | `Clementine.AgentServer` | its module docs |

[Getting Started](guides/getting-started.md) is the place to begin
reading. The design and its failure matrices are in
[docs/DURABLE_EXECUTION_RFC.md](docs/DURABLE_EXECUTION_RFC.md) and
[docs/LOOP_RFC.md](docs/LOOP_RFC.md).

## Models and providers

An agent names its model by an alias from config, or by a
`{provider, id}` tuple such as `{:anthropic, "claude-opus-4-8"}`. There
are no built-in aliases: `:claude_sonnet` resolves because config names
it. An alias may carry output limits and provider-neutral reasoning:

```elixir
config :clementine, :models,
  claude_sonnet: [provider: :anthropic, id: "claude-sonnet-5"],
  claude_opus: [
    provider: :anthropic,
    id: "claude-opus-4-8",
    defaults: [max_tokens: 16_000],
    reasoning: [thinking: :adaptive, effort: :high]
  ],
  gpt: [provider: :openai, id: "gpt-5.5", reasoning: :medium]
```

`:anthropic` (the Messages API) and `:openai` (the Responses API) have
clients of their own. `:openrouter`, `:bedrock`, `:vertex`, and
`:openai_compatible` (vLLM, SGLang, Tinker, any server that speaks it)
share one Chat Completions client. Keys are config too
(`openai_api_key`, `openrouter_api_key`, ...). The catalog is checked at
boot, so a typo fails startup, not a run.
[docs/MODELS.md](docs/MODELS.md) has every key, a recipe per provider,
and how to add a model or a provider.

## For coding agents

[`usage-rules.md`](usage-rules.md) is the durable runtime's rules, short
and decisive: the glue, which callback runs inside a transaction, and
what never to do. The [`usage_rules`](https://hexdocs.pm/usage_rules)
package gathers it into an app's `AGENTS.md`.

## License

MIT
