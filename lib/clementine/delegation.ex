defmodule Clementine.Delegation do
  @moduledoc """
  A run that asks other agents and waits for their answers.

  An agent offers the agents it may ask with `delegates:`
  (`Clementine.Agent`):

      use Clementine.Agent,
        key: "planner",
        model: :claude_sonnet,
        instructions: "Plan the work; ask the researcher for facts.",
        delegates: [MyApp.Agents.Researcher, MyApp.Agents.Writer]

  The model then sees a `delegate` tool taking `agent`, an enum of the
  offered agents' keys, and `prompt`, the whole brief: the child sees
  nothing of the parent's conversation.

  ## A call, a child, a wait

  Each `delegate` call starts one run of that agent, a child of the
  parent: its `parent_id` is the parent's, its tag `{:delegate,
  tool_use_id}`, its subject and actor the parent's, and its metadata
  `%{"delegated_by" => parent_agent_key}`. The children of one batch
  start in one transaction, the one that parks the parent, so they exist
  exactly when the parent waits on them, and a drain or a crash before
  the park leaves none behind.

  The parent parks `waiting`, with the suspension reason
  `{:external, {:delegation, child_ids}}` and a `Clementine.Pending.Delegation`
  in its checkpoint. When the last child ends, the parent resumes on a
  new job, and each `delegate` call settles with its child's answer:

  - a completed child's output, as is when it is text, and JSON-encoded
    when it is anything else (a map from `output_schema:`);
  - a child that failed, was cancelled, or was interrupted, as an error
    result naming what happened.

  Calls in one batch run side by side, and their answers return to the
  model together, with the batch's other results. A batch that also
  holds an approval-gated call waits for the decision first: the batch
  parks for each gated call, then once for its children.

  ## Lanes and cycles

  A child is a task on the parent's subject, so it needs a lane of its
  own there:

  - a turn agent (`turn: true`) is never a delegate, because a turn's
    lane is its thread, which the parent's turn may hold; the call is
    refused at once;
  - an agent with an active task on the subject (the parent itself, a
    sibling in the same batch, or a run the app started) is refused when
    the batch parks.

  An agent among those whose requests led to the park (the parent, its
  parent, and so on up) is refused there too, subject or not, so agents
  cannot ask each other in a circle and a chain of asks is as deep as
  there are agents at most.

  Each refusal is an error tool result the model reads, never a crash.
  When no child of a batch could start, the parent resumes once its
  execution is over.

  ## Cancel, reaper, purge

  Cancelling a parent that waits on its children flags it, as a running
  run is flagged, and cancels its live children in the same transaction:
  a queued child ends at once, a running one gets its own flag. The last
  child's end resumes the parent, whose next execution honors the flag
  before anything else: it ends `cancelled` after its children, so a
  cascade (a thread's loop, its turn, the turn's children) finishes from
  the bottom up, and the subject purges once the top has ended.

  Cancelling one child resumes the parent once its siblings have ended,
  with that call settled as cancelled. A child the reaper interrupts, or
  one never claimed, ends like any run, and its end resumes the parent
  the same way. The reaper also resumes a waiting parent whose children
  have all ended when no end reached it, once its park and its last
  child's end are a sweep interval old. A parent ended while it waits
  (the reaper's `max_wait:` ceiling) cancels its live children with it.
  `Clementine.Runs.purge/1` follows `parent_id`, so a subject's purge
  takes the children too.

  ## The trace

  When the parent resumes, it records a `:delegate` entry for each call
  that started a child, with the child's id, its agent, and how it ended,
  just before the call's `:tool_call` entry (`Clementine.Trace`). The
  child's own trace is `Clementine.Runs.trace(child_id)`.

  ## Where it runs

  Only `Clementine.Runs` starts children, so only its runs are offered
  `delegate` (the runner's `delegation: true`). On `Clementine.run/3`,
  `Clementine.stream/3`, `Clementine.AgentServer`, and a local loop's
  children, an agent's `delegates:` are not offered: the model sees no
  `delegate` tool, and the trace's execution entry lists none.

  ## Deploying it

  Code from before delegation drops a child's end when its parent is a
  rollout, and cannot read a delegation's checkpoint. Ship the version
  of Clementine that has it one deploy before any agent offers
  `delegates:`. A parent whose child's end was dropped anyway is resumed
  by the reaper's next sweep, once all its children have ended.
  """

  alias Clementine.{EngineTool, Result}

  @tool_name "delegate"

  @typedoc """
  A child the parent waits on: the agent's key, the prompt, and the id of
  its run once the runtime has started it.
  """
  @type child :: %{agent: String.t(), prompt: String.t(), run_id: term() | nil}

  @typedoc """
  What the model reads for one child's end: `"status"` (`"completed"`,
  `"failed"`, `"cancelled"`, or `"interrupted"`), `"content"`, and
  `"is_error"`.
  """
  @type outcome :: %{String.t() => String.t() | boolean()}

  @doc false
  # The name of the engine tool that starts children.
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc false
  # What a build may check of `delegates` without reading a delegate's
  # key: a list of modules, none twice, and no tool the agent may offer
  # (`tools`) named delegate. `use Clementine.Agent` builds an agent at
  # compile time, when two agents may name each other.
  @spec check(term(), [module()]) :: :ok | {:error, String.t()}
  def check(delegates, tools) when is_list(delegates) do
    cond do
      not Enum.all?(delegates, &is_atom/1) ->
        {:error,
         "delegates: takes agent modules (use Clementine.Agent), got: #{inspect(delegates)}"}

      (repeated = for({m, n} <- Enum.frequencies(delegates), n > 1, do: m)) != [] ->
        {:error, "delegates: lists #{inspect(repeated)} more than once"}

      tool = Enum.find(tools, &named_delegate?/1) ->
        {:error,
         "#{inspect(tool)} is named #{inspect(@tool_name)}, the tool that asks other " <>
           "agents: rename it"}

      true ->
        :ok
    end
  end

  def check(other, _tools), do: {:error, "delegates: takes a list, got: #{inspect(other)}"}

  # A tool module may be compiled on demand, as Clementine.Skill does: a
  # tool never names an agent, so no build waits on itself.
  defp named_delegate?(tool) do
    is_atom(tool) and Code.ensure_compiled(tool) == {:module, tool} and
      function_exported?(tool, :__name__, 0) and tool.__name__() == @tool_name
  end

  @doc false
  # Everything a run checks of `delegates` before it executes: `check/2`,
  # then each an agent module, their keys distinct. The `delegate` engine
  # tool, or the error the run fails with.
  @spec prepare(term(), [module()]) :: {:ok, EngineTool.t()} | {:error, String.t()}
  def prepare(delegates, tools) do
    with :ok <- check(delegates, tools) do
      {:ok, tool(delegates)}
    end
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  @doc false
  # The `delegate` engine tool for an agent offering `delegates`: `agent`
  # is an enum of their keys, and the description lists each with its
  # own description, when it has one.
  @spec tool([module(), ...]) :: EngineTool.t()
  def tool([_ | _] = delegates) do
    entries = entries(delegates)
    keys = Enum.map(entries, &elem(&1, 0))

    listing =
      Enum.map_join(entries, "\n", fn
        {key, nil} -> "- #{key}"
        {key, description} -> "- #{key}: #{description}"
      end)

    %EngineTool{
      kind: :delegate,
      name: @tool_name,
      description:
        "Ask another agent to do a task, and wait for its answer. Each call starts one " <>
          "run of that agent with your prompt as its whole brief: it sees nothing of this " <>
          "conversation, so say everything it needs. Calls you make together run side by " <>
          "side, and their answers come back as these calls' results once every one has " <>
          "ended.\n\nAgents:\n" <> listing,
      parameters: [
        agent: [
          type: :string,
          required: true,
          enum: keys,
          description: "The agent to ask"
        ],
        prompt: [
          type: :string,
          required: true,
          description: "The task, as a complete brief"
        ]
      ]
    }
  end

  @doc false
  # Each delegate's key and description (`nil` without one), in order:
  # what the tool lists, and what the agent fingerprint covers.
  @spec entries([module()]) :: [{String.t(), String.t() | nil}]
  def entries(delegates) do
    delegates
    |> keys()
    |> Enum.zip(delegates)
    |> Enum.map(fn {key, module} ->
      {key, if(function_exported?(module, :description, 0), do: module.description())}
    end)
  end

  @doc false
  # The keys of `delegates`, each an agent module (`use Clementine.Agent`),
  # in order. Raises for anything else, or for two that share a key.
  @spec keys([module()]) :: [String.t()]
  def keys(delegates) do
    keys = Enum.map(delegates, &key!/1)

    case for {key, n} <- Enum.frequencies(keys), n > 1, do: key do
      [] ->
        keys

      repeated ->
        raise ArgumentError, "delegates: offers more than one agent keyed #{inspect(repeated)}"
    end
  end

  defp key!(module) do
    if is_atom(module) and Code.ensure_loaded?(module) and
         function_exported?(module, :key, 0) and function_exported?(module, :turn, 0) do
      module.key()
    else
      raise ArgumentError,
            "delegates: takes agent modules (use Clementine.Agent), got: #{inspect(module)}"
    end
  end

  @doc false
  # Checks one `delegate` call against the offered `delegates`: the child
  # it asks for, or the error the model reads. The agent is looked up
  # among the offered ones only, never as a module, and a turn agent is
  # refused, since its lane is a thread.
  @spec call([module()], map()) :: {:ok, child()} | {:error, String.t()}
  def call(delegates, input) do
    keys = keys(delegates)

    with {:ok, key} <- requested_agent(input, keys),
         {:ok, module} <- offered(delegates, keys, key),
         :ok <- task(module, key),
         {:ok, prompt} <- prompt(input) do
      {:ok, %{agent: key, prompt: prompt, run_id: nil}}
    end
  end

  defp requested_agent(%{"agent" => key}, _keys) when is_binary(key), do: {:ok, key}

  defp requested_agent(_input, keys) do
    {:error, "delegate needs the agent to ask: one of #{Enum.join(keys, ", ")}."}
  end

  defp offered(delegates, keys, key) do
    case Enum.find_index(keys, &(&1 == key)) do
      nil ->
        {:error,
         "There is no agent #{inspect(key)} to ask. The agents are: #{Enum.join(keys, ", ")}."}

      index ->
        {:ok, Enum.at(delegates, index)}
    end
  end

  defp task(module, key) do
    if module.turn() do
      {:error,
       "Cannot ask #{inspect(key)}: it takes turns on a conversation, and only an agent " <>
         "that runs tasks can be asked."}
    else
      :ok
    end
  end

  defp prompt(%{"prompt" => prompt}) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      {:error, "delegate needs a prompt: the task, as a complete brief."}
    else
      {:ok, prompt}
    end
  end

  defp prompt(_input), do: {:error, "delegate needs a prompt: the task, as a complete brief."}

  @doc """
  What the model reads for the end of a child of `agent`: a completed
  child's output (as is when it is text, JSON-encoded when it is anything
  else, such as a map from `output_schema:`), or an error result naming
  how it ended otherwise. The runtime builds the
  `{:delegated, %{tool_use_id => outcome}}` resume payload from these.
  """
  @spec outcome(String.t(), Result.t()) :: outcome()
  def outcome(_agent, %Result.Completed{output: output}) do
    %{"status" => "completed", "content" => render(output), "is_error" => false}
  end

  def outcome(agent, %Result.Failed{error: error}) do
    %{
      "status" => "failed",
      "content" => "The #{agent} run failed: #{error_message(error)}",
      "is_error" => true
    }
  end

  def outcome(agent, %Result.Cancelled{}) do
    %{
      "status" => "cancelled",
      "content" => "The #{agent} run was cancelled before it answered.",
      "is_error" => true
    }
  end

  def outcome(agent, %Result.Interrupted{reason: reason}) do
    %{
      "status" => "interrupted",
      "content" =>
        "The #{agent} run was interrupted (#{interrupt_code(reason)}) before it answered.",
      "is_error" => true
    }
  end

  defp render(output) when is_binary(output), do: output
  defp render(nil), do: ""

  defp render(output) do
    case Jason.encode(output) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(output)
    end
  end

  defp error_message(%Clementine.Error{message: message}) when is_binary(message), do: message
  defp error_message(other), do: inspect(other)

  defp interrupt_code(%Clementine.InterruptReason{code: {:app, code}}), do: inspect(code)
  defp interrupt_code(%Clementine.InterruptReason{code: code}), do: Atom.to_string(code)
  defp interrupt_code(other), do: inspect(other)
end
