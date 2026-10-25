defmodule Clementine.RunsCase do
  @moduledoc """
  The case for tests of the durable runtime (`Clementine.Runs`), set up the
  way a host runs it: Oban in `:manual` testing mode, then
  `{Clementine, ...}` with the test agents and `Clementine.RunsCase.Host`,
  on a shared SQL sandbox (runs execute in more than one process:
  heartbeats, tools, racing sweeps). Model turns are scripted on
  `Clementine.LLM.MockClient` in global mode.
  """

  use ExUnit.CaseTemplate

  import Ecto.Query, only: [from: 2]

  alias Clementine.Runs.AgentRun
  alias Clementine.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @moduletag :postgres

      use Oban.Testing, repo: Clementine.TestRepo

      import Mox
      import Clementine.RunsCase

      alias Clementine.Runs
      alias Clementine.Runs.{AgentRun, Worker}
      alias Clementine.RunsCase.{Approval, Chat, Echo, Lookup}
      alias Clementine.TestRepo

      setup :set_mox_global
      setup :verify_on_exit!
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    start_supervised!({Oban, repo: TestRepo, testing: :manual})

    unless tags[:runtime] == false do
      start_supervised!(
        {Clementine,
         repo: TestRepo,
         agents: [__MODULE__.Echo, __MODULE__.Lookup, __MODULE__.Approval, __MODULE__.Chat],
         host: __MODULE__.Host}
      )
    end

    :ok
  end

  @doc "Scripts the model's next turn: the provider events it streams back."
  def expect_turn(events) when is_list(events) do
    Mox.expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
      events
    end)
  end

  @doc "A model turn that answers with `text` and ends the run."
  def text_events(text) do
    [
      {:text_delta, text},
      {:message_delta, %{"stop_reason" => "end_turn"},
       %{"input_tokens" => 10, "output_tokens" => 5}}
    ]
  end

  @doc "A model turn that calls the tool named `name` with `input`."
  def tool_events(id, name, input) do
    [
      {:tool_use_start, id, name},
      {:input_json_delta, id, Jason.encode!(input)},
      {:content_block_stop, 0},
      {:message_delta, %{"stop_reason" => "tool_use"},
       %{"input_tokens" => 10, "output_tokens" => 5}}
    ]
  end

  @doc """
  Moves a run's `queued_at`, and its job's `attempted_at` and state when
  `job_state:` is given, back by `minutes`: how a test ages a run past
  the reaper's thresholds.
  """
  def backdate!(%AgentRun{} = run, minutes, opts \\ []) do
    then = DateTime.add(DateTime.utc_now(), -minutes, :minute)

    {1, _} =
      TestRepo.update_all(from(r in AgentRun, where: r.id == ^run.id), set: [queued_at: then])

    if job_state = opts[:job_state] do
      {1, _} =
        TestRepo.update_all(from(j in Oban.Job, where: j.id == ^run.oban_job_id),
          set: [state: job_state, attempted_at: then]
        )
    end

    :ok
  end

  @doc "Inserts a queued run directly, with no Oban job."
  def insert_queued_run!(attrs \\ %{}) do
    attrs
    |> Map.new()
    |> Map.put_new(:agent_key, "test_echo")
    |> Map.put_new(:input, %{"prompt" => "Hello"})
    |> AgentRun.queued_changeset()
    |> TestRepo.insert!()
  end

  @doc """
  The `create_run` function of `Clementine.LifecycleCase`: a queued run in
  a fresh subject, carrying the suite's projection probe in its metadata
  (`Clementine.RunsCase.Host.run_finished/2` honors it) and its kind.
  """
  def create_conformance_run(attrs) do
    run =
      insert_queued_run!(%{
        subject_type: "conformance",
        subject_id: Integer.to_string(System.unique_integer([:positive])),
        metadata: probe(Keyword.get(attrs, :projection))
      })

    case Keyword.get(attrs, :kind, :rollout) do
      :rollout ->
        :ok

      kind ->
        {1, _} =
          TestRepo.update_all(from(r in AgentRun, where: r.id == ^run.id),
            set: [kind: Atom.to_string(kind)]
          )
    end

    run.id
  end

  defp probe(nil), do: %{}
  defp probe(:raise), do: %{"conformance_probe" => "raise"}
  defp probe({:raise_on, variant}), do: %{"conformance_probe" => Atom.to_string(variant)}

  @doc "The storage clock."
  def db_now! do
    %{rows: [[now]]} = TestRepo.query!("SELECT now()")
    now
  end
end

defmodule Clementine.RunsCase.Host do
  @moduledoc """
  The test host. It refuses resumes decided `by: "mallory"`, and resolves
  `"ticket"` subjects (a `"gone"` subject never resolves).

  `run_finished/2` writes a row to its own table (`host_writes/1` reads
  them) and then raises for the conformance suite's projection probe;
  `run_committed/2` raises when the run's metadata says
  `"committed_probe" => "raise"`, and `run_transition/2` when it says
  `"transition_probe" => "raise"`. `run_event/2` raises on the run's
  events when it says `"event_probe" => "raise"`, and on its first event
  waits for `{:release, run_id}` when it says `"event_probe" => "hold"`.
  They report to a process registered as `:clementine_runs_test`, with
  whether they ran inside a transaction.
  """

  @behaviour Clementine.Host

  import Ecto.Query, only: [from: 2]

  alias Clementine.Result
  alias Clementine.TestRepo

  @impl true
  def authorize_resume(_run, {_verdict, %{by: "mallory"}}), do: {:error, :forbidden}
  def authorize_resume(_run, _decision), do: :ok

  @impl true
  def run_finished(run, result) do
    {1, _} =
      TestRepo.insert_all("clementine_test_uuid_jobs", [
        %{run_ref: Ecto.UUID.dump!(run.id), kind: "run_finished"}
      ])

    :ok = probe(result, run.metadata)
    report({:run_finished, run, result})
  end

  @impl true
  def run_committed(run, result) do
    if run.metadata["committed_probe"] == "raise", do: raise("committed probe")
    report({:run_committed, run, result, TestRepo.in_transaction?()})
  end

  @impl true
  def run_transition(run, transition) do
    if run.metadata["transition_probe"] == "raise", do: raise("transition probe")
    report({:run_transition, run, transition, TestRepo.in_transaction?()})
  end

  @impl true
  def run_event(run, event) do
    case {run.metadata["event_probe"], event.seq} do
      {"raise", _seq} ->
        raise "event probe"

      {"hold", 1} ->
        report({:run_event_held, run.id, self()})

        receive do
          {:release, run_id} when run_id == run.id -> :ok
        end

      _other ->
        :ok
    end

    report({:run_event, run, event, TestRepo.in_transaction?(), self()})
  end

  @doc "The kinds of the rows `run_finished/2` wrote for `run_id`, oldest first."
  def host_writes(run_id) do
    TestRepo.all(
      from(j in "clementine_test_uuid_jobs",
        where: j.run_ref == type(^run_id, Ecto.UUID),
        order_by: j.id,
        select: j.kind
      )
    )
  end

  defp report(message) do
    if pid = Process.whereis(:clementine_runs_test), do: send(pid, message)
    :ok
  end

  @impl true
  def resolve_subject("ticket", id), do: {:ok, %{ticket: id}}
  def resolve_subject("gone", _id), do: {:error, :subject_gone}
  def resolve_subject(_type, _id), do: {:ok, nil}

  defp probe(result, %{"conformance_probe" => probe}) do
    case {probe, result} do
      {"raise", _result} -> raise "conformance probe"
      {"completed", %Result.Completed{}} -> raise "conformance probe: completed"
      {"failed", %Result.Failed{}} -> raise "conformance probe: failed"
      {"cancelled", %Result.Cancelled{}} -> raise "conformance probe: cancelled"
      {"interrupted", %Result.Interrupted{}} -> raise "conformance probe: interrupted"
      _other -> :ok
    end
  end

  defp probe(_result, _metadata), do: :ok
end

defmodule Clementine.RunsCase.Echo do
  @moduledoc "A test agent with no tools: one model turn answers."
  use Clementine.Agent, key: "test_echo", model: :claude_sonnet, instructions: "Answer."
end

defmodule Clementine.RunsCase.Lookup do
  @moduledoc """
  A test agent whose one tool is safe to repeat, so its runs can be
  requeued. It writes its own agent/1, which sees the resolved subject.
  """
  use Clementine.Agent, key: "test_lookup"

  defmodule Tool do
    @moduledoc false
    use Clementine.Tool,
      name: "lookup",
      description: "Looks something up.",
      retry: :safe,
      parameters: [query: [type: :string, required: true]]

    @impl true
    def run(%{query: query}, context) do
      {:ok, "Found #{query} about #{inspect(context[:subject])}."}
    end
  end

  @impl true
  def agent(run) do
    Clementine.Agent.new(
      model: :claude_sonnet,
      instructions: "Look up #{inspect(run.subject)}.",
      tools: [Tool]
    )
  end
end

defmodule Clementine.RunsCase.Approval do
  @moduledoc "A test agent whose one tool needs a human's approval."

  defmodule SendNote do
    @moduledoc false
    use Clementine.Tool,
      name: "send_note",
      description: "Sends a note.",
      approval: :required,
      retry: :unsafe,
      parameters: [text: [type: :string, required: true]]

    @impl true
    def run(%{text: text}, _context), do: {:ok, "Sent #{text}."}
  end

  use Clementine.Agent,
    key: "test_approval",
    model: :claude_sonnet,
    instructions: "Send notes.",
    tools: [SendNote]
end

defmodule Clementine.RunsCase.Chat do
  @moduledoc """
  A test agent that converses. Its history is the run's metadata
  `"history"`, as `Clementine.LLM.Message.to_map/1` maps (anything else is
  returned as is), and every call reports to the test process. Its one
  tool needs approval.
  """

  use Clementine.Agent,
    key: "test_chat",
    model: :claude_sonnet,
    instructions: "Chat.",
    tools: [Clementine.RunsCase.Approval.SendNote]

  alias Clementine.LLM.Message

  @impl true
  def history(run) do
    if pid = Process.whereis(:clementine_runs_test), do: send(pid, {:history, run})

    case Map.get(run.metadata, "history", []) do
      [_ | _] = messages -> Enum.map(messages, &Message.from_map/1)
      other -> other
    end
  end
end
