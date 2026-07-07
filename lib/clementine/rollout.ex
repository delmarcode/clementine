defmodule Clementine.Rollout do
  @moduledoc """
  One inner agent execution: the Gather → Act loop, and the inert spec that
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

  Verification is deliberately not part of the inner loop: judging a result
  and deciding to retry is outer-control work (see `Clementine.Verifier` for
  the judge-function shape it uses).

  Formerly `Clementine.Loop`; renamed so `Loop` can name the outer control
  primitive.
  """

  alias Clementine.LLM.Message.{AssistantMessage, UserMessage}
  alias Clementine.LLM.Message.{Content, ToolResultMessage}
  alias Clementine.{ApprovalRequest, LLM, Pending, Suspension, Tool, ToolRunner}

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
  - `:messages` - starting message history (default `[]`)
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

    [
      model: agent.model,
      system: agent.instructions,
      tools: agent.tools,
      context: rollout.context,
      messages: rollout.messages,
      max_iterations: Keyword.get(limits(rollout), :max_iterations, @default_max_iterations)
    ]
  end

  defmodule Execution do
    @moduledoc false
    # Loop state for `execute/2`: the runner-supplied closures, the
    # accumulated typed usage, and `prefix_len` — where history + input end
    # and generated messages begin, so `Result.Completed` can separate the
    # two.
    defstruct [
      :model,
      :system,
      :tools,
      :context,
      :max_iterations,
      :emit,
      :cancel?,
      :mark_effects,
      :deadline,
      :input_message,
      :prefix_len,
      :started_at,
      messages: [],
      iteration: 0,
      usage: %Clementine.Usage{},
      fence_raised?: false
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
  Animates a rollout spec: the Gather → Act loop with the runner's execution
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
  - `:cancel?` - zero-arity closure over `Protocol.cancellation/1`, polled
    at iteration boundaries (before each gather, which is also after each
    tool batch).
  - `:mark_effects` - zero-arity closure over `Protocol.mark_effects/1`,
    called once, before the first tool batch containing a tool whose
    `retry` metadata is not `:safe` (`:unknown` is `:unsafe`). Batches of
    only `:safe` tools leave the fence down: nothing external can happen,
    so the run stays requeue-eligible.
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

    exec = %Execution{
      model: Keyword.fetch!(config, :model),
      system: Keyword.get(config, :system),
      tools: Keyword.get(config, :tools, []),
      context: Keyword.get(config, :context, %{}),
      max_iterations: Keyword.get(config, :max_iterations, @default_max_iterations),
      emit: Keyword.get(opts, :emit),
      cancel?: Keyword.get(opts, :cancel?, fn -> :none end),
      mark_effects: Keyword.get(opts, :mark_effects, fn -> :ok end),
      deadline: Keyword.get(opts, :deadline),
      input_message: input_message,
      prefix_len: length(rollout.messages) + 1,
      started_at: System.monotonic_time()
    }

    :telemetry.execute(
      [:clementine, :rollout, :start],
      %{system_time: System.system_time()},
      %{model: exec.model, max_iterations: exec.max_iterations, tool_count: length(exec.tools)}
    )

    try do
      case restore(exec, Keyword.get(opts, :resume), rollout) do
        {:ok, %Execution{} = exec} ->
          boundary(exec)

        {:resolve, %Execution{} = exec, pending, payload} ->
          resolve_pending(exec, pending, payload)

        {:error, %Clementine.Error{} = error} ->
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

  # Fresh start: history, then the materialized input message.
  defp restore(%Execution{} = exec, nil, rollout) do
    {:ok, %{exec | messages: rollout.messages ++ [exec.input_message]}}
  end

  # Resume is snapshot restoration: the checkpoint's messages already
  # contain history and input, so nothing is re-appended. A pending
  # operation is the act the suspension interrupted; the payload resolves
  # it before the loop may gather again.
  defp restore(%Execution{} = exec, {checkpoint, payload}, _rollout) do
    with {:ok, %Clementine.Checkpoint{} = checkpoint} <- decode_checkpoint(checkpoint) do
      exec = %{
        exec
        | messages: checkpoint.messages,
          iteration: checkpoint.iteration,
          usage: checkpoint.usage
      }

      # Shapes beyond ToolApproval are deliberately unspecified until their
      # reasons activate; a checkpoint carrying one is exactly "content no
      # longer understood" and takes the doctrine's incompatible path — a
      # decoded envelope already fails inside decode, so this arm guards
      # host-built structs.
      case checkpoint.pending do
        nil ->
          {:ok, exec}

        %Pending.ToolApproval{} = pending ->
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

  defp pending_shape(%struct{}), do: inspect(struct)
  defp pending_shape(other), do: inspect(other)

  defp decode_checkpoint(%Clementine.Checkpoint{version: version} = checkpoint) do
    if version == Clementine.Checkpoint.version() do
      {:ok, checkpoint}
    else
      {:error,
       incompatible_checkpoint(
         "unknown checkpoint version #{inspect(version)} " <>
           "(current: #{Clementine.Checkpoint.version()})",
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
  # further gated calls parks again, one decision at a time.
  defp resolve_pending(%Execution{} = exec, %Pending.ToolApproval{} = pending, payload) do
    with :continue <- check_signals(),
         :continue <- check_deadline(exec),
         :continue <- check_cancel(exec),
         {:ok, pending_use, batch} <- pending_batch(exec, pending) do
      case payload do
        {:approved, _meta} ->
          case execute_now(exec, [pending_use], pending.completed_results) do
            {:ok, %Execution{} = exec, completed} -> settle_batch(exec, batch, completed)
            {:error, %Clementine.Error{} = error} -> fail(exec, error)
            unwound -> conclude(exec, unwound)
          end

        {:denied, meta} ->
          denial = %Clementine.ToolResult{content: denial_message(meta), is_error: true}

          emit_event(exec, :tool_result, %{
            tool_use_id: pending_use.id,
            result: denial.content,
            is_error: true
          })

          settle_batch(exec, batch, Map.put(pending.completed_results, pending_use.id, denial))

        other ->
          fail(exec, invalid_resume_payload(other, pending))
      end
    else
      {:error, %Clementine.Error{} = error} -> fail(exec, error)
      unwound -> conclude(exec, unwound)
    end
  end

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
        %AssistantMessage{} = message -> AssistantMessage.get_tool_uses(message)
        _other -> []
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

          _tool ->
            {:ok, pending_use, batch}
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
  # cooperative cancel poll, and the iteration cap, in that order.
  defp boundary(%Execution{} = exec) do
    with :continue <- check_signals(),
         :continue <- check_deadline(exec),
         :continue <- check_cancel(exec),
         :continue <- check_iterations(exec) do
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

  defp gather(%Execution{} = exec) do
    emit_event(exec, :iteration_start, %{n: exec.iteration})

    case stream_response(exec) do
      {:ok, response} -> act(record_usage(exec, response), response)
      {:signal, signal} -> conclude(exec, unwind(signal))
      {:error, reason} -> fail(exec, Clementine.Error.normalize(reason))
    end
  end

  defp stream_response(%Execution{} = exec) do
    alias Clementine.LLM.StreamParser.Accumulator

    metadata = %{
      model: exec.model,
      iteration: exec.iteration,
      message_count: length(exec.messages),
      tool_count: length(exec.tools),
      streaming: true
    }

    :telemetry.execute(
      [:clementine, :llm, :start],
      %{system_time: System.system_time()},
      metadata
    )

    started = System.monotonic_time()
    stream = LLM.stream(exec.model, exec.system, exec.messages, exec.tools, stream_opts(exec))

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
        # the partial usage is what actually burned.
        emit_llm_stop(metadata, duration, Clementine.Usage.new(acc.usage), nil)
        {:signal, signal}

      Accumulator.error?(acc) ->
        :telemetry.execute(
          [:clementine, :llm, :exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: acc.error})
        )

        {:error, acc.error}

      true ->
        response = Accumulator.to_response(acc)

        emit_llm_stop(
          metadata,
          duration,
          Clementine.Usage.new(response.usage),
          response.stop_reason
        )

        {:ok, response}
    end
  end

  defp emit_llm_stop(metadata, duration, %Clementine.Usage{} = usage, stop_reason) do
    :telemetry.execute(
      [:clementine, :llm, :stop],
      %{
        duration: duration,
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens
      },
      Map.put(metadata, :stop_reason, stop_reason)
    )
  end

  defp emit_llm_raise(metadata, started, kind, reason, stacktrace) do
    :telemetry.execute(
      [:clementine, :llm, :exception],
      %{duration: System.monotonic_time() - started},
      Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
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
      emit_event(exec, :usage_delta, %{
        input_tokens: delta.input_tokens,
        output_tokens: delta.output_tokens
      })
    end

    %{exec | usage: Clementine.Usage.add(exec.usage, delta)}
  end

  defp act(%Execution{} = exec, response) do
    exec = %{exec | messages: exec.messages ++ [AssistantMessage.new(response.content)]}

    if LLM.tool_use?(response) do
      act_on_tools(exec, LLM.get_tool_uses(response))
    else
      conclude(
        exec,
        {:ok,
         Clementine.Result.completed(
           input_message: exec.input_message,
           messages: Enum.drop(exec.messages, exec.prefix_len),
           output: LLM.get_text(response),
           usage: exec.usage
         )}
      )
    end
  end

  # A signal that arrived during the gather is already in the mailbox:
  # honor it before the fence write and before any tool starts — a
  # pending drain must not forfeit requeue eligibility, and a superseded
  # executor must not start new external effects.
  defp act_on_tools(%Execution{} = exec, tool_uses) do
    case check_signals() do
      :continue -> settle_batch(exec, tool_uses, %{})
      unwound -> conclude(exec, unwound)
    end
  end

  # Settles one tool batch toward its ToolResultMessage, possibly across
  # suspensions: uncovered ungated calls execute now; then the first
  # uncovered approval-gated call parks the run — everything settled so
  # far rides in the checkpoint, so nothing is discarded and nothing
  # unsafe re-executes on resume — and a fully covered batch feeds back
  # to the model. Resume re-enters here with the decided call already
  # settled, so a batch holding several gated calls parks once per
  # decision.
  defp settle_batch(%Execution{} = exec, tool_uses, completed) do
    uncovered = Enum.reject(tool_uses, &Map.has_key?(completed, &1.id))
    {gated, ungated} = Enum.split_with(uncovered, &approval_gated?(exec.tools, &1))

    case execute_now(exec, ungated, completed) do
      {:ok, %Execution{} = exec, completed} ->
        case gated do
          [] ->
            finish_batch(exec, tool_uses, completed)

          [next | _later] ->
            conclude(exec, {:suspend, suspension_request(exec, next, completed)})
        end

      {:error, %Clementine.Error{} = error} ->
        fail(exec, error)

      unwound ->
        conclude(exec, unwound)
    end
  end

  # {:policy, _} is reserved and unresolved in this engine version, so it
  # gates exactly like :required: a tool that declares any approval
  # requirement never executes without a decision. An unresolvable tool
  # name never executes anything — it settles as an "Unknown tool" error
  # result — so it cannot be gated either.
  defp approval_gated?(tools, tool_use) do
    case Tool.find_by_name(tools, tool_use.name) do
      nil -> false
      tool -> Tool.approval(tool) != :never
    end
  end

  # Runs the calls that may execute in this pass — fence first, keyed to
  # exactly these calls: only code that runs now can cause an effect, so
  # a parked gated call contributes nothing to the fence decision — and
  # settles their normalized results into the batch map.
  defp execute_now(%Execution{} = exec, [], completed), do: {:ok, exec, completed}

  defp execute_now(%Execution{} = exec, calls, completed) do
    tool_calls = Enum.map(calls, fn t -> %{id: t.id, name: t.name, input: t.input} end)
    context = Map.put(exec.context, :_clementine_iteration, exec.iteration)

    with {:continue, %Execution{} = exec} <- raise_fence(exec, calls),
         {:ok, results} <-
           ToolRunner.run_batch(exec.tools, tool_calls, context, batch_opts(exec)) do
      Enum.each(results, &emit_tool_result(exec, &1))
      {:ok, exec, Enum.reduce(results, completed, &settle_result/2)}
    end
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
  defp suspension_request(%Execution{} = exec, tool_use, completed) do
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
        completed_results: completed
      },
      messages: exec.messages,
      iteration: exec.iteration,
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

  defp stream_opts(%Execution{deadline: nil}), do: []

  defp stream_opts(%Execution{deadline: deadline}) do
    [receive_timeout: min(@provider_receive_timeout, remaining_ms(deadline))]
  end

  defp batch_opts(%Execution{deadline: nil}), do: []

  defp batch_opts(%Execution{deadline: deadline}) do
    [timeout: min(ToolRunner.default_timeout(), remaining_ms(deadline))]
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
          %{model: exec.model, kind: :error, reason: error}
        )

      _stopped ->
        :telemetry.execute(
          [:clementine, :rollout, :stop],
          measurements,
          %{model: exec.model, status: stop_status(result)}
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
  # runner's rescue tier.
  defp emit_rollout_raise(%Execution{} = exec, kind, reason, stacktrace) do
    :telemetry.execute(
      [:clementine, :rollout, :exception],
      %{duration: System.monotonic_time() - exec.started_at},
      %{model: exec.model, kind: kind, reason: reason, stacktrace: stacktrace}
    )
  end

  defp emit_event(%Execution{emit: nil}, _type, _payload), do: :ok

  defp emit_event(%Execution{emit: stamper}, type, payload) do
    Clementine.Events.Stamper.emit(stamper, type, payload)
  end
end
