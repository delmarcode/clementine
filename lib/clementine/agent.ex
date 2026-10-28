defmodule Clementine.Agent do
  @moduledoc """
  A reusable capability definition: model, instructions, tools, defaults,
  and policy.

  An agent is inert data — not a process, and it does not execute by itself.
  A `Clementine.Rollout` pairs an agent with input to describe one attempt;
  a runner animates it. Agents are runtime-constructed values, not
  compile-time modules: multi-tenant hosts resolve model, tools, and
  instructions at execution time and build agents with `new/1`.

  ## Agents the durable runtime runs

  `Clementine.Runs` runs agents defined as modules: `use Clementine.Agent`
  with a stable `key`, the string run rows store, and either the agent's
  fields:

      defmodule MyApp.Agents.Weather do
        use Clementine.Agent,
          key: "weather",
          model: :claude_sonnet,
          instructions: "Answer questions about the weather.",
          tools: [MyApp.Agents.Weather.Tools.Forecast],
          defaults: [max_iterations: 10, max_duration: :timer.minutes(5)]
      end

  or, when the agent depends on the run, an `c:agent/1` of your own, which
  the runtime calls at every claim:

      defmodule MyApp.Agents.Triage do
        use Clementine.Agent, key: "triage"

        @impl true
        def agent(run) do
          Clementine.Agent.new(
            model: :claude_sonnet,
            instructions: MyApp.Triage.instructions(run.subject),
            tools: [MyApp.Agents.Triage.Tools.Assess]
          )
        end
      end

  The fields given to `use` build the agent at compile time, so a typo in
  them fails the build. List the module in the child spec's `agents:`.

  ## Turns and tasks

  A run is a **turn** or a **task**. A turn is a run on a thread: its
  subject is the thread (a conversation, say), it reads the thread as its
  history, and the host appends what it said in
  `c:Clementine.Host.run_finished/2`. A task is any other run. The agent
  declares which its runs are with `turn: true`, and `Clementine.Runs.start/3`
  copies that to the row, so queries and the database see it and a later
  change to the agent never relabels its history.

  A turn agent must write `c:history/1`, the thread's messages before the
  run's prompt, read from the app's own tables; leaving it out fails the
  build. A task agent may write one too (a one-shot summarizer wanting the
  transcript as history rather than through a tool); it defaults to `[]`.

      defmodule MyApp.Agents.Chat do
        use Clementine.Agent,
          key: "chat",
          turn: true,
          model: :claude_sonnet,
          instructions: "You are a helpful assistant."

        @impl true
        def history(run), do: MyApp.Chat.messages(run.subject_id)
      end

  Which a run is decides its **lane**, the key under which active runs are
  exclusive. A turn's lane is its thread, whichever agent it belongs to:
  one active turn per thread, so a second agent's turn on a thread in use
  is refused too. A task's lane is its agent and subject: a chat turn and
  a triage task on one conversation run side by side. A turn needs a
  subject (`{:error, :subject_required}` without one); a task without one
  has no lane and blocks nothing.

  `c:agent/1` and `c:history/1` see `run.subject` and `run.actor` resolved
  (`c:Clementine.Host.resolve_subject/2` and
  `c:Clementine.Host.resolve_actor/2`).

  Note: this module shadows Elixir's built-in `Agent` under a bare `alias`;
  prefer `alias Clementine.Agent, as: AgentDef` where the collision bites.
  The in-memory agent *process* lives at `Clementine.AgentServer`.
  """

  @enforce_keys [:model]
  defstruct id: nil,
            model: nil,
            instructions: nil,
            tools: [],
            defaults: [],
            policy: %{}

  @type t :: %__MODULE__{
          id: term(),
          model: Clementine.LLM.ModelRegistry.model_ref(),
          instructions: String.t() | nil,
          tools: [module()],
          defaults: keyword(),
          policy: map()
        }

  @doc """
  The key run rows carry in their `agent_key` column. Keep it stable once runs
  exist: a run whose key no longer resolves is cancelled as unstartable.
  """
  @callback key() :: String.t()

  @doc """
  Whether this agent's runs are turns on a thread (`turn: true` on `use`).
  `Clementine.Runs.start/3` copies it to the row's `turn` column.
  """
  @callback turn() :: boolean()

  @doc """
  The agent for one execution of `run`: model, instructions, tools, and
  limits. Called at every claim, so it may read whatever the run needs;
  `run.subject` and `run.actor` hold what the host resolved
  (`c:Clementine.Host.resolve_subject/2`, `c:Clementine.Host.resolve_actor/2`).
  `use Clementine.Agent` with the agent's fields defines it.
  """
  @callback agent(run :: Clementine.Runs.AgentRun.t()) :: t()

  @doc """
  The conversation before `run`'s prompt, oldest first, as
  `Clementine.LLM.Message` structs: `UserMessage`, `AssistantMessage`, and
  `ToolResultMessage`. The model sees them, then the prompt. Leave the
  prompt itself out.

  The messages are the app's data: store what a run said in
  `c:Clementine.Host.run_finished/2` (`Result.Completed` carries the
  prompt as `input_message` and the run's own turns as `messages`;
  `Clementine.LLM.Message.to_map/1` and `from_map/1` round-trip them
  through a `jsonb` column), and read them back here. Where the cutoff
  falls (messages that arrived after the prompt, say) is the app's rule.

  It is called when a run starts from its prompt, after the subject and
  actor resolve, so `run.subject` and `run.actor` are set. A run that
  resumes after an approval continues from its checkpoint, which already
  holds the conversation, so it is not called again. Anything but a list
  of messages cancels the run as unstartable. A turn agent (`turn: true`)
  must define it; for any other `use Clementine.Agent` defines it to
  return `[]`.
  """
  @callback history(run :: Clementine.Runs.AgentRun.t()) :: [Clementine.LLM.Message.message()]

  @doc """
  Releases what one execution of `run` held, after it ends however it
  ends: a sandbox, a session with a tool server, a temporary directory.
  `context` is the map the run's tools saw (`run_id`, `agent_key`,
  `turn`, `subject`, `actor`, `parent_id`, `tag`, `metadata`); an
  `c:agent/1` that
  opens a resource keeps its handle somewhere the tools and this callback
  both reach, such as the process dictionary, or reads it back from
  `run.id`.

  It runs in the worker's process once `Clementine.Runner` has returned,
  whether the execution finished, parked, was requeued, or crashed, and
  its return value is ignored. A raise is logged and the execution's
  outcome stands. Optional; most agents hold nothing.
  """
  @callback after_execution(run :: Clementine.Runs.AgentRun.t(), context :: map()) :: any()

  @optional_callbacks history: 1, after_execution: 2

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Clementine.Agent
      @before_compile Clementine.Agent

      {key, fields} = Keyword.pop(opts, :key)
      {turn, fields} = Keyword.pop(fields, :turn, false)

      unless is_binary(key) and key != "" do
        raise ArgumentError,
              "use Clementine.Agent needs a non-empty string key:, got: #{inspect(key)}"
      end

      unless is_boolean(turn) do
        raise ArgumentError,
              "use Clementine.Agent takes turn: true or false, got: #{inspect(turn)}"
      end

      @clementine_agent_key key
      @clementine_agent_turn turn

      @impl Clementine.Agent
      def key, do: @clementine_agent_key

      @impl Clementine.Agent
      def turn, do: @clementine_agent_turn

      # A turn reads its thread as history, so a turn agent writes
      # history/1 itself (__before_compile__ checks); a task defaults to
      # none.
      unless turn do
        @impl Clementine.Agent
        def history(_run), do: []

        defoverridable history: 1
      end

      if fields != [] do
        @clementine_agent Clementine.Agent.new([id: key] ++ fields)

        @impl Clementine.Agent
        def agent(_run), do: @clementine_agent

        defoverridable agent: 1
      end
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    if Module.get_attribute(env.module, :clementine_agent_turn) and
         not Module.defines?(env.module, {:history, 1}) do
      raise ArgumentError,
            "#{inspect(env.module)} is a turn agent (turn: true) and must define history/1, " <>
              "the thread's messages before the run's prompt. An agent with no history to " <>
              "read is a task: leave turn: out"
    end
  end

  @doc """
  Builds an agent definition.

  ## Options

  - `:model` (required) - model alias atom or `{provider, id}` tuple
  - `:id` - host-app identifier, kept for audit trails
  - `:instructions` - system prompt
  - `:tools` - tool modules
  - `:defaults` - default rollout limits (`max_iterations:`, `max_duration:`)
  - `:policy` - host-app policy/config passthrough (opaque to Clementine)
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)
end
