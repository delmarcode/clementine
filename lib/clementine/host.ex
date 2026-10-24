defmodule Clementine.Host do
  @moduledoc """
  The host's say in the durable runtime: one optional module, named in the
  child spec, with up to three callbacks. Every callback is optional;
  leave out the ones the app has no opinion on.

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

        alias Clementine.Result

        @impl true
        def authorize_resume(run, {_decision, %{by: user_id}}) do
          if MyApp.Tickets.may_approve?(user_id, run.subject_id),
            do: :ok,
            else: {:error, :forbidden}
        end

        def authorize_resume(_run, _decision), do: {:error, :forbidden}

        @impl true
        def run_finished(run, %Result.Completed{output: output}) do
          MyApp.Tickets.record_triage!(run.subject_id, output)
        end

        def run_finished(_run, _result), do: :ok

        @impl true
        def resolve_subject("ticket", id) do
          case MyApp.Tickets.get(id) do
            nil -> {:error, :ticket_not_found}
            ticket -> {:ok, ticket}
          end
        end
      end

  Nothing else about the runtime is configurable.
  """

  alias Clementine.Runs.AgentRun

  @typedoc "A decision on a waiting run, as `Clementine.Runs.resume/2` takes it."
  @type decision :: {:approved, map()} | {:denied, map()}

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

  @doc """
  What happens when a run finishes: completed, failed, cancelled, or
  interrupted, as the `Clementine.Result` variant says.

  It runs inside the transaction that writes the terminal status, after
  the runtime stored a completed run's output in `result`, so the app's
  writes commit with the status or not at all. Raising aborts that write
  (the runner retries, and the reaper finishes the story), so keep work
  that reaches outside the database out of it: insert an Oban job here
  instead, and it commits with the run.
  """
  @callback run_finished(AgentRun.t(), Clementine.Result.t()) :: any()

  @doc """
  Turns a run's stored subject (`{type, id}` as `Clementine.Runs.start/3`
  took it, as strings) into the value the agent works on. It runs at
  every claim, before the agent is built; the value reaches
  `c:Clementine.Agent.agent/1` as `run.subject` and every tool as
  `context.subject`.

  `{:error, reason}` cancels the run as unstartable with the reason: a run
  about a ticket that no longer exists never starts. Without this
  callback, `subject` is `nil` and agents read `subject_type` and
  `subject_id` themselves.
  """
  @callback resolve_subject(type :: String.t(), id :: String.t() | nil) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks authorize_resume: 2, run_finished: 2, resolve_subject: 2
end
