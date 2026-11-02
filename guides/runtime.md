# The Durable Runtime

Clementine ships the durable machinery as a runtime: it owns the
`agent_runs` table, the Oban worker, the reaper, and the drain, and the
host writes only glue. Runs survive deploys, pause for approval, and get
finished by the reaper when their node dies, and a fix to any of that
reaches every host as a dependency bump.

The host keeps three things:

- a child after Oban in its supervision tree;
- one migration calling `Clementine.Migration.up(version: 6)`;
- `use Clementine.Agent` modules.

`mix clementine.install` writes them (plus the config and a test case),
and `mix clementine.gen.agent Weather` adds an agent with a tool and a
test. An app that needs its own run table and worker builds them from the
pieces instead; [Durable Execution](durable-execution.md) walks that
path.

## The glue

The child goes after Oban, so the runtime can check Oban is running, and
so it stops first at shutdown and drains its runs while Oban still owes
them the grace period:

<!-- guide-sample: parse-only -->
```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Oban, Application.fetch_env!(:my_app, Oban)},
  {Clementine,
   repo: MyApp.Repo,
   oban: Oban,
   queue: :agents,
   agents: [MyApp.Agents.Weather],
   host: MyApp.Agents.Host}
]
```

`repo` is required, and must be the repo Oban uses: a run and its job
commit in one transaction. `oban` defaults to `Oban`, `queue` to `:agents`
(declare it in the Oban config: `queues: [agents: 10]`), `agents` to
none, and `host` to none. Nothing else is configurable.

The migration builds `agent_runs`, keyed by UUID, with the column recipe,
the subject, the actor, the turn flag, and the lane index, plus the
loop inbox and the run trace beside it:

```elixir
defmodule MyApp.Repo.Migrations.AddClementine do
  use Ecto.Migration

  def up, do: Clementine.Migration.up(version: 6)
  def down, do: Clementine.Migration.down(version: 6)
end
```

Each version's DDL is frozen in `Clementine.Migration`, and each stamps
its number on the table. The runtime checks the stamp as it starts and
refuses to start against a table behind the code's version, naming the
migration to write: a host on version 5 adds one calling
`Clementine.Migration.up(from: 5, version: 6)`.

An agent is a module with a stable key, the string its run rows store:

```elixir
defmodule MyApp.Agents.Weather do
  use Clementine.Agent,
    key: "weather",
    model: "claude-sonnet-5-5",
    instructions: "Answer questions about the weather in a few sentences.",
    tools: [],
    defaults: [max_iterations: 10, max_duration: :timer.minutes(5)]
end
```

When the agent depends on the run, write `agent/1` instead; the runtime
calls it at every claim:

```elixir
defmodule MyApp.Agents.Triage do
  use Clementine.Agent, key: "triage"

  @impl true
  def agent(run) do
    Clementine.Agent.new(
      model: "claude-sonnet-5-5",
      instructions: "Triage this ticket: #{inspect(run.subject)}"
    )
  end
end
```

An agent that converses is a turn agent: `turn: true`, and `history/1`,
the messages before the run's prompt, oldest first, read from the app's
own tables. The runtime sends them to the model, then the prompt. It
runs when a run starts from its prompt, not when a run resumes after an
approval, whose checkpoint already holds the conversation:

```elixir
defmodule MyApp.Agents.Chat do
  use Clementine.Agent,
    key: "chat",
    turn: true,
    model: "claude-sonnet-5-5",
    instructions: "You are a helpful assistant. Be brief."

  @impl true
  def history(run), do: MyApp.Chat.messages(run.subject_id)
end
```

A turn is a run on a thread: its subject is the thread, and the host's
`run_finished/2` appends what it said (below). A turn agent without
`history/1` fails the build; any other agent is a task, and may define
one too.

## Subject, actor, and the lane

A run carries up to two references, stored as text and resolved by the
host at every claim: its subject, what it is about
(`subject: {"ticket", id}`), and its actor, whose authority it acts with
(`actor: {"user", id}`). Either refusal cancels the run as unstartable,
so a run acting for an account suspended while it waited for approval
never resumes.

Which decides the run's lane, the key under which active runs (queued,
running, or waiting) are exclusive, held by one unique index:

- a turn's lane is its thread, whichever agent it belongs to: at most
  one active turn per thread, so a second agent's turn on a busy thread
  is refused too;
- a task's lane is its agent and subject: tasks of different agents on
  one subject, and a turn and a task, run side by side;
- a run with no subject has no lane and blocks nothing.

Busy means refused: `start/3` returns `{:error, :active_run_exists}`. A
thread that should queue messages instead gets a loop, which holds the
lane and starts one turn at a time: `Clementine.Thread`, the controller
that ships with the runtime, or one of your own; see
[Durable Loops](durable-loops.md).

## Running agents

`Clementine.Runs` is the whole API:

<!-- guide-sample: parse-only -->
```elixir
{:ok, run} =
  Clementine.Runs.start(MyApp.Agents.Triage, prompt,
    subject: {"ticket", ticket.id},
    actor: {"user", user.id}
  )

Clementine.Runs.get(run.id)
#=> %Clementine.Runs.AgentRun{status: "completed", result: %{"output" => "..."}}

:ok = Clementine.Runs.resume(run.id, {:approved, %{by: user.id}})
{:ok, :finished} = Clementine.Runs.cancel(run.id)

Clementine.Runs.active?(MyApp.Agents.Triage, {"conversation", id})  # a screen in flight?
Clementine.Runs.active({"conversation", id})                        # the turn in flight, or nil
Clementine.Runs.latest({"conversation", id}, turn: true)            # the thread's newest turn
Clementine.Runs.list(actor: {"user", id}, limit: 50)                # an account's runs
```

A completed run stores its output in `result["output"]`: the answer's
text, or, for an agent with `output_schema:`, the decoded answer
(`%{"verdict" => "pass", ...}`), the same map `run_finished/2` sees in
`Result.Completed`'s `output`.

- `start/3` inserts the run and its Oban job in one transaction, and
  copies the agent's `turn` to the row. A start in a busy lane returns
  `{:error, :active_run_exists}`; a turn without a subject id,
  `{:error, :subject_required}`.
- `get/1` returns the row. Read it freely; only the runtime writes it.
  `AgentRun.active?/1` and `terminal?/1` read its status.
- `trace/1` returns the run's trace, below.
- `active?/2`, `active/1`, `latest/2`, and `list/1` read runs by subject,
  agent, turn, and actor, newest first, rollouts unless told
  `kind: :loop`.
- `resume/2` takes a waiting run's decision, `{:approved, meta}` or
  `{:denied, meta}`. A tool declared `approval: :required` parks its run
  in `waiting` before it executes, and one declared `{:policy, term}`
  does when the host's `authorize_tool/3` says so (see
  [Approvals](approvals.md)). The
  resume and the run's new job commit in one transaction, so a sweep can
  never find the resumed run without a job, and the claim that follows
  resolves the subject and actor again. A run waiting on the agents it
  asked takes no decision: `{:error, :delegating}`.
- `cancel/1` finishes a queued or waiting run at once and flags a running
  one. The flag goes on to the process running it, on whichever node, so
  the model call in flight is aborted and the run ends `cancelled`
  mid-response. On this node the runtime sends it directly; for another
  it notifies every node through Oban's notifier, so a notifier that
  cannot listen (Postgres behind a transaction pooler) leaves the run to
  find the flag at its next step.

## Refusals, cut-off answers, and empty ones

A run whose final turn the provider refused, or cut off, fails. It never
completes, so no app reads a refusal or half an answer as the answer. A
final turn that wrote nothing completes when the run called tools, and
says so; a run that did nothing at all fails:

| The final turn | The run | `error.code` |
|----------------|---------|--------------|
| Anthropic's `stop_reason: "refusal"`; OpenAI's refusal content, or a content filter (`"content_filter"`) | `failed` | `:refused` |
| `"max_tokens"` (OpenAI's `max_output_tokens`, Chat Completions' `length`), `"model_context_window_exceeded"`, an OpenAI response left incomplete, a Chat Completions finish reason Clementine does not know (`"incomplete"`) | `failed` | `:truncated` |
| Either of those inside a tool call's input | `failed`, and none of the turn's calls runs | `:refused` or `:truncated` |
| `"end_turn"`, `"stop_sequence"` | `completed`, with that `stop_reason` | |
| No text, after the run called tools: an empty `"end_turn"`, which Claude sends most after tool results | `completed`, `stop_reason: "empty"`, `output: ""` | |
| No text, and the run called no tools | `failed` | `:empty` |

- The error is `kind: :rollout` and not retryable: the same request to
  the same model mostly gets the same answer. `run_finished/2` receives
  `%Result.Failed{error: %Clementine.Error{code: :refused}}`, the row says
  `status: "failed"` and `error["code"] == "refused"`, a loop hears the
  `Result.Failed`, and `clementine_rollout_exceptions_total` counts it
  by `error_code`, never as `clementine_rollout_stops_total{status="success"}`.
  The trace's last `:model_call` keeps the stop reason, and, under
  `trace: :content`, what the model wrote before it stopped.
- `error.raw` says what stopped it: `"stop_reason"`; on an Anthropic
  refusal, `"stop_details"`, its `"category"` (`"cyber"`, `"bio"`,
  `"reasoning_extraction"`, ...) and `"explanation"`, never content,
  and the message names the category; on a stop inside a tool call,
  `"unfinished_call"`, naming the call (`"tool_use_id"`, `"tool_name"`)
  and why it is unfinished.
- Only a final answer is judged. A turn that calls tools runs them
  whatever it stopped on, except a refused one, or one cut off inside a
  call: the provider stopped the turn, and its calls were one answer,
  of which the last is half-written. That is the likeliest cut for an
  agent that answers in a tool's input. A paused turn (`"pause_turn"`)
  goes back to the provider and continues.
- A completed run names its final turn's stop reason:
  `Result.Completed`'s `stop_reason`, and `result["stop_reason"]` on the
  row. An empty answer completes because an agent whose answer is its
  tool calls (a screener's submission, an email reply sent through a
  tool) is done; one whose answer is its text said nothing.
- The empty final turn is in `messages`, as an assistant message of no
  content. It closes the exchange before it: `Clementine.History.window/2`
  (and an app's own trim of an open exchange at a thread's end) keeps the
  calls the turn made, so the next turn does not make them again, and a
  skill's system message is followed by an assistant turn, as the API
  requires. No provider is sent it as an empty message, and no history
  sends a text block that is empty or only whitespace, which the API
  refuses on every later turn.
- A failed turn returns no messages, so a host that stores a thread's
  turns from `Result.Completed` stores nothing of it. Keep the user's
  message that drew a refusal in the thread: it is what the user said,
  and two user messages in a row are valid on every provider.
- A refusal is usually not the last word. Anthropic's advice is to send
  the same request to another Claude model, which usually answers it.
  Its server-side fallback (`fallbacks: "default"`, a beta) does that
  inside one call, and an agent's own fallbacks within a run are
  planned (OPS-200); Clementine sends neither yet, so retry the run on
  an agent with another `model:`. A `"reasoning_extraction"` refusal
  has no fallback: the prompt asked the model to write out its
  reasoning. Ask for a short explanation instead, or read the thinking
  blocks under `display: :summarized`.
- There is no switch that completes a cut-off answer. Raise the model's
  `max_tokens` (its catalog entry's `defaults:`), or ask for less. An
  app that wants what the model wrote before the cut reads the streamed
  text, or the trace's last `:model_call` content.

What each kind of agent does with it:

- **A task whose answer is its tool calls** (yakky's screener, which
  submits an assessment through a tool). The run fails; the tool calls
  before the final turn stand, and a submission the cut fell inside
  did not run. Keep the path for a run that ends without its
  submission: the screen fails closed and goes to a person. Name the
  code to staff, since a refusal and a cut-off answer need different
  fixes.
- **An extractor** (revy's, which records statements through a tool and
  ignores its final text). A failed run means the packet was not read
  to the end, never that it documents nothing. On `:refused`, send the
  packet to another model first: that usually answers it. A
  `"reasoning_extraction"` refusal needs a prompt change instead, and
  one still refused goes to a person. On `:truncated` (most often a cut
  inside a call's input), retry with a larger `max_tokens` or a smaller
  packet. On `:empty`, the model neither recorded nor said anything;
  that is not "no statements" either, so have the model say so when a
  packet has none. Statements recorded before a failure are partial
  evidence; never conclude an absence from them.
- **A chat turn** (yakky's patient assistant, Meli). The turn fails and
  the thread moves on (`on_failure: "surface"`). Show a refusal as the
  assistant declining, not as a crash, and take down the text the turn
  streamed before it: Anthropic says to discard it. Keep the user's
  message, and offer to try again (on another model, once you can). Show
  a cut-off answer as cut off; the streamed text is all there is of it,
  so store it yourself if the app keeps a record of what the user read.
  On `stop_reason: "empty"`, show that the assistant did not reply (with
  a way to ask again), never silence, and store the turn's messages as
  usual: the empty turn is what closes its tool calls (a sent email, a
  flagged emergency). `:empty` (a turn that did nothing) shows the same.
  `"on_failure": "retry"` runs a refused or cut-off turn again, which
  is likely refused or cut off again, and repeats what its tools did (a
  sent email): keep it for turns whose tools are safe to repeat.

In tests, script the stop through the Anthropic fake
(`expect_claude_turn/2`):

<!-- guide-sample: parse-only -->
```elixir
expect_claude_turn([{:text, "I can't help with"}],
  stop_reason: "refusal",
  stop_details: %{"type" => "refusal", "category" => "cyber", "explanation" => "..."}
)

assert :ok = perform_job(Clementine.Runs.Worker, %{"run_id" => run.id})
assert %{status: "failed", error: %{"code" => "refused"}} = Clementine.Runs.get(run.id)

# A cut inside a call's input: none of the turn's calls runs.
expect_claude_turn([{:unfinished_tool_use, "toolu_1", "submit", ~s({"tier": "hi)}])
```

## Asking other agents

An agent that needs another agent's answer before it goes on lists the
agents it may ask with `delegates:` (`Clementine.Delegation`):

<!-- guide-sample: parse-only -->
```elixir
defmodule MyApp.Agents.Planner do
  use Clementine.Agent,
    key: "planner",
    model: "claude-sonnet-5-5",
    instructions: "Plan the launch. Ask the researcher for facts you lack.",
    delegates: [MyApp.Agents.Researcher, MyApp.Agents.Writer]
end
```

The model sees a `delegate` tool taking `agent`, an enum of the
delegates' keys, and `prompt`, the child's whole brief. The tool lists
each delegate with its `description:`, so give each one a sentence on
when to ask it (`use Clementine.Agent, key: "researcher", description:
"Finds and cites facts.", ...`). Only `Clementine.Runs` offers
`delegate`; on `Clementine.run/3`, `stream/3`, and `AgentServer` the
agent's delegates are left out.

- **The call.** Each call starts a run of that agent: a child whose
  `parent_id` is the parent's, tagged `{:delegate, tool_use_id}`, with the
  parent's subject and actor and `metadata: %{"delegated_by" => "planner"}`.
  The children of one batch start in the transaction that parks the
  parent, so they exist exactly when it waits on them. A batch that also
  holds an approval-gated call waits for the decision first, then parks
  once for its children.
- **The resume.** A child's end reaches its parent inside the child's
  terminal transaction. The last one resumes the parent, on a new job,
  and each `delegate` call settles with its child's output: text as is,
  anything else (a map from `output_schema:`) JSON-encoded. A child that
  failed, was cancelled, or was interrupted settles as an error the model
  reads. A parent resumed and then drained before any effect requeues
  and resumes again with the same answers.
- **Lanes and cycles.** A child is a task on the parent's subject. A
  turn agent is never a delegate: the call is refused at once. A
  delegate with an active task on the subject, the parent itself or a
  sibling of the same batch included, is refused when the parent parks,
  and so is an agent above the parent in its chain of asks, subject or
  not. Each refusal is an error result the model reads; if no child of
  a batch could start, the parent resumes once its execution is over.
- **Cancel.** `cancel/1` of a waiting parent flags it (`{:ok, :flagged}`)
  and cancels its live children in the same transaction: a queued child
  ends, a running one gets its flag. The parent ends `cancelled` after
  the last of them, so a thread's erasure works as for any thread:
  cancel the loop, and purge from its `run_committed/2`, which runs once
  the turn and the turn's delegates have all ended. `cancel/1` of one
  child settles that call as cancelled once its siblings have ended.
- **The reaper** leaves a waiting parent alone, and a child it interrupts
  (its node died, or it was never claimed) resumes the parent like any
  end. A parent still waiting on children that have all ended (an end
  that never reached it) is resumed by a sweep once its park and its
  last child's end are a sweep interval old. `max_wait:` on
  the policy bounds a parent's wait as it bounds an approval's, and its
  end cancels the children.
- **Purge** follows `parent_id`, so `purge/1` of the subject takes the
  children and their traces.

`delegate` blocks the run that asks until every child ends. Fan-out
that a product drives (start several, decide on each answer, keep
answering the user meanwhile) belongs in a loop.

**Deploying it.** Ship this version of Clementine one deploy before any
agent offers `delegates:`. Nodes on older code drop a child's end when
its parent is a rollout, and cannot read a delegation's checkpoint: a
child they ran during a rolling deploy would leave its parent waiting
until a new node's reaper resumes it, and a parent they claimed would
fail as `:incompatible_checkpoint`.

## Models that bind their thinking

Claude Fable 5.1, Mythos 5.1, Opus 5.5, Sonnet 5.5, and Haiku 5.5 (their
sheets say `thinking: [binding: :prefix]`) bind each thinking block to the conversation it was
produced in: the system prompt, the tools as a set, and every message
before it. The API accepts a replayed block only while all of that is
unchanged, and only in the order its conversation produced it. On an
account created on or after 2026-08-31 a replay after any change is a
400 (on Mythos 5.1, on every account); on an older one the stale
reasoning reaches the model and is billed. A conversation breaks the
rule when its app rebuilds the system prompt every turn, deploys a tool,
slides a window over the history, or replays turns in an order other
than the one the model saw.

What Clementine does about it, without any option:

- **It checks before it sends.** Each turn from one of these models is
  stored with a `binding`, a digest of the request it answered as sent
  (`Clementine.LLM.Message.AssistantMessage`). On replay a turn keeps its
  thinking only while that digest holds; otherwise it goes without it,
  as does every turn after it. A turn with no binding (stored before
  bindings, or produced by an older model) goes without its thinking
  too. Text and tool calls always go. So a changed system prompt, tool
  list, or history start costs the earlier turns' reasoning, and the
  request is never refused: the turns produced after the change bind to
  it and keep theirs.
- **It reports what it dropped.** A call that sends earlier turns
  without their thinking emits `[:clementine, :llm, :thinking_dropped]`
  (counts and the first turn's index, never content), counted in
  `clementine_llm_thinking_dropped_total`, and logs a warning. A change
  reports once, since the next turn is produced after it. An app whose
  every turn reports a drop is replaying its threads out of order, and
  loses its reasoning and its prompt cache on every turn.
- **Its own edits are append-only.** A skill load offers the skill's
  tools in a `Clementine.LLM.Message.SystemMessage` after the load's
  result, sent as a mid-conversation system message with inline tool
  definitions (the `inline-tools-2026-09-15` beta), and the request's
  `tools` stay as the first request sent them. A later turn of the
  thread reads the loaded skills back from that message, so their tools
  stay callable. Models that do not bind get the skill's tools in
  `tools`, as before.
- **A turn of thinking alone stays sendable.** The API takes a system
  message only before an assistant turn or at the end. A turn that held
  nothing but thinking, right after a skill load, would vanish once its
  thinking had to go, and leave the system message before the next
  prompt. It goes as the text `(no reply)` instead, which is what the
  turn showed, and the model reads that as what it said then.
- **Both are facts of the model's sheet, not of its id.**
  `thinking.binding: :prefix` turns the check on, and
  `features.mid_conversation_system` sends a system message in place;
  elsewhere it joins `system` and `tools` (Claude Sonnet 5 takes none in
  place). A model Clementine does not ship says both in its declaration
  (`docs/MODELS.md`), and defaults to neither.
- **It shows the text written between tool calls.** Claude Fable 5.1,
  Mythos 5.1, Opus 5.5, Sonnet 5.5, and Fable 5 can write a short
  progress update before a tool call. It comes back as a thinking block
  of its own, empty under the default display. Ask for the text with
  `display: :updates` on the agent, or, on Sonnet 5.5 with up-front
  thinking off, `thinking: :between_tools`. It streams as `:thinking_delta` events, whose
  `index` tells one update from the next, and is stored in the turn's
  thinking blocks; render a non-empty one as a status line. Haiku 5.5
  writes none.

What the app does:

- **Store every message a turn returns, and replay them in the order the
  model saw them**: each turn's prompt, then `result.messages`, system
  messages included. A message that arrives while a turn runs belongs
  after that turn's reply, wherever its row sorts. A history sorted any
  other way reorders turns, which costs their thinking and the prompt
  cache on every turn. Keep system messages out of what people see:
  they are instructions to the model.
- **Trim a long thread in steps**, with `Clementine.History.window/2`.
  A window of the last N messages moves every turn, so no turn keeps its
  thinking and the cached prefix never matches. `window(messages, max:
  100)` holds its start while the thread grows by fifty messages, then
  moves by fifty at once. It carries the system messages before its
  start along, so a skill loaded long ago stays loaded.
- **Keep the agent's instructions and tools stable within a thread.**
  A change is never refused, and costs the earlier reasoning once.

```elixir
@impl true
def history(run) do
  run.subject_id
  |> MyApp.Chat.messages()
  |> Clementine.History.window(max: 100)
end
```

`provider_options: [prefix_mismatch: :error]` on the agent asks the API
to refuse an invalid replay on any account (`:drop_block` asks it to drop
the blocks instead, a stopgap). Either sends the
`thinking-binding-controls-2026-08-01` beta, and Clementine logs what a
response reports it dropped. Neither is needed with the check above, and
neither shows what Clementine dropped: Clementine removes stale thinking
before the request leaves, so the API never sees it. `:error` catches
only what Clementine's check cannot see, such as thinking moved in from
another conversation; Clementine's own drops are the telemetry event
above. Sonnet 5.5 and Haiku 5.5 take either value only with `thinking:
:adaptive`, and Sonnet 5.5 refuses both with `thinking: :between_tools`.

In tests, script the model with `Clementine.LLM.Anthropic.Fake` on one of
these models; the installer's `expect_claude_turn/2` uses it. It is
strict by default: a turn whose request sent an earlier turn without its
thinking fails, naming the first such message. So a test that runs a
thread turn by turn, storing each turn as the app does, fails on a
reordered or trimmed history, a rebuilt system prompt, or a lost
binding, none of which the API would refuse. Pass `strict: false` for a
turn that changes the thread on purpose (a window's step, new
instructions); the fake then refuses only what the API refuses.

```elixir
test "each turn replays the thread as the model saw it" do
  thread = MyApp.Chat.start_thread!()

  expect_claude_turn([{:thinking, "Hm."}, {:text, "Hello."}])
  MyApp.Chat.send!(thread, "Hi")

  expect_claude_turn([{:thinking, "Hm."}, {:text, "Sure."}])
  MyApp.Chat.send!(thread, "Can you help?")

  # Fails if history/1 reorders, trims, or rebuilds what earlier turns sent.
  expect_claude_turn([{:text, "Done."}])
  MyApp.Chat.send!(thread, "Thanks")
end
```

## The trace

Every run records what it did, and `Clementine.Runs.trace/1` reads it
back, oldest first, as `Clementine.Trace.Entry` structs:

<!-- guide-sample: parse-only -->
```elixir
Clementine.Runs.trace(run.id)
#=> [
#=>   %Clementine.Trace.Entry{epoch: 1, seq: 1, kind: :execution,
#=>     payload: %{"provider" => "anthropic", "platform" => "anthropic",
#=>                "model" => "claude-sonnet-5", "tools" => ["lookup"], "deferred" => [],
#=>                "agent_fingerprint" => "33e5…", "instructions" => "…", "resumed" => false}},
#=>   %Clementine.Trace.Entry{epoch: 1, seq: 2, kind: :model_call,
#=>     payload: %{"iteration" => 1, "stop_reason" => "tool_use", "duration_ms" => 812,
#=>                "usage" => %{"input_tokens" => 1204, "output_tokens" => 38,
#=>                             "cache_read_tokens" => 1100, "cache_write_tokens" => 96},
#=>                "provider" => "anthropic", "platform" => "anthropic",
#=>                "model" => "claude-sonnet-5", "cache_ttl" => "five_minutes",
#=>                "cost" => %{"currency" => "USD", "micros" => 1284},
#=>                "content" => […]}},
#=>   %Clementine.Trace.Entry{epoch: 1, seq: 3, kind: :tool_call,
#=>     payload: %{"name" => "lookup", "args" => %{"query" => "…"}, "result" => "…",
#=>                "is_error" => false, "duration_ms" => 40, "approval" => nil,
#=>                "policy" => nil, …}},
#=>   …
#=> ]

tools_called = for %{kind: :tool_call, payload: %{"name" => name}} <- Clementine.Runs.trace(run.id), do: name
```

- An `:execution` entry opens each execution: when the run starts, and
  again, `"resumed" => true`, when it resumes after an approval or a
  delegation, under the next epoch. It names the model's vendor
  (`"provider"`), the platform its requests go to (`"platform"`), and
  its id (`"model"`). `"tools"` names every tool offered,
  `"deferred"` the ones among them the model loads through tool search,
  `"skills"` the skills it may load, and `"delegates"` the agents it may
  ask. Its `"agent_fingerprint"` is a sha256 over the system prompt, the
  tool schemas, the model id, which tools are deferred, the output
  schema, the skills offered (names, descriptions, and their tools'
  schemas), and the delegates' keys, so runs that offered the model the
  same thing group together.
- A `:model_call` entry records each call to the model, a call cut off
  by a cancel included, with the usage it had reported (its cache reads
  and writes show whether the call found the prompt cache warm), the
  provider, platform, and model it ran on, the cache TTL its writes were
  priced at (`"cache_ttl"`), and its cost at the model's prices then, at
  the tier its prompt reached (`nil` without prices;
  `Clementine.Runs.cost/2` sums a run's, and `docs/MODELS.md` has the
  `prices:` fact). A `:tool_call`
  entry records each tool call started, with the arguments it ran with
  (and `"unknown" => true` beside its `"name"` when the model asked for a
  tool the agent does not offer) and the decision it waited on (`"approval" => %{"verdict" => "approved",
  "by" => ...}`); a call to a `{:policy, term}` tool also carries the
  tool policy's verdict (`"policy" => %{"verdict" => "allow" |
  "require_approval" | "deny", "reason" => ..., "failed" => ...}`), and a
  call it denied ran nothing. A `:policy` entry records each answer the
  policy gave, as it gave it, so a run that ends while it waits still
  shows the policy asked for approval. A call a cancel or a drain cut off is there too: with
  its result if it had one, and `"killed" => true` if it was killed
  before it answered, so what it did is unknown. A `:skill_load` entry
  records each skill the model loaded (`Clementine.Skill`), with the
  tools it brought and a sha256 of the body the model read, just before
  the `use_skill` call that loaded it. A `:delegate` entry records each
  child a `delegate` call started, with its agent, its run id (`trace/1`
  of it is the child's own trace), and how it ended, just before the
  call's `:tool_call` entry, when the parent resumes.
- The runner writes new entries at every iteration boundary, fenced on
  the epoch like the heartbeat, and the rest with the run's end or park,
  in the same transaction: `run_finished/2` already sees the whole trace.
  A run reaped after its node died has its trace up to its last
  boundary.
- `trace: :facts` on the agent keeps names, arguments, ids, timing,
  usage, and the fingerprint, and leaves out the system prompt, what the
  model said, and what each tool returned. A turn agent whose host stores
  the conversation loses nothing by it; a task agent keeps the default,
  `:content`, because nothing else holds its trajectory.
- The trace lives in `agent_run_trace`, which only Clementine writes, and
  goes with the run: `purge/1` erases it. It is not your audit log: a
  security event that must outlive a purged conversation goes in your
  own table, from the tool or the context function that caused it.
- `trace/1` checks nothing, like `get/1`: check the run's subject or actor
  before showing a trace to anyone.

## The warehouse

Every Clementine app has the same tables, so one warehouse model can
compare them all: tokens by app, agent, provider, platform, and model,
and cost, which is directional: each call is frozen at the prices in
force in its app, the sheet's list prices or the app's override, and two
apps on one model may price it apart. Every column of the tables holds facts or content, and a
warehouse copy keeps only the facts:

- **Leave out** `Clementine.Migration.content_columns/0`: `agent_runs`'
  `input`, `result`, `metadata`, `suspension` (the checkpoint holds the
  conversation), `resume`, `cancel`, `error`, `loop_policy`, and
  `envelope`;
  `agent_run_inbox`'s `payload` and `dedup_key`; and `agent_run_trace`'s
  `payload`. They hold prompts, replies, tool arguments and results, and
  your free-form data.
- **Keep** the rest, `Clementine.Migration.fact_columns/0`: ids, keys,
  statuses, timestamps, `agent_runs.usage` (a run's tokens), and the
  trace's fact columns. Each model call's row holds its `iteration`,
  `provider` (the model's vendor), `platform`, `model`, `cache_ttl`,
  `input_tokens`, `output_tokens`, `cache_read_tokens`,
  `cache_write_tokens`, `cost_micros`, `currency`, `duration_ms`, and
  `stop_reason`; each tool call's holds its
  `iteration`, `tool_use_id`, `tool_name`, `is_error`, `killed`,
  `duration_ms`, `approval_verdict`, `policy_verdict`, and
  `policy_failed`. A skill load's row holds its `skill_name`, and a
  delegate's its `delegate_key`, each beside the `tool_use_id` of the call
  that made it; a delegate's child is the run whose `tag_id` is that id.

The fact columns hold no text a person, a model, or a tool produced: a
fact is stored once, in its column, and `payload` keeps the rest of the
entry. `Clementine.Migration`'s docs list every column and what each
content column holds; a later version that adds a column says which it
is.

Three facts are only as safe as what you put in them; the
`Clementine.Migration` docs say more:

- `subject_id`, `actor_id`, and `tag_id` are facts while you keep them
  ids. An email address or an email's Message-ID there is content, as in
  `dedup_key`. A thread tags each turn with its message's id, so if you
  send a Message-ID as both the message's `"id"` and its `dedup_key`, it
  lands in `tag_id` too: leave `tag_id` out as well.
- `skill_name` is a fact while your skills' names are names.
- `agent_fingerprint` is a hash over the instructions and the rest of
  what an execution offered. If your instructions differ by person, it
  confirms a guess at them: leave it out.

## The host module

Eight questions belong to the app, and one optional module answers them.
Every callback is optional:

```elixir
defmodule MyApp.Agents.Host do
  @behaviour Clementine.Host

  alias Clementine.Result

  # Who may approve or deny a waiting run.
  @impl true
  def authorize_resume(run, {_verdict, %{by: user_id}}) do
    if MyApp.Tickets.may_approve?(user_id, run.subject_id), do: :ok, else: {:error, :forbidden}
  end

  def authorize_resume(_run, _decision), do: {:error, :forbidden}

  # Whether a call to a tool declared approval: {:policy, term} runs,
  # waits for approval, or is refused with a reason the model reads.
  # Before the call's batch runs anything; a raise denies the call.
  @impl true
  def authorize_tool(run, %Clementine.ApprovalRequest{args: args}, :refund) do
    cond do
      not MyApp.Accounts.may_refund?(run.actor) -> {:deny, "You may not issue refunds."}
      args["amount_cents"] > 50_00 -> :require_approval
      true -> :allow
    end
  end

  def authorize_tool(_run, _request, _term), do: {:deny, "No policy covers this tool."}

  # Tokens and tool activity while a run executes, for a UI. In a process
  # of its own, in order, outside any transaction.
  @impl true
  def run_event(run, %Clementine.Event{type: :text_delta, payload: %{content: text}}) do
    broadcast(run, {:run_text, run.id, text})
  end

  def run_event(_run, _event), do: :ok

  # Every change short of the end: claimed, suspended, resumed, requeued,
  # cancel requested. After the commit, best-effort.
  @impl true
  def run_transition(run, transition) do
    broadcast(run, {:run_status, run.id, transition})
  end

  # What must happen when a run ends. Inside the transaction that ends
  # it: these writes, and the mail job, commit with the run's end or not
  # at all. A chat turn stores its messages here.
  @impl true
  def run_finished(%{agent_key: "chat"} = run, %Result.Completed{} = result) do
    MyApp.Chat.append!(run.subject_id, [result.input_message | result.messages])
  end

  def run_finished(run, %Result.Completed{output: output}) do
    MyApp.Tickets.record_triage!(run.subject_id, output)
    Oban.insert!(MyApp.Workers.TriageMail.new(%{"ticket_id" => run.subject_id}))
  end

  def run_finished(_run, _result), do: :ok

  # Who hears of the end. After the commit, once, best-effort.
  @impl true
  def run_committed(run, _result) do
    broadcast(run, {:run_ended, run.id})
  end

  # How a subject resolves, at every claim. An error cancels the run as
  # unstartable.
  @impl true
  def resolve_subject("ticket", id) do
    case MyApp.Tickets.get(id) do
      nil -> {:error, :ticket_not_found}
      ticket -> {:ok, ticket}
    end
  end

  def resolve_subject(_type, _id), do: {:ok, nil}

  # How an actor resolves, at every claim, the one after a resume
  # included. A refusal cancels the run as unstartable.
  @impl true
  def resolve_actor("user", id) do
    case MyApp.Accounts.get_user(id) do
      %{suspended_at: nil} = user -> {:ok, user}
      nil -> {:error, :user_not_found}
      _suspended -> {:error, :user_suspended}
    end
  end

  def resolve_actor(_type, _id), do: {:ok, nil}

  defp broadcast(run, message) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "#{run.subject_type}:#{run.subject_id}", message)
  end
end
```

A run reaches the host in order: its claim, its events, then the change
that stops the execution (a suspension, a requeue, or the end), every
event before the change that follows it. Only `run_finished/2` runs
inside a transaction; everything else comes after a commit, never for a
write that rolled back. A `Clementine.Result.Cancelled` carries the
stored reason: `%{"code" => "cancelled"}` from `cancel/1`, and
`%{"code" => "unstartable", "detail" => why}` for a run the runtime could
not build at a claim. A `Clementine.RunView` closes on the run
`run_committed/2` hands over (`RunView.close(view, run)`).

`run_event/2` gets each `Clementine.Event` in a process of its own. The
run does not wait for each call, but it waits once the callback falls 64
events behind, and a callback still stuck five seconds later hears no
more of that execution while the run goes on. Events are advisory: a UI
that misses some recovers from the stored conversation and the run's
end. `run_transition/2` hears every change short of the end, in
whichever process wrote it, with the run as that change committed it;
the end reaches only the two finish hooks.

Both finish hooks see every end (`Completed`, `Failed`, `Cancelled`,
`Interrupted`), after the runtime stored a completed run's output in
`result`. To choose between them, ask whether losing the work matters:

- **It matters**: `run_finished/2`, inside the transaction that ends the
  run. Raising aborts the end, and the runner retries it, so nothing that
  leaves the database belongs here: send mail or call services from an
  Oban job inserted here, which commits with the run.
- **It may be lost**: `run_committed/2`, after that transaction commits,
  once, and never for an end that rolled back. It runs in whichever
  process wrote the end (the worker, the reaper, or the caller of
  `cancel/1`), and a raise there is logged. A node that dies between the
  commit and the call loses it.

Keep every callback fast, and call `resume/2` and `cancel/1` outside a
transaction (they raise inside one, because the host would hear of their
writes before the caller's commit). The resolved subject and actor reach
`agent/1` and `history/1` as `run.subject` and `run.actor`, and every
tool as `context.subject` and `context.actor`, beside `context.run_id`,
`context.agent_key`, `context.turn`, and `context.metadata` (the run's
metadata as `start/3` stored it).

Coding agents working in the app get these rules from
[`usage-rules.md`](../usage-rules.md), which the
[`usage_rules`](https://hexdocs.pm/usage_rules) package gathers into the
app's `AGENTS.md`.

## Testing

Oban runs in `:manual` testing mode in the test environment, and so the
reaper does not start there (Oban's own plugins don't either). Script the
model with a Mox mock set as Clementine's `llm_client`, and execute a run
with `Oban.Testing`:

<!-- guide-sample: parse-only -->
```elixir
{:ok, run} = Clementine.Runs.start(MyApp.Agents.Weather, "Is it sunny?")

expect(MyApp.Agents.LLMMock, :stream, fn _model, _system, _messages, _tools, _opts ->
  [{:text_delta, "Sunny."}, {:message_delta, %{"stop_reason" => "end_turn"}, %{}}]
end)

assert :ok = perform_job(Clementine.Runs.Worker, %{"run_id" => run.id})
assert %{status: "completed"} = Clementine.Runs.get(run.id)
```

`mix clementine.install` writes the mock, makes it the `llm_client` in
`config/test.exs`, and writes `MyApp.AgentsCase`, whose `expect_turn/1`,
`text_events/1`, and `tool_events/3` script turns like this one. Its
`expect_claude_turn/2` scripts a turn through
`Clementine.LLM.Anthropic.Fake`, which fails a turn whose replayed
history lost the model's earlier reasoning
([Models that bind their thinking](#models-that-bind-their-thinking))
or holds what the API refuses (a text block empty or only whitespace).
Its options script the rest of a real response: `stop_reason:`
(`"refusal"`, `"max_tokens"`, `"pause_turn"`, ...) and a refusal's
`stop_details:`, `usage:` in the API's keys, cache tokens included,
which reach the token and cost series as a real response's would, and
`api_errors:`, the 429s and 529s the client retries before the answer
(each backoff capped to the call's budget), or a status it gives up on.
A `{:error, "overloaded_error"}` step ends the turn mid-stream, and an
`{:unfinished_tool_use, id, name, json}` step ends it cut off inside a
call's input.

<!-- guide-sample: parse-only -->
```elixir
expect_claude_turn([{:text, "Sunny."}],
  usage: [input_tokens: 40, cache_read_input_tokens: 900],
  api_errors: [529]
)
```

The runtime's own suite proves the concurrency claims against Postgres in
Clementine's CI: the conformance suite on `agent_runs`, the resume racing
a sweep, a burst that outgrows the queue, the reaper, and the drain.

## Operations

- **Reaper.** Every node sweeps once a minute with
  `Clementine.Reconciler.Policy`'s defaults: a running run whose heartbeat
  is two minutes stale is interrupted, and so is a queued run whose job
  started executing fifteen minutes ago without claiming it. Time a job
  spends waiting in a busy queue does not count, so a burst bigger than
  the queue's limit waits rather than being interrupted. A waiting run is
  never reaped. Sweeps on several nodes need no coordination.
- **Drain.** At shutdown, runs that have not touched the world are
  requeued for the next node, and the rest finish `interrupted`. Give
  them time with Oban's `shutdown_grace_period` and keep the platform's
  termination grace above it.
- **Retries.** None (`max_attempts: 1`): a failed or interrupted run may
  already have acted. The reaper interrupts; only the drain requeues, and
  only runs that have not touched the world.

## Moving from a copied runtime

Before the runtime moved into the library, `mix clementine.install`
copied it into the app as `MyApp.Agents.{AgentRun, Lifecycle, Definition,
Catalog, Runs, RunWorker, Reaper, DrainNotifier}`. Its table (for apps
generated with binary ids) is version 1's table before two changes: the
agent column was `agent`, and the single-active index covered
`(subject_type, subject_id)`. Step 6 migrates it, and every row stays.

Move in one switch deploy. The migration renames a column the copied
runtime reads, so stop every old node before it runs; a rolling deploy
would leave old nodes failing on the missing column.

1. Delete those modules except `RunWorker`, their tests, and the
   `MyApp.Agents.Runners`, `Reaper`, and `DrainNotifier` children.
2. Add `{Clementine, repo: ..., agents: [...]}` after Oban, listing the
   agents from `config :my_app, MyApp.Agents.Catalog`, and delete that
   config.
3. Turn each agent's `@behaviour MyApp.Agents.Definition` into
   `use Clementine.Agent, key: "..."` with the same key, keeping its
   `agent/1`.
4. Move anything the copied `Lifecycle.project/3` did beyond storing the
   output into `run_finished/2` of a host module, and any authorization
   around `Runs.resume/2` into `authorize_resume/2`.
5. Replace `MyApp.Agents.Runs.start("key", prompt)` with
   `Clementine.Runs.start(MyApp.Agents.Key, prompt)`, `get_run/1` with
   `get/1`, `run.agent` with `run.agent_key`, and `RunWorker` with
   `Runs.Worker` in tests.
6. Keep the old migration, and do not add `Clementine.Migration.up/1`:
   the table exists. Add one that brings it to version 1, then one
   calling `Clementine.Migration.up(from: 1, version: 2)` (the runtime
   refuses to start against version 1, and says so). The hand-rolled
   version 1 carries no version stamp; the upgrade stamps it. The
   upgrade adds `turn` as `false` on every row and backfills nothing,
   because which keys are turn agents is the app's code: when the table
   holds rows, set `turn` for the turn agents' rows in that same
   migration, right after the upgrade
   (`execute "UPDATE agent_runs SET turn = true WHERE agent_key IN ('chat')"`),
   so an active turn keeps its thread the moment the lane index exists:

   ```elixir
   defmodule MyApp.Repo.Migrations.MatchClementineVersion1 do
     use Ecto.Migration

     def change do
       rename table(:agent_runs), :agent, to: :agent_key
       execute "ALTER INDEX agent_runs_agent_index RENAME TO agent_runs_agent_key_index",
               "ALTER INDEX agent_runs_agent_key_index RENAME TO agent_runs_agent_index"

       drop index(:agent_runs, [:subject_type, :subject_id],
              name: :agent_runs_single_active_run_index,
              unique: true,
              where: "status IN ('queued', 'running', 'waiting') AND kind = 'rollout'"
            )

       create unique_index(:agent_runs, [:agent_key, :subject_type, :subject_id],
                name: :agent_runs_single_active_run_index,
                where: "status IN ('queued', 'running', 'waiting') AND kind = 'rollout'"
              )
     end
   end
   ```

   Any later version arrives the same way, `up(from: 5, version: 6)`.
7. Keep `RunWorker` for one deploy, reduced to a forwarder. Jobs queued
   before the switch name it, and so do jobs the old nodes requeued while
   they drained; without it they fail, and the reaper interrupts their
   runs. The job arguments are the same:

   ```elixir
   defmodule MyApp.Agents.RunWorker do
     use Oban.Worker, queue: :agents, max_attempts: 1

     @impl Oban.Worker
     def perform(job), do: Clementine.Runs.Worker.perform(job)
   end
   ```

   Delete it in a later deploy, once no unfinished job names it:
   `SELECT count(*) FROM oban_jobs WHERE worker = 'MyApp.Agents.RunWorker'
   AND state NOT IN ('completed', 'cancelled', 'discarded')` returns 0.

An app whose run machinery grew on its own (yakky's `Yakky.Agents`)
moves the same way once its table matches version 1, and then takes
version 2. Compare it column by column first: version 1 names the agent
column `agent_key`, stores `subject_id` as text, scopes the single-active
index by `(agent_key, subject_type, subject_id)`, and inserts rows with
no other required columns. Product columns that version 2 answers (who
the run acts for, whether it is a turn, the thread's latest turn) go;
the rest may stay as long as they are nullable or have defaults. A chat
turn's history moves to the agent's `history/1`, its token stream to
`run_event/2`, broadcasts of its other transitions to
`run_transition/2`, and broadcasts of its end to `run_committed/2`.
