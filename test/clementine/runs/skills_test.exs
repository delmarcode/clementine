defmodule Clementine.Runs.SkillsTest do
  @moduledoc """
  Skills on the durable runtime, on Postgres: a run that loads a skill and
  parks on the skill's gated tool stores checkpoint version 2 with the
  skill named, and the resume after approval offers the skill's tools
  again; a run parked with no skill loaded stores exactly the version-1
  envelope, which older code reads and this code resumes; and an agent
  that stopped offering a loaded skill fails the resume as
  `:incompatible_checkpoint`.
  """

  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]

  alias Clementine.Tool

  defmodule Ship do
    @moduledoc false
    use Clementine.Tool,
      name: "ship",
      description: "Ships a release; needs approval",
      approval: :required,
      parameters: [version: [type: :string, required: true]]

    @impl true
    def run(%{version: version}, context),
      do: {:ok, "Shipped #{version} to #{context.subject_id}."}
  end

  defmodule Releases do
    @moduledoc false
    use Clementine.Skill,
      name: "releases",
      description: "Ship a release. Use when asked to ship.",
      tools: [Ship]

    @impl true
    def body(context), do: "Ship to #{context.subject_id} only after its checks pass."
  end

  defmodule Releaser do
    @moduledoc false
    # Offers the skill unless the run's metadata says a deploy dropped it,
    # or sets its skills past Agent.new/1 when it says "clash".
    use Clementine.Agent, key: "test_releaser"

    @impl true
    def agent(run) do
      agent =
        Clementine.Agent.new(
          model: :claude_sonnet,
          instructions: "Release things.",
          tools: [Clementine.RunsCase.Context],
          skills: if(run.metadata["dropped"], do: [], else: [Releases])
        )

      if run.metadata["clash"], do: %{agent | skills: [Releases, Releases]}, else: agent
    end
  end

  @moduletag runtime: false

  setup do
    start_supervised!(
      {Clementine, repo: TestRepo, agents: [Releaser, Approval], host: Clementine.RunsCase.Host}
    )

    :ok
  end

  defp expect_offered(events) do
    test = self()

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, tools, _opts ->
      send(test, {:offered, Enum.map(tools, &Tool.to_schema(&1).name)})
      events
    end)
  end

  defp stored_checkpoint(run_id) do
    TestRepo.one(from(r in AgentRun, where: r.id == ^run_id, select: r.suspension["checkpoint"]))
  end

  defp park_on_ship! do
    {:ok, run} = Runs.start(Releaser, "Ship 1.2", subject: {"ticket", "t-9"})
    expect_offered(tool_events("tu_1", "use_skill", %{"name" => "releases"}))
    expect_offered(tool_events("tu_2", "ship", %{"version" => "1.2"}))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "waiting"} = Runs.get(run.id)
    run
  end

  test "a skill's gated tool parks the run, and the resume after approval offers the skill's " <>
         "tools again" do
    run = park_on_ship!()

    assert_received {:offered, ["context", "use_skill"]}
    assert_received {:offered, ["context", "ship", "use_skill"]}

    assert %{"version" => 2, "skills" => ["releases"]} = stored_checkpoint(run.id)

    assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
    expect_offered(text_events("Shipped."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert %AgentRun{status: "completed", result: %{"output" => "Shipped."}} = Runs.get(run.id)
    assert_received {:offered, ["context", "ship", "use_skill"]}

    trace = Runs.trace(run.id)

    assert [%{epoch: 1, payload: %{"name" => "releases", "tools" => ["ship"]}}] =
             Enum.filter(trace, &(&1.kind == :skill_load))

    assert %{
             payload: %{
               "name" => "ship",
               "result" => "Shipped 1.2 to t-9.",
               "approval" => %{"verdict" => "approved", "by" => "alice"}
             }
           } = Enum.find(trace, &(&1.kind == :tool_call and &1.epoch == 2))

    assert %{payload: %{"name" => "use_skill", "result" => body}} =
             Enum.find(trace, &(&1.kind == :tool_call and &1.epoch == 1))

    assert body =~ "Ship to t-9 only after its checks pass."
  end

  test "a run parked with no skill loaded stores the envelope version 1 wrote, and resumes" do
    {:ok, run} = Runs.start(Approval, "Tell the team")
    expect_turn(tool_events("tu_1", "send_note", %{"text" => "hi"}))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    # What code that reads only version 1 finds: version 1, and no key it
    # does not know, through a rolling deploy or a rollback.
    stored = stored_checkpoint(run.id)
    assert stored["version"] == 1

    assert stored |> Map.keys() |> Enum.sort() ==
             ~w(cursor iteration messages pending rollout_id usage version)

    assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
    expect_turn(text_events("Sent."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert %AgentRun{status: "completed", result: %{"output" => "Sent."}} = Runs.get(run.id)
  end

  test "an agent that no longer offers a loaded skill fails the resume as :incompatible_checkpoint" do
    run = park_on_ship!()

    # A deploy between the park and the resume dropped the skill.
    {1, _} =
      TestRepo.update_all(from(r in AgentRun, where: r.id == ^run.id),
        set: [metadata: %{"dropped" => true}]
      )

    assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert %AgentRun{status: "failed", error: %{"code" => "incompatible_checkpoint"} = error} =
             Runs.get(run.id)

    assert error["message"] =~ ~s(skill "releases", which the agent no longer offers)
  end

  test "an agent/1 that sets clashing skills past Agent.new/1 fails the run as :invalid_skills" do
    {:ok, run} =
      Runs.start(Releaser, "Ship 1.2", subject: {"ticket", "t-9"}, metadata: %{"clash" => true})

    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert %AgentRun{status: "failed", error: %{"code" => "invalid_skills"} = error} =
             Runs.get(run.id)

    assert error["message"] =~ ~s(more than one skill named ["releases"])
  end
end
