defmodule Clementine.Loop.Protocol do
  @moduledoc """
  Host-facing loop operations, implemented once in the library on top of
  the `Clementine.Loop.Host` seam — the loop layer's analog of
  `Clementine.Lifecycle.Protocol`.

  V1 carries creation; the send verb and cancellation land with their own
  epics on the same seam.
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
end
