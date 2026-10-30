defmodule Clementine.Runs.ToolPolicyTest do
  @moduledoc """
  The host's tool policy on the durable runtime, on Postgres:
  `c:Clementine.Host.authorize_tool/3` is asked about each call to a
  `{:policy, term}` tool with the run as `agent/1` saw it (subject and
  actor resolved), and its answers run the call, park the run for
  `Runs.resume/2`, or refuse the call; the approval's resume asks again,
  with the run as that claim resolved it, and a deny wins; a raise
  denies the call and logs without the run's data; a run a `delegate`
  call started is asked about with its own run, which carries the
  parent's subject and actor; and a host without the callback gates the
  tool like `:required`.
  """

  use Clementine.RunsCase

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Clementine.ApprovalRequest

  defmodule Refund do
    @moduledoc false
    use Clementine.Tool,
      name: "refund",
      description: "Refunds an order",
      approval: {:policy, :refund},
      retry: :unsafe,
      parameters: [
        order: [type: :string, required: true],
        cents: [type: :integer, required: true]
      ]

    @impl true
    def run(%{order: order, cents: cents}, _context),
      do: {:ok, "Refunded #{cents} on #{order}."}
  end

  defmodule Cashier do
    @moduledoc false
    use Clementine.Agent,
      key: "test_cashier",
      model: :claude_sonnet,
      instructions: "Refund orders.",
      tools: [Refund]
  end

  defmodule Manager do
    @moduledoc false
    use Clementine.Agent,
      key: "test_manager",
      model: :claude_sonnet,
      instructions: "Get refunds done.",
      delegates: [Cashier]
  end

  defmodule PolicyHost do
    @moduledoc false
    # Resolves subjects and actors as the test host does, and answers for
    # refunds: an intern may not refund, nor a run whose metadata says its
    # refunds were revoked; an order named "raise" or "clause" breaks the
    # policy; and a refund over 100.00 needs approval.
    @behaviour Clementine.Host

    alias Clementine.RunsCase.Host

    @impl true
    defdelegate resolve_subject(type, id), to: Host

    @impl true
    defdelegate resolve_actor(type, id), to: Host

    @impl true
    def authorize_tool(run, %ApprovalRequest{args: args} = request, term) do
      if pid = Process.whereis(:clementine_runs_test),
        do: send(pid, {:authorize_tool, run, request, term})

      case {run.actor, run.metadata, args} do
        {%{user: "intern"}, _metadata, _args} -> {:deny, "Interns may not refund."}
        {_actor, %{"refunds" => "revoked"}, _args} -> {:deny, "Refund authority was revoked."}
        {_actor, _metadata, %{"order" => "raise"}} -> raise "policy store down"
        {_actor, _metadata, %{"order" => "clause"}} -> no_rule(run)
        {_actor, _metadata, %{"cents" => cents}} when cents > 100_00 -> :require_approval
        _other -> :allow
      end
    end

    defp no_rule(%Clementine.Runs.AgentRun{status: "never"}), do: :allow
  end

  @moduletag runtime: false

  setup tags do
    Process.register(self(), :clementine_runs_test)

    start_supervised!(
      {Clementine,
       repo: TestRepo, agents: [Cashier, Manager], host: Map.get(tags, :host, PolicyHost)}
    )

    :ok
  end

  defp refund(order, cents), do: %{"order" => order, "cents" => cents}

  defp tool_call(run_id, tool_use_id) do
    run_id
    |> Runs.trace()
    |> Enum.find(&(&1.kind == :tool_call and &1.payload["tool_use_id"] == tool_use_id))
    |> Map.fetch!(:payload)
  end

  defp stored_checkpoint(run_id) do
    TestRepo.one(from(r in AgentRun, where: r.id == ^run_id, select: r.suspension["checkpoint"]))
  end

  # Scripts the model's next turn, checking first that the request carries
  # `text`, the result of the turn before.
  defp expect_turn_reading(text, events) do
    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, messages, _tools, _opts ->
      assert inspect(messages, limit: :infinity, printable_limit: :infinity) =~ text
      events
    end)
  end

  test "the host is asked with the run as agent/1 saw it, the call, and the tool's term, " <>
         "and :allow runs the call" do
    {:ok, run} =
      Runs.start(Cashier, "Refund o-1", subject: {"ticket", "t-1"}, actor: {"user", "ada"})

    run_id = run.id
    expect_turn(tool_events("tu_1", "refund", refund("o-1", 500)))
    expect_turn_reading("Refunded 500 on o-1.", text_events("Refunded."))

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "completed"} = Runs.get(run.id)

    assert_received {:authorize_tool,
                     %AgentRun{
                       id: ^run_id,
                       agent_key: "test_cashier",
                       subject: %{ticket: "t-1"},
                       actor: %{user: "ada"}
                     },
                     %ApprovalRequest{
                       tool_use_id: "tu_1",
                       tool_name: "refund",
                       args: %{"order" => "o-1", "cents" => 500}
                     }, :refund}

    assert %{"policy" => %{"verdict" => "allow"}, "approval" => nil} =
             tool_call(run.id, "tu_1")
  end

  test ":require_approval parks the run, Runs.resume/2 settles the call, and the trace keeps " <>
         "both" do
    {:ok, run} = Runs.start(Cashier, "Refund o-1", actor: {"user", "ada"})
    expect_turn(tool_events("tu_1", "refund", refund("o-1", 500_00)))

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "waiting"} = Runs.get(run.id)
    assert_received {:authorize_tool, _run, %ApprovalRequest{tool_use_id: "tu_1"}, :refund}

    assert %{
             "version" => 2,
             "pending" => %{"tool_name" => "refund", "policy" => "require_approval"}
           } =
             stored_checkpoint(run.id)

    assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
    expect_turn_reading("Refunded 50000 on o-1.", text_events("Refunded."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert %AgentRun{status: "completed"} = Runs.get(run.id)
    # The approval's resume asked once more, and :require_approval runs it.
    assert_received {:authorize_tool, _run, %ApprovalRequest{tool_use_id: "tu_1"}, :refund}

    assert %{
             "policy" => %{"verdict" => "require_approval"},
             "approval" => %{"verdict" => "approved", "by" => "alice"},
             "result" => "Refunded 50000 on o-1."
           } = tool_call(run.id, "tu_1")
  end

  test "an authority revoked while the call waited wins over the approval: the approved " <>
         "call runs nothing" do
    {:ok, run} = Runs.start(Cashier, "Refund o-1", actor: {"user", "ada"})
    expect_turn(tool_events("tu_1", "refund", refund("o-1", 900_00)))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "waiting"} = Runs.get(run.id)

    # Ada's refund authority is revoked, but her account stands, so
    # resolve_actor/2 still lets the run resume. A manager approves.
    {1, _} =
      TestRepo.update_all(from(r in AgentRun, where: r.id == ^run.id),
        set: [metadata: %{"refunds" => "revoked"}]
      )

    assert :ok = Runs.resume(run.id, {:approved, %{by: "manager"}})
    expect_turn_reading("Refund authority was revoked.", text_events("I cannot."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "completed"} = Runs.get(run.id)

    assert %{
             "approval" => %{"verdict" => "approved", "by" => "manager"},
             "policy" => %{"verdict" => "deny", "reason" => "Refund authority was revoked."},
             "is_error" => true
           } = tool_call(run.id, "tu_1")

    assert [
             %{epoch: 1, payload: %{"verdict" => "require_approval"}},
             %{epoch: 2, payload: %{"verdict" => "deny"}}
           ] =
             run.id |> Runs.trace() |> Enum.filter(&(&1.kind == :policy))
  end

  test "{:deny, reason} settles the call as an error the model reads" do
    {:ok, run} = Runs.start(Cashier, "Refund o-1", actor: {"user", "intern"})
    expect_turn(tool_events("tu_1", "refund", refund("o-1", 500)))
    expect_turn_reading("Interns may not refund.", text_events("I cannot."))

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "completed"} = Runs.get(run.id)

    assert %{
             "policy" => %{"verdict" => "deny", "reason" => "Interns may not refund."},
             "is_error" => true
           } = tool_call(run.id, "tu_1")
  end

  test "a host whose authorize_tool raises denies the call, and the log says why" do
    {:ok, run} = Runs.start(Cashier, "Refund it", actor: {"user", "ada"})
    expect_turn(tool_events("tu_1", "refund", refund("raise", 500)))
    expect_turn_reading("the tool's policy check failed", text_events("The check failed."))

    log =
      capture_log(fn ->
        assert :ok = perform_job(Worker, %{"run_id" => run.id})
      end)

    assert log =~ "raised RuntimeError"
    assert %AgentRun{status: "completed"} = Runs.get(run.id)

    assert %{"policy" => %{"verdict" => "deny", "failed" => true}, "is_error" => true} =
             tool_call(run.id, "tu_1")
  end

  test "a host whose authorize_tool has no clause for the call denies it, and the log holds " <>
         "none of the run's data" do
    ssn = "123-45-6789"

    {:ok, run} =
      Runs.start(Cashier, "Refund the order of SSN #{ssn}",
        actor: {"user", "ada"},
        metadata: %{"ssn" => ssn}
      )

    expect_turn(tool_events("tu_1", "refund", refund("clause", 500)))
    expect_turn_reading("the tool's policy check failed", text_events("The check failed."))

    log =
      capture_log(fn ->
        assert :ok = perform_job(Worker, %{"run_id" => run.id})
      end)

    # The FunctionClauseError's top frame held the whole run.
    assert log =~ "raised FunctionClauseError"
    refute log =~ ssn
    assert %AgentRun{status: "completed"} = Runs.get(run.id)
  end

  test "a run a delegate call started is asked about with its own run, which carries the " <>
         "parent's subject and actor" do
    {:ok, parent} =
      Runs.start(Manager, "Get o-1 refunded", subject: {"ticket", "t-1"}, actor: {"user", "ada"})

    parent_id = parent.id

    expect_turn(
      tool_events("tu_1", "delegate", %{"agent" => "test_cashier", "prompt" => "Refund o-1."})
    )

    assert :ok = perform_job(Worker, %{"run_id" => parent.id})
    assert %AgentRun{status: "waiting"} = Runs.get(parent.id)
    # The parent's delegate call asked nothing.
    refute_received {:authorize_tool, _run, _request, _term}

    assert [%AgentRun{id: child_id, parent_id: ^parent_id}] = Runs.list(agent: Cashier)

    expect_turn(tool_events("tu_c1", "refund", refund("o-1", 500)))
    expect_turn(text_events("Refunded o-1."))
    assert :ok = perform_job(Worker, %{"run_id" => child_id})

    assert_received {:authorize_tool,
                     %AgentRun{
                       id: ^child_id,
                       parent_id: ^parent_id,
                       subject: %{ticket: "t-1"},
                       actor: %{user: "ada"}
                     }, %ApprovalRequest{tool_name: "refund"}, :refund}

    expect_turn_reading("Refunded o-1.", text_events("Done."))
    assert :ok = perform_job(Worker, %{"run_id" => parent.id})
    assert %AgentRun{status: "completed"} = Runs.get(parent.id)
  end

  @tag host: Clementine.RunsCase.Host
  test "a host without authorize_tool gates a {:policy, _} tool like :required" do
    {:ok, run} = Runs.start(Cashier, "Refund o-1", actor: {"user", "ada"})
    expect_turn(tool_events("tu_1", "refund", refund("o-1", 500)))

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "waiting"} = Runs.get(run.id)

    pending = stored_checkpoint(run.id)["pending"]
    assert %{"tool_name" => "refund"} = pending
    refute Map.has_key?(pending, "policy")

    assert :ok = Runs.resume(run.id, {:approved, %{by: "alice"}})
    expect_turn_reading("Refunded 500 on o-1.", text_events("Refunded."))
    assert :ok = perform_job(Worker, %{"run_id" => run.id})

    assert %AgentRun{status: "completed"} = Runs.get(run.id)

    assert %{"policy" => nil, "approval" => %{"verdict" => "approved"}} =
             tool_call(run.id, "tu_1")
  end
end
