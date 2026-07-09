defmodule Clementine.Loop.Protocol do
  @moduledoc """
  Host-facing loop operations, implemented once in the library on top of
  the `Clementine.Loop.Host` seam — the loop layer's analog of
  `Clementine.Lifecycle.Protocol`: creation, cancellation, the send verb,
  and the child-ref correlation lookup.
  """

  alias Clementine.Lifecycle.Facts
  alias Clementine.Loop
  alias Clementine.Loop.{Codec, Envelope, Input}

  @doc """
  Creates a loop, insert-or-get, idempotent on the host's scope key
  (LOOP_RFC §Creation): the row lands `queued` with the spec persisted
  (`loop_module` as string, `loop_args` JSON, policy) and the first step
  job enqueued in the same atomic unit; `init/1` runs in the first step.
  Webhook-safe under provider retries by the scope key alone — the first
  message rides the same request as an `append` after create returns.

  The spec:

  - `:module` (required) — the loop behaviour module, or its persisted
    string form. A module without the loop contract is refused as
    `{:error, {:incompatible_spec, _}}`.
  - `:scope` (required) — the idempotency key, a string. Compose it from
    your domain (`"thread:mailbox-7:msg-thread-key"`,
    `"conversation:42"`); the recipe's `loop_scope` column is unique
    where present.
  - `:args` — JSON-safe map handed to `init/1` on the first step
    (default `%{}`).
  - `:policy` — JSON-safe map persisted to `loop_policy` (batch cap,
    dead-letter threshold, deadlines); interpretation belongs to the step
    runner (default `%{}`).
  - `:attrs` — host product columns for the new row (a scope foreign key,
    say); opaque to the machinery (default `%{}`).

  Options: `:ctx` — the opaque host context (default `nil`).

  JSON-safety violations in `:args`/`:policy` raise `ArgumentError` — a
  spec is durable cargo, and a value that cannot cross the storage
  boundary must fail at the caller, not in a later step.
  """
  @spec create(module(), map(), keyword()) ::
          {:ok, Facts.t()} | {:ok, :already_exists, Facts.t()} | {:error, term()}
  def create(host, spec, opts \\ []) when is_map(spec) do
    ctx = Keyword.get(opts, :ctx)

    with {:ok, module} <- Loop.resolve(Map.fetch!(spec, :module)) do
      normalized = %{
        module: module,
        scope: fetch_scope!(spec),
        args: Codec.validate_json_map!(Map.get(spec, :args, %{}), "loop_args"),
        policy: Codec.validate_json_map!(Map.get(spec, :policy, %{}), "loop_policy"),
        attrs: Map.get(spec, :attrs, %{}),
        state_version: module.__loop__(:state_version)
      }

      host.create(normalized, ctx)
    end
  end

  defp fetch_scope!(spec) do
    case Map.fetch(spec, :scope) do
      {:ok, scope} when is_binary(scope) and scope != "" ->
        scope

      _ ->
        raise ArgumentError,
              "loop creation requires a :scope string — the idempotency key create " <>
                "is insert-or-get on; got: #{inspect(Map.get(spec, :scope))}"
    end
  end

  @doc """
  Requests cancellation of a loop — the loop-owned verb that
  `Lifecycle.Protocol.request_cancel/4` refuses loop-kind runs in favor
  of (LOOP_RFC §Cancellation And Halt, amendment A2). Sets the
  kind-aware cancel flag and wakes a parked loop, so the next step
  enters cascade mode — ahead of every queued input by design (a "stop"
  must not wait behind fifty messages; the flag reads at claim, not
  through the FIFO).

  `{:ok, :flagged}` is a delivery promise, not an outcome promise. The
  step machinery — never `handle/2` — runs the cascade: it
  `request_cancel`s live children as commit cargo, absorbs their
  completions between parks, and finishes last with `Result.Cancelled`
  and the terminal inbox sweep, children's terminals preceding the
  loop's at every level (matrix row L8). Two races resolve against the
  flag, both deliberately: a halt already mid-cascade keeps its own
  result (first cause wins), and a finish already committing wins
  outright — the completed work stands, exactly the shipped
  `request_cancel` posture. The flag survives crashes and parks; only
  the finish clears it.

  Cancelling a loop that has never stepped short-circuits its queued
  inputs: the first step enters the cascade with no children and
  finishes immediately, sweeping the inbox to dead-letters — nothing
  silently lost, nothing handled after the operator said stop.

  Options: `:ctx` — the opaque host context (default `nil`).
  """
  @spec cancel(module(), Clementine.Loop.Host.loop_ref(), term(), keyword()) ::
          {:ok, :flagged}
          | {:error, :already_terminal}
          | {:error, :rollout_run}
          | {:error, :not_found}
          | {:error, term()}
  def cancel(host, loop_ref, reason, opts \\ []) do
    host.cancel(loop_ref, reason, Keyword.get(opts, :ctx))
  end

  @doc """
  Sends a message to a loop — the host-caller half of LOOP_RFC
  §Loop-To-Loop Messaging, sugar over `append/4`: the payload wraps as a
  `{:message, payload}` input and rides append's atomic unit (row, wake,
  step-job enqueue). A step's `{:send, target, payload}` action never
  comes here — it is StepCommit cargo, delivered inside `apply_step/2`'s
  unit under the machinery's replay-stable causal key
  (`"send:" <> sender <> ":" <> causal_input <> ":" <> action_index`).

  `:dedup_key` is the caller's idempotency key, caller-supplied today
  (LOOP_RFC §Non-Final): a webhook passes the provider's message id; a
  cross-substrate transport passes the causal key that traveled with the
  message, so the far inbox enforces the sender's exactly-once-in-effect
  (Governing Invariant 12) — a re-dispatched or redelivered send lands
  `{:ok, :duplicate}` while its row lives. Omitted, nothing dedups.

  Addressing, authorization, and transport across trust boundaries are
  host meaning: `loop_ref` is whatever the host's directory resolved, and
  this verb trusts it — an MCP send_message tool wrapping it is the
  accounting-agent-to-CRM-agent story. The append return contract makes
  outcomes observable to the sender: `{:ok, :dead_lettered}` says the
  target is terminal and the message was retained as evidence, never to
  be consumed (matrix row L10) — react or alert, nothing was lost
  silently. `{:error, :rollout_run}` refuses miswired refs (amendment
  A2's mirror).

  Options: `:dedup_key` (default `nil`), `:ctx` — the opaque host
  context (default `nil`).
  """
  @spec send(module(), Clementine.Loop.Host.loop_ref(), term(), keyword()) ::
          {:ok, :appended}
          | {:ok, :duplicate}
          | {:ok, :dead_lettered}
          | {:error, :not_found}
          | {:error, :rollout_run}
          | {:error, term()}
  def send(host, loop_ref, payload, opts \\ []) do
    host.append(
      loop_ref,
      Input.message(payload),
      Keyword.get(opts, :dedup_key),
      Keyword.get(opts, :ctx)
    )
  end

  @doc """
  Resolves the live child run ref the loop's envelope records for `tag` —
  the host correlation of LOOP_RFC §Children: a streaming UI attaches to
  the child ref as the turn spawns; a sync await watches that ref for its
  terminal notification.

  The envelope's children map commits in the same atomic unit that
  inserts the child row, so `{:ok, child_ref}` is exactly as durable as
  the child itself — one lookup hop after the spawning step's commit,
  dwarfed by model latency. `{:error, :no_child}` is a truthful read, not
  a failure: the tag is not live — the spawning step has not committed
  yet (poll; "as it spawns" is one commit away), or the child already
  retired when its completion folded (live-key lifetime — the tag may be
  re-armed by a later spawn).

  Deploy-shaped problems return the loop layer's clean errors —
  `{:error, {:incompatible_spec, _}}` when the persisted `loop_module`
  cannot resolve (its vocabulary is what decodes `tag` to the envelope's
  `tag_key`), `{:error, {:incompatible_state, _}}` when the stored
  envelope cannot; `{:error, :rollout_run}` and `{:error, :not_found}`
  pass through from `load/2`. A `tag` outside the loop's declared
  vocabulary raises `ArgumentError` — the caller's contract violation,
  loud at the call.

  Options: `:ctx` — the opaque host context (default `nil`).
  """
  @spec child_ref(module(), Clementine.Loop.Host.loop_ref(), term(), keyword()) ::
          {:ok, term()}
          | {:error, :no_child}
          | {:error, :not_found}
          | {:error, :rollout_run}
          | {:error, {:incompatible_state, map()} | {:incompatible_spec, map()}}
          | {:error, term()}
  def child_ref(host, loop_ref, tag, opts \\ []) do
    with {:ok, loaded} <- host.load(loop_ref, Keyword.get(opts, :ctx)),
         {:ok, module} <- Loop.resolve(loaded.module),
         {:ok, envelope} <- decode_envelope(loaded.envelope) do
      tag_key = Codec.key(tag, vocabulary: module.__loop__(:vocabulary))

      case envelope && Map.get(envelope.children, tag_key) do
        nil -> {:error, :no_child}
        child_ref -> {:ok, child_ref}
      end
    end
  end

  # A loop that has never committed a step has no envelope — and no
  # children — so nil decodes to nil rather than an error.
  defp decode_envelope(nil), do: {:ok, nil}

  defp decode_envelope(data) do
    case Envelope.decode(data) do
      {:ok, %Envelope{} = envelope} -> {:ok, envelope}
      {:error, detail} -> {:error, detail}
    end
  end
end
