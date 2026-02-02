defmodule Clementine.Loop do
  @moduledoc """
  The core agentic loop implementation.

  This module implements the gather→act→verify loop that powers Clementine agents.
  It's designed as a pure functional module that can be used by different
  execution contexts (GenServer, one-off scripts, etc.).

  ## The Loop

  ```
  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │   ┌─────────┐    ┌─────────┐    ┌─────────┐           │
  │   │ Gather  │───▶│   Act   │───▶│ Verify  │───┐       │
  │   │ Context │    │         │    │         │   │       │
  │   └─────────┘    └─────────┘    └─────────┘   │       │
  │        ▲                                       │       │
  │        └───────────────────────────────────────┘       │
  │                                                         │
  │                    until done                           │
  └─────────────────────────────────────────────────────────┘
  ```

  The loop continues until:
  - The model returns a final response (no tool calls)
  - A verification step confirms success
  - Max iterations reached
  - An unrecoverable error occurs

  """

  alias Clementine.{LLM, ToolRunner, Verifier}

  @default_max_iterations 10

  defmodule State do
    @moduledoc """
    State maintained during loop execution.
    """
    defstruct [
      :model,
      :system,
      :tools,
      :verifiers,
      :context,
      :max_iterations,
      :on_event,
      messages: [],
      iteration: 0
    ]

    @type t :: %__MODULE__{
            model: atom(),
            system: String.t() | nil,
            tools: [module()],
            verifiers: [module()],
            context: map(),
            max_iterations: pos_integer(),
            on_event: (term() -> any()) | nil,
            messages: [map()],
            iteration: non_neg_integer()
          }
  end

  @type result :: {:ok, String.t(), [map()]} | {:error, term()}

  @doc """
  Runs the agentic loop with the given configuration.

  ## Parameters

  - `config` - Keyword list with:
    - `:model` - The model atom (required)
    - `:system` - System prompt
    - `:tools` - List of tool modules
    - `:verifiers` - List of verifier modules
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
      verifiers: Keyword.get(config, :verifiers, []),
      context: Keyword.get(config, :context, %{}),
      max_iterations: Keyword.get(config, :max_iterations, @default_max_iterations),
      on_event: Keyword.get(config, :on_event),
      messages: Keyword.get(config, :messages, [])
    }

    # Add user message
    user_message = %{role: :user, content: prompt}
    state = %{state | messages: state.messages ++ [user_message]}

    emit_event(state, {:loop_start, prompt})

    iterate(state)
  end

  # Main iteration function
  defp iterate(%State{iteration: iteration, max_iterations: max} = state)
       when iteration >= max do
    emit_event(state, {:loop_end, :max_iterations})
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
        {:error, reason}
    end
  end

  # Call the LLM
  defp call_llm(%State{} = state) do
    emit_event(state, :llm_call_start)

    result = LLM.call(
      state.model,
      state.system,
      state.messages,
      state.tools
    )

    emit_event(state, {:llm_call_end, result})
    result
  end

  # Handle LLM response
  defp handle_response(%State{} = state, response) do
    # Add assistant message to history
    assistant_message = %{role: :assistant, content: response.content}
    state = %{state | messages: state.messages ++ [assistant_message]}

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

    # Execute tools
    results = ToolRunner.execute(state.tools, tool_calls, state.context)
    emit_event(state, {:tool_results, results})

    # Format results for the conversation
    result_content = ToolRunner.format_results(results)

    # Add tool results as user message
    tool_result_message = %{role: :user, content: result_content}
    state = %{state | messages: state.messages ++ [tool_result_message]}

    # Continue the loop
    iterate(state)
  end

  # Handle final response (no tool use)
  defp handle_final_response(%State{} = state, response) do
    text = LLM.get_text(response)
    emit_event(state, {:final_text, text})

    # Run verifiers
    case run_verifiers(state, text) do
      :ok ->
        emit_event(state, {:loop_end, :success})
        {:ok, text, state.messages}

      {:retry, reason} ->
        handle_verification_failure(state, reason)
    end
  end

  # Run verifiers on the result
  defp run_verifiers(%State{verifiers: []}, _text), do: :ok

  defp run_verifiers(%State{verifiers: verifiers, context: context}, text) do
    Verifier.run_all(verifiers, text, context)
  end

  # Handle verification failure
  defp handle_verification_failure(%State{} = state, reason) do
    emit_event(state, {:verification_failed, reason})

    # Add retry message to conversation
    retry_message = %{role: :user, content: "Verification failed: #{reason}\n\nPlease fix the issues and try again."}
    state = %{state | messages: state.messages ++ [retry_message]}

    # Continue the loop
    iterate(state)
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
      verifiers: Keyword.get(config, :verifiers, []),
      context: Keyword.get(config, :context, %{}),
      max_iterations: Keyword.get(config, :max_iterations, @default_max_iterations),
      on_event: fn event -> stream_callback.({:loop_event, event}) end,
      messages: Keyword.get(config, :messages, [])
    }

    # Add user message
    user_message = %{role: :user, content: prompt}
    state = %{state | messages: state.messages ++ [user_message]}

    emit_event(state, {:loop_start, prompt})

    iterate_streaming(state, stream_callback)
  end

  # Streaming iteration - uses LLM.stream instead of LLM.call
  defp iterate_streaming(%State{iteration: iteration, max_iterations: max} = state, _callback)
       when iteration >= max do
    emit_event(state, {:loop_end, :max_iterations})
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
        {:error, reason}
    end
  end

  # Streaming LLM call - emits text deltas as they arrive
  defp call_llm_streaming(%State{} = state, stream_callback) do
    alias Clementine.LLM.StreamParser.Accumulator

    emit_event(state, :llm_call_start)

    stream = LLM.stream(
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

    if Accumulator.error?(acc) do
      emit_event(state, {:llm_call_end, {:error, acc.error}})
      {:error, acc.error}
    else
      result = Accumulator.to_response(acc)
      emit_event(state, {:llm_call_end, {:ok, result}})
      {:ok, result}
    end
  rescue
    e -> {:error, e}
  end

  # Handle response in streaming mode
  defp handle_response_streaming(%State{} = state, response, stream_callback) do
    # Add assistant message to history
    assistant_message = %{role: :assistant, content: response.content}
    state = %{state | messages: state.messages ++ [assistant_message]}

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

    # Execute tools and emit results
    results = ToolRunner.execute(state.tools, tool_calls, state.context)

    # Emit tool results to the stream callback
    Enum.each(results, fn {id, result} ->
      stream_callback.({:tool_result, id, result})
    end)

    emit_event(state, {:tool_results, results})

    # Format results for the conversation
    result_content = ToolRunner.format_results(results)

    # Add tool results as user message
    tool_result_message = %{role: :user, content: result_content}
    state = %{state | messages: state.messages ++ [tool_result_message]}

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
