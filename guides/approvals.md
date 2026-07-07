# Approvals & Suspension

Some tool calls should not run until a human says so: a production deploy,
a destructive migration, an outbound email. Clementine models this as
**suspension** — the run parks with a durable checkpoint, the worker's job
completes normally, and hours or days later an authorized decision resumes
the run exactly where it stopped, without re-executing anything that
already ran.

This guide assumes the setup from
[Durable Execution](durable-execution.md). Suspension requires a durable
lifecycle by definition — a parked run must outlive the process that
parked it. The ephemeral one-liner path (`Clementine.run/3` and
`Clementine.stream/3`) raises on approval-gated tools rather than pretend
otherwise.

## Gate a tool

One line of tool metadata:

```elixir
defmodule MyApp.Tools.Deploy do
  use Clementine.Tool,
    name: "deploy",
    description: "Deploy the current release to an environment",
    approval: :required,
    retry: :unsafe,
    parameters: [
      env: [type: :string, required: true, description: "Target environment"]
    ]

  @impl true
  def run(%{env: env}, _context) do
    {:ok, "Deployed to #{env}"}
  end
end
```

`approval: :required` gates every call to this tool. `:never` (the
default) never gates. `{:policy, term}` is reserved for app-resolved
policies; until policy resolution exists, it gates exactly like
`:required` — the safe reading of an unresolved policy.

## What happens at the gate

When the model requests a gated call, the rollout stops *before executing
it* and the runner parks the run:

1. Ungated siblings in the same tool batch execute normally; their results
   ride in the checkpoint (`completed_results`). Nothing is discarded, and
   nothing unsafe re-executes on resume.
2. The run transitions `running -> waiting`, storing a
   `Clementine.Suspension` in your run row: the reason
   (`{:approval, %Clementine.ApprovalRequest{}}` — which call, which
   arguments), the `Clementine.Checkpoint` (accumulated messages,
   iteration count, usage, the pending call), and the
   `Clementine.ResumeToken`.
3. **No finish occurs.** The heartbeat stops, `Runner.execute/2` returns
   `{:suspended, token}`, and the Oban job completes — a completed job is
   the *normal* state of a suspended run.
4. Only after the suspension is durable does the advisory
   `approval_requested` event go out to observers — an approval UI must
   never precede a durable suspension.

The run now sits in `waiting`, owned by nobody, until your app acts.

## Build the approval surface

The resume token is read from **your own storage** — it lives inside the
suspension your run row carries. It is deliberately absent from the
`approval_requested` event: the event tells every observer *that* an
approval is pending; the token is a control-plane reference for code
you've authorized.

```elixir
defmodule MyApp.Approvals do
  alias Clementine.Lifecycle.Protocol
  alias Clementine.{ApprovalRequest, Suspension}
  alias Clementine.Lifecycle.Facts

  @lifecycle MyApp.ClementineLifecycle

  @doc """
  What is this run waiting on? Feeds the approval UI: the gated tool's
  name and arguments, straight from the stored suspension.
  """
  def pending(run_id) do
    with {:ok, %Suspension{reason: {:approval, request}}} <- suspension(run_id) do
      {:ok, %ApprovalRequest{} = request}
    end
  end

  @doc """
  An approver decided. Authorization is *your* meaning — check it before
  touching the token; the token authenticates nothing.
  """
  def decide(run_id, decision, %{id: user_id} = approver) do
    with :ok <- authorize!(run_id, approver),
         {:ok, %Suspension{token: token}} <- suspension(run_id),
         {:ok, _facts} <- Protocol.resume(@lifecycle, token, payload(decision, user_id)) do
      # Resume never hides an enqueue: waiting -> queued happened, and
      # handing the run to a worker is explicitly the app's move.
      MyApp.Runs.re_enqueue!(run_id)
    end
  end

  defp suspension(run_id) do
    case @lifecycle.fetch(run_id, nil) do
      {:ok, %Facts{status: :waiting, suspension: %Suspension{} = suspension}} ->
        {:ok, suspension}

      {:ok, %Facts{}} ->
        {:error, :run_not_waiting}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp payload(:approve, user_id), do: {:approved, %{by: user_id}}

  defp payload({:deny, message}, user_id),
    do: {:denied, %{by: user_id, message: message}}

  @doc """
  End a parked run outright instead of resuming it — denial-as-cancel,
  or an app-side expiry sweep.
  """
  def cancel(run_id, reason) do
    with {:ok, _flavor} <- Protocol.request_cancel(@lifecycle, run_id, reason) do
      :ok
    end
  end

  defp authorize!(_run_id, _approver) do
    # Your rules: role checks, ownership, four-eyes, whatever the product
    # demands. Clementine deliberately has no opinion here.
    :ok
  end
end
```

How you *notify* approvers is equally yours — a PubSub-fed inbox, an
email, a Slack message. The `after_transition/3` hook fires for the
suspend transition like any other (see
[Observing Runs](observation.md)), which is the natural place to trigger
notifications.

## The round trip, end to end

On `{:approved, meta}`, the app re-enqueues the same worker. The next
claim increments the epoch and hands the checkpoint back through the
lease; the rollout restores its messages and iteration count, executes
the gated call *now*, merges the siblings' checkpointed results, and
continues gathering until a terminal. The worker code never branches on
any of this — see the worker's return mapping in
[Durable Execution](durable-execution.md).

On `{:denied, meta}`, nothing external executes: the rollout synthesizes
an **error tool result** carrying `meta[:message]` (default:
`"Denied by approver."`) for the gated call and lets the model react —
apologize, propose an alternative, ask what to do instead. Denial is a
conversation turn, not an exception.

If your product wants denial to *end* the run instead, cancel it rather
than resuming it — `MyApp.Approvals.cancel/2` above. On a `waiting` run,
`Clementine.Lifecycle.Protocol.request_cancel/4` is a direct terminal
transition: nobody owns the run, so it becomes `cancelled` immediately,
the projection fires with `Clementine.Result.Cancelled`, and observers
hear about it through `after_transition/3`.

## The token is a staleness defense, not a permission

`Clementine.Lifecycle.Protocol.resume/4` validates the token against
current facts — the run
is still `waiting`, the suspension is still the one the token came from
(epoch match), the reason type matches — so the failure modes of
approval UIs die with precise errors instead of corrupting state:

- `{:error, :already_resumed}` — the token fired once already (a
  double-clicked approve button, a replayed webhook). The run is
  untouched.
- `{:error, :stale_reference}` — the token is from a superseded
  suspension of this run.
- `{:error, :wrong_reference_type}` — the token's reason type does not
  match the stored suspension.
- `{:error, :run_not_waiting}` — the run already reached a terminal.
- `{:error, :not_found}` — the token names no run.

What the token does **not** do is authorize. Its fields are guessable; it
carries no secret. *Who may resume* is app meaning, enforced by your code
before it calls `resume` — that is why the token never rides in broadcast
events.

## Parked runs and policy

A suspension is durable and patient — and unmanaged patience is a leak.
Three levers, all app policy:

- **Expiry by reaper.** Set `max_wait:` on your
  `Clementine.Reconciler.Policy` and the sweep interrupts runs waiting
  past the ceiling as `:suspension_expired`. Each suspension gets its own
  window (the wait clock restarts at every park). The default policy has
  no ceiling: a run leaves `waiting` only by explicit decision.
- **Cancel.** `Clementine.Lifecycle.Protocol.request_cancel/4` on the
  waiting run, as above.
- **Deny-with-message.** Resume with `{:denied, %{message: "expired"}}`
  and let the model close the loop conversationally.

Two product consequences worth deciding up front:

- With the default single-active index, a parked run **blocks new runs in
  its scope** — the conversation is "busy" until the approval resolves.
  Narrow the index to `[:queued, :running]` if your product should chat
  past a parked approval (see the index discussion in
  [Durable Execution](durable-execution.md)).
- A deploy can change your code between suspend and resume. Checkpoints
  carry a format `version`; a checkpoint the new code no longer
  understands fails the run with error code `:incompatible_checkpoint` —
  a clean `Failed` terminal, never a crash — and your app chooses the
  recovery (surface it, or start a fresh run from the original input).
