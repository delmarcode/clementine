if Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Lifecycle.Ecto do
    @moduledoc """
    The Ecto lifecycle adapter: `fetch`/`apply` against the host's own run
    table, generated from the column recipe
    (`Clementine.Lifecycle.Ecto.Migration`). The host writes the one
    genuinely product-meaning function — the projection — plus, optionally,
    the `after_transition/3` notification hook:

        defmodule Meli.ClementineLifecycle do
          use Clementine.Lifecycle.Ecto,
            repo: Meli.Repo,
            schema: Meli.Conversations.ConversationRun
            # column names default to the recipe's; override only when yours
            # differ: fields: [epoch: :run_epoch, status: :run_status]

          @impl Clementine.Lifecycle.Ecto
          def project(%Clementine.Result.Completed{} = result, run, _ctx) do
            Meli.Conversations.append_run_messages!(run, result.messages)
          end

          def project(_result, _run, _ctx), do: :ok

          @impl Clementine.Lifecycle.Ecto
          def after_transition(facts, transition, _ctx) do
            MeliWeb.RunBroadcasts.transition(facts, transition)
          end
        end

    ## What the generated functions do

    `apply/2` executes the guarded compare-and-swap the lifecycle contract
    demands — one `UPDATE ... RETURNING` conditional on the exact
    `(status, epoch)` pair, rowcount zero meaning `{:error, :stale}` — and,
    on every transition carrying a `result`, runs `project/3` inside the
    same transaction: if the projection raises, the transition does not
    commit. Symbolic timestamps (`:now`, `{:now_plus, ms}`) resolve with
    `fragment("now()")` — the storage clock is the single time source;
    stamps nested inside jsonb values (a cancel flag's `requested_at`)
    resolve from `SELECT now()` in the same transaction, which in Postgres
    is the identical transaction timestamp.

    `:heartbeat` is special-cased: a single guarded `UPDATE`, no wrapping
    transaction (one `UPDATE` is already atomic), touching only
    `heartbeat_at` — plus the small `usage` sample when the heartbeat
    piggybacks one. It never rewrites the large jsonb columns
    (`suspension`, `error`), keeping the steady-state write HOT-update
    friendly.

    `after_transition/3` fires post-commit, outside the transaction, for
    every applied transition — it is the universal observation point where
    transition notifications fan out (and where a terminal notification
    closes `Clementine.RunView` folds). Failures are logged, never raised,
    and never affect the committed transition. Hosts that find per-heartbeat
    notifications noisy filter on `transition.op`.

    ## The cancel push channel

    Pass `pubsub: MyApp.PubSub` (requires the optional `phoenix_pubsub`
    dependency) to light up token-latency cancellation: the adapter then
    exports `subscribe_cancel/1` — the runner subscribes after claim — and
    broadcasts `{:clementine, :cancel, reason}` on `cancel_topic/1`
    post-commit whenever a cooperative cancel flag lands. Push is an
    optimization; the runner's boundary poll remains the guarantee, so a
    lost broadcast costs latency, never correctness. Direct cancels of
    unowned (`queued`/`waiting`) runs do not broadcast — there is no
    executor to reach; observers learn of them through
    `after_transition/3` like every other transition.

    ## The escape hatch: a hand-written lifecycle

    The adapter hides column mapping, not the model. The de-sugared
    two-function implementation is public contract and works verbatim
    against the recipe columns (reuse `Clementine.Lifecycle.Ecto.Codec` for
    the value codecs rather than re-deriving them):

        defmodule Meli.ClementineLifecycle do
          @behaviour Clementine.Lifecycle
          import Ecto.Query
          alias Clementine.Lifecycle.Ecto.Codec
          alias Clementine.Lifecycle.Transition
          alias Clementine.Result
          alias Meli.{Repo, Conversations}
          alias Meli.Conversations.ConversationRun

          @fields Codec.resolve_fields(:id, [])

          @impl true
          def fetch(run_id, _ctx) do
            case Repo.get(ConversationRun, run_id) do
              nil -> {:error, :not_found}
              run -> {:ok, Codec.to_facts(run, @fields)}
            end
          end

          @impl true
          def apply(%Transition{} = t, ctx) do
            Repo.transaction(fn ->
              with {:ok, run} <- cas(t),
                   :ok <- project(t, run, ctx) do
                Codec.to_facts(run, @fields)
              else
                {:error, reason} -> Repo.rollback(reason)
              end
            end)
          end

          # The one subtle line in the module. The conformance suite fails
          # loudly if either half of the guard is missing.
          defp cas(%Transition{run_ref: id, expect: expect, set: set}) do
            from(r in ConversationRun,
              where: r.id == ^id,
              where: r.status == ^Codec.encode_status(expect.status),
              where: r.lease_epoch == ^expect.epoch,
              select: r,
              update: [set: ^to_columns(set)]
            )
            |> Repo.update_all([])
            |> case do
              {1, [run]} -> {:ok, run}
              {0, _} -> {:error, :stale}
            end
          end

          # Every terminal transition carries a Result (finish, interrupt,
          # direct cancel); project the variants you care about.
          defp project(%Transition{result: %Result.Completed{} = r}, run, _ctx) do
            Conversations.append_run_messages!(run, r.messages)
            :ok
          end

          defp project(_transition, _run, _ctx), do: :ok

          # Writes exactly the keys present in `set`, mapping Facts keys to
          # columns and encoding values via Codec; resolves symbolic stamps
          # against the database clock — `:now` becomes
          # `dynamic(fragment("now()"))` in the update, and stamps nested
          # inside jsonb values resolve from `SELECT now()` in the same
          # transaction (the identical transaction timestamp).
          defp to_columns(set), do: ...
        end

    ## Large checkpoints: the side-table escape hatch

    `suspension` lives in a jsonb column by default; a suspension write
    happens once per suspension and is bounded by the model's context
    window, so column storage is acceptable for most apps. Apps whose
    checkpoints run large can move the value to a side table invisibly:
    `apply` owns that choice — store a pointer in the `suspension` column
    (or a bare marker row id), write the body to the side table in the same
    transaction, and have `fetch` join it back before decoding. Nothing in
    the protocol observes the difference; the conformance suite passes
    either way.
    """

    import Ecto.Query

    require Logger

    alias Clementine.Lifecycle.Ecto.Codec
    alias Clementine.Lifecycle.{Facts, Transition}

    @doc """
    The host's product projection: invoked with the transition's
    `Clementine.Result` and the freshly updated row, inside the same
    transaction as the state write, for every transition into a terminal
    status — finish, reaper interrupt, and direct cancel alike. Raise to
    abort: the transition will not commit. The default implementation is a
    no-op.
    """
    @callback project(Clementine.Result.t(), row :: Ecto.Schema.t(), ctx :: term()) :: any()

    @doc """
    Post-commit notification hook, invoked outside the transaction for
    every applied transition with the committed facts. This is where
    transition notifications broadcast (resume, reap, and direct cancel
    reach observers only through here — no executor was alive to announce
    them) and where terminal notifications close RunView folds. Failures
    are logged and swallowed. The default implementation is a no-op.

    Post-commit means the *outermost* commit: a transition applied inside
    an enclosing atomic unit (the loop adapter's `apply_step/2` cancelling
    children as cargo) defers this hook and the cancel push until that
    unit commits, and drops them if it rolls back — no observer hears of
    a transition that never happened.
    """
    @callback after_transition(Facts.t(), Transition.t(), ctx :: term()) :: any()

    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        @behaviour Clementine.Lifecycle
        @behaviour Clementine.Lifecycle.Ecto

        @clementine_ecto_repo Keyword.fetch!(opts, :repo)
        @clementine_ecto_schema Keyword.fetch!(opts, :schema)
        @clementine_ecto_fields Keyword.get(opts, :fields, [])
        @clementine_ecto_pubsub Keyword.get(opts, :pubsub)

        if @clementine_ecto_pubsub && !Code.ensure_loaded?(Phoenix.PubSub) do
          raise ArgumentError,
                "#{inspect(__MODULE__)} sets pubsub: #{inspect(@clementine_ecto_pubsub)} " <>
                  "but Phoenix.PubSub is not available; add {:phoenix_pubsub, \"~> 2.1\"} " <>
                  "to your dependencies"
        end

        @doc false
        def __clementine_config__ do
          Clementine.Lifecycle.Ecto.config(
            @clementine_ecto_repo,
            @clementine_ecto_schema,
            @clementine_ecto_fields,
            @clementine_ecto_pubsub
          )
        end

        @impl Clementine.Lifecycle
        def fetch(run_ref, ctx) do
          Clementine.Lifecycle.Ecto.fetch(__MODULE__, run_ref, ctx)
        end

        @impl Clementine.Lifecycle
        def apply(transition, ctx) do
          Clementine.Lifecycle.Ecto.apply_transition(__MODULE__, transition, ctx)
        end

        if @clementine_ecto_pubsub do
          @impl Clementine.Lifecycle
          def subscribe_cancel(lease) do
            Clementine.Lifecycle.Ecto.subscribe_cancel(__MODULE__, lease)
          end
        end

        @impl Clementine.Lifecycle.Ecto
        def project(_result, _row, _ctx), do: :ok

        @impl Clementine.Lifecycle.Ecto
        def after_transition(_facts, _transition, _ctx), do: :ok

        defoverridable project: 3, after_transition: 3
      end
    end

    @doc false
    def config(repo, schema, field_overrides, pubsub \\ nil) do
      [ref_column] = schema.__schema__(:primary_key)

      %{
        repo: repo,
        schema: schema,
        fields: Codec.resolve_fields(ref_column, field_overrides),
        pubsub: pubsub
      }
    end

    @doc """
    The push-channel topic for one run's cancel notifications. Both halves
    of the channel — the adapter's post-commit broadcast and the runner's
    `subscribe_cancel/1` subscription — derive it from the same `run_ref`.
    """
    @spec cancel_topic(term()) :: String.t()
    def cancel_topic(run_ref), do: "clementine:cancel:#{ref_string(run_ref)}"

    defp ref_string(run_ref) when is_binary(run_ref), do: run_ref
    defp ref_string(run_ref) when is_integer(run_ref), do: Integer.to_string(run_ref)
    defp ref_string(run_ref), do: inspect(run_ref)

    @doc false
    def subscribe_cancel(module, %Clementine.Lease{run_ref: run_ref}) do
      %{pubsub: pubsub} = module.__clementine_config__()
      pubsub_subscribe(pubsub, cancel_topic(run_ref))
    end

    @doc false
    def fetch(module, run_ref, _ctx) do
      %{repo: repo, schema: schema, fields: fields} = module.__clementine_config__()

      case repo.get(schema, run_ref) do
        nil -> {:error, :not_found}
        row -> {:ok, Codec.to_facts(row, fields)}
      end
    end

    @doc false
    def apply_transition(module, %Transition{op: :heartbeat} = transition, ctx) do
      # A single guarded UPDATE is already atomic; no transaction, no
      # projection, only small columns.
      %{fields: fields} = config = module.__clementine_config__()

      case cas_update(config, transition, nil) do
        {:ok, row} ->
          facts = Codec.to_facts(row, fields)
          emit(fn -> notify(module, facts, transition, ctx) end)
          {:ok, facts}

        {:error, :stale} ->
          {:error, :stale}
      end
    end

    def apply_transition(module, %Transition{} = transition, ctx) do
      %{repo: repo, fields: fields} = config = module.__clementine_config__()

      repo.transaction(fn ->
        # now() in Postgres is the transaction timestamp: this value and the
        # fragment("now()") the CAS update uses resolve identically.
        now = if nested_stamps?(transition.set), do: storage_now(repo)

        case cas_update(config, transition, now) do
          {:ok, row} ->
            if transition.result, do: module.project(transition.result, row, ctx)
            row

          {:error, :stale} ->
            repo.rollback(:stale)
        end
      end)
      |> case do
        {:ok, row} ->
          facts = Codec.to_facts(row, fields)

          emit(fn ->
            push_cancel(config, transition)
            notify(module, facts, transition, ctx)
          end)

          {:ok, facts}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # Post-commit emissions defer while an enclosing atomic unit collects
    # them (see after_transition/3's doc). The stash is process-local
    # because the enclosing transaction is: Ecto transactions live on the
    # calling process's connection.
    @deferred_emissions :clementine_lifecycle_deferred_emissions

    @doc false
    def begin_deferred_emissions do
      Process.put(@deferred_emissions, [])
      :ok
    end

    @doc false
    def flush_deferred_emissions do
      case Process.delete(@deferred_emissions) do
        nil -> :ok
        stashed -> stashed |> Enum.reverse() |> Enum.each(& &1.())
      end

      :ok
    end

    @doc false
    def drop_deferred_emissions do
      Process.delete(@deferred_emissions)
      :ok
    end

    defp emit(fun) do
      case Process.get(@deferred_emissions) do
        nil ->
          fun.()
          :ok

        stashed ->
          Process.put(@deferred_emissions, [fun | stashed])
          :ok
      end
    end

    defp cas_update(%{repo: repo, schema: schema, fields: fields}, %Transition{} = t, now) do
      updates =
        Enum.map(t.set, fn {key, value} ->
          {Keyword.fetch!(fields, key), encode_set_value(key, value, now)}
        end)

      query =
        from(r in schema,
          where: field(r, ^fields[:ref]) == ^t.run_ref,
          where: field(r, ^fields[:status]) == ^Codec.encode_status(t.expect.status),
          where: field(r, ^fields[:epoch]) == ^t.expect.epoch,
          update: [set: ^updates],
          select: r
        )

      case repo.update_all(query, []) do
        {1, [row]} -> {:ok, row}
        {0, _} -> {:error, :stale}
      end
    end

    defp encode_set_value(_key, :now, _now) do
      dynamic(fragment("now()"))
    end

    defp encode_set_value(_key, {:now_plus, ms}, _now) when is_integer(ms) do
      dynamic(fragment("now() + (? * interval '1 millisecond')", ^ms))
    end

    defp encode_set_value(key, value, now) do
      Codec.encode_value(key, resolve_nested(value, now))
    end

    # Symbolic stamps one plain-map level deep (a cancel flag's
    # requested_at, a resume's resumed_at) resolve from the pre-fetched
    # transaction timestamp.
    defp resolve_nested(value, now) when is_map(value) and not is_struct(value) do
      Map.new(value, fn
        {k, :now} -> {k, now}
        {k, {:now_plus, ms}} -> {k, DateTime.add(now, ms, :millisecond)}
        {k, v} -> {k, v}
      end)
    end

    defp resolve_nested(value, _now), do: value

    defp nested_stamps?(set) do
      Enum.any?(set, fn
        {_key, value} when is_map(value) and not is_struct(value) ->
          Enum.any?(value, fn
            {_k, :now} -> true
            {_k, {:now_plus, _}} -> true
            _ -> false
          end)

        _ ->
          false
      end)
    end

    defp storage_now(repo) do
      %{rows: [[%DateTime{} = now]]} = repo.query!("SELECT now()")
      now
    end

    # The library-side half of the cancel push channel: a committed
    # cooperative-cancel flag (the flavor whose set carries :cancel, not a
    # terminal status) broadcasts to whichever executor subscribed at
    # claim. Post-commit and best-effort exactly like notify/3 — a downed
    # or misconfigured PubSub must not crash a committed transition or
    # keep it from reaching after_transition/3; the boundary poll
    # guarantees delivery semantics, so a lost broadcast costs latency
    # only.
    defp push_cancel(%{pubsub: pubsub}, %Transition{
           op: :cancel_request,
           run_ref: run_ref,
           set: %{cancel: %{reason: reason}}
         })
         when not is_nil(pubsub) do
      pubsub_broadcast(pubsub, cancel_topic(run_ref), {:clementine, :cancel, reason})
    rescue
      e ->
        Logger.error(
          "cancel push broadcast raised: #{Exception.message(e)} " <>
            "(pubsub: #{inspect(pubsub)}, run: #{inspect(run_ref)})"
        )
    catch
      kind, reason ->
        Logger.error(
          "cancel push broadcast #{kind}: #{inspect(reason)} " <>
            "(pubsub: #{inspect(pubsub)}, run: #{inspect(run_ref)})"
        )
    end

    defp push_cancel(_config, _transition), do: :ok

    if Code.ensure_loaded?(Phoenix.PubSub) do
      defp pubsub_subscribe(pubsub, topic), do: Phoenix.PubSub.subscribe(pubsub, topic)

      defp pubsub_broadcast(pubsub, topic, message) do
        Phoenix.PubSub.broadcast(pubsub, topic, message)
        :ok
      end
    else
      defp pubsub_subscribe(_pubsub, _topic), do: {:error, :phoenix_pubsub_unavailable}
      defp pubsub_broadcast(_pubsub, _topic, _message), do: :ok
    end

    # Post-commit, best-effort: a failed notification must never fail (or
    # retry) a committed transition.
    defp notify(module, %Facts{} = facts, %Transition{} = transition, ctx) do
      try do
        module.after_transition(facts, transition, ctx)
      rescue
        e ->
          Logger.error(
            "#{inspect(module)}.after_transition/3 raised: #{Exception.message(e)} " <>
              "(op: #{transition.op}, run: #{inspect(transition.run_ref)})"
          )
      catch
        kind, reason ->
          Logger.error(
            "#{inspect(module)}.after_transition/3 #{kind}: #{inspect(reason)} " <>
              "(op: #{transition.op}, run: #{inspect(transition.run_ref)})"
          )
      end

      {:ok, facts}
    end
  end
end
