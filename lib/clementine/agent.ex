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

  An agent that converses also writes `c:history/1`, which returns the
  messages before the run's prompt from the app's own tables:

      defmodule MyApp.Agents.Chat do
        use Clementine.Agent,
          key: "chat",
          model: :claude_sonnet,
          instructions: "You are a helpful assistant."

        @impl true
        def history(run), do: MyApp.Chat.messages(run.subject_id)
      end

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
  The agent for one execution of `run`: model, instructions, tools, and
  limits. Called at every claim, so it may read whatever the run needs;
  `run.subject` holds what `c:Clementine.Host.resolve_subject/2` returned.
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
  through a `jsonb` column), and read them back here.

  It is called when a run starts from its prompt, after the subject
  resolves, so `run.subject` is set. A run that resumes after an approval
  continues from its checkpoint, which already holds the conversation, so
  it is not called again. Anything but a list of messages cancels the run
  as unstartable. `use Clementine.Agent` defines it to return `[]`.
  """
  @callback history(run :: Clementine.Runs.AgentRun.t()) :: [Clementine.LLM.Message.message()]

  @optional_callbacks history: 1

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Clementine.Agent

      {key, fields} = Keyword.pop(opts, :key)

      unless is_binary(key) and key != "" do
        raise ArgumentError,
              "use Clementine.Agent needs a non-empty string key:, got: #{inspect(key)}"
      end

      @clementine_agent_key key

      @impl Clementine.Agent
      def key, do: @clementine_agent_key

      @impl Clementine.Agent
      def history(_run), do: []

      defoverridable history: 1

      if fields != [] do
        @clementine_agent Clementine.Agent.new([id: key] ++ fields)

        @impl Clementine.Agent
        def agent(_run), do: @clementine_agent

        defoverridable agent: 1
      end
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
