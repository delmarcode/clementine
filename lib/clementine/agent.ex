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

  ## Deferred tools

  An agent with more tools than a model can choose among well (tens, or
  every tool of several MCP servers) lists the ones it rarely needs as
  `deferred:` rather than `tools:`:

      use Clementine.Agent,
        key: "support",
        model: :claude_sonnet,
        instructions: "Help customers with their orders.",
        tools: [MyApp.Tools.LookupOrder],
        deferred: [MyApp.Tools.IssueRefund, MyApp.Tools.ChangeAddress]

  The model starts out seeing only `tools:` and searches the deferred ones
  by name and description, loading the few it needs (Anthropic's tool
  search). A deferred tool is an ordinary `Clementine.Tool`: once found
  it runs like any other, and `approval:`, `retry:`, and the tool context
  apply unchanged. A provider without tool search gets deferred tools as
  ordinary tools. A tool that leaves the list drops out of the earlier
  searches a thread's history replays, so the thread keeps working; that
  edits the replayed history, which restarts the prompt cache and may
  void earlier thinking on models that verify it.

  ## Structured output

  An agent whose answer code reads (a grader's verdict, a planner's next
  steps, a loop's decision) gives the answer's JSON schema as
  `output_schema:`:

      use Clementine.Agent,
        key: "grader",
        model: :claude_sonnet,
        instructions: "Grade the essay against the rubric.",
        tools: [MyApp.Tools.FetchRubric],
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "verdict" => %{"type" => "string", "enum" => ["pass", "fail"]},
            "reasons" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["verdict", "reasons"],
          "additionalProperties" => false
        }

  A completed run's `Clementine.Result.Completed` `output` is then the
  decoded answer, a map with string keys, rather than text: what
  `c:Clementine.Host.run_finished/2` receives, what `run.result["output"]`
  stores, and what a loop's `{:completed, tag, result}` carries. The run
  still calls its tools as it likes; only the answer that ends it is
  constrained, through the provider's own structured output. An answer
  that does not decode or match fails the run with a `Clementine.Error`
  of code `:invalid_output`. See `Clementine.OutputSchema`.

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

  ## The trace

  Every run records a trace (`Clementine.Runs.trace/1`): the model and
  tools each execution offered, each model call, and each tool call with
  its arguments. `trace:` says how much of the content it keeps.
  `:content`, the default, keeps the system prompt, what the model said,
  and what each tool returned. `:facts` keeps names, arguments, ids,
  timing, usage, and the agent's fingerprint, and none of the text: right
  for a turn agent whose host stores the conversation already.

      use Clementine.Agent, key: "chat", turn: true, trace: :facts, ...

  ## Skills

  An agent may offer skills (`Clementine.Skill`): instructions for one
  kind of task and the tools it needs, which the model loads when a task
  calls for them, rather than carrying every procedure in the system
  prompt and every tool from the start.

      use Clementine.Agent,
        key: "support",
        model: :claude_sonnet,
        instructions: "Help customers with their orders.",
        tools: [MyApp.Tools.Search],
        skills: [MyApp.Skills.Refunds, MyApp.Skills.Shipping]

  `skills:` takes modules that `use Clementine.Skill` and skills built with
  `Clementine.Skill.new/1`, so an `c:agent/1` may offer skills the app
  keeps as rows. With any, the model sees a `use_skill` tool listing each
  skill's name and description; loading one returns its body and adds its
  tools. A run that parks resumes with the skills it had loaded, so an
  `c:agent/1` must offer them again at the resume's claim, as it must its
  tools. Every tool the model can be offered, the agent's own (`tools:`
  and `deferred:`) and each skill's, has a name of its own, and none is
  named `use_skill`. A skill's tools load in full when the skill loads,
  never through tool search, so none of them may also be deferred. `new/1`
  raises otherwise, and a run whose `c:agent/1` sets `skills` without it
  fails as `:invalid_skills` before anything runs.

  ## Delegates

  An agent may ask other agents (`Clementine.Delegation`): the model calls
  a `delegate` tool, each call starts a run of the agent it names on the
  parent's subject, with the parent's actor, and the parent waits, parked,
  until every one has ended. Each call's result is its child's answer.

      use Clementine.Agent,
        key: "planner",
        model: :claude_sonnet,
        instructions: "Plan the work. Ask the researcher for facts.",
        delegates: [MyApp.Agents.Researcher, MyApp.Agents.Writer]

  `delegates:` takes agent modules the child spec lists; the model sees
  their keys as the `agent` enum, each with its `description:` when it
  has one, so give a delegate one that says when to ask it:

      use Clementine.Agent,
        key: "researcher",
        description: "Finds and cites facts. Ask it for anything you would look up.",
        model: :claude_sonnet,
        instructions: "..."

  `description:` goes to `use` in either form, beside `key:`, with the
  agent's fields or with an `c:agent/1` of your own. A delegate runs
  tasks: a turn agent is refused at the call. An `c:agent/1` may offer
  different delegates by subject or actor, and no tool the agent offers
  is named `delegate`. Only `Clementine.Runs` starts a delegate's run, so
  only there is `delegate` offered.

  Note: this module shadows Elixir's built-in `Agent` under a bare `alias`;
  prefer `alias Clementine.Agent, as: AgentDef` where the collision bites.
  The in-memory agent *process* lives at `Clementine.AgentServer`.
  """

  @enforce_keys [:model]
  defstruct id: nil,
            model: nil,
            instructions: nil,
            tools: [],
            deferred: [],
            output_schema: nil,
            skills: [],
            delegates: [],
            defaults: [],
            policy: %{},
            tool_context: %{},
            trace: :content

  @type t :: %__MODULE__{
          id: term(),
          model: Clementine.LLM.ModelRegistry.model_ref(),
          instructions: String.t() | nil,
          tools: [module()],
          deferred: [module()],
          output_schema: Clementine.OutputSchema.t() | nil,
          skills: [Clementine.Skill.t()],
          delegates: [module()],
          defaults: keyword(),
          policy: map(),
          tool_context: map(),
          trace: Clementine.Trace.fidelity()
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
  What the agent does, in a sentence (`description:` on `use`), or `nil`.
  A delegating agent's model reads it beside the agent's key in its
  `delegate` tool (`Clementine.Delegation`), so it says when to ask this
  agent; the agent's own model never sees it.
  """
  @callback description() :: String.t() | nil

  @doc """
  The agent for one execution of `run`: model, instructions, tools, and
  limits. Called at every claim, so it may read whatever the run needs;
  `run.subject` and `run.actor` hold what the host resolved
  (`c:Clementine.Host.resolve_subject/2`, `c:Clementine.Host.resolve_actor/2`).
  `use Clementine.Agent` with the agent's fields defines it.

  `tool_context:` is what this execution's tools see beyond the run: a
  `working_dir` and `capabilities` for the built-in file and shell tools,
  a sandbox or session handle for the agent's own. The runtime merges it
  under its own keys (`run_id`, `agent_key`, `turn`, `subject`, `actor`,
  `metadata`, `parent_id`, `tag`), which always win: an agent adds to
  what its tools see, never changes what the run is. On the durable
  runtime a built-in file or shell tool has no working directory unless
  this sets one, and refuses rather than fall back to the app's own.
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

  @optional_callbacks history: 1, after_execution: 2, description: 0

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Clementine.Agent
      @before_compile Clementine.Agent

      {key, fields} = Keyword.pop(opts, :key)
      {turn, fields} = Keyword.pop(fields, :turn, false)
      {description, fields} = Keyword.pop(fields, :description)

      unless is_binary(key) and key != "" do
        raise ArgumentError,
              "use Clementine.Agent needs a non-empty string key:, got: #{inspect(key)}"
      end

      unless is_boolean(turn) do
        raise ArgumentError,
              "use Clementine.Agent takes turn: true or false, got: #{inspect(turn)}"
      end

      unless is_nil(description) or (is_binary(description) and description != "") do
        raise ArgumentError,
              "use Clementine.Agent takes description: as a non-empty string, got: " <>
                inspect(description)
      end

      @clementine_agent_key key
      @clementine_agent_turn turn
      @clementine_agent_description description

      @impl Clementine.Agent
      def key, do: @clementine_agent_key

      @impl Clementine.Agent
      def turn, do: @clementine_agent_turn

      @impl Clementine.Agent
      def description, do: @clementine_agent_description

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
  - `:deferred` - tool modules the model loads on demand through the
    provider's tool search, rather than seeing up front (see "Deferred
    tools" above); a tool is in `:tools` or `:deferred`, not both
  - `:output_schema` - the JSON schema of the final answer, its root an
    object; with it, a completed run's `output` is the decoded map (see
    "Structured output" above). Atom keys become strings
  - `:skills` - skills the model may load (see "Skills" above): modules
    that `use Clementine.Skill`, or `Clementine.Skill` structs
  - `:delegates` - agents the model may ask (see "Delegates" above):
    modules that `use Clementine.Agent`
  - `:defaults` - default rollout limits (`max_iterations:`, `max_duration:`)
  - `:policy` - host-app policy/config passthrough (opaque to Clementine)
  - `:tool_context` - keys every tool of the execution sees (`working_dir:`,
    `capabilities:`, an app's own handles), under the runtime's keys, which
    win; on the durable runtime, the one place a built-in file tool's
    `working_dir` comes from
  - `:trace` - how much content the run's trace keeps: `:content`
    (default) or `:facts` (`Clementine.Trace`)
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    agent = struct!(__MODULE__, opts)
    Clementine.Trace.validate_fidelity!(agent.trace)

    case Enum.filter(agent.deferred, &(&1 in agent.tools)) do
      [] ->
        agent |> normalize_output_schema() |> put_skills!() |> check_delegates!()

      both ->
        raise ArgumentError,
              "a tool is in tools: or deferred:, not both; found in both: #{inspect(both)}"
    end
  end

  # Delegates are agent modules, kept as given, and checked as far as a
  # build may (Clementine.Delegation.check/2): their keys are read when a
  # run prepares, never here, since `use` builds an agent at compile time,
  # and two agents may name each other.
  defp check_delegates!(%__MODULE__{delegates: []} = agent), do: agent

  defp check_delegates!(%__MODULE__{} = agent) do
    tools = agent.tools ++ agent.deferred ++ Enum.flat_map(agent.skills, & &1.tools)

    case Clementine.Delegation.check(agent.delegates, tools) do
      :ok -> agent
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp normalize_output_schema(%__MODULE__{output_schema: nil} = agent), do: agent

  defp normalize_output_schema(%__MODULE__{output_schema: schema} = agent),
    do: %{agent | output_schema: Clementine.OutputSchema.normalize!(schema)}

  # Skills arrive as modules or structs and are kept as structs, checked
  # against every tool the agent may offer (Clementine.Skill.prepare/2).
  # The rollout checks again, since an agent/1 may set the field directly.
  defp put_skills!(%__MODULE__{skills: []} = agent), do: agent

  defp put_skills!(%__MODULE__{} = agent) do
    case Clementine.Skill.prepare(agent.skills, agent.tools ++ agent.deferred, agent.deferred) do
      {:ok, skills} -> %{agent | skills: skills}
      {:error, message} -> raise ArgumentError, message
    end
  end
end
