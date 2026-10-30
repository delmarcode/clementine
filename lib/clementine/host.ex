defmodule Clementine.Host do
  @moduledoc """
  The host's say in the durable runtime: one optional module, named in the
  child spec, with up to eight callbacks. Every callback is optional;
  leave out the ones the app has no opinion on.

  | Callback | Runs | Use it for |
  | --- | --- | --- |
  | `c:authorize_resume/2` | in `Clementine.Runs.resume/2`, on the locked run | who may approve or deny a waiting run |
  | `c:authorize_tool/3` | before each call to a tool declared `approval: {:policy, term}` | whether this call runs, waits for approval, or is refused |
  | `c:resolve_subject/2` | at every claim | turning the stored `{type, id}` into what the agent works on |
  | `c:resolve_actor/2` | at every claim | turning the stored `{type, id}` into whose authority the run acts with, or refusing it |
  | `c:run_event/2` | while a run executes, in a process of its own | streaming tokens and tool activity to a UI |
  | `c:run_transition/2` | after each change short of the end commits | status broadcasts: running, waiting, queued again |
  | `c:run_finished/2` | inside the transaction that ends a run | database writes that must commit with the run's end, including the Oban job for mail or anything else that must happen |
  | `c:run_committed/2` | after that transaction commits | broadcasts of the end and other notifications that may be lost |

  Only `c:run_finished/2` runs inside a transaction. Every other
  notification comes after its commit, never for a write that rolled
  back, and may be lost. A run's life reaches the host in order: its
  claim, its events, then the change that ends the execution (a
  suspension, a requeue, or the end), each event before the change that
  follows it.

  To choose between the two finish hooks, ask whether losing the work
  matters. If it does, write it in `run_finished/2` (as an Oban job when
  it leaves the database), and it commits with the run. If it doesn't,
  send it from `run_committed/2`. Keep every callback fast. Coding
  agents: the rules are in [`usage-rules.md`](usage-rules.md).

      children = [
        MyApp.Repo,
        {Oban, Application.fetch_env!(:my_app, Oban)},
        {Clementine,
         repo: MyApp.Repo,
         oban: Oban,
         queue: :agents,
         agents: [MyApp.Agents.Triage],
         host: MyApp.Agents.Host}
      ]

      defmodule MyApp.Agents.Host do
        @behaviour Clementine.Host

        alias Clementine.{Event, Result}

        @impl true
        def authorize_resume(run, {_decision, %{by: user_id}}) do
          if MyApp.Tickets.may_approve?(user_id, run.subject_id),
            do: :ok,
            else: {:error, :forbidden}
        end

        def authorize_resume(_run, _decision), do: {:error, :forbidden}

        @impl true
        def authorize_tool(run, %Clementine.ApprovalRequest{args: args}, :refund) do
          cond do
            not MyApp.Accounts.may_refund?(run.actor) -> {:deny, "You may not issue refunds."}
            args["amount_cents"] > 50_00 -> :require_approval
            true -> :allow
          end
        end

        @impl true
        def run_event(run, %Event{type: :text_delta, payload: %{content: text}}) do
          broadcast(run, {:run_text, run.id, text})
        end

        def run_event(_run, _event), do: :ok

        @impl true
        def run_transition(run, transition) do
          broadcast(run, {:run_status, run.id, transition})
        end

        @impl true
        def run_finished(run, %Result.Completed{output: output}) do
          MyApp.Tickets.record_triage!(run.subject_id, output)
          Oban.insert!(MyApp.Workers.TriageMail.new(%{"ticket_id" => run.subject_id}))
        end

        def run_finished(_run, _result), do: :ok

        @impl true
        def run_committed(run, _result) do
          broadcast(run, {:run_ended, run.id})
        end

        @impl true
        def resolve_subject("ticket", id) do
          case MyApp.Tickets.get(id) do
            nil -> {:error, :ticket_not_found}
            ticket -> {:ok, ticket}
          end
        end

        def resolve_subject(_type, _id), do: {:ok, nil}

        @impl true
        def resolve_actor("user", id) do
          case MyApp.Accounts.get_user(id) do
            %{suspended_at: nil} = user -> {:ok, user}
            nil -> {:error, :user_not_found}
            _suspended -> {:error, :user_suspended}
          end
        end

        def resolve_actor(_type, _id), do: {:ok, nil}

        defp broadcast(run, message) do
          Phoenix.PubSub.broadcast(MyApp.PubSub, "ticket:" <> run.subject_id, message)
        end
      end

  Nothing else about the runtime is configurable.
  """

  alias Clementine.Runs.AgentRun

  @typedoc "A decision on a waiting run, as `Clementine.Runs.resume/2` takes it."
  @type decision :: {:approved, map()} | {:denied, map()}

  @typedoc """
  A change short of a run's end, as `c:run_transition/2` hears it:

    * `:claimed` — a worker took the run; it is `running`.
    * `:suspended` — it parked for approval; it is `waiting`.
    * `:resumed` — a decision put it back in the queue; it is `queued`.
    * `:requeued` — a drain at shutdown (or the reaper) put it back in
      the queue before it touched the world; it is `queued`.
    * `:cancel_requested` — `Clementine.Runs.cancel/1` flagged it; it is
      still `running`, and the runner, told at once, stops it
      mid-response. Its end follows, usually `cancelled`.
  """
  @type transition :: :claimed | :suspended | :resumed | :requeued | :cancel_requested

  @doc """
  Who may approve or deny a waiting run. `Clementine.Runs.resume/2` calls
  it with the locked run and the decision, after checking that the run is
  waiting and before resuming it; `{:error, reason}` refuses the resume
  and comes back from `resume/2` as is.

  Put whatever identifies the decider in the decision's map, which is
  stored with the resume (an id keeps it small). Without this callback
  every resume is allowed: the resume token authenticates nothing, so an
  app that leaves it out must check before calling `resume/2`.
  """
  @callback authorize_resume(AgentRun.t(), decision()) :: :ok | {:error, term()}

  @typedoc "The tool policy's answer for one call, as `c:authorize_tool/3` gives it."
  @type tool_verdict :: :allow | :require_approval | {:deny, reason :: String.t()}

  @doc """
  The tool policy: whether one call to a tool declared
  `approval: {:policy, term}` runs. The engine asks it before the call's
  batch runs anything, with the run as `c:Clementine.Agent.agent/1` saw it
  (`run.subject` and `run.actor` resolved), the call as a
  `Clementine.ApprovalRequest` (its tool's name and exactly the arguments
  that would run), and the tool's `term`. It answers:

    * `:allow` — the call runs with its batch.
    * `:require_approval` — the call waits for a decision, as if its tool
      said `approval: :required`: the run parks, and
      `Clementine.Runs.resume/2` settles it.
    * `{:deny, reason}` — the call runs nothing and settles as an error
      result whose text is `reason`, a string the model reads and can
      answer.

  It fails closed. A raise, an exit, a throw, or any other answer denies
  the call, logs why, and gives the model only "Denied: the tool's policy
  check failed.". The trace's `:tool_call` entry records the verdict
  beside the approval (`Clementine.Trace`).

  It runs in the run's process at every call, so keep it fast and free of
  writes. It covers every tool the run offers: the agent's own, deferred
  ones, and those a loaded skill brought. A run a `delegate` call started
  is asked about with its own run, which carries the parent's subject and
  actor. Engine tools (`use_skill`, `delegate`) carry no approval: which
  skills and delegates a run is offered is `agent/1`'s decision. A call
  that was still waiting when its batch parked is asked about again when
  the run resumes; a call a decision settled is not.

  Without this callback a `{:policy, term}` tool gates every call like
  `:required`.
  """
  @callback authorize_tool(AgentRun.t(), Clementine.ApprovalRequest.t(), term :: term()) ::
              tool_verdict()

  @doc """
  Database writes that must commit with a run's end: completed, failed,
  cancelled, or interrupted, as the `Clementine.Result` variant says.

  It runs inside the transaction that writes the terminal status, after
  the runtime stored a completed run's output in `result`, so the app's
  writes commit with the status or not at all. Raising aborts that write;
  the runner retries it, and the reaper finishes the story. Keep anything
  that leaves the database out of it, because a rollback cannot take back
  an email or an HTTP call: insert an Oban job here instead, and it
  commits with the run. Notifications that may be lost belong in
  `c:run_committed/2`.
  """
  @callback run_finished(AgentRun.t(), Clementine.Result.t()) :: any()

  @doc """
  Notifications about a run's end, after the transaction that wrote it
  commits: a PubSub broadcast, a LiveView refresh, telemetry. It gets the
  same run and result as `c:run_finished/2`, once per committed end, and
  never for an end that rolled back.

  It runs in whichever process wrote the end (the run's worker, the
  reaper's sweep, or the caller of `Clementine.Runs.cancel/1`), so keep it
  fast. It is best-effort: a raise is logged and the end stands, and a
  node that dies between the commit and the call never makes it. Work
  that must happen belongs in `c:run_finished/2`, as an Oban job when it
  leaves the database.
  """
  @callback run_committed(AgentRun.t(), Clementine.Result.t()) :: any()

  @doc """
  One execution event of a running run: a `Clementine.Event` whose `type`
  is `:iteration_start`, `:text_delta`, `:tool_use_start`,
  `:tool_input_delta`, `:tool_result`, `:approval_requested`,
  `:usage_delta`, or `:error`, with its `payload`. Use it to stream a run
  to a UI, typically with a PubSub broadcast.

  It runs in a process of its own, never inside a transaction, and gets
  a run's events in order, every one before the transition that follows
  it. The run does not wait for each call, but it waits once the
  callback is 64 events behind, and if the callback then takes more than
  five seconds, the host hears no more of that execution's events while
  the run goes on. A raise is logged and the next event still arrives.

  Events are advisory and may be lost: what a UI shows from them must
  also follow from the run's end (`c:run_committed/2`). `run` is the run
  as its claim committed it (`run.status` is `"running"`, and
  `run.lease_epoch` the execution's epoch), and `run.subject` and
  `run.actor` are `nil` here.
  """
  @callback run_event(AgentRun.t(), Clementine.Event.t()) :: any()

  @doc """
  A change to a run short of its end, after the transaction that wrote it
  commits: claimed, suspended, resumed, requeued, or flagged for
  cancellation (see `t:transition/0`). `run` is the run as the change
  committed it: its `status`, `lease_epoch`, `executor_id`, `cancel`,
  and every other column the runtime writes. The end reaches
  `c:run_finished/2` and `c:run_committed/2` instead, never this
  callback.

  Like `c:run_committed/2`, it runs in whichever process wrote the change
  (the run's worker, the caller of `Clementine.Runs.resume/2` or
  `Clementine.Runs.cancel/1`, or the reaper's sweep), once per committed
  change and never for one that rolled back. It is best-effort: a raise
  is logged, and a node that dies between the commit and the call never
  makes it. Nothing commits with these changes: a write that must happen
  belongs in `c:run_finished/2`.
  """
  @callback run_transition(AgentRun.t(), transition()) :: any()

  @doc """
  Turns a run's stored subject (`{type, id}` as `Clementine.Runs.start/3`
  took it, as strings) into the value the agent works on. It runs at
  every claim, before the agent is built; the value reaches
  `c:Clementine.Agent.agent/1` and `c:Clementine.Agent.history/1` as
  `run.subject` and every tool as `context.subject`.

  `{:error, reason}` cancels the run as unstartable with the reason: a run
  about a ticket that no longer exists never starts. Without this
  callback, `subject` is `nil` and agents read `subject_type` and
  `subject_id` themselves.
  """
  @callback resolve_subject(type :: String.t(), id :: String.t() | nil) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Turns a run's stored actor (`{type, id}` as `Clementine.Runs.start/3`
  took it, as strings), whose authority the run acts with, into the value
  the agent and its tools act as. The same contract as
  `c:resolve_subject/2`: it runs at every claim, the one after a resume
  included, before the agent is built, and the value reaches
  `c:Clementine.Agent.agent/1` and `c:Clementine.Agent.history/1` as
  `run.actor` and every tool as `context.actor`.

  `{:error, reason}` refuses the actor and cancels the run as unstartable
  with the reason: a run acting for an account suspended since it was
  started, or parked for approval, never starts or resumes. A run with no
  actor type (the system's) never reaches this callback; without it,
  `actor` is `nil` and agents read `actor_type` and `actor_id` themselves. A check
  that binds the two, such as the thread belonging to the actor, is a
  comparison of `run.subject` and `run.actor` in `agent/1` or a tool.
  """
  @callback resolve_actor(type :: String.t(), id :: String.t() | nil) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks authorize_resume: 2,
                      authorize_tool: 3,
                      run_event: 2,
                      run_transition: 2,
                      run_finished: 2,
                      run_committed: 2,
                      resolve_subject: 2,
                      resolve_actor: 2
end
