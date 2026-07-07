defmodule Clementine.Test.Ecto.Factory do
  @moduledoc """
  The conformance factory: inserts one queued run row per call (fresh
  scope, so the single-active index never collides) and returns its ref.
  The `LifecycleCase` projection-probe convention is encoded in the row's
  `label`, which both test lifecycles' projections decode through
  `Clementine.Test.Ecto.ProjectionProbe`.
  """

  alias Clementine.Test.Ecto.Run
  alias Clementine.TestRepo

  @spec create_run(keyword()) :: integer()
  def create_run(attrs \\ []) do
    label =
      case Keyword.get(attrs, :projection) do
        nil -> nil
        :raise -> "raise"
        {:raise_on, variant} -> "raise:#{variant}"
      end

    kind = attrs |> Keyword.get(:kind, :rollout) |> Atom.to_string()

    run =
      TestRepo.insert!(%Run{
        scope_id: System.unique_integer([:positive]),
        label: label,
        kind: kind
      })

    run.id
  end

  @doc "The storage clock — inside a sandbox checkout, the transaction timestamp."
  @spec db_now!() :: DateTime.t()
  def db_now! do
    %{rows: [[%DateTime{} = now]]} = TestRepo.query!("SELECT now()")
    now
  end
end
