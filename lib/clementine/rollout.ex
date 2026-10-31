defmodule Clementine.Rollout do
  @moduledoc """
  One agent execution: the model–tool cycle, and the inert spec that
  describes it.

  A rollout is Clementine's inner unit of agent work: call the model, execute
  tool calls, feed results back, repeat until a final answer or a limit. The
  `%Clementine.Rollout{}` struct is the inert spec (what to try); the
  functions in this module are the engine that animates it. Durable execution
  wraps rollouts in runs — see the durable execution RFC.

  ## The Loop

  ```
  ┌───────────────────────────────────────┐
  │                                       │
  │   ┌─────────┐        ┌─────────┐      │
  │   │ Gather  │───────▶│   Act   │───┐  │
  │   └─────────┘        └─────────┘   │  │
  │        ▲                           │  │
  │        └───────────────────────────┘  │
  │                                       │
  │              until done               │
  └───────────────────────────────────────┘
  ```

  The loop continues until:
  - The model returns a final response (no tool calls)
  - An approval-gated tool call parks the run: the loop returns a
    `Clementine.Suspension.Request` carrying its own state, and resumes
    from the checkpoint once a decision arrives
  - Max iterations reached
  - An unrecoverable error occurs

  Verification is deliberately not part of the model–tool cycle: judging a
  result and deciding to retry is outer-control work (see
  `Clementine.Verifier` for the judge-function shape it uses).

  ## Engine Tools

  Most tool calls act on the world, through `Clementine.ToolRunner`. An
  engine tool (`Clementine.EngineTool`) acts on the execution itself.
  `use_skill` settles in place, first in its batch: it loads a
  `Clementine.Skill`, adding the skill's tools to the ones offered from
  the next model call on, and the batch's other calls resolve against the
  toolset it leaves. The system prompt never changes. `delegate` parks:
  its calls are checked first, and once the batch's other calls have
  settled (approval-gated ones included, one decision at a time), the
  run parks on them with a `Clementine.Pending.Delegation`, and the
  runtime starts the children in the write that parks it
  (`Clementine.Delegation`). The resume settles each call with its
  child's answer.

  ## Tool Policy

  A tool declared `approval: {:policy, term}` asks the `:authorize_tool`
  function about each call before the batch runs anything: `:allow`
  runs it with the batch, `:require_approval` parks it like
  `approval: :required`, and `{:deny, reason}` settles it as an error
  result carrying `reason`, which the model reads. An approved call is
  asked once more when the approval resumes the run, and a deny wins. A
  function that raises, exits, throws, answers anything else, or does
  not answer in time denies the call and logs why, without the run's
  data. Without the function, `{:policy, _}` gates like `:required`.
  The check covers every tool the execution offers: the agent's,
  deferred ones, and those a loaded skill brought. Engine tools carry
  no approval. The host's `c:Clementine.Host.authorize_tool/3` is the
  function on the durable runtime.

  The policy and a skill's body are host code, and run in a task of
  their own (`Clementine.HostCall`), bounded like a tool call; a cancel,
  a drain, or a lost lease while one runs kills it and unwinds the run.

  Formerly `Clementine.Loop`; renamed so `Loop` can name the outer control
  primitive.
  """

  alias Clementine.LLM.Message.{AssistantMessage, UserMessage}
  alias Clementine.LLM.Message.{Content, ToolResultMessage}

  alias Clementine.{
    ApprovalRequest,
    Delegation,
    EngineTool,
    LLM,
    Pending,
    Skill,
    Suspension,
    Tool
  }

  alias Clementine.{HostCall, ToolInput, ToolResult, ToolRunner, Trace}
  alias Clementine.Trace.Recorder

  require Logger

  @default_max_iterations 10

  # Mirrors the streaming clients' default receive timeout; the execution
  # deadline may only shrink it, never extend it.
  @provider_receive_timeout :timer.minutes(5)

  @enforce_keys [:agent, :input]
  defstruct agent: nil,
            input: nil,
            messages: [],
            context: %{},
            limits: []

  @type t :: %__MODULE__{
          agent: Clementine.Agent.t(),
          input: String.t(),
          messages: [Clementine.LLM.Message.message()],
          context: map(),
          limits: keyword()
        }

  @doc """
  Builds a rollout spec: an agent, an input prompt, and optional starting
  history, context, and limits. The spec is inert data — nothing executes
  until an engine function (or a runner) animates it.

  ## Options

  - `:agent` (required) - a `Clementine.Agent` struct
  - `:input` (required) - the user prompt for this rollout
  - `:messages` - starting message history (default `[]`); a run that
    resumes from a checkpoint continues from the checkpoint's messages
  - `:context` - context map passed to tools (default `%{}`)
  - `:limits` - `[max_iterations: pos_integer(), max_duration: pos_integer()]`;
    unset keys fall back to the agent's defaults
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  The rollout's effective limits: agent defaults merged under rollout limits
  (the rollout wins). `max_duration:` is what a runner's claim mints the
  execution deadline from; `max_iterations:` bounds the loop.
  """
  @spec limits(t()) :: keyword()
  def limits(%__MODULE__{} = rollout) do
    %Clementine.Agent{} = agent = rollout.agent
    Keyword.merge(agent.defaults, rollout.limits)
  end

  # Lowers a rollout spec into the keyword config `execute/2` consumes.
  # Agent defaults merge under rollout limits (the rollout wins).
  @spec to_config(t()) :: keyword()
  defp to_config(%__MODULE__{} = rollout) do
    %Clementine.Agent{} = agent = rollout.agent

    # A tool in both lists goes once, up front: Agent.new/1 refuses the
    # overlap, but an agent/1 may build or update the struct directly, and
    # a tool sent twice is a request the provider refuses.
    deferred = agent.deferred |> Enum.reject(&(&1 in agent.tools)) |> Enum.uniq()

    [
      model: agent.model,
      system: agent.instructions,
      tools: agent.tools ++ deferred,
      deferred: deferred,
      output_schema: agent.output_schema,
      skills: agent.skills,
      delegates: agent.delegates,
      context: rollout.context,
      messages: rollout.messages,
      max_iterations: Keyword.get(limits(rollout), :max_iterations, @default_max_iterations),
      trace: Trace.validate_fidelity!(agent.trace)
    ]
  end

  defmodule Execution do
    @moduledoc false
    # Loop state for `execute/2`: the runner-supplied closures, the
    # accumulated typed usage, and `prefix_len` — where history + input end
    # and generated messages begin, so `Result.Completed` can separate the
    # two. `recorder` is the runner's trace buffer (nil: no trace), and
    # `fidelity` the agent's `trace:`. `tools` are the tool modules
    # offered now (the agent's, then each loaded skill's), `engine_tools`
    # the engine's own, `skills` the skills the agent offers,
    # `loaded_skills` the names of those loaded, in load order, and
    # `delegates` the agent modules it may ask. `authorize_tool` answers
    # for `{:policy, term}` tools (nil: they gate like :required).
    # `resolved` is `model` resolved once for the execution
    # (`Trace.resolve_model/1`), and `agent_key` the run's agent key: every
    # trace entry and telemetry event of the execution names both.
    defstruct [
      :model,
      :resolved,
      :agent_key,
      :system,
      :tools,
      :deferred,
      :output_schema,
      :context,
      :max_iterations,
      :emit,
      :recorder,
      :cancel?,
      :mark_effects,
      :authorize_tool,
      :deadline,
      :input_message,
      :prefix_len,
      :started_at,
      messages: [],
      iteration: 0,
      usage: %Clementine.Usage{},
      fence_raised?: false,
      fidelity: :content,
      paused?: false,
      skills: [],
      delegates: [],
      delegation?: false,
      engine_tools: [],
      loaded_skills: []
    ]
  end

  @typedoc """
  The closed return set of `execute/2`. Every value a rollout can produce is
  named here; anything else is a contract violation the runner converts to
  `finish(failed)` — never a crash.
  """
  @type execute_result ::
          {:ok, Clementine.Result.Completed.t()}
          | {:suspend, Clementine.Suspension.Request.t()}
          | {:cancelled, reason :: term()}
          | :drained
          | {:error, Clementine.Error.t()}
          | :lost_lease

  @doc """
  Animates a rollout spec: the model–tool cycle with the runner's execution
  apparatus threaded through. This is the engine a `Clementine.Runner`
  drives — the one engine; scripts reach it through `Clementine.run/3` and
  `Clementine.stream/3`, interactive processes through
  `Clementine.AgentServer`.

  ## Options

  - `:resume` - `{checkpoint, payload}` from the lease of a resumed run;
    restores loop state from the checkpoint (snapshot restoration, not
    replay). A pending `Clementine.Pending.ToolApproval` is resolved by
    the payload — `{:approved, meta}` executes the gated call now and
    merges it with the checkpointed sibling results; `{:denied, meta}`
    synthesizes an error tool result carrying `meta[:message]` (default
    `"Denied by approver."`) and lets the model react. A checkpoint with
    no pending operation (an `{:until, t}` wait resumed with `:elapsed`,
    or host-built prior messages) simply continues the loop. An
    unreadable or incompatible checkpoint — unknown version, undecodable
    envelope, or a pending call this rollout cannot support — returns
    `{:error, %Error{code: :incompatible_checkpoint}}`; never a crash and
    never a bare atom.
  - `:emit` - a `Clementine.Events.Stamper` for execution events; omitted
    means no events.
  - `:trace` - the runner's trace buffer: the rollout records an entry
    for the execution, each model call, and each settled tool call
    (`Clementine.Trace`), and writes the new ones at every iteration
    boundary before it gathers; a write that finds the lease lost
    unwinds as `:lost_lease`. Omitted means no trace.
  - `:cancel?` - zero-arity closure that reads the run's cancel flag,
    polled at iteration boundaries (before each gather, which is also
    after each tool batch).
  - `:mark_effects` - zero-arity closure that marks the run as having had
    effects, called once, before the first tool batch containing a tool whose
    `retry` metadata is not `:safe` (`:unknown` is `:unsafe`). Batches of
    only `:safe` tools leave the fence down: nothing external can happen,
    so the run stays requeue-eligible.
  - `:delegation` - `true` when the lifecycle starts the children of a
    delegation park (`Clementine.Runs`); without it the agent's
    `delegates:` are not offered.
  - `:authorize_tool` - a two-arity function the rollout asks about each
    call to a tool declared `approval: {:policy, term}`, with the call as
    a `Clementine.ApprovalRequest` (the arguments that would run) and
    `term`. It answers `:allow`, `:require_approval`, or
    `{:deny, reason}` with `reason` a string (see "Tool Policy" above).
    It runs in a task before the batch's fence, one call at a time, and
    a signal that arrives meanwhile unwinds the run before anything
    runs. A call still waiting when the batch parks is asked again on
    each resume, and an approved one once more when its approval
    resumes the run; a call an approver denied is not. Omitted means
    `{:policy, _}` gates like `:required`.
  - `:deadline` - the execution deadline minted at claim, checked at
    iteration boundaries and applied as a cap on the provider stream's
    receive timeout and on per-tool timeouts.

  ## Signals

  The blocking points — the provider-stream receive loop and the tool-batch
  await — additionally match runner-directed messages and unwind, aborting
  in-flight work: `{:clementine, :lease_lost, lease}` → `:lost_lease`,
  `{:clementine, :drain}` → `:drained`, `{:clementine, :cancel, reason}` →
  `{:cancelled, reason}`. Infrastructure signals (lease loss, drain) abort
  a tool batch outright; a cancel push applies the cooperative kill policy
  instead — `retry: :safe` tools are killed immediately, unsafe tools run
  out their own timeout (killing an effectful tool mid-flight creates
  unknowable external state), and the loop stops before the next gather.

  ## Cancellation Latency

  The boundary poll alone bounds cancel latency to one iteration — at
  worst one full model response plus one tool batch. With the optional
  push channel (`subscribe_cancel` on the lifecycle) the signal lands in
  the blocking points and aborts the in-flight provider stream, making a
  mid-stream cancel effectively instant; mid-batch, only unsafe tools'
  own timeouts remain. The poll is the guarantee; push is the
  optimization.
  """
  @spec execute(t(), keyword()) :: execute_result()
  def execute(%__MODULE__{} = rollout, opts \\ []) do
    config = to_config(rollout)
    input_message = UserMessage.new(rollout.input)

    model = Keyword.fetch!(config, :model)

    exec = %Execution{
      model: model,
      resolved: Trace.resolve_model(model),
      agent_key: agent_key(rollout),
      system: Keyword.get(config, :system),
      tools: Keyword.get(config, :tools, []),
      deferred: Keyword.get(config, :deferred, []),
      output_schema: Keyword.get(config, :output_schema),
      skills: Keyword.get(config, :skills, []),
      delegates: Keyword.get(config, :delegates, []),
      delegation?: Keyword.get(opts, :delegation, false),
      context: Keyword.get(config, :context, %{}),
      max_iterations: Keyword.get(config, :max_iterations, @default_max_iterations),
      emit: Keyword.get(opts, :emit),
      recorder: Keyword.get(opts, :trace),
      fidelity: Keyword.fetch!(config, :trace),
      cancel?: Keyword.get(opts, :cancel?, fn -> :none end),
      mark_effects: Keyword.get(opts, :mark_effects, fn -> :ok end),
      authorize_tool: Keyword.get(opts, :authorize_tool),
      deadline: Keyword.get(opts, :deadline),
      input_message: input_message,
      prefix_len: length(rollout.messages) + 1,
      started_at: System.monotonic_time()
    }

    :telemetry.execute(
      [:clementine, :rollout, :start],
      %{system_time: System.system_time()},
      Map.merge(identity(exec), %{
        max_iterations: exec.max_iterations,
        tool_count: length(exec.tools)
      })
    )

    try do
      case prepare(exec, Keyword.get(opts, :resume), rollout) do
        {:ok, %Execution{} = exec} ->
          boundary(exec)

        {:resolve, %Execution{} = exec, pending, payload} ->
          resolve_pending(exec, pending, payload)

        {:error, %Execution{} = exec, %Clementine.Error{} = error} ->
          fail(exec, error)
      end
    rescue
      e ->
        emit_rollout_raise(exec, :error, e, __STACKTRACE__)
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        emit_rollout_raise(exec, kind, reason, __STACKTRACE__)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # Checks what the agent offers (its output schema, its skills, its
  # delegates),
  # restores a resumed run's state, and records the execution entry. The
  # entry names the toolset the execution begins with, so it follows the
  # restore that rebuilds it; an execution that fails here records one
  # too, with the agent's own tools.
  defp prepare(%Execution{} = exec, resume, rollout) do
    resumed? = resume != nil

    with {:ok, %Execution{} = exec} <- normalize_output_schema(exec),
         {:ok, %Execution{} = exec} <- prepare_skills(exec),
         {:ok, %Execution{} = exec} <- prepare_delegates(exec) do
      case restore(exec, resume, rollout) do
        {:ok, %Execution{} = restored} = ok ->
          record_execution(restored, exec.tools, resumed?)
          ok

        {:resolve, %Execution{} = restored, _pending, _payload} = resolve ->
          record_execution(restored, exec.tools, true)
          resolve

        {:error, %Clementine.Error{} = error} ->
          record_execution(exec, exec.tools, resumed?)
          {:error, exec, error}
      end
    else
      {:error, %Execution{} = exec, %Clementine.Error{}} = error ->
        record_execution(exec, exec.tools, resumed?)
        error
    end
  end

  # Agent.new/1 normalizes an output_schema, but an agent/1 may set the
  # struct's field directly: normalize it here too (a normalized schema
  # comes back unchanged), so the execution's trace entry fingerprints the
  # schema the run uses, and fail the run on one that is not a schema
  # before anything executes.
  defp normalize_output_schema(%Execution{output_schema: nil} = exec), do: {:ok, exec}

  defp normalize_output_schema(%Execution{output_schema: schema} = exec) do
    case Clementine.OutputSchema.normalize(schema) do
      {:ok, schema} -> {:ok, %{exec | output_schema: schema}}
      {:error, %Clementine.Error{} = error} -> {:error, exec, error}
    end
  end

  # Agent.new/1 checks skills, but an agent/1 may set the field directly
  # (a raw skill module, a tool whose name another takes): every run is
  # checked here, against the tools it offers of its own, deferred ones
  # included, and one that fails runs nothing. A run with skills is
  # offered use_skill.
  defp prepare_skills(%Execution{skills: []} = exec), do: {:ok, exec}

  defp prepare_skills(%Execution{} = exec) do
    case Skill.prepare(exec.skills, exec.tools, exec.deferred) do
      {:ok, skills} ->
        {:ok, %{exec | skills: skills, engine_tools: [Skill.use_skill_tool(skills)]}}

      {:error, message} ->
        {:error, %{exec | skills: []},
         %Clementine.Error{
           kind: :rollout,
           code: :invalid_skills,
           message: message,
           retryable?: false
         }}
    end
  end

  # Agent.new/1 checks what a build may of delegates, but reads no
  # delegate's key, and an agent/1 may set the field directly: every run
  # checks them here (agent modules, their keys distinct, no tool it
  # offers named delegate), and one that fails runs nothing. A run with
  # delegates is offered delegate, when its runner's lifecycle starts the
  # children (`delegation: true`); elsewhere it is offered none.
  defp prepare_delegates(%Execution{delegates: []} = exec), do: {:ok, exec}

  defp prepare_delegates(%Execution{delegation?: false} = exec),
    do: {:ok, %{exec | delegates: []}}

  defp prepare_delegates(%Execution{} = exec) do
    offered = exec.tools ++ Enum.flat_map(exec.skills, & &1.tools)

    case Delegation.prepare(exec.delegates, offered) do
      {:ok, tool} ->
        {:ok, %{exec | engine_tools: exec.engine_tools ++ [tool]}}

      {:error, message} ->
        {:error, %{exec | delegates: []},
         %Clementine.Error{
           kind: :rollout,
           code: :invalid_delegates,
           message: message,
           retryable?: false
         }}
    end
  end

  # Fresh start: history, then the materialized input message.
  defp restore(%Execution{} = exec, nil, rollout) do
    {:ok, %{exec | messages: rollout.messages ++ [exec.input_message]}}
  end

  # Resume is snapshot restoration: the checkpoint's messages already
  # contain history and input, so nothing is re-appended. A pending
  # operation is the act the suspension interrupted; the payload resolves
  # it before the loop may gather again.
  defp restore(%Execution{} = exec, {checkpoint, payload}, _rollout) do
    with {:ok, %Clementine.Checkpoint{} = checkpoint} <- decode_checkpoint(checkpoint),
         {:ok, %Execution{} = exec} <- restore_skills(exec, checkpoint) do
      exec = %{
        exec
        | messages: checkpoint.messages,
          prefix_len: resumed_prefix_len(checkpoint.messages, exec.prefix_len),
          iteration: checkpoint.iteration,
          usage: checkpoint.usage
      }

      # Shapes beyond ToolApproval and Delegation are unspecified until
      # their reasons activate; a checkpoint carrying one is exactly
      # "content no longer understood" and takes the doctrine's
      # incompatible path — a decoded envelope already fails inside
      # decode, so this arm guards host-built structs.
      case checkpoint.pending do
        nil ->
          {:ok, exec}

        %Pending.ToolApproval{} = pending ->
          {:resolve, exec, pending, payload}

        %Pending.Delegation{} = pending ->
          {:resolve, exec, pending, payload}

        other ->
          {:error,
           incompatible_checkpoint(
             "pending operation #{pending_shape(other)} is not resolvable " <>
               "by this engine version",
             checkpoint
           )}
      end
    end
  end

  # Where a checkpoint's generated messages begin: after its last user
  # message, which is the input, since the loop appends only assistant
  # turns and tool results. Read from the checkpoint, a resumed run's
  # `Result.Completed.messages` stays exact whether or not the caller
  # passes the starting history again, and whatever it holds by now.
  defp resumed_prefix_len(messages, fallback) do
    case messages |> Enum.reverse() |> Enum.find_index(&match?(%UserMessage{}, &1)) do
      nil -> fallback
      from_end -> length(messages) - from_end
    end
  end

  # The skills loaded before the park are loaded again, from the agent's
  # current skills: the resume offers the tools the checkpointed messages
  # were written against. A skill the agent no longer offers is a
  # checkpoint this rollout cannot honor, as a gated tool it no longer
  # carries is.
  defp restore_skills(%Execution{} = exec, %Clementine.Checkpoint{skills: names} = checkpoint) do
    Enum.reduce_while(names, {:ok, exec}, fn name, {:ok, exec} ->
      case Enum.find(exec.skills, &(&1.name == name)) do
        %Skill{} = skill ->
          {:cont, {:ok, put_skill(exec, skill)}}

        nil ->
          {:halt,
           {:error,
            incompatible_checkpoint(
              "the checkpoint loaded skill #{inspect(name)}, which the agent no " <>
                "longer offers",
              checkpoint
            )}}
      end
    end)
  end

  defp pending_shape(%struct{}), do: inspect(struct)
  defp pending_shape(other), do: inspect(other)

  defp decode_checkpoint(%Clementine.Checkpoint{version: version} = checkpoint) do
    if version in Clementine.Checkpoint.versions() do
      {:ok, checkpoint}
    else
      {:error,
       incompatible_checkpoint(
         "unknown checkpoint version #{inspect(version)} " <>
           "(this engine reads #{inspect(Clementine.Checkpoint.versions())})",
         checkpoint
       )}
    end
  end

  defp decode_checkpoint(other), do: Clementine.Checkpoint.decode(other)

  # Resolving a pending approval completes the act it interrupted, before
  # the boundary decides whether the loop may gather again (RFC §The
  # Resume Flow, step 7) — so it owes the boundary's own checks first: a
  # cancel flagged after the claim must be honored before the gated call
  # executes, not one batch later. Approval executes the gated call in
  # this execution; denial synthesizes an error tool result carrying the
  # approver's message and lets the model react. Either way the batch
  # settles through the same path as a fresh act, so a batch holding
  # further gated calls parks again, one decision at a time. An approved
  # call to a {:policy, term} tool is put to the tool policy once more
  # (resolve_approved/5); a denied one is not.
  defp resolve_pending(%Execution{} = exec, %Pending.ToolApproval{} = pending, payload) do
    with :continue <- check_signals(),
         :continue <- check_deadline(exec),
         :continue <- check_cancel(exec),
         {:ok, pending_use, batch} <- pending_batch(exec, pending) do
      case payload do
        {:approved, _meta} ->
          resolve_approved(exec, pending, pending_use, batch, payload)

        {:denied, meta} ->
          denial = %Clementine.ToolResult{content: denial_message(meta), is_error: true}

          emit_event(exec, :tool_result, %{
            tool_use_id: pending_use.id,
            result: denial.content,
            is_error: true
          })

          record_tool_call(exec, pending_use, denial, 0,
            approval: payload,
            policy: pending.policy
          )

          settle_batch(exec, batch, Map.put(pending.completed_results, pending_use.id, denial))

        other ->
          fail(exec, invalid_resume_payload(other, pending))
      end
    else
      {:error, %Clementine.Error{} = error} -> fail(exec, error)
      unwound -> conclude(exec, unwound)
    end
  end

  # Resolving a pending delegation settles each waiting `delegate` call
  # with its child's outcome from the payload — or, for a call whose
  # child could not start, the refusal the park left in the checkpoint —
  # after the boundary's own checks, as an approval's resolve does. The
  # batch then settles through the same path as a fresh act: every other
  # call settled before the park, so it feeds back to the model.
  defp resolve_pending(%Execution{} = exec, %Pending.Delegation{} = pending, payload) do
    with :continue <- check_signals(),
         :continue <- check_deadline(exec),
         :continue <- check_cancel(exec),
         {:ok, batch} <- delegation_batch(exec, pending),
         {:ok, outcomes} <- delegated(pending, payload) do
      completed =
        batch
        |> Enum.filter(&Map.has_key?(pending.children, &1.id))
        |> Enum.reduce(pending.completed_results, fn call, completed ->
          child = Map.fetch!(pending.children, call.id)
          Map.put(completed, call.id, settle_child(exec, call, child, outcomes, completed))
        end)

      settle_batch(exec, batch, completed)
    else
      {:error, %Clementine.Error{} = error} -> fail(exec, error)
      unwound -> conclude(exec, unwound)
    end
  end

  # A child that ran settles from its outcome, and the trace records the
  # child (its id, agent, and how it ended) before the call; a call whose
  # child could not start settles with the refusal the park recorded.
  defp settle_child(%Execution{} = exec, call, child, outcomes, completed) do
    result =
      case Map.fetch(outcomes, call.id) do
        {:ok, outcome} ->
          record(exec, :delegate, Trace.delegate(exec.iteration, call.id, child, outcome))
          %ToolResult{content: outcome["content"], is_error: outcome["is_error"]}

        :error ->
          Map.fetch!(completed, call.id)
      end

    emit_event(exec, :tool_result, %{
      tool_use_id: call.id,
      result: result.content,
      is_error: result.is_error
    })

    record_tool_call(exec, call, result, 0)
    result
  end

  # The approved call runs with exactly the arguments approved, unless the
  # tool policy, asked once more, now denies it: then it settles as the
  # deny, and its trace entry carries the approval beside it.
  defp resolve_approved(%Execution{} = exec, pending, pending_use, batch, payload) do
    with {:ok, decision} <- reauthorize(exec, pending_use, pending),
         :continue <- after_host_code(exec, [pending_use]) do
      case decision do
        {:deny, verdict} ->
          completed =
            settle_denied(exec, pending_use, verdict, pending.completed_results,
              approval: payload
            )

          settle_batch(exec, batch, completed)

        {:run, verdict} ->
          verdicts = if verdict, do: %{pending_use.id => verdict}, else: %{}

          case execute_now(exec, [pending_use], pending.completed_results, payload, verdicts) do
            {:ok, %Execution{} = exec, completed} -> settle_batch(exec, batch, completed)
            {:error, %Clementine.Error{} = error} -> fail(exec, error)
            unwound -> conclude(exec, unwound)
          end
      end
    else
      {:unwind, unwound} -> conclude(exec, unwound)
      {:error, %Clementine.Error{} = error} -> fail(exec, error)
      unwound -> conclude(exec, unwound)
    end
  end

  # The checkpoint's last message must be the assistant turn whose calls
  # the delegation waits on, as for an approval: the batch is read back
  # from it.
  defp delegation_batch(%Execution{} = exec, %Pending.Delegation{} = pending) do
    batch =
      case List.last(exec.messages) do
        %AssistantMessage{} = message ->
          repair_tool_uses(exec, AssistantMessage.get_tool_uses(message), false)

        _other ->
          []
      end

    ids = MapSet.new(batch, & &1.id)

    case Enum.reject(Map.keys(pending.children), &MapSet.member?(ids, &1)) do
      [] ->
        {:ok, batch}

      missing ->
        {:error,
         incompatible_checkpoint(
           "pending delegate calls #{Enum.join(missing, ", ")} are not in the " <>
             "checkpoint's last assistant message",
           pending
         )}
    end
  end

  # The payload names an outcome for each child that ran; a child with
  # none must be one the park refused, its refusal already settled.
  defp delegated(%Pending.Delegation{} = pending, {:delegated, outcomes} = payload)
       when is_map(outcomes) do
    refused = pending.completed_results

    Enum.reduce_while(pending.children, {:ok, %{}}, fn {id, _child}, {:ok, acc} ->
      case Map.get(outcomes, id) do
        %{"content" => content, "is_error" => is_error} = outcome
        when is_binary(content) and is_boolean(is_error) ->
          {:cont, {:ok, Map.put(acc, id, outcome)}}

        nil when is_map_key(refused, id) ->
          {:cont, {:ok, acc}}

        _missing_or_malformed ->
          {:halt, {:error, invalid_resume_payload(payload, pending)}}
      end
    end)
  end

  defp delegated(%Pending.Delegation{} = pending, payload),
    do: {:error, invalid_resume_payload(payload, pending)}

  # The checkpoint's last message must be the assistant turn that issued
  # the pending call — the batch is read back from it, so sibling
  # coverage survives the suspension. A checkpoint that cannot support
  # its own pending operation, or that names a tool this rollout no
  # longer carries, is not understood (RFC §Doctrine: Snapshot, Not
  # Replay) — for a denial as much as an approval: the engine does not
  # guess at checkpoints it cannot fully resolve.
  defp pending_batch(%Execution{} = exec, %Pending.ToolApproval{} = pending) do
    batch =
      case List.last(exec.messages) do
        %AssistantMessage{} = message ->
          repair_tool_uses(exec, AssistantMessage.get_tool_uses(message), false)

        _other ->
          []
      end

    case Enum.find(batch, &(&1.id == pending.tool_use_id)) do
      nil ->
        {:error,
         incompatible_checkpoint(
           "pending tool call #{pending.tool_use_id} is not in the checkpoint's " <>
             "last assistant message",
           pending
         )}

      pending_use ->
        case Tool.find_by_name(exec.tools, pending.tool_name) do
          nil ->
            {:error,
             incompatible_checkpoint(
               "pending tool #{pending.tool_name} does not resolve in this " <>
                 "rollout's toolset",
               pending
             )}

          # The approved call runs with exactly the arguments approved:
          # the checkpointed ones, never a re-derivation from history.
          _tool when is_map(pending.args) ->
            {:ok, %{pending_use | input: pending.args}, batch}

          _tool ->
            {:error, incompatible_checkpoint("pending approval arguments are not a map", pending)}
        end
    end
  end

  @denial_message "Denied by approver."

  defp denial_message(%{message: message}) when is_binary(message), do: message
  defp denial_message(_meta), do: @denial_message

  defp invalid_resume_payload(payload, %Pending.ToolApproval{} = pending) do
    %Clementine.Error{
      kind: :rollout,
      code: :invalid_resume_payload,
      message:
        "resume payload #{inspect(payload)} cannot resolve the pending " <>
          "approval of tool #{pending.tool_name}; approval resumes take " <>
          "{:approved, meta} | {:denied, meta}",
      retryable?: false,
      raw: payload
    }
  end

  defp invalid_resume_payload(payload, %Pending.Delegation{} = pending) do
    %Clementine.Error{
      kind: :rollout,
      code: :invalid_resume_payload,
      message:
        "resume payload #{inspect(payload, limit: 5)} cannot resolve the pending " <>
          "delegation of #{map_size(pending.children)} call(s); a delegation resumes with " <>
          "{:delegated, %{tool_use_id => outcome}}, an outcome for each child that ran",
      retryable?: false,
      raw: payload
    }
  end

  defp incompatible_checkpoint(message, raw) do
    %Clementine.Error{
      kind: :rollout,
      code: :incompatible_checkpoint,
      message: message,
      retryable?: false,
      raw: raw
    }
  end

  # The iteration boundary: every check the loop owes between one Act and
  # the next Gather — runner signals, the execution deadline, the
  # cooperative cancel poll, and the iteration cap, in that order — and,
  # when the loop goes on, the trace write of what the last iteration did.
  # An exit here leaves the entries to the write that ends the run.
  defp boundary(%Execution{} = exec) do
    with :continue <- check_signals(),
         :continue <- check_deadline(exec),
         :continue <- check_cancel(exec),
         :continue <- check_iterations(exec),
         :continue <- flush_trace(exec) do
      gather(%{exec | iteration: exec.iteration + 1})
    else
      {:error, %Clementine.Error{} = error} -> fail(exec, error)
      unwound -> conclude(exec, unwound)
    end
  end

  defp check_signals do
    receive do
      {:clementine, :lease_lost, _lease} -> :lost_lease
      {:clementine, :drain} -> :drained
      {:clementine, :cancel, reason} -> {:cancelled, reason}
    after
      0 -> :continue
    end
  end

  defp check_deadline(%Execution{deadline: nil}), do: :continue

  defp check_deadline(%Execution{deadline: %DateTime{} = deadline}) do
    if DateTime.compare(DateTime.utc_now(), deadline) == :lt do
      :continue
    else
      {:error, Clementine.Error.normalize(:deadline_exceeded)}
    end
  end

  defp check_cancel(%Execution{cancel?: cancel?}) do
    case cancel?.() do
      :none -> :continue
      {:requested, reason} -> {:cancelled, reason}
      {:error, :lost_lease} -> :lost_lease
      # A transient fetch failure must not kill a healthy run; the poll is
      # best-effort and the next boundary re-asks.
      {:error, _transient} -> :continue
    end
  end

  defp check_iterations(%Execution{iteration: iteration, max_iterations: max})
       when iteration >= max do
    {:error, Clementine.Error.normalize(:max_iterations_reached)}
  end

  defp check_iterations(%Execution{}), do: :continue

  defp flush_trace(%Execution{recorder: nil}), do: :continue

  defp flush_trace(%Execution{recorder: recorder}) do
    case Recorder.flush(recorder) do
      :ok -> :continue
      :lost_lease -> :lost_lease
    end
  end

  # Every call to the model is recorded, and so is what it burned: a call
  # a signal aborts or a provider error ends keeps the usage its stream
  # reported (the input count from its start, the output so far), so a
  # cancelled or failed run is charged for it.
  defp gather(%Execution{} = exec) do
    emit_event(exec, :iteration_start, %{n: exec.iteration})

    case stream_response(exec) do
      {:ok, response, call} ->
        exec = record_usage(exec, response)
        record_model_call(exec, call, response.stop_reason, response.content)
        act(exec, response)

      {:signal, signal, partial, call} ->
        exec = record_usage(exec, partial)
        record_model_call(exec, call, nil, partial.content)
        conclude(exec, unwind(signal))

      {:error, reason, usage, call} ->
        exec = record_usage(exec, %{usage: usage})
        record_model_call(exec, call, nil, nil)
        fail(exec, Clementine.Error.normalize(reason))
    end
  end

  defp record_model_call(exec, call, stop_reason, content) do
    record(
      exec,
      :model_call,
      Trace.model_call(
        call.model,
        exec.iteration,
        to_ms(call.duration),
        stop_reason,
        call.usage,
        call.cost,
        content
      )
    )
  end

  # One model call as it is recorded: the model it ran on (the
  # execution's resolution), how long it took, what it burned, and what
  # that cost at the model's prices then. Its trace entry and its
  # telemetry event both read this, so they name the same model and the
  # same cost.
  defp metered(model, duration, usage) do
    usage = Clementine.Usage.new(usage)
    %{model: model, duration: duration, usage: usage, cost: Clementine.Cost.of(usage, model)}
  end

  defp stream_response(%Execution{} = exec) do
    alias Clementine.LLM.StreamParser.Accumulator

    model = exec.resolved
    tools = offered_tools(exec)

    metadata =
      Map.merge(identity(exec), %{
        iteration: exec.iteration,
        message_count: length(exec.messages),
        tool_count: length(tools),
        streaming: true
      })

    :telemetry.execute(
      [:clementine, :llm, :start],
      %{system_time: System.system_time()},
      metadata
    )

    started = System.monotonic_time()
    stream = LLM.stream(exec.model, exec.system, exec.messages, tools, stream_opts(exec))

    {acc, signal} =
      try do
        Enum.reduce_while(stream, {Accumulator.new(), nil}, fn
          {:signal, message}, {acc, _signal} ->
            {:halt, {acc, message}}

          event, {acc, nil} ->
            forward_stream_event(exec, event)
            {:cont, {Accumulator.process(acc, event), nil}}
        end)
      rescue
        e ->
          emit_llm_raise(metadata, started, :error, e, __STACKTRACE__)
          reraise e, __STACKTRACE__
      catch
        kind, reason ->
          emit_llm_raise(metadata, started, kind, reason, __STACKTRACE__)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    duration = System.monotonic_time() - started

    cond do
      signal != nil ->
        # Aborted by a runner signal: no provider stop_reason exists, and
        # the partial usage is what actually burned: the accumulator keeps
        # the input count the stream's start reported.
        call = metered(model, duration, acc.usage)
        emit_llm_stop(metadata, call, nil)
        emit_llm_usage(metadata, call, :aborted, nil)
        {:signal, signal, Accumulator.to_response(acc), call}

      Accumulator.error?(acc) ->
        # What the stream reported before the error burned too, and the
        # trace prices it, so the event carries it as stop does.
        call = metered(model, duration, acc.usage)
        {measurements, currency} = call_measurements(call)

        :telemetry.execute(
          [:clementine, :llm, :exception],
          measurements,
          Map.merge(metadata, %{
            kind: :error,
            reason: acc.error,
            error_code: Clementine.Error.normalize(acc.error).code,
            currency: currency
          })
        )

        emit_llm_usage(metadata, call, :error, nil)
        {:error, acc.error, acc.usage, call}

      true ->
        response = Accumulator.to_response(acc)
        call = metered(model, duration, response.usage)
        emit_llm_stop(metadata, call, response.stop_reason)
        emit_llm_usage(metadata, call, :stop, response.stop_reason)
        {:ok, response, call}
    end
  end

  defp emit_llm_stop(metadata, call, stop_reason) do
    {measurements, currency} = call_measurements(call)

    :telemetry.execute(
      [:clementine, :llm, :stop],
      measurements,
      Map.merge(metadata, %{stop_reason: stop_reason, currency: currency})
    )
  end

  # Every metered call, however it ended, in one event. The metrics count
  # calls and sum tokens and spend from it alone, so a total is one
  # series summed over `outcome`, never two series added, where an agent
  # missing from either side drops out of the sum.
  defp emit_llm_usage(metadata, call, outcome, stop_reason) do
    {measurements, currency} = call_measurements(call)

    :telemetry.execute(
      [:clementine, :llm, :usage],
      Map.delete(measurements, :duration),
      Map.merge(metadata, %{outcome: outcome, stop_reason: stop_reason, currency: currency})
    )
  end

  # A call's measurements, and the currency of its cost. A priced call
  # adds `cost_micros`; an unpriced one leaves it out rather than
  # reporting zero. The metrics read it through a function that returns
  # nil when it is missing, which every reporter skips: a missing atom
  # measurement is skipped by some reporters and counted as 1 by others
  # (Peep).
  defp call_measurements(%{duration: duration, usage: usage, cost: cost}) do
    measurements = %{
      duration: duration,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: usage.cache_read_tokens,
      cache_write_tokens: usage.cache_write_tokens
    }

    case cost do
      %Clementine.Cost{micros: micros, currency: currency} ->
        {Map.put(measurements, :cost_micros, micros), currency}

      nil ->
        {measurements, nil}
    end
  end

  # A raise meters nothing, so no usage event follows it. Its error code
  # is the one `Clementine.Error.from_exception/3` gives any raise.
  defp emit_llm_raise(metadata, started, kind, reason, stacktrace) do
    :telemetry.execute(
      [:clementine, :llm, :exception],
      %{duration: System.monotonic_time() - started},
      Map.merge(metadata, %{
        kind: kind,
        reason: reason,
        stacktrace: stacktrace,
        error_code: :exception,
        currency: nil
      })
    )
  end

  defp forward_stream_event(exec, {:text_delta, text}),
    do: emit_event(exec, :text_delta, %{content: text})

  defp forward_stream_event(exec, {:tool_use_start, id, name}),
    do: emit_event(exec, :tool_use_start, %{tool_use_id: id, name: name})

  defp forward_stream_event(exec, {:input_json_delta, id, chunk}),
    do: emit_event(exec, :tool_input_delta, %{tool_use_id: id, content: chunk})

  defp forward_stream_event(_exec, _event), do: :ok

  defp record_usage(%Execution{} = exec, response) do
    delta = Clementine.Usage.new(response.usage)

    if Clementine.Usage.total(delta) > 0 do
      emit_event(exec, :usage_delta, Map.from_struct(delta))
    end

    %{exec | usage: Clementine.Usage.add(exec.usage, delta)}
  end

  # A turn the provider paused mid-way through its own tools (a long tool
  # search) goes back as it stands, and the provider resumes it: one more
  # gather, bounded by the iteration cap like any other. The continuation
  # joins the paused turn's message, so history holds the turn as one
  # assistant message and the output is the whole turn's text.
  defp act(%Execution{} = exec, response) do
    exec = %{exec | messages: append_turn(exec, response.content), paused?: false}

    cond do
      LLM.tool_use?(response) ->
        act_on_tools(exec, LLM.get_tool_uses(response))

      LLM.paused?(response) ->
        boundary(%{exec | paused?: true})

      true ->
        case final_output(exec, List.last(exec.messages), response) do
          {:ok, output} ->
            conclude(
              exec,
              {:ok,
               Clementine.Result.completed(
                 input_message: exec.input_message,
                 messages: Enum.drop(exec.messages, exec.prefix_len),
                 output: output,
                 usage: exec.usage
               )}
            )

          {:error, %Clementine.Error{} = error} ->
            fail(exec, error)
        end
    end
  end

  defp append_turn(%Execution{paused?: true, messages: messages}, content) do
    %AssistantMessage{} = paused = List.last(messages)
    List.replace_at(messages, -1, %{paused | content: paused.content ++ content})
  end

  defp append_turn(%Execution{messages: messages}, content) do
    messages ++ [AssistantMessage.new(content)]
  end

  # The output is the final turn's text, the paused turn's included. An
  # agent with an output_schema answers in JSON: the output is the decoded
  # map of what the turn wrote last, after any search or thinking, and an
  # answer that does not decode or match fails the run
  # (Clementine.OutputSchema).
  defp final_output(%Execution{output_schema: nil}, %AssistantMessage{} = turn, _response),
    do: {:ok, AssistantMessage.get_text(turn)}

  defp final_output(%Execution{output_schema: schema}, %AssistantMessage{} = turn, response),
    do: Clementine.OutputSchema.decode(schema, turn.content, response.stop_reason)

  # A signal that arrived during the gather is already in the mailbox:
  # honor it before the fence write and before any tool starts — a
  # pending drain must not forfeit requeue eligibility, and a superseded
  # executor must not start new external effects.
  defp act_on_tools(%Execution{} = exec, tool_uses) do
    case check_signals() do
      :continue -> settle_batch(exec, repair_tool_uses(exec, tool_uses, true), %{})
      unwound -> conclude(exec, unwound)
    end
  end

  # The model's calls are normalized once, when its batch is acted on and
  # before anything is gated or executed, so an approver sees exactly the
  # arguments that will run (Clementine.ToolInput). History keeps the
  # model's own calls. `report?` is false when a resume re-reads a batch
  # already reported.
  defp repair_tool_uses(%Execution{} = exec, tool_uses, report?) do
    Enum.map(tool_uses, fn tool_use ->
      with %{} = input <- tool_use.input,
           parameters when is_list(parameters) <- parameters(exec, tool_use.name),
           {repaired, [_ | _] = fields} <-
             ToolInput.repair(input, parameters, tool: tool_use.name) do
        if report?, do: report_repair(exec, tool_use, fields)
        %{tool_use | input: repaired}
      else
        _ -> tool_use
      end
    end)
  end

  defp parameters(%Execution{} = exec, name) do
    case engine_tool(exec, name) do
      %EngineTool{parameters: parameters} ->
        parameters

      nil ->
        case Tool.find_by_name(exec.tools, name) do
          nil -> nil
          tool -> tool.__parameters__()
        end
    end
  end

  defp report_repair(%Execution{} = exec, tool_use, fields) do
    :telemetry.execute(
      [:clementine, :tool, :input_repaired],
      %{count: length(fields)},
      Map.merge(identity(exec), %{
        tool: tool_use.name,
        tool_call_id: tool_use.id,
        iteration: exec.iteration,
        fields: fields
      })
    )
  end

  # Settles one tool batch toward its ToolResultMessage, possibly across
  # suspensions: uncovered engine calls go first, since they change the
  # execution the rest resolve against — a call that settles now (a
  # skill load) settles in place, and a call that parks (a delegate) is
  # checked and held; the tool policy then answers for the calls whose
  # tools declare `{:policy, term}`, and a call it denies settles now,
  # running nothing; uncovered ungated calls execute now; then the first
  # uncovered approval-gated call parks the run — everything settled so
  # far rides in the checkpoint, so nothing is discarded and nothing
  # unsafe re-executes on resume. With no gated call left, held delegate
  # calls park the run once, for all their children. A fully covered
  # batch feeds back to the model. Resume re-enters here with the
  # decided call already settled, so a batch holding several gated calls
  # parks once per decision, and its delegate calls after the last.
  defp settle_batch(%Execution{} = exec, tool_uses, completed) do
    uncovered = Enum.reject(tool_uses, &Map.has_key?(completed, &1.id))
    {engine, world} = Enum.split_with(uncovered, &engine_tool(exec, &1.name))

    with {:ok, %Execution{} = exec, completed, held} <-
           settle_engine_calls(exec, engine, completed),
         :continue <- after_host_code(exec, engine) do
      settle_world(exec, tool_uses, repair_after_loads(exec, engine, world), completed, held)
    else
      {:error, %Clementine.Error{} = error} -> fail(exec, error)
      unwound -> conclude(exec, unwound)
    end
  end

  # Engine calls and the tool policy run host code (a skill's body, the
  # host's authorize_tool) through Clementine.HostCall, which unwinds on
  # a signal that lands while the code runs. One that lands just after is
  # honored here, before the fence write and before any tool starts, as
  # one that arrived during the gather is. Host code may also run out the
  # execution's deadline (HostCall's bound is the time left): that is
  # honored here too, so an expired execution neither starts tools nor
  # parks, which would hand the run a fresh budget on its resume. `calls`
  # are those whose settling ran host code; none means nothing ran.
  defp after_host_code(_exec, [] = _calls), do: :continue

  defp after_host_code(exec, _calls) do
    with :continue <- check_signals(), do: check_deadline(exec)
  end

  defp settle_world(%Execution{} = exec, tool_uses, world, completed, held) do
    # Each verdict is an answer the policy gave, so host code ran.
    with {:ok, {gated, ungated, completed, verdicts}} <- gate_calls(exec, world, completed),
         :continue <- after_host_code(exec, Map.keys(verdicts)) do
      case execute_now(exec, ungated, completed, nil, verdicts) do
        {:ok, %Execution{} = exec, completed} ->
          cond do
            gated != [] ->
              conclude(exec, {:suspend, suspension_request(exec, hd(gated), completed, verdicts)})

            held != %{} ->
              park_for_children(exec, held, completed)

            true ->
              finish_batch(exec, tool_uses, completed)
          end

        {:error, %Clementine.Error{} = error} ->
          fail(exec, error)

        unwound ->
          conclude(exec, unwound)
      end
    else
      {:error, %Clementine.Error{} = error} -> fail(exec, error)
      unwound -> conclude(exec, unwound)
    end
  end

  # Splits a batch's world calls into those that park for a decision and
  # those that run now, settling the ones the tool policy denies, one call
  # at a time, in batch order. `verdicts` holds the policy's answer for
  # each call it was asked about, for the trace entry the call gets when
  # it settles. A signal while the policy answers stops the split; the
  # answers given so far are on the trace already.
  defp gate_calls(%Execution{} = exec, world, completed) do
    world
    |> Enum.reduce_while({[], [], completed, %{}}, fn call, acc ->
      case gate(exec, call) do
        {:unwind, unwound} -> {:halt, {:unwind, unwound}}
        verdict -> {:cont, gate_call(call, verdict, acc, exec)}
      end
    end)
    |> case do
      {:unwind, unwound} ->
        unwound

      {gated, ungated, completed, verdicts} ->
        {:ok, {Enum.reverse(gated), Enum.reverse(ungated), completed, verdicts}}
    end
  end

  defp gate_call(call, verdict, {gated, ungated, completed, verdicts}, exec) do
    case verdict do
      :run ->
        {gated, [call | ungated], completed, verdicts}

      :park ->
        {[call | gated], ungated, completed, verdicts}

      :allow ->
        {gated, [call | ungated], completed, Map.put(verdicts, call.id, :allow)}

      :require_approval ->
        {[call | gated], ungated, completed, Map.put(verdicts, call.id, :require_approval)}

      denied ->
        completed = settle_denied(exec, call, denied, completed)
        {gated, ungated, completed, Map.put(verdicts, call.id, denied)}
    end
  end

  # :required parks every call for a decision. {:policy, term} asks the
  # tool policy, and without one parks like :required: a tool that
  # declares any approval requirement never executes unchecked. An
  # unresolvable tool name never executes anything — it settles as an
  # "Unknown tool" error result — so it is never gated.
  defp gate(%Execution{} = exec, call) do
    case Tool.find_by_name(exec.tools, call.name) do
      nil ->
        :run

      tool ->
        case Tool.approval(tool) do
          :never -> :run
          :required -> :park
          {:policy, _term} when exec.authorize_tool == nil -> :park
          {:policy, term} -> authorize(exec, call, term)
        end
    end
  end

  @policy_failed "Denied: the tool's policy check failed."

  # The host's answer for one call, asked with exactly the arguments that
  # would run, in a task bounded like a tool call (Clementine.HostCall).
  # Every answer is on the trace as it is given (a :policy entry), so a
  # run that parks or unwinds after it keeps it. Anything but an answer
  # the policy may give, a raise, or no answer in time denies the call
  # (fails closed) and is logged without the run's data; the model reads
  # only that the check failed.
  defp authorize(%Execution{authorize_tool: authorize_tool} = exec, call, term) do
    request = %ApprovalRequest{tool_use_id: call.id, tool_name: call.name, args: call.input}
    timeout = host_timeout(exec)

    case HostCall.run(fn -> authorize_tool.(request, term) end, timeout) do
      {:signal, signal} ->
        {:unwind, unwind(signal)}

      outcome ->
        verdict = verdict(call, outcome, timeout)
        record(exec, :policy, Trace.policy(exec.iteration, call, verdict))
        verdict
    end
  end

  defp verdict(_call, {:ok, :allow}, _timeout), do: :allow
  defp verdict(_call, {:ok, :require_approval}, _timeout), do: :require_approval

  defp verdict(_call, {:ok, {:deny, reason}}, _timeout) when is_binary(reason),
    do: {:deny, reason}

  defp verdict(call, {:ok, other}, _timeout) do
    policy_failed(
      call,
      "answered #{HostCall.shape(other)}, which is not :allow, :require_approval, or " <>
        "{:deny, reason} with a string reason"
    )
  end

  defp verdict(call, {:failed, kind, reason, stacktrace}, _timeout),
    do: policy_failed(call, HostCall.describe(kind, reason, stacktrace))

  defp verdict(call, :timeout, timeout),
    do: policy_failed(call, "did not answer within #{timeout} ms")

  defp policy_failed(call, why) do
    Logger.error(
      "authorize_tool for tool #{inspect(call.name)} (call #{call.id}) #{why}\n" <>
        "The call is denied."
    )

    {:failed, @policy_failed}
  end

  # An approval satisfies :require_approval, but not a policy that has
  # turned the call down since it parked: an approved call to a
  # {:policy, term} tool is asked about once more, and a deny (or a
  # failure) wins over the approval. :allow or :require_approval runs it,
  # the approval already given. Without a policy, or for a tool that no
  # longer declares one, the approval decides, and the trace keeps the
  # verdict that parked it.
  defp reauthorize(%Execution{authorize_tool: nil}, _call, pending),
    do: {:ok, {:run, pending.policy}}

  defp reauthorize(%Execution{} = exec, call, pending) do
    case Tool.approval(Tool.find_by_name(exec.tools, call.name)) do
      {:policy, term} ->
        case authorize(exec, call, term) do
          {:unwind, _unwound} = unwind -> unwind
          verdict when verdict in [:allow, :require_approval] -> {:ok, {:run, verdict}}
          denied -> {:ok, {:deny, denied}}
        end

      _declared ->
        {:ok, {:run, pending.policy}}
    end
  end

  # Host code runs no longer than a tool call may: the tool timeout or
  # the run's remaining time, whichever is less.
  defp host_timeout(%Execution{deadline: nil}), do: ToolRunner.default_timeout()

  defp host_timeout(%Execution{deadline: deadline}),
    do: min(ToolRunner.default_timeout(), remaining_ms(deadline))

  # A denied call runs nothing: it settles as the error result the model
  # reads, reported and traced like any settled call.
  defp settle_denied(%Execution{} = exec, call, verdict, completed, gate \\ []) do
    result = %ToolResult{content: elem(verdict, 1), is_error: true}

    emit_event(exec, :tool_result, %{
      tool_use_id: call.id,
      result: result.content,
      is_error: true
    })

    record_tool_call(exec, call, result, 0, Keyword.put(gate, :policy, verdict))
    Map.put(completed, call.id, result)
  end

  # The batch was repaired as it arrived, against the tools offered then;
  # a call to a tool a skill load in this batch just added was not, so the
  # rest of the batch is repaired again against the toolset the loads left.
  # A call already repaired has nothing left to repair.
  defp repair_after_loads(_exec, [] = _engine_calls, world), do: world
  defp repair_after_loads(exec, _engine_calls, world), do: repair_tool_uses(exec, world, true)

  defp engine_tool(%Execution{engine_tools: tools}, name) do
    Enum.find(tools, &(&1.name == name))
  end

  # Engine calls go in batch order, each against the execution the one
  # before left. A call that settles now is traced and reported like any
  # tool call; a call that parks comes back held, to settle on the
  # resume. They touch nothing outside the execution: no fence, no gate,
  # no runner.
  defp settle_engine_calls(%Execution{} = exec, calls, completed) do
    Enum.reduce_while(calls, {:ok, exec, completed, %{}}, fn call, {:ok, exec, completed, held} ->
      started = System.monotonic_time()

      case engine_call(exec, engine_tool(exec, call.name), call) do
        {exec, %ToolResult{} = result} ->
          emit_event(exec, :tool_result, %{
            tool_use_id: call.id,
            result: result.content,
            is_error: result.is_error
          })

          record_tool_call(exec, call, result, to_ms(System.monotonic_time() - started))
          {:cont, {:ok, exec, Map.put(completed, call.id, result), held}}

        {exec, {:park, child}} ->
          {:cont, {:ok, exec, completed, Map.put(held, call.id, child)}}

        {:unwind, unwound} ->
          {:halt, unwound}
      end
    end)
  end

  defp engine_call(%Execution{} = exec, %EngineTool{kind: :use_skill}, call),
    do: use_skill(exec, call)

  # A delegate call the engine can refuse from what it holds (an agent
  # not offered, a turn agent, no prompt) settles now as an error; any
  # other is held for the park, where the runtime starts its child.
  defp engine_call(%Execution{} = exec, %EngineTool{kind: :delegate}, call) do
    case Delegation.call(exec.delegates, call.input) do
      {:ok, child} -> {exec, {:park, child}}
      {:error, message} -> {exec, %ToolResult{content: message, is_error: true}}
    end
  end

  # Only a first load changes the execution: the skill's tools are
  # offered from the next model call on, and the checkpoint of a later
  # park names it. The load runs the skill's body, host code, in a task
  # bounded like a tool call (Clementine.HostCall): a body that does not
  # finish in time is an error the model reads, and a signal while it
  # runs unwinds the run with nothing loaded.
  defp use_skill(%Execution{} = exec, call) do
    %Execution{skills: skills, loaded_skills: loaded, context: context} = exec
    load = fn -> Skill.load(skills, loaded, call.input, context) end

    case HostCall.run(load, host_timeout(exec)) do
      {:ok, {:loaded, %Skill{} = skill, body, content}} ->
        record(exec, :skill_load, Trace.skill_load(exec.iteration, call.id, skill, body))
        {put_skill(exec, skill), %ToolResult{content: content, is_error: false}}

      {:ok, {:unchanged, content}} ->
        {exec, %ToolResult{content: content, is_error: false}}

      {:ok, {:error, content}} ->
        {exec, %ToolResult{content: content, is_error: true}}

      :timeout ->
        {exec, unloaded(call, "its body did not finish in time")}

      {:failed, _kind, _reason, _stacktrace} ->
        {exec, unloaded(call, "loading it failed")}

      {:signal, signal} ->
        {:unwind, unwind(signal)}
    end
  end

  defp unloaded(call, why) do
    name = if is_map(call.input), do: call.input["name"]

    %ToolResult{
      content: "The skill #{inspect(name)} could not be loaded: #{why}.",
      is_error: true
    }
  end

  defp put_skill(%Execution{} = exec, %Skill{} = skill) do
    %{
      exec
      | tools: exec.tools ++ Enum.reject(skill.tools, &(&1 in exec.tools)),
        loaded_skills: exec.loaded_skills ++ [skill.name]
    }
  end

  # The tools the model is offered: the modules, then the engine's own.
  defp offered_tools(%Execution{} = exec), do: exec.tools ++ exec.engine_tools

  defp offered_name(%Execution{} = exec, name) do
    if Tool.find_by_name(exec.tools, name) || engine_tool(exec, name), do: name
  end

  # Runs the calls that may execute in this pass — fence first, keyed to
  # exactly these calls: only code that runs now can cause an effect, so
  # a parked gated call contributes nothing to the fence decision — and
  # settles their normalized results into the batch map.
  # `approval` is the decision a resumed call ran under, and `verdicts`
  # the tool policy's answer for each call it was asked about, for their
  # trace entries.
  defp execute_now(%Execution{} = exec, [], completed, _approval, _verdicts),
    do: {:ok, exec, completed}

  defp execute_now(%Execution{} = exec, calls, completed, approval, verdicts) do
    tool_calls = Enum.map(calls, fn t -> %{id: t.id, name: t.name, input: t.input} end)
    context = Map.put(exec.context, :_clementine_iteration, exec.iteration)
    gates = Map.new(calls, &{&1.id, [approval: approval, policy: verdicts[&1.id]]})

    with {:continue, %Execution{} = exec} <- raise_fence(exec, calls) do
      uses = Map.new(calls, &{&1.id, &1})

      case ToolRunner.run_batch(exec.tools, tool_calls, context, batch_opts(exec)) do
        {:ok, results} ->
          settled =
            Enum.reduce(results, completed, fn {id, result, duration_ms}, completed ->
              emit_tool_result(exec, {id, result})
              completed = settle_result({id, result}, completed)

              record_tool_call(
                exec,
                Map.fetch!(uses, id),
                completed[id],
                duration_ms,
                Map.fetch!(gates, id)
              )

              completed
            end)

          {:ok, exec, settled}

        # The model never sees these, but they ran: the trace keeps them.
        {:cancelled, reason, settled} ->
          record_abandoned(exec, uses, settled, gates)
          {:cancelled, reason}

        {:drained, settled} ->
          record_abandoned(exec, uses, settled, gates)
          :drained

        :lost_lease ->
          :lost_lease
      end
    end
  end

  # A cancel or a drain cut the batch short: every call is still on the
  # record, the ones killed before they answered marked so, since what
  # they did is unknown.
  defp record_abandoned(exec, uses, settled, gates) do
    Enum.each(settled, fn
      {id, :killed, duration_ms} ->
        record_tool_call(exec, Map.fetch!(uses, id), :killed, duration_ms, Map.fetch!(gates, id))

      {id, result, duration_ms} ->
        %{^id => tool_result} = settle_result({id, result}, %{})

        record_tool_call(
          exec,
          Map.fetch!(uses, id),
          tool_result,
          duration_ms,
          Map.fetch!(gates, id)
        )
    end)
  end

  # A settled result keeps exactly the content and error flag the model
  # will see; callback metadata is advisory and does not survive the
  # checkpoint boundary.
  defp settle_result({id, result}, completed) do
    normalized = Clementine.ToolResult.normalize(result)

    Map.put(completed, id, %Clementine.ToolResult{
      content: Clementine.ToolResult.content(normalized),
      is_error: Clementine.ToolResult.error?(normalized)
    })
  end

  # `gate` is how the call came to run or not: `approval:`, the decision
  # it waited on, and `policy:`, the tool policy's verdict on it. A name
  # the agent does not offer is the model's text, not a tool's name: the
  # entry names no tool, and the result the model read says what it asked
  # for.
  defp record_tool_call(exec, tool_use, result, duration_ms, gate \\ []) do
    {content, is_error, killed} =
      case result do
        %Clementine.ToolResult{content: content, is_error: is_error} -> {content, is_error, false}
        :killed -> {nil, true, true}
      end

    record(
      exec,
      :tool_call,
      Trace.tool_call(%{
        iteration: exec.iteration,
        tool_use_id: tool_use.id,
        name: offered_name(exec, tool_use.name),
        args: tool_use.input,
        result: content,
        is_error: is_error,
        killed: killed,
        duration_ms: duration_ms,
        approval: Keyword.get(gate, :approval),
        policy: Keyword.get(gate, :policy)
      })
    )
  end

  # The batch is fully settled: results return to the model in tool-use
  # order, and the loop continues at the boundary.
  defp finish_batch(%Execution{} = exec, tool_uses, completed) do
    result_content =
      Enum.map(tool_uses, fn tool_use ->
        %Clementine.ToolResult{} = result = Map.fetch!(completed, tool_use.id)
        Content.tool_result(tool_use.id, result.content, result.is_error)
      end)

    boundary(%{exec | messages: exec.messages ++ [%ToolResultMessage{content: result_content}]})
  end

  # The suspension body: everything the rollout knows and nothing it does
  # not — the cursor and the token need the lease, which the rollout
  # never sees (RFC §Checkpoints And Suspension, assembly split).
  defp suspension_request(%Execution{} = exec, tool_use, completed, verdicts) do
    %Suspension.Request{
      reason:
        {:approval,
         %ApprovalRequest{
           tool_use_id: tool_use.id,
           tool_name: tool_use.name,
           args: tool_use.input
         }},
      pending: %Pending.ToolApproval{
        tool_use_id: tool_use.id,
        tool_name: tool_use.name,
        args: tool_use.input,
        completed_results: completed,
        policy: verdicts[tool_use.id]
      },
      messages: exec.messages,
      iteration: exec.iteration,
      skills: exec.loaded_skills,
      usage: exec.usage
    }
  end

  # The children start in the write that parks the run, so a drain, a
  # cancel pushed meanwhile, or a cancel flag already set is honored
  # first: nothing starts for a run that is going away.
  defp park_for_children(%Execution{} = exec, held, completed) do
    with :continue <- check_signals(),
         :continue <- check_cancel(exec) do
      conclude(exec, {:suspend, delegation_request(exec, held, completed)})
    else
      unwound -> conclude(exec, unwound)
    end
  end

  # The delegation's suspension body. The reason names no child yet: the
  # runtime that starts them fills in their ids, in the pending children
  # and in the reason, in the write that parks the run.
  defp delegation_request(%Execution{} = exec, held, completed) do
    %Suspension.Request{
      reason: {:external, {:delegation, []}},
      pending: %Pending.Delegation{children: held, completed_results: completed},
      messages: exec.messages,
      iteration: exec.iteration,
      skills: exec.loaded_skills,
      usage: exec.usage
    }
  end

  # The effect fence must be durable before the first effect exists — but
  # only batches that can cause one raise it: a batch of only retry: :safe
  # tools leaves the run requeue-eligible by those tools' own declaration.
  # A fence write that fails transiently fails the run closed — proceeding
  # unfenced would make a later requeue double-execute the batch.
  defp raise_fence(%Execution{fence_raised?: true} = exec, _tool_uses), do: {:continue, exec}

  defp raise_fence(%Execution{mark_effects: mark_effects} = exec, tool_uses) do
    if batch_effectful?(exec.tools, tool_uses) do
      case mark_effects.() do
        :ok -> {:continue, %{exec | fence_raised?: true}}
        {:error, :lost_lease} -> :lost_lease
        {:error, reason} -> {:error, Clementine.Error.normalize(reason)}
      end
    else
      {:continue, exec}
    end
  end

  # An unresolvable tool name never executes anything — it settles as an
  # "Unknown tool" error result — so it cannot produce an effect.
  defp batch_effectful?(tools, tool_uses) do
    Enum.any?(tool_uses, fn use ->
      case Tool.find_by_name(tools, use.name) do
        nil -> false
        tool -> Tool.retry(tool) != :safe
      end
    end)
  end

  defp stream_opts(%Execution{deadline: nil} = exec), do: request_opts(exec)

  defp stream_opts(%Execution{deadline: deadline} = exec) do
    [receive_timeout: min(@provider_receive_timeout, remaining_ms(deadline))] ++
      request_opts(exec)
  end

  defp request_opts(%Execution{} = exec) do
    deferred_opts(exec.deferred) ++
      output_schema_opts(exec.output_schema) ++ cache_key_opts(LLM.Cache.key(exec.context))
  end

  defp deferred_opts([]), do: []
  defp deferred_opts(deferred), do: [deferred: deferred]

  defp output_schema_opts(nil), do: []
  defp output_schema_opts(schema), do: [output_schema: schema]

  defp cache_key_opts(nil), do: []
  defp cache_key_opts(key), do: [cache_key: key]

  defp batch_opts(%Execution{deadline: nil} = exec), do: [metadata: identity(exec)]

  defp batch_opts(%Execution{deadline: deadline} = exec) do
    [
      timeout: min(ToolRunner.default_timeout(), remaining_ms(deadline)),
      metadata: identity(exec)
    ]
  end

  # Ceiling division: a cap computed by flooring could expire a hair
  # before the deadline instant, letting the boundary check pass once more.
  # Overshooting by under a millisecond is harmless — the boundary is the
  # enforcement, the cap only bounds the wait.
  defp remaining_ms(%DateTime{} = deadline) do
    deadline
    |> DateTime.diff(DateTime.utc_now(), :microsecond)
    |> max(0)
    |> Kernel.+(999)
    |> div(1000)
  end

  defp emit_tool_result(exec, {id, result}) do
    normalized = Clementine.ToolResult.normalize(result)

    emit_event(exec, :tool_result, %{
      tool_use_id: id,
      result: Clementine.ToolResult.content(normalized),
      is_error: Clementine.ToolResult.error?(normalized)
    })
  end

  defp unwind({:clementine, :lease_lost, _lease}), do: :lost_lease
  defp unwind({:clementine, :drain}), do: :drained
  defp unwind({:clementine, :cancel, reason}), do: {:cancelled, reason}

  defp fail(%Execution{} = exec, %Clementine.Error{} = error) do
    emit_event(exec, :error, %{error: error})
    conclude(exec, {:error, error})
  end

  # Every exit from the loop flows through here exactly once — at the site
  # that creates the terminal value, never the frames it propagates through.
  # Returned errors emit `:exception` (the legacy `:loop` reading, kept
  # across the rename); everything else is a `:stop` whose status names the
  # branch of the closed return set.
  defp conclude(%Execution{} = exec, result) do
    measurements = %{
      duration: System.monotonic_time() - exec.started_at,
      iterations: exec.iteration
    }

    case result do
      {:error, %Clementine.Error{} = error} ->
        :telemetry.execute(
          [:clementine, :rollout, :exception],
          measurements,
          Map.merge(identity(exec), %{kind: :error, reason: error, error_kind: error.kind})
        )

      _stopped ->
        :telemetry.execute(
          [:clementine, :rollout, :stop],
          measurements,
          Map.merge(identity(exec), %{status: stop_status(result)})
        )
    end

    result
  end

  defp stop_status({:ok, %Clementine.Result.Completed{}}), do: :success
  defp stop_status({:suspend, _request}), do: :suspended
  defp stop_status({:cancelled, _reason}), do: :cancelled
  defp stop_status(:drained), do: :drained
  defp stop_status(:lost_lease), do: :lost_lease

  # A genuine raise concludes no exit value, so `conclude/2` never sees it:
  # the span still terminates — `:exception` with the raise's kind and
  # stacktrace, no iteration count — and the raise continues to the
  # runner's rescue tier. Its error kind is the one the runner's rescue
  # gives it (`Clementine.Error.from_exception/3`).
  defp emit_rollout_raise(%Execution{} = exec, kind, reason, stacktrace) do
    :telemetry.execute(
      [:clementine, :rollout, :exception],
      %{duration: System.monotonic_time() - exec.started_at},
      Map.merge(identity(exec), %{
        kind: kind,
        reason: reason,
        stacktrace: stacktrace,
        error_kind: :runtime
      })
    )
  end

  # What this execution offers the model, once, before the model runs.
  # `agent_tools` are the agent's own, which the fingerprint covers.
  defp record_execution(%Execution{recorder: nil}, _agent_tools, _resumed?), do: :ok

  defp record_execution(%Execution{} = exec, agent_tools, resumed?) do
    record(
      exec,
      :execution,
      Trace.execution(exec.resolved, exec.system, agent_tools, resumed?,
        deferred: exec.deferred,
        output_schema: exec.output_schema,
        skills: exec.skills,
        delegates: delegate_entries(exec),
        offered: offered_tools(exec)
      )
    )
  end

  defp delegate_entries(%Execution{delegates: []}), do: []
  defp delegate_entries(%Execution{delegates: delegates}), do: Delegation.entries(delegates)

  @doc false
  # The agent key a rollout's records name: the run row's key, which the
  # runtime puts in the tool context (an in-process caller may name one
  # there too), else nil. Never the agent's `id`: an app may set that to
  # anything (a per-workspace id, say), and a metric label must stay a
  # key fixed in code.
  @spec agent_key(t()) :: String.t() | nil
  def agent_key(%__MODULE__{context: %{agent_key: key}}) when is_binary(key), do: key
  def agent_key(%__MODULE__{}), do: nil

  # What every rollout, llm, and tool event of the execution says it
  # ran: bounded values, fixed in code, that metrics may tag by
  # (`Clementine.Telemetry`).
  defp identity(%Execution{agent_key: agent_key, resolved: model}) do
    %{agent_key: agent_key, provider: model.provider, model: model.id, alias: model.alias}
  end

  defp record(%Execution{recorder: nil}, _kind, _payload), do: :ok

  defp record(%Execution{recorder: recorder, fidelity: fidelity}, kind, payload) do
    Recorder.record(recorder, kind, Trace.payload(kind, payload, fidelity))
  end

  defp to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)

  defp emit_event(%Execution{emit: nil}, _type, _payload), do: :ok

  defp emit_event(%Execution{emit: stamper}, type, payload) do
    Clementine.Events.Stamper.emit(stamper, type, payload)
  end
end
