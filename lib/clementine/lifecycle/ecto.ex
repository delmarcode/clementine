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
    """
    @callback after_transition(Facts.t(), Transition.t(), ctx :: term()) :: any()

    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        @behaviour Clementine.Lifecycle
        @behaviour Clementine.Lifecycle.Ecto

        @clementine_ecto_repo Keyword.fetch!(opts, :repo)
        @clementine_ecto_schema Keyword.fetch!(opts, :schema)
        @clementine_ecto_fields Keyword.get(opts, :fields, [])

        @doc false
        def __clementine_config__ do
          Clementine.Lifecycle.Ecto.config(
            @clementine_ecto_repo,
            @clementine_ecto_schema,
            @clementine_ecto_fields
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

        @impl Clementine.Lifecycle.Ecto
        def project(_result, _row, _ctx), do: :ok

        @impl Clementine.Lifecycle.Ecto
        def after_transition(_facts, _transition, _ctx), do: :ok

        defoverridable project: 3, after_transition: 3
      end
    end

    @doc false
    def config(repo, schema, field_overrides) do
      [ref_column] = schema.__schema__(:primary_key)

      %{
        repo: repo,
        schema: schema,
        fields: Codec.resolve_fields(ref_column, field_overrides)
      }
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
          notify(module, Codec.to_facts(row, fields), transition, ctx)

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
          notify(module, Codec.to_facts(row, fields), transition, ctx)

        {:error, reason} ->
          {:error, reason}
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
