defmodule Clementine.LLM.ChatCompletionsStreamParser do
  @moduledoc false

  # Parses OpenAI Chat Completions SSE streams (OpenRouter, Bedrock, Vertex
  # MaaS, and self-hosted OpenAI-compatible servers) into Clementine's
  # provider event tuples. Chunks carry `choices[0].delta`; tool call
  # arguments arrive as string fragments keyed by `index`; the stream closes
  # with a `data: [DONE]` sentinel. SSE comment payloads (OpenRouter
  # keep-alives) carry no data lines and are ignored.

  defmodule State do
    @moduledoc false
    defstruct buffer: "",
              index_call_ids: %{},
              started_calls: [],
              finish_reason: nil,
              usage: %{},
              done: false
  end

  def new do
    %State{}
  end

  def parse(%State{buffer: buffer} = state, data) when is_binary(data) do
    full_data = buffer <> data
    {events_data, remaining} = split_events(full_data)
    state = %{state | buffer: remaining}

    Enum.map_reduce(events_data, state, &parse_event/2)
    |> then(fn {event_lists, new_state} -> {List.flatten(event_lists), new_state} end)
  end

  defp parse_event(event_str, state) do
    event_str = String.trim(event_str)

    if event_str == "" do
      {[], state}
    else
      case parse_sse_event(event_str) do
        {:ok, data} ->
          convert_chunk(data, state)

        :done ->
          finish(state)

        :ignore ->
          {[], state}

        {:error, reason} ->
          {[{:error, parse_error("Malformed SSE JSON", reason)}], state}
      end
    end
  end

  defp parse_error(message, reason) do
    %{
      "type" => "stream_parse_error",
      "message" => message,
      "reason" => exception_message(reason)
    }
  end

  defp exception_message(%_{} = reason), do: Exception.message(reason)
  defp exception_message(reason), do: inspect(reason)

  defp split_events(data) do
    parts = String.split(data, "\n\n")

    case parts do
      [] ->
        {[], ""}

      [single] ->
        if String.ends_with?(data, "\n\n") do
          {[single], ""}
        else
          {[], single}
        end

      multiple ->
        if String.ends_with?(data, "\n\n") do
          {multiple, ""}
        else
          {Enum.drop(multiple, -1), List.last(multiple)}
        end
    end
  end

  defp parse_sse_event(event_str) do
    data_lines =
      event_str
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.replace_prefix(&1, "data: ", ""))

    if data_lines == [] do
      :ignore
    else
      json_str = Enum.join(data_lines, "\n")

      if String.trim(json_str) == "[DONE]" do
        :done
      else
        case Jason.decode(json_str) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end
      end
    end
  end

  defp convert_chunk(%{"error" => error}, state) when is_map(error) do
    {[{:error, error}], state}
  end

  defp convert_chunk(data, state) do
    state = remember_usage(state, Map.get(data, "usage"))

    case Map.get(data, "choices") do
      [choice | _] ->
        delta = Map.get(choice, "delta") || %{}

        {text_events, state} = text_events(delta, state)
        {tool_events, state} = tool_call_events(Map.get(delta, "tool_calls"), state)
        state = remember_finish_reason(state, Map.get(choice, "finish_reason"))

        {text_events ++ tool_events, state}

      _ ->
        {[], state}
    end
  end

  defp text_events(%{"content" => text}, state) when is_binary(text) and text != "" do
    {[{:text_delta, text}], state}
  end

  defp text_events(_delta, state), do: {[], state}

  defp tool_call_events(nil, state), do: {[], state}

  defp tool_call_events(tool_calls, state) when is_list(tool_calls) do
    Enum.map_reduce(tool_calls, state, &tool_call_event/2)
    |> then(fn {event_lists, state} -> {List.flatten(event_lists), state} end)
  end

  defp tool_call_events(_other, state), do: {[], state}

  defp tool_call_event(call, state) do
    index = Map.get(call, "index", 0)
    function = Map.get(call, "function") || %{}
    arguments = Map.get(function, "arguments")

    {start_events, state} =
      case Map.get(state.index_call_ids, index) do
        nil ->
          call_id = Map.get(call, "id") || "tool_call_#{index}"
          name = Map.get(function, "name", "unknown")

          {[{:tool_use_start, call_id, name}],
           %{
             state
             | index_call_ids: Map.put(state.index_call_ids, index, call_id),
               started_calls: state.started_calls ++ [{index, call_id}]
           }}

        _call_id ->
          {[], state}
      end

    call_id = Map.fetch!(state.index_call_ids, index)

    argument_events =
      if is_binary(arguments) and arguments != "" do
        [{:input_json_delta, call_id, arguments}]
      else
        []
      end

    {start_events ++ argument_events, state}
  end

  defp remember_finish_reason(state, reason) when is_binary(reason) do
    %{state | finish_reason: reason}
  end

  defp remember_finish_reason(state, _reason), do: state

  defp remember_usage(state, usage) when is_map(usage), do: %{state | usage: usage}
  defp remember_usage(state, _usage), do: state

  # The [DONE] sentinel closes the message: open tool calls get their
  # content_block_stop, then stop_reason and usage flush in message_delta.
  # A retried stream resets parser state, so `done` only guards duplicate
  # sentinels within one attempt.
  defp finish(%State{done: true} = state), do: {[], state}

  defp finish(state) do
    stop_events =
      Enum.map(state.started_calls, fn {index, _call_id} -> {:content_block_stop, index} end)

    events =
      stop_events ++
        [
          {:message_delta, %{"stop_reason" => stop_reason(state)}, state.usage},
          {:message_stop}
        ]

    {events, %{state | done: true}}
  end

  defp stop_reason(%State{finish_reason: "stop"}), do: "end_turn"
  defp stop_reason(%State{finish_reason: "tool_calls"}), do: "tool_use"
  defp stop_reason(%State{finish_reason: "length"}), do: "max_tokens"
  defp stop_reason(%State{finish_reason: reason}) when is_binary(reason), do: reason

  defp stop_reason(%State{started_calls: started}) when started != [], do: "tool_use"
  defp stop_reason(_state), do: "end_turn"
end
