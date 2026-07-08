defmodule Clementine.Test.Ecto.Factory do
  @moduledoc """
  The conformance factory: inserts one queued run row per call (fresh
  scope, so the single-active index never collides) and returns its ref.
  The `LifecycleCase` projection-probe convention is encoded in the row's
  `label`, which both test lifecycles' projections decode through
  `Clementine.Test.Ecto.ProjectionProbe`.

  `create_loop/1` is the `Clementine.LoopCase` factory: a thin wrapper
  over `Clementine.Loop.Protocol.create/3` encoding the battery's two
  conventions — `scope_token:` composes a deterministic scope (equal
  tokens hit create's insert-or-get) and `completion_glue: :dropped`
  labels the loop row with `Clementine.Test.Ecto.LoopHost.drop_glue_label/0`
  so its children terminalize without the completion-append glue (the
  row L13 strand; see `Clementine.Test.Ecto.LoopHost.child_attrs/4`).
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

  @spec create_loop(keyword()) :: integer()
  def create_loop(attrs) do
    scope =
      case Keyword.get(attrs, :scope_token) do
        nil -> "conformance:#{System.unique_integer([:positive])}"
        token -> "conformance:#{token}"
      end

    row_attrs =
      case Keyword.get(attrs, :completion_glue) do
        :dropped -> %{label: Clementine.Test.Ecto.LoopHost.drop_glue_label()}
        nil -> %{}
      end

    spec = %{
      module: Keyword.fetch!(attrs, :module),
      scope: scope,
      args: Keyword.fetch!(attrs, :args),
      policy: Keyword.fetch!(attrs, :policy),
      attrs: row_attrs
    }

    case Clementine.Loop.Protocol.create(Clementine.Test.Ecto.LoopHost, spec) do
      {:ok, facts} -> facts.ref
      {:ok, :already_exists, facts} -> facts.ref
    end
  end

  @doc "The LoopCase step-job observation hook: jobs are ledger rows, so a plain count."
  @spec step_jobs(integer()) :: non_neg_integer()
  def step_jobs(loop_ref) do
    import Ecto.Query, only: [from: 2]

    TestRepo.aggregate(
      from(j in Clementine.Test.Ecto.Job, where: j.run_ref == ^loop_ref and j.kind == "step"),
      :count
    )
  end

  @doc "The storage clock — inside a sandbox checkout, the transaction timestamp."
  @spec db_now!() :: DateTime.t()
  def db_now! do
    %{rows: [[%DateTime{} = now]]} = TestRepo.query!("SELECT now()")
    now
  end
end
