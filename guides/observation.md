# Observing Runs

A durable run is owned by a worker, not by whoever is watching it. Clients
observe execution — they never own it: a browser disconnect must not kill
a run, and a reconnect must show mid-run state without replaying history.

Observation travels **two roads**, and the split matters:

- **Execution events** — things the executor sees while animating the
  rollout: text deltas, tool starts, tool results. They flow through your
  `Clementine.Events` sink, stamped with `(epoch, seq)` identity, and they
  are *advisory*: anything derived from events must be re-derivable from
  the terminal result plus lifecycle facts. Nothing requires persisting
  them.
- **Transition notifications** — lifecycle facts changes: claimed,
  suspended, resumed, requeued, finished, reaped. These travel through
  your lifecycle's `after_transition/3` hook, because three of them
  (resume, reaper interrupt, direct cancel) happen when *no executor is
  alive* to emit an event. A notification is just the new
  `Clementine.Lifecycle.Facts` — it needs no sequence number;
  `(status, epoch)` orders itself.

A typical UI subscribes to one topic per run and receives both.

## The event sink

The sink is a behaviour with one callback. Delivery is decoupled from
execution: the runner ignores error returns and isolates raises, so a
downed PubSub costs visibility, never correctness.

```elixir
defmodule MyApp.ClementineEvents do
  @behaviour Clementine.Events

  @impl true
  def emit(lease, event) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "run:#{lease.run_ref}",
      {:run_event, event}
    )
  end
end
```

Pass it to the runner (`events: MyApp.ClementineEvents` in the worker from
[Durable Execution](durable-execution.md)). Each `Clementine.Event`
carries `run_ref`, `epoch`, `seq`, a `type` from the closed taxonomy
(`:iteration_start`, `:text_delta`, `:tool_use_start`,
`:tool_input_delta`, `:tool_result`, `:approval_requested`,
`:usage_delta`, `:error`), and a `payload`.

`(epoch, seq)` is the ordering scheme: each execution numbers its own
events gaplessly; the epoch orders executions, so ordering survives
suspend/resume cycles without any durable counter. Two consequences worth
knowing: gaps *across* epochs are expected and meaningless, and consumers
drop events from an epoch lower than the highest seen — which is what
silences a superseded executor's stragglers for free.

## Transition notifications

The Ecto adapter invokes `after_transition/3` post-commit, outside the
transaction, for every applied transition. Broadcast the facts on the same
topic; most hosts filter out the per-heartbeat noise:

```elixir
defmodule MyApp.ClementineLifecycle do
  use Clementine.Lifecycle.Ecto,
    repo: MyApp.Repo,
    schema: MyApp.Runs.AgentRun

  @impl Clementine.Lifecycle.Ecto
  def project(%Clementine.Result.Completed{} = result, run, _ctx) do
    MyApp.Chat.append_messages!(run.conversation_id, result.messages)
  end

  def project(_result, _run, _ctx), do: :ok

  @impl Clementine.Lifecycle.Ecto
  def after_transition(facts, %Clementine.Lifecycle.Transition{op: op}, _ctx)
      when op != :heartbeat do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "run:#{facts.ref}",
      {:run_transition, facts}
    )
  end

  def after_transition(_facts, _transition, _ctx), do: :ok
end
```

This is the one universal observation point: a user's cancel, an approval
resume, a reaper interrupt on another node — every write in the system
lands here, including the terminal ones. Failures in the hook are logged
and swallowed; they never affect the committed transition.

## RunView: the canonical fold

Clementine owns the event taxonomy, so Clementine owns the reduction from
events to a live view — `Clementine.RunView`: the accumulated text so
far, tools in flight, usage (scoped to the current epoch — see the module
doc for that boundary), and the `{epoch, seq}` cursor.

```text
view = RunView.new(run_ref)
view = RunView.apply(view, event)   # pure; drops stale epochs and seqs
view = RunView.close(view, facts)   # terminal notification arrived
```

The fold is where the subtle correctness lives, and it ships in the
library so apps stop rebuilding it: `apply/2` discards duplicates, events
at or below the cursor, and events from superseded epochs; `close/2` pins
the terminal facts, and a closed view rejects everything at or below its
final epoch. Closure is what finally silences a reaped run's zombie
executor — a reaped run never mints a successor epoch, so no epoch
comparison could ever drop its ghost stream; the terminal notification
can, and does.

Cache one view per active run wherever you already cache things. A
GenServer + map is enough to serve reconnect snapshots:

```elixir
defmodule MyApp.RunViewCache do
  use GenServer

  alias Clementine.{Event, RunView}
  alias Clementine.Lifecycle.Facts

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Track a run — call at enqueue."
  def watch(run_id), do: GenServer.call(__MODULE__, {:watch, run_id})

  @doc "The live view for a reconnecting client, or nil if untracked."
  def snapshot(run_id), do: GenServer.call(__MODULE__, {:snapshot, run_id})

  @impl GenServer
  def init(views), do: {:ok, views}

  @impl GenServer
  def handle_call({:watch, run_id}, _from, views) do
    :ok = Phoenix.PubSub.subscribe(MyApp.PubSub, "run:#{run_id}")
    {:reply, :ok, Map.put_new(views, run_id, RunView.new(run_id))}
  end

  def handle_call({:snapshot, run_id}, _from, views) do
    {:reply, Map.get(views, run_id), views}
  end

  @impl GenServer
  def handle_info({:run_event, %Event{run_ref: run_id} = event}, views) do
    {:noreply, Map.replace_lazy(views, run_id, &RunView.apply(&1, event))}
  end

  def handle_info({:run_transition, %Facts{ref: run_id} = facts}, views) do
    if Facts.terminal?(facts) do
      # Keep the closed view around briefly for late reconnects.
      Process.send_after(self(), {:evict, run_id}, :timer.minutes(1))
      {:noreply, Map.replace_lazy(views, run_id, &RunView.close(&1, facts))}
    else
      {:noreply, views}
    end
  end

  def handle_info({:evict, run_id}, views) do
    {:noreply, Map.delete(views, run_id)}
  end
end
```

## Reconnect

With the fold in the library, reconnect is subscription order plus
idempotence — no buffering dance, no gap bookkeeping:

1. Subscribe to the run's topic.
2. Snapshot the cached `RunView`.
3. Apply everything that arrives; the fold discards whatever the snapshot
   already contains.

In a LiveView:

<!-- guide-sample: parse-only -->
```elixir
defmodule MyAppWeb.RunLive do
  use MyAppWeb, :live_view

  alias Clementine.RunView
  alias Clementine.Lifecycle.Facts

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, "run:#{run_id}")
    end

    view = MyApp.RunViewCache.snapshot(run_id) || RunView.new(run_id)
    {:ok, assign(socket, view: view)}
  end

  @impl true
  def handle_info({:run_event, event}, socket) do
    {:noreply, update(socket, :view, &RunView.apply(&1, event))}
  end

  def handle_info({:run_transition, %Facts{} = facts}, socket) do
    if Facts.terminal?(facts) do
      {:noreply, update(socket, :view, &RunView.close(&1, facts))}
    else
      # claimed / suspended / resumed — update whatever status chrome
      # the page shows; the facts carry everything.
      {:noreply, socket}
    end
  end
end
```

Between a reap and its closing notification there is a brief window where
a partitioned-but-alive zombie can stream ghost deltas. They touch nothing
durable, and closure ends them — the honest worst case of observing a
system whose truth is the terminal result, not the stream.

## Telemetry

Execution and lifecycle are also instrumented with `:telemetry` events —
`[:clementine, :rollout | :llm | :tool, ...]` around the engine and
`[:clementine, :run, :claimed | :heartbeat | :suspended | :resumed |
:finished | :requeued | :lease_lost | :reaped]` across the run
lifecycle. `Clementine.Telemetry` documents every event and ships
`metrics/0` definitions for `telemetry_metrics` reporters;
`Clementine.Telemetry.Logger` is a ready-made dev/debug handler.
