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
  alias Clementine.{LLM, ToolRunner}

  @default_max_iterations 10

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
  Lowers a rollout spec into the keyword config the engine functions accept.

  Agent defaults merge under rollout limits (the rollout wins).
  """
  @spec to_config(t()) :: keyword()
  def to_config(%__MODULE__{} = rollout) do
    %Clementine.Agent{} = agent = rollout.agent
    limits = Keyword.merge(agent.defaults, rollout.limits)

    [
      model: agent.model,
      system: agent.instructions,
      tools: agent.tools,
      context: rollout.context,
      messages: rollout.messages,
      max_iterations: Keyword.get(limits, :max_iterations, @default_max_iterations)
    ]
  end

  defmodule State do
    @moduledoc """
    State maintained during loop execution.
    """
    defstruct [
      :model,
      :system,
      :tools,
      :context,
      :max_iterations,
      :on_event,
      :loop_start_time,
      messages: [],
      iteration: 0
    ]

    @type t :: %__MODULE__{
            model: Clementine.LLM.ModelRegistry.model_ref(),
            system: String.t() | nil,
            tools: [module()],
            context: map(),
            max_iterations: pos_integer(),
            on_event: (term() -> any()) | nil,
            loop_start_time: integer() | nil,
            messages: [Clementine.LLM.Message.message()],
            iteration: non_neg_integer()
          }
  end

  @type result :: {:ok, String.t(), [Clementine.LLM.Message.message()]} | {:error, term()}

  @doc """
  Runs the agentic loop with the given configuration.

  ## Parameters

  - `config` - Keyword list with:
    - `:model` - Model reference (required): alias atom (e.g. `:claude_sonnet`) or `{provider, id}` tuple
    - `:system` - System prompt
    - `:tools` - List of tool modules
    - `:context` - Context map for tools
    - `:max_iterations` - Maximum loop iterations (default: 10)
    - `:messages` - Initial message history
    - `:on_event` - Optional callback for events

  - `prompt` - The user prompt to execute

  ## Returns

  - `{:ok, result, messages}` - Success with final text and updated message history
  - `{:error, reason}` - Failure with error reason

  """
  def run(config, prompt) when is_list(config) and is_binary(prompt) do
    state = %State{
      model: Keyword.fetch!(config, :model),
      system: Keyword.get(config, :system),
      tools: Keyword.get(config, :tools, []),
      context: Keyword.get(config, :context, %{}),
      max_iterations: Keyword.get(config, :max_iterations, @default_max_iterations),
      on_event: Keyword.get(config, :on_event),
      messages: Keyword.get(config, :messages, []),
      loop_start_time: System.monotonic_time()
    }

    # Add user message
    state = %{state | messages: state.messages ++ [UserMessage.new(prompt)]}

    emit_event(state, {:loop_start, prompt})

    :telemetry.execute(
      [:clementine, :loop, :start],
      %{system_time: System.system_time()},
      %{model: state.model, max_iterations: state.max_iterations, tool_count: length(state.tools)}
    )

    iterate(state)
  end

  # Main iteration function
  defp iterate(%State{iteration: iteration, max_iterations: max} = state)
       when iteration >= max do
    emit_event(state, {:loop_end, :max_iterations})

    :telemetry.execute(
      [:clementine, :loop, :stop],
      %{duration: System.monotonic_time() - state.loop_start_time, iterations: state.iteration},
      %{model: state.model, status: :max_iterations}
    )

    {:error, :max_iterations_reached}
  end

  defp iterate(%State{} = state) do
    state = %{state | iteration: state.iteration + 1}
    emit_event(state, {:iteration_start, state.iteration})

    case call_llm(state) do
      {:ok, response} ->
        handle_response(state, response)

      {:error, reason} ->
        emit_event(state, {:loop_end, {:error, reason}})

        :telemetry.execute(
          [:clementine, :loop, :exception],
          %{
            duration: System.monotonic_time() - state.loop_start_time,
            iterations: state.iteration
          },
          %{model: state.model, kind: :error, reason: reason}
        )

        {:error, reason}
    end
  end

  # Call the LLM
  defp call_llm(%State{} = state) do
    emit_event(state, :llm_call_start)

    llm_start = System.monotonic_time()

    :telemetry.execute(
      [:clementine, :llm, :start],
      %{system_time: System.system_time()},
      %{
        model: state.model,
        iteration: state.iteration,
        message_count: length(state.messages),
        tool_count: length(state.tools),
        streaming: false
      }
    )

    result =
      LLM.call(
        state.model,
        state.system,
        state.messages,
        state.tools
      )

    llm_duration = System.monotonic_time() - llm_start

    case result do
      {:ok, response} ->
        :telemetry.execute(
          [:clementine, :llm, :stop],
          %{
            duration: llm_duration,
            input_tokens: get_in(response.usage, ["input_tokens"]) || 0,
            output_tokens: get_in(response.usage, ["output_tokens"]) || 0
          },
          %{
            model: state.model,
            iteration: state.iteration,
            stop_reason: response.stop_reason,
            streaming: false
          }
        )

      {:error, reason} ->
        :telemetry.execute(
          [:clementine, :llm, :exception],
          %{duration: llm_duration},
          %{
            model: state.model,
            iteration: state.iteration,
            kind: :error,
            reason: reason,
            streaming: false
          }
        )
    end

    emit_event(state, {:llm_call_end, result})
    result
  end

  # Handle LLM response
  defp handle_response(%State{} = state, response) do
    # Add assistant message to history
    state = %{state | messages: state.messages ++ [AssistantMessage.new(response.content)]}

    if LLM.tool_use?(response) do
      handle_tool_use(state, response)
    else
      handle_final_response(state, response)
    end
  end

  # Handle tool use response
  defp handle_tool_use(%State{} = state, response) do
    tool_uses = LLM.get_tool_uses(response)
    emit_event(state, {:tool_use, tool_uses})

    # Convert tool uses to tool runner format
    tool_calls =
      Enum.map(tool_uses, fn t ->
        %{id: t.id, name: t.name, input: t.input}
      end)

    # Execute tools (per-tool telemetry is emitted by ToolRunner)
    context = Map.put(state.context, :_clementine_iteration, state.iteration)
    results = ToolRunner.execute(state.tools, tool_calls, context)
    emit_event(state, {:tool_results, results})

    # Format results for the conversation
    result_content = ToolRunner.format_results(results)

    # Add tool results as user message
    state = %{state | messages: state.messages ++ [%ToolResultMessage{content: result_content}]}

    # Continue the loop
    iterate(state)
  end

  # Handle final response (no tool use)
  defp handle_final_response(%State{} = state, response) do
    text = LLM.get_text(response)
    emit_event(state, {:final_text, text})
    emit_event(state, {:loop_end, :success})

    :telemetry.execute(
      [:clementine, :loop, :stop],
      %{
        duration: System.monotonic_time() - state.loop_start_time,
        iterations: state.iteration
      },
      %{model: state.model, status: :success}
    )

    {:ok, text, state.messages}
  end

  # Emit events for callbacks
  defp emit_event(%State{on_event: nil}, _event), do: :ok

  defp emit_event(%State{on_event: callback}, event) when is_function(callback, 1) do
    try do
      callback.(event)
    rescue
      _ -> :ok
    end
  end

  @doc """
  Runs the loop with streaming output.

  Similar to `run/2` but streams text deltas in real-time via the callback.
  The callback receives events like:

  - `{:text_delta, text}` - Text chunk from the model
  - `{:tool_use_start, id, name}` - Model is calling a tool
  - `{:tool_result, id, result}` - Tool execution result
  - `{:error, reason}` - Streaming error from the LLM
  - `{:loop_event, event}` - Internal loop events (iteration_start, etc.)

  Returns `{:ok, text, messages}` on success or `{:error, reason}` if the stream errors.

  ## Example

      Clementine.Loop.run_stream(config, "Hello", fn
        {:text_delta, text} -> IO.write(text)
        {:tool_use_start, _id, name} -> IO.puts("\\n[Calling \#{name}...]")
        _ -> :ok
      end)

  """
  def run_stream(config, prompt, stream_callback) when is_function(stream_callback, 1) do
    state = %State{
      model: Keyword.fetch!(config, :model),
      system: Keyword.get(config, :system),
      tools: Keyword.get(config, :tools, []),
      context: Keyword.get(config, :context, %{}),
      max_iterations: Keyword.get(config, :max_iterations, @default_max_iterations),
      on_event: fn event -> stream_callback.({:loop_event, event}) end,
      messages: Keyword.get(config, :messages, []),
      loop_start_time: System.monotonic_time()
    }

    # Add user message
    state = %{state | messages: state.messages ++ [UserMessage.new(prompt)]}

    emit_event(state, {:loop_start, prompt})

    :telemetry.execute(
      [:clementine, :loop, :start],
      %{system_time: System.system_time()},
      %{model: state.model, max_iterations: state.max_iterations, tool_count: length(state.tools)}
    )

    iterate_streaming(state, stream_callback)
  end

  # Streaming iteration - uses LLM.stream instead of LLM.call
  defp iterate_streaming(%State{iteration: iteration, max_iterations: max} = state, _callback)
       when iteration >= max do
    emit_event(state, {:loop_end, :max_iterations})

    :telemetry.execute(
      [:clementine, :loop, :stop],
      %{duration: System.monotonic_time() - state.loop_start_time, iterations: state.iteration},
      %{model: state.model, status: :max_iterations}
    )

    {:error, :max_iterations_reached}
  end

  defp iterate_streaming(%State{} = state, stream_callback) do
    state = %{state | iteration: state.iteration + 1}
    emit_event(state, {:iteration_start, state.iteration})

    case call_llm_streaming(state, stream_callback) do
      {:ok, response} ->
        handle_response_streaming(state, response, stream_callback)

      {:error, reason} ->
        emit_event(state, {:loop_end, {:error, reason}})

        :telemetry.execute(
          [:clementine, :loop, :exception],
          %{
            duration: System.monotonic_time() - state.loop_start_time,
            iterations: state.iteration
          },
          %{model: state.model, kind: :error, reason: reason}
        )

        {:error, reason}
    end
  end

  # Streaming LLM call - emits text deltas as they arrive
  defp call_llm_streaming(%State{} = state, stream_callback) do
    emit_event(state, :llm_call_start)

    llm_start = System.monotonic_time()

    :telemetry.execute(
      [:clementine, :llm, :start],
      %{system_time: System.system_time()},
      %{
        model: state.model,
        iteration: state.iteration,
        message_count: length(state.messages),
        tool_count: length(state.tools),
        streaming: true
      }
    )

    do_call_llm_streaming(state, stream_callback, llm_start)
  end

  defp do_call_llm_streaming(%State{} = state, stream_callback, llm_start) do
    alias Clementine.LLM.StreamParser.Accumulator

    stream =
      LLM.stream(
        state.model,
        state.system,
        state.messages,
        state.tools
      )

    # Process the stream, emitting events and accumulating the response
    acc =
      stream
      |> Enum.reduce(Accumulator.new(), fn event, acc ->
        # Forward relevant events to the callback
        case event do
          {:text_delta, _} -> stream_callback.(event)
          {:tool_use_start, _, _} -> stream_callback.(event)
          {:input_json_delta, _, _} -> stream_callback.(event)
          {:error, reason} -> stream_callback.({:error, reason})
          _ -> :ok
        end

        Accumulator.process(acc, event)
      end)

    llm_duration = System.monotonic_time() - llm_start

    if Accumulator.error?(acc) do
      emit_event(state, {:llm_call_end, {:error, acc.error}})

      :telemetry.execute(
        [:clementine, :llm, :exception],
        %{duration: llm_duration},
        %{
          model: state.model,
          iteration: state.iteration,
          kind: :error,
          reason: acc.error,
          streaming: true
        }
      )

      {:error, acc.error}
    else
      result = Accumulator.to_response(acc)
      emit_event(state, {:llm_call_end, {:ok, result}})

      :telemetry.execute(
        [:clementine, :llm, :stop],
        %{
          duration: llm_duration,
          input_tokens: get_in(result.usage, ["input_tokens"]) || 0,
          output_tokens: get_in(result.usage, ["output_tokens"]) || 0
        },
        %{
          model: state.model,
          iteration: state.iteration,
          stop_reason: result.stop_reason,
          streaming: true
        }
      )

      {:ok, result}
    end
  rescue
    e ->
      llm_duration = System.monotonic_time() - llm_start

      :telemetry.execute(
        [:clementine, :llm, :exception],
        %{duration: llm_duration},
        %{
          model: state.model,
          iteration: state.iteration,
          kind: :error,
          reason: e,
          streaming: true
        }
      )

      {:error, e}
  end

  # Handle response in streaming mode
  defp handle_response_streaming(%State{} = state, response, stream_callback) do
    # Add assistant message to history
    state = %{state | messages: state.messages ++ [AssistantMessage.new(response.content)]}

    if LLM.tool_use?(response) do
      handle_tool_use_streaming(state, response, stream_callback)
    else
      handle_final_response(state, response)
    end
  end

  # Handle tool use in streaming mode
  defp handle_tool_use_streaming(%State{} = state, response, stream_callback) do
    tool_uses = LLM.get_tool_uses(response)
    emit_event(state, {:tool_use, tool_uses})

    # Convert tool uses to tool runner format
    tool_calls =
      Enum.map(tool_uses, fn t ->
        %{id: t.id, name: t.name, input: t.input}
      end)

    # Execute tools (per-tool telemetry is emitted by ToolRunner)
    context = Map.put(state.context, :_clementine_iteration, state.iteration)
    results = ToolRunner.execute(state.tools, tool_calls, context)

    # Emit tool results to the stream callback
    Enum.each(results, fn {id, result} ->
      stream_callback.({:tool_result, id, result})
    end)

    emit_event(state, {:tool_results, results})

    # Format results for the conversation
    result_content = ToolRunner.format_results(results)

    # Add tool results as user message
    state = %{state | messages: state.messages ++ [%ToolResultMessage{content: result_content}]}

    # Continue the loop
    iterate_streaming(state, stream_callback)
  end

  @doc """
  Continues an existing conversation with a new prompt.

  Takes the message history from a previous run and continues from there.
  """
  def continue(config, messages, prompt) when is_list(messages) and is_binary(prompt) do
    run(Keyword.put(config, :messages, messages), prompt)
  end
end
