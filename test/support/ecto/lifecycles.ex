defmodule Clementine.Test.Ecto.Lifecycle do
  @moduledoc """
  The adapter under test. `ctx` is the test pid: the projection and the
  notification hook report there, so tests assert both what committed and
  what observers were told. A row labeled `"boom"` makes the projection
  raise — the atomicity probe.
  """

  use Clementine.Lifecycle.Ecto,
    repo: Clementine.TestRepo,
    schema: Clementine.Test.Ecto.Run

  @impl Clementine.Lifecycle.Ecto
  def project(result, row, ctx) do
    if row.label == "boom", do: raise("projection boom")
    if is_pid(ctx), do: send(ctx, {:projected, result, row})
    :ok
  end

  @impl Clementine.Lifecycle.Ecto
  def after_transition(facts, transition, ctx) do
    if is_pid(ctx), do: send(ctx, {:transition, facts, transition})
    if transition.meta[:raise_in_hook], do: raise("hook boom")
    :ok
  end
end

defmodule Clementine.Test.Ecto.HandWrittenLifecycle do
  @moduledoc """
  The de-sugared two-function implementation from the RFC (§A Hand-Written
  Lifecycle, In Full), verbatim in shape, against the recipe columns — the
  documented escape hatch. Column codecs come from `Codec`, exactly as the
  adapter moduledoc's escape-hatch example shows.
  """

  @behaviour Clementine.Lifecycle

  import Ecto.Query

  alias Clementine.Lifecycle.Ecto.Codec
  alias Clementine.Lifecycle.Transition
  alias Clementine.Result
  alias Clementine.Test.Ecto.Run
  alias Clementine.TestRepo, as: Repo

  @fields Codec.resolve_fields(:id, [])

  @impl true
  def fetch(run_id, _ctx) do
    case Repo.get(Run, run_id) do
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
    from(r in Run,
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

  # Every terminal transition carries a Result (finish, interrupt, direct
  # cancel); project the variants you care about, ignore the rest.
  defp project(%Transition{result: %Result.Completed{} = r}, run, ctx) do
    if is_pid(ctx), do: send(ctx, {:hand_written_projected, r, run})
    :ok
  end

  defp project(_transition, _run, _ctx), do: :ok

  # Writes exactly the keys present in `set`; resolves symbolic :now and
  # {:now_plus, ms} against the database clock (fragment("now()")).
  defp to_columns(set) do
    now = if Enum.any?(set, fn {_k, v} -> symbolic?(v) end), do: db_now()

    Enum.map(set, fn {key, value} ->
      {Keyword.fetch!(@fields, key), to_column_value(key, value, now)}
    end)
  end

  defp to_column_value(_key, :now, _now), do: dynamic(fragment("now()"))

  defp to_column_value(_key, {:now_plus, ms}, _now) do
    dynamic(fragment("now() + (? * interval '1 millisecond')", ^ms))
  end

  defp to_column_value(key, value, now) when is_map(value) and not is_struct(value) do
    resolved =
      Map.new(value, fn {k, v} -> {k, if(symbolic?(v), do: resolve(v, now), else: v)} end)

    Codec.encode_value(key, resolved)
  end

  defp to_column_value(key, value, _now), do: Codec.encode_value(key, value)

  defp symbolic?(:now), do: true
  defp symbolic?({:now_plus, _}), do: true

  defp symbolic?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(value, fn {_k, v} -> symbolic?(v) end)
  end

  defp symbolic?(_), do: false

  defp resolve(:now, now), do: now
  defp resolve({:now_plus, ms}, now), do: DateTime.add(now, ms, :millisecond)

  # In Postgres now() is the transaction timestamp, so this value matches
  # the fragment("now()") the same transaction's UPDATE resolves.
  defp db_now do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT now()")
    now
  end
end
