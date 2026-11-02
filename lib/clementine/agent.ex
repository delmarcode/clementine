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
          model: "claude-sonnet-5-5",
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
            model: "claude-sonnet-5-5",
            instructions: MyApp.Triage.instructions(run.subject),
            tools: [MyApp.Agents.Triage.Tools.Assess]
          )
        end
      end

  The fields given to `use` build the agent at compile time, so a typo in
  them fails the build. List the module in the child spec's `agents:`.

  ## The model and its policy

  An agent names its model by the vendor's id and makes its own choices
  for it, checked against the model's fact sheet (`Clementine.Model`):

      use Clementine.Agent,
        key: "triage",
        model: "claude-sonnet-5-5",
        effort: :high,
        max_tokens: 16_000,
        cache: [ttl: :one_hour]

  - `max_tokens:` the output ceiling of one response, thinking included;
    default `min(16_000, the model's max_output)`.
  - `effort:` one of the model's effort levels; default the model's own,
    sent explicitly.
  - `thinking:` `:adaptive`, `:enabled`, `:between_tools`, or `:off`;
    default `:adaptive` where the model takes it.
  - `display:` `:omitted`, `:summarized`, or `:updates`, for the
    thinking a Claude model returns; default the model's own (`:omitted`
    from Claude 4.7 on, `:summarized` on 4.5 and 4.6).
  - `cache:` `true` (default, the model's shortest TTL), `false`, or
    `[ttl: ...]`.
  - `provider_options:` what one vendor alone takes (`budget_tokens:` on
    a Claude model before 4.7, OpenAI's `summary:`).

  `Clementine.LLM.Policy` has each in full. A model the sheets and the
  app's config do not know, or a choice its sheet refuses, fails
  `new/1`, boot, and the start of a run, naming what the model takes
  instead and where the choice came from: `use`, `new/1`, or the model
  `c:agent/1` picked for the run.

  `use` with `model:` defines `__model__/0`, so a module whose
  `c:agent/1` builds the agent per run still declares its model where
  the child spec and tools can read it. `use`'s choices are for its
  model: the runtime applies them when `c:agent/1` leaves the model to
  `use` or picks the same one, filling each choice `c:agent/1` leaves
  unset (and `provider_options:` key by key). When `c:agent/1` picks
  another model for a run, an eval's, say, none of `use`'s choices
  apply, and the agent runs on that model's defaults and its own
  choices:

      use Clementine.Agent, key: "triage", model: "claude-sonnet-5-5", effort: :xhigh

      @impl true
      def agent(run) do
        # "claude-opus-5-5" from an eval runs at its own default effort.
        Clementine.Agent.new(
          model: run.metadata["model"] || __model__(),
          instructions: MyApp.Triage.instructions(run.subject)
        )
      end

  `use` builds its agent at compile time, when only compile-time config
  is read, so a model `config/runtime.exs` declares is left to boot to
  check. `new/1` checks what it can before the runtime fills the rest
  (a `thinking: :enabled` whose `budget_tokens` `use` gives passes
  there); the start of every run checks the whole.

  ## Deferred tools

  An agent with more tools than a model can choose among well (tens, or
  every tool of several MCP servers) lists the ones it rarely needs as
  `deferred:` rather than `tools:`:

      use Clementine.Agent,
        key: "support",
        model: "claude-sonnet-5-5",
        instructions: "Help customers with their orders.",
        tools: [MyApp.Tools.LookupOrder],
        deferred: [MyApp.Tools.IssueRefund, MyApp.Tools.ChangeAddress]

  The model starts out seeing only `tools:` and searches the deferred ones
  by name and description, loading the few it needs (Anthropic's tool
  search). A deferred tool is an ordinary `Clementine.Tool`: once found
  it runs like any other, and `approval:`, `retry:`, and the tool context
  apply unchanged. A provider without tool search gets deferred tools as
  ordinary tools. A tool that leaves the list drops out of the earlier
  searches a thread's history replays, so the thread keeps working; the
  changed list restarts the prompt cache and, on a model that binds its
  thinking, costs the earlier turns' thinking once (the runtime guide's
  "Models that bind their thinking").

  ## Structured output

  An agent whose answer code reads (a grader's verdict, a planner's next
  steps, a loop's decision) gives the answer's JSON schema as
  `output_schema:`:

      use Clementine.Agent,
        key: "grader",
        model: "claude-sonnet-5-5",
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
          model: "claude-sonnet-5-5",
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
        model: "claude-sonnet-5-5",
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
        model: "claude-sonnet-5-5",
        instructions: "Plan the work. Ask the researcher for facts.",
        delegates: [MyApp.Agents.Researcher, MyApp.Agents.Writer]

  `delegates:` takes agent modules the child spec lists; the model sees
  their keys as the `agent` enum, each with its `description:` when it
  has one, so give a delegate one that says when to ask it:

      use Clementine.Agent,
        key: "researcher",
        description: "Finds and cites facts. Ask it for anything you would look up.",
        model: "claude-sonnet-5-5",
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

  @policy Clementine.LLM.Policy.keys()

  defstruct id: nil,
            model: nil,
            max_tokens: nil,
            effort: nil,
            thinking: nil,
            display: nil,
            cache: nil,
            provider_options: nil,
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
          model: String.t() | nil,
          max_tokens: pos_integer() | nil,
          effort: Clementine.Model.effort() | nil,
          thinking: Clementine.Model.thinking_type() | nil,
          display: :omitted | :summarized | :updates | nil,
          cache: boolean() | keyword() | nil,
          provider_options: keyword() | nil,
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
  `Clementine.LLM.Message` structs: `UserMessage`, `AssistantMessage`,
  `ToolResultMessage`, and the `SystemMessage`s a skill load records.
  The model sees them, then the prompt. Leave the prompt itself out.
  Return them in the order the model saw them, and trim a long thread
  with `Clementine.History.window/2`: on a model that binds its thinking,
  a reordered or freshly trimmed history costs the earlier turns'
  reasoning.

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
      @clementine_agent_model Keyword.get(fields, :model)
      @clementine_agent_policy Keyword.take(fields, Clementine.LLM.Policy.keys())

      if @clementine_agent_model == nil and @clementine_agent_policy != [] do
        raise ArgumentError,
              "use Clementine.Agent (#{inspect(__MODULE__)}): " <>
                "#{inspect(Keyword.keys(@clementine_agent_policy))} are choices for a model; " <>
                "declare it with model: too, or make them in agent/1"
      end

      @doc "The model id this agent declares on `use`, or `nil`."
      def __model__, do: @clementine_agent_model

      @doc false
      # The policy this agent declares on `use`.
      def __policy__, do: @clementine_agent_policy

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
        @clementine_agent Clementine.Agent.__use__(__MODULE__, [id: key] ++ fields)

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

  - `:model` - the model's id (`"claude-sonnet-5-5"`), one Clementine
    ships a sheet for or `config :clementine, :models` declares. An agent
    the runtime builds from a module may leave it out and take the
    module's `__model__/0`
  - `:max_tokens`, `:effort`, `:thinking`, `:display`, `:cache`,
    `:provider_options` - the agent's choices for its model (see "The
    model and its policy" above)
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
    # The runtime may still fill a choice this agent leaves unset from its
    # module's `use` (`declared!/2`), so what needs one waits for the
    # check at the run's start, at boot, and on every request.
    build!(opts, "Clementine.Agent.new/1", partial: true)
  end

  @doc false
  # `use Clementine.Agent`'s build, at compile time. Its choices are whole
  # for its model, so they are checked whole; a model that compile-time
  # config does not know (one `config/runtime.exs` declares) is left to
  # boot.
  @spec __use__(module(), keyword()) :: t()
  def __use__(module, opts) do
    model = Keyword.get(opts, :model)

    source = "use Clementine.Agent (#{inspect(module)})"

    if is_nil(model) or Clementine.Models.known?(model) do
      build!(opts, source, [])
    else
      opts |> Keyword.delete(:model) |> build!(source, []) |> Map.put(:model, model)
    end
  end

  defp build!(opts, source, checks) do
    agent = struct!(__MODULE__, opts)
    Clementine.Trace.validate_fidelity!(agent.trace)
    check_model!(agent, source, checks)

    case Enum.filter(agent.deferred, &(&1 in agent.tools)) do
      [] ->
        agent |> normalize_output_schema() |> put_skills!() |> check_delegates!()

      both ->
        raise ArgumentError,
              "a tool is in tools: or deferred:, not both; found in both: #{inspect(both)}"
    end
  end

  @doc """
  The agent's choices for its model, as `Clementine.LLM.Policy` and a
  client's request opts take them: the ones it sets, and no others.
  """
  @spec policy(t()) :: keyword()
  def policy(%__MODULE__{} = agent) do
    # `false` is a choice (`cache: false`); only `nil` is unset.
    for key <- @policy, not is_nil(Map.fetch!(agent, key)), do: {key, Map.fetch!(agent, key)}
  end

  @doc false
  # The agent `module.agent/1` built, completed from the module's `use`
  # and checked whole against the model's sheet. `use`'s choices are for
  # its model: they fill what agent/1 leaves unset when agent/1 leaves the
  # model to `use` or names the same one, and none applies when agent/1
  # picks another model for the run. The runtime calls it at every claim
  # (an ArgumentError cancels the run as unstartable), and
  # `Clementine.run/3` given a module.
  @spec declared!(module(), t()) :: t()
  def declared!(module, %__MODULE__{} = agent) do
    {model, declared} = declared(module)

    cond do
      agent.model == nil and model == nil ->
        raise ArgumentError,
              "#{inspect(module)}.agent/1 names no model, and its use Clementine.Agent " <>
                "declares none: give one (model: \"claude-sonnet-5-5\")"

      model == nil ->
        check!(agent, &"#{inspect(module)}.agent/1: #{&1}")

      agent.model in [nil, model] ->
        filled = fill(%{agent | model: model}, declared)

        check!(filled, fn message ->
          own = policy(agent)

          if own != [] and match?({:error, _}, Clementine.LLM.Policy.resolve(model, own)),
            do: "#{inspect(module)}.agent/1's Clementine.Agent.new/1 choices: #{message}",
            else:
              "#{inspect(module)}'s use Clementine.Agent choices #{inspect(declared)}" <>
                if(own == [], do: "", else: ", with agent/1's #{inspect(own)}") <>
                ": #{message}"
        end)

      true ->
        check!(agent, fn message ->
          "#{inspect(module)}.agent/1 picked #{inspect(agent.model)} for this run, not the " <>
            "#{inspect(model)} its use Clementine.Agent declares, so only agent/1's own " <>
            "choices apply: #{message}"
        end)
    end
  end

  @doc false
  # The agent an in-process run executes (`Clementine.run/3`,
  # `Clementine.stream/3`): an agent struct, checked whole, or a
  # `use Clementine.Agent` module's, built for `run` and completed from
  # its `use` as the runtime does.
  @spec for_run!(t() | module(), term(), String.t()) :: t()
  def for_run!(%__MODULE__{model: nil}, _run, caller) do
    raise ArgumentError,
          "#{caller}: the agent names no model. Give Clementine.Agent.new/1 a model: " <>
            "(\"claude-sonnet-5-5\"), or pass the agent's module, whose use Clementine.Agent " <>
            "declares one (#{caller}(MyApp.Agents.Triage, prompt))"
  end

  def for_run!(%__MODULE__{} = agent, _run, caller),
    do: check!(agent, &"#{caller}: #{&1}")

  def for_run!(module, run, _caller) when is_atom(module) do
    unless Clementine.Runs.Config.agent?(module) do
      raise ArgumentError,
            "expected a Clementine.Agent struct or a use Clementine.Agent module, got: " <>
              inspect(module)
    end

    declared!(module, module.agent(run || default_run(module)))
  end

  # What an in-process run of a module hands its agent/1 when the caller
  # gives no run: a row with only the agent's key and kind.
  defp default_run(module) do
    fields = [agent_key: module.key(), turn: module.turn(), metadata: %{}]

    if Code.ensure_loaded?(Clementine.Runs.AgentRun),
      do: struct(Clementine.Runs.AgentRun, fields),
      else: Map.new(fields)
  end

  # `use`'s choices under the ones agent/1 made, provider options key by
  # key.
  defp fill(agent, declared) do
    Enum.reduce(declared, agent, fn
      {:provider_options, options}, agent ->
        %{agent | provider_options: Keyword.merge(options, agent.provider_options || [])}

      {key, value}, agent ->
        if is_nil(Map.fetch!(agent, key)), do: Map.put(agent, key, value), else: agent
    end)
  end

  defp check!(agent, describe) do
    case Clementine.LLM.Policy.resolve(agent.model, policy(agent)) do
      {:ok, _policy} -> agent
      {:error, message} -> raise ArgumentError, describe.(message)
    end
  end

  @doc false
  # Checks a module's declared model and policy against the sheets and
  # the app's config, as boot does for every agent in `agents:`.
  @spec check_declared(module()) :: :ok | {:error, String.t()}
  def check_declared(module) do
    with {:ok, _policy} <- resolve_declared(module), do: :ok
  end

  @doc false
  # The module's declared model and choices, resolved against the sheet:
  # `{:ok, nil}` for a module that declares no model.
  @spec resolve_declared(module()) ::
          {:ok, Clementine.LLM.Policy.t() | nil} | {:error, String.t()}
  def resolve_declared(module) do
    case declared(module) do
      {nil, _policy} ->
        {:ok, nil}

      {model, policy} ->
        with {:error, message} <- Clementine.LLM.Policy.resolve(model, policy),
             do: {:error, "its use Clementine.Agent declares #{inspect(policy)}: #{message}"}
    end
  end

  # What a module's `use` declares: its model and its choices. A module
  # that implements the behaviour by hand declares neither.
  defp declared(module) do
    model = if function_exported?(module, :__model__, 0), do: module.__model__()
    policy = if function_exported?(module, :__policy__, 0), do: module.__policy__(), else: []
    {model, policy}
  end

  # An agent without a model is one the runtime completes from its
  # module (`declared!/2`); one with a model is checked now, so a typo or
  # a choice its sheet refuses fails the build.
  defp check_model!(%__MODULE__{model: nil} = agent, _source, _checks), do: agent

  defp check_model!(%__MODULE__{model: model} = agent, source, checks) do
    case Clementine.LLM.Policy.resolve(model, policy(agent), checks) do
      {:ok, _policy} -> agent
      {:error, message} -> raise ArgumentError, "#{source}: #{message}"
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
