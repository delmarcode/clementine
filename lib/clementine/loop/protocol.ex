defmodule Clementine.Loop.Protocol do
  @moduledoc """
  Host-facing loop operations, implemented once in the library on top of
  the `Clementine.Loop.Host` seam — the loop layer's analog of
  `Clementine.Lifecycle.Protocol`.

  V1 carries creation and cancellation; the send verb lands with its own
  epic on the same seam.
  """

  alias Clementine.Lifecycle.Facts
  alias Clementine.Loop
  alias Clementine.Loop.Codec

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
end
