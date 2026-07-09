defmodule Clementine.Test.Ecto.Job do
  @moduledoc """
  The stand-in for Oban's job rows: `enqueue_step`/`enqueue_child`/
  `schedule_timer` insert here through the same repo, so tests prove the
  jobs commit — and roll back — with their atomic units.
  """

  use Ecto.Schema

  schema "clementine_test_jobs" do
    field(:run_ref, :integer)
    field(:kind, :string)
    field(:args, :map)
  end
end

defmodule Clementine.Test.Ecto.LoopHost do
  @moduledoc """
  The loop host under test: the Ecto adapter over the shared test
  lifecycle and the recipe inbox, with jobs as `Clementine.Test.Ecto.Job`
  rows. `cancel_timer/4` reports to the `ctx` pid when one is given, so
  tests observe the best-effort cancellation seam.

  `child_attrs/4` propagates the `Clementine.LoopCase` lost-glue probe:
  children of a loop labeled `drop_glue_label/0` inherit the label, and
  `Clementine.Test.Ecto.Lifecycle.project/3` skips the completion-append
  glue for labeled rows — the manufactured row L13 strand. One constant,
  three readers (factory, this host, the projection).

  `build_child/4` builds a real (mock-streamed) rollout from the durable
  args and, like `cancel_timer/4`, reports its invocation to a pid `ctx`,
  so the child-glue tests assert what the worker seam handed the host:
  the child's facts, the decoded tag, the args verbatim.
  """

  use Clementine.Loop.Ecto,
    lifecycle: Clementine.Test.Ecto.Lifecycle,
    inbox_table: "clementine_test_loop_inbox"

  import Ecto.Query, only: [from: 2]

  alias Clementine.Test.Ecto.Job
  alias Clementine.TestRepo

  @drop_glue_label "drop_completions"

  @doc "The LoopCase lost-glue probe label — see the moduledoc."
  def drop_glue_label, do: @drop_glue_label

  @impl Clementine.Loop.Ecto
  def child_attrs(loop_row, _tag_key, _child_args, _ctx) do
    if loop_row.label == @drop_glue_label, do: %{label: @drop_glue_label}, else: %{}
  end

  @impl Clementine.Loop.Host
  def build_child(facts, tag, child_args, ctx) do
    if is_pid(ctx), do: send(ctx, {:build_child, facts, tag, child_args})

    agent = Clementine.Agent.new(model: :claude_sonnet, instructions: "test child")
    {:ok, Clementine.Rollout.new(agent: agent, input: Map.get(child_args, "input", "go"))}
  end

  @impl Clementine.Loop.Host
  def enqueue_step(loop_ref, _ctx) do
    TestRepo.insert!(%Job{run_ref: loop_ref, kind: "step"})
    :ok
  end

  @impl Clementine.Loop.Ecto
  def enqueue_child(child_row, child_args, _ctx) do
    TestRepo.insert!(%Job{run_ref: child_row.id, kind: "child", args: child_args})
    :ok
  end

  @impl Clementine.Loop.Ecto
  def schedule_timer(loop_row, timer_spec, _ctx) do
    job =
      TestRepo.insert!(%Job{
        run_ref: loop_row.id,
        kind: "timer",
        args: %{"tag_key" => timer_spec.tag_key}
      })

    {:ok, %{"job_id" => job.id}}
  end

  @impl Clementine.Loop.Ecto
  def cancel_timer(_loop_row, tag_key, meta, ctx) do
    if job_id = meta["job_id"] do
      TestRepo.delete_all(from(j in Job, where: j.id == ^job_id))
    end

    if is_pid(ctx), do: send(ctx, {:timer_cancelled, tag_key, meta})
    :ok
  end
end
