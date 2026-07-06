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
  - Max iterations reached
  - An unrecoverable error occurs

  Verification is deliberately not part of the inner loop: judging a result
  and deciding to retry is outer-control work (see `Clementine.Verifier` for
  the judge-function shape it uses).

  Formerly `Clementine.Loop`; renamed so `Loop` can name the outer control
  primitive.
  """

  alias Clementine.LLM.Message.{AssistantMessage, UserMessage}
  alias Clementine.LLM.Message.ToolResultMessage
  alias Clementine.{LLM, Tool, ToolRunner}

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
    restores loop state from the checkpoint. An unreadable or incompatible
    checkpoint returns `{:error, %Error{code: :incompatible_checkpoint}}` —
    never a crash and never a bare atom.
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
      prefix_len: length(rollout.messages) + 1
    }

    case restore(exec, Keyword.get(opts, :resume), rollout) do
      {:ok, %Execution{} = exec} -> boundary(exec)
      {:error, %Clementine.Error{} = error} -> fail(exec, error)
    end
  end

  # Fresh start: history, then the materialized input message.
  defp restore(%Execution{} = exec, nil, rollout) do
    {:ok, %{exec | messages: rollout.messages ++ [exec.input_message]}}
  end

  # Resume is snapshot restoration: the checkpoint's messages already
  # contain history and input, so nothing is re-appended. The payload
  # resolves the pending operation — a capability that arrives with gated
  # tools; until then any pending content is "not understood" and takes the
  # incompatible-checkpoint path the doctrine prescribes.
  defp restore(%Execution{} = exec, {checkpoint, _payload}, _rollout) do
    with {:ok, %Clementine.Checkpoint{} = checkpoint} <- decode_checkpoint(checkpoint),
         :ok <- pending_supported(checkpoint) do
      {:ok,
       %{
         exec
         | messages: checkpoint.messages,
           iteration: checkpoint.iteration,
           usage: checkpoint.usage
       }}
    end
  end

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

  defp pending_supported(%Clementine.Checkpoint{pending: nil}), do: :ok

  defp pending_supported(%Clementine.Checkpoint{pending: pending} = checkpoint) do
    {:error,
     incompatible_checkpoint(
       "pending operation #{inspect(pending.__struct__)} is not resolvable " <>
         "by this engine version",
       checkpoint
     )}
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
      unwound -> unwound
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
      {:signal, signal} -> unwind(signal)
      {:error, reason} -> fail(exec, Clementine.Error.normalize(reason))
    end
  end

  defp stream_response(%Execution{} = exec) do
    alias Clementine.LLM.StreamParser.Accumulator

    stream = LLM.stream(exec.model, exec.system, exec.messages, exec.tools, stream_opts(exec))

    {acc, signal} =
      Enum.reduce_while(stream, {Accumulator.new(), nil}, fn
        {:signal, message}, {acc, _signal} ->
          {:halt, {acc, message}}

        event, {acc, nil} ->
          forward_stream_event(exec, event)
          {:cont, {Accumulator.process(acc, event), nil}}
      end)

    cond do
      signal != nil -> {:signal, signal}
      Accumulator.error?(acc) -> {:error, acc.error}
      true -> {:ok, Accumulator.to_response(acc)}
    end
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
      {:ok,
       Clementine.Result.completed(
         input_message: exec.input_message,
         messages: Enum.drop(exec.messages, exec.prefix_len),
         output: LLM.get_text(response),
         usage: exec.usage
       )}
    end
  end

  defp act_on_tools(%Execution{} = exec, tool_uses) do
    with :continue <- check_approval_gate(exec, tool_uses),
         {:continue, exec} <- raise_fence(exec, tool_uses) do
      run_tool_batch(exec, tool_uses)
    else
      {:error, %Clementine.Error{} = error} -> fail(exec, error)
      unwound -> unwound
    end
  end

  # Suspend-for-approval arrives with gated tools; until this engine can
  # park a run for a decision, executing an approval-gated tool ungated
  # would silently dishonor the tool's own declaration — so it fails
  # closed instead, exactly like a pending operation it cannot resolve.
  defp check_approval_gate(%Execution{tools: tools}, tool_uses) do
    gated =
      Enum.find(tool_uses, fn use ->
        case Tool.find_by_name(tools, use.name) do
          nil -> false
          tool -> Tool.approval(tool) != :never
        end
      end)

    case gated do
      nil ->
        :continue

      %{name: name} ->
        {:error,
         %Clementine.Error{
           kind: :rollout,
           code: :approval_unsupported,
           message:
             "tool #{name} declares approval gating, which this engine version " <>
               "cannot honor yet (suspend-for-approval arrives with gated tools)",
           retryable?: false
         }}
    end
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

  defp run_tool_batch(%Execution{} = exec, tool_uses) do
    tool_calls = Enum.map(tool_uses, fn t -> %{id: t.id, name: t.name, input: t.input} end)
    context = Map.put(exec.context, :_clementine_iteration, exec.iteration)

    case ToolRunner.run_batch(exec.tools, tool_calls, context, batch_opts(exec)) do
      {:ok, results} ->
        Enum.each(results, &emit_tool_result(exec, &1))
        result_content = ToolRunner.format_results(results)

        boundary(%{
          exec
          | messages: exec.messages ++ [%ToolResultMessage{content: result_content}]
        })

      # The kill policy already ran inside the batch await; the loop stops
      # here, before the next gather.
      {:cancelled, reason} ->
        {:cancelled, reason}

      unwound when unwound in [:lost_lease, :drained] ->
        unwound
    end
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
    {:error, error}
  end

  defp emit_event(%Execution{emit: nil}, _type, _payload), do: :ok

  defp emit_event(%Execution{emit: stamper}, type, payload) do
    Clementine.Events.Stamper.emit(stamper, type, payload)
  end
end
