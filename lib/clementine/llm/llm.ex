defmodule Clementine.LLM do
  @moduledoc """
  LLM interface module.

  This module provides the main interface for interacting with LLM providers.
  It routes requests to the appropriate provider based on configuration.

  ## Usage

      # Synchronous call
      {:ok, response} = Clementine.LLM.call(:claude_sonnet, system, messages, tools)

      # Streaming call
      stream = Clementine.LLM.stream(:claude_sonnet, system, messages, tools)
      Enum.each(stream, fn event -> IO.inspect(event) end)

  """

  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Error

  @doc """
  Makes a synchronous LLM call.

  ## Parameters

  - `model` - Model reference: alias atom (e.g., `:claude_sonnet`) or `{provider, id}` tuple
  - `system` - The system prompt (can be nil or empty string)
  - `messages` - List of conversation messages
  - `tools` - List of tool modules (can be empty)
  - `opts` - Additional options:
    - `:max_tokens` - Override max tokens for this request
    - `:reasoning` - Override configured provider reasoning for this request

  ## Returns

  - `{:ok, response}` where response contains:
    - `:content` - List of content blocks (text and/or tool_use)
    - `:stop_reason` - Why the model stopped ("end_turn", "tool_use", etc.)
    - `:usage` - Token usage information
  - `{:error, reason}` on failure

  """
  def call(model, system, messages, tools, opts \\ []) do
    client = get_client()

    client
    |> apply(:call, [model, system, messages, tools, opts])
    |> normalize_call_result()
  rescue
    e ->
      {:error, exception_reason(:error, e)}
  catch
    kind, reason ->
      {:error, exception_reason(kind, reason)}
  end

  @doc """
  Makes a streaming LLM call.

  Returns a Stream that emits events as they arrive from the API.

  ## Events

  The stream emits tuples like:
  - `{:message_start, message_data}` - Message metadata
  - `{:text_delta, text}` - Text content chunk
  - `{:tool_use_start, id, name}` - Start of tool use
  - `{:input_json_delta, id, json_chunk}` - Tool input JSON chunk
  - `{:content_block_stop, index}` - End of content block
  - `{:message_delta, delta, usage}` - Message update (stop_reason)
  - `{:message_stop}` - End of message

  ## Example

      Clementine.LLM.stream(:claude_sonnet, system, messages, tools)
      |> Enum.each(fn
        {:text_delta, text} -> IO.write(text)
        {:tool_use_start, _id, name} -> IO.puts("\\n[Calling \#{name}...]")
        _ -> :ok
      end)

  """
  def stream(model, system, messages, tools, opts \\ []) do
    client = get_client()

    client.stream(model, system, messages, tools, opts)
    |> normalize_stream_result()
  rescue
    e ->
      [{:error, exception_reason(:error, e)}]
  catch
    kind, reason ->
      [{:error, exception_reason(kind, reason)}]
  end

  @doc """
  Collects a stream into a complete response.

  This is useful when you want streaming behavior (e.g., for real-time display)
  but also need the final complete response.

  Returns `{:error, reason}` if the stream emitted an error event.

  ## Example

      stream = Clementine.LLM.stream(:claude_sonnet, system, messages, tools)
      {:ok, response} = Clementine.LLM.collect_stream(stream)

  """
  def collect_stream(stream) do
    alias Clementine.LLM.StreamParser.Accumulator

    acc =
      stream
      |> Enum.reduce(Accumulator.new(), fn event, acc ->
        Accumulator.process(acc, event)
      end)

    if Accumulator.error?(acc) do
      {:error, acc.error}
    else
      {:ok, Accumulator.to_response(acc)}
    end
  rescue
    e -> {:error, exception_reason(:error, e)}
  catch
    kind, reason -> {:error, exception_reason(kind, reason)}
  end

  @doc """
  Checks if a response indicates the model wants to use tools.
  """
  @spec tool_use?(Clementine.LLM.Response.t()) :: boolean()
  def tool_use?(response) do
    response.stop_reason == "tool_use" ||
      Enum.any?(response.content, &match?(%Content.ToolUse{}, &1))
  end

  @doc """
  Extracts tool use requests from a response.
  """
  @spec get_tool_uses(Clementine.LLM.Response.t()) :: [Content.ToolUse.t()]
  def get_tool_uses(response) do
    response.content
    |> Enum.filter(&match?(%Content.ToolUse{}, &1))
  end

  @doc """
  Extracts text content from a response.
  """
  @spec get_text(Clementine.LLM.Response.t()) :: String.t()
  def get_text(response) do
    response.content
    |> Enum.filter(&match?(%Content.Text{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  # Get the configured LLM client (allows for mocking in tests)
  defp get_client do
    Application.get_env(:clementine, :llm_client, Clementine.LLM.Router)
  end

  defp normalize_call_result({:ok, %Clementine.LLM.Response{}} = result), do: result
  defp normalize_call_result({:error, _reason} = error), do: error
  defp normalize_call_result(other), do: {:error, {:invalid_llm_client_result, other}}

  defp normalize_stream_result(stream) do
    if Enumerable.impl_for(stream) do
      Stream.resource(
        fn -> {:stream, stream} end,
        &next_safe_stream_event/1,
        &cleanup_safe_stream/1
      )
    else
      [{:error, {:invalid_llm_client_stream, stream}}]
    end
  end

  defp next_safe_stream_event(:done), do: {:halt, :done}

  defp next_safe_stream_event({:stream, stream}) do
    reduce_next_stream_event(fn acc ->
      Enumerable.reduce(stream, {:cont, acc}, &suspend_after_event/2)
    end)
  end

  defp next_safe_stream_event({:continuation, continuation}) do
    reduce_next_stream_event(fn acc -> continuation.({:cont, acc}) end)
  end

  defp reduce_next_stream_event(reduce_fun) do
    case reduce_fun.(nil) do
      {:suspended, event, continuation} ->
        {[event], {:continuation, continuation}}

      {:done, _acc} ->
        {:halt, :done}

      {:halted, _acc} ->
        {:halt, :done}
    end
  rescue
    e ->
      {[{:error, exception_reason(:error, e)}], :done}
  catch
    kind, reason ->
      {[{:error, exception_reason(kind, reason)}], :done}
  end

  defp suspend_after_event(event, _acc), do: {:suspend, event}

  defp cleanup_safe_stream({:continuation, continuation}) do
    continuation.({:halt, nil})
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp cleanup_safe_stream(_state), do: :ok

  defp exception_reason(kind, reason), do: Error.normalize_exception(kind, reason)
end
