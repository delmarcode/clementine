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
  """

  use Clementine.Loop.Ecto,
    lifecycle: Clementine.Test.Ecto.Lifecycle,
    inbox_table: "clementine_test_loop_inbox"

  import Ecto.Query, only: [from: 2]

  alias Clementine.Test.Ecto.Job
  alias Clementine.TestRepo

  @impl Clementine.Loop.Host
  def build_child(_facts, _tag, child_args, _ctx) do
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
