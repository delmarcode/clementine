defmodule Clementine.LLM.OpenAIStreamParser do
  @moduledoc false

  defmodule State do
    @moduledoc false
    defstruct buffer: "",
              item_call_ids: %{},
              started_calls: MapSet.new(),
              calls_with_arg_deltas: MapSet.new(),
              closed_calls: MapSet.new()
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
        {:ok, event_type, data} ->
          convert_event(event_type, data, state)

        :done ->
          {[], state}

        :ignore ->
          {[], state}

        {:error, _reason} ->
          {[], state}
      end
    end
  end

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
    lines = String.split(event_str, "\n")

    event_type =
      Enum.find_value(lines, fn line ->
        case line do
          "event: " <> type -> String.trim(type)
          _ -> nil
        end
      end)

    data_lines =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.replace_prefix(&1, "data: ", ""))

    cond do
      data_lines == [] ->
        :ignore

      true ->
        json_str = Enum.join(data_lines, "\n")

        if json_str == "[DONE]" do
          :done
        else
          case Jason.decode(json_str) do
            {:ok, data} ->
              {:ok, event_type || Map.get(data, "type"), data}

            {:error, reason} ->
              {:error, {:json_decode, reason}}
          end
        end
    end
  end

  defp convert_event("response.output_text.delta", %{"delta" => text}, state)
       when is_binary(text) do
    {[{:text_delta, text}], state}
  end

  defp convert_event("response.output_item.added", %{"item" => item} = data, state) do
    output_index = Map.get(data, "output_index", 0)
    process_output_item(item, output_index, state, :added)
  end

  defp convert_event("response.output_item.done", %{"item" => item} = data, state) do
    output_index = Map.get(data, "output_index", 0)
    process_output_item(item, output_index, state, :done)
  end

  defp convert_event(
         "response.function_call_arguments.delta",
         %{"item_id" => item_id, "delta" => delta},
         state
       )
       when is_binary(item_id) and is_binary(delta) do
    call_id = Map.get(state.item_call_ids, item_id)

    if is_binary(call_id) do
      events = if delta == "", do: [], else: [{:input_json_delta, call_id, delta}]
      {events, %{state | calls_with_arg_deltas: MapSet.put(state.calls_with_arg_deltas, call_id)}}
    else
      {[], state}
    end
  end

  defp convert_event(
         "response.function_call_arguments.done",
         %{"item_id" => item_id} = data,
         state
       )
       when is_binary(item_id) do
    call_id = Map.get(state.item_call_ids, item_id)
    arguments = Map.get(data, "arguments", "")

    cond do
      not is_binary(call_id) ->
        {[], state}

      arguments == "" ->
        {[], state}

      MapSet.member?(state.calls_with_arg_deltas, call_id) ->
        {[], state}

      true ->
        {[
           {:input_json_delta, call_id, arguments}
         ], %{state | calls_with_arg_deltas: MapSet.put(state.calls_with_arg_deltas, call_id)}}
    end
  end

  defp convert_event("response.completed", %{"response" => response}, state) do
    {fallback_tool_events, state} = ensure_completed_tool_events(response, state)
    usage = Map.get(response, "usage", %{}) || %{}
    output = Map.get(response, "output", [])

    stop_reason =
      if Enum.any?(output, &(Map.get(&1, "type") == "function_call")) do
        "tool_use"
      else
        "end_turn"
      end

    events =
      fallback_tool_events ++
        [{:message_delta, %{"stop_reason" => stop_reason}, usage}, {:message_stop}]

    {events, state}
  end

  defp convert_event("response.error", %{"error" => error}, state) do
    {[{:error, error}], state}
  end

  defp convert_event("error", error, state) do
    {[{:error, error}], state}
  end

  defp convert_event(_event_type, _data, state) do
    {[], state}
  end

  defp process_output_item(%{"type" => "function_call"} = item, output_index, state, stage) do
    item_id = Map.get(item, "id")
    call_id = Map.get(item, "call_id") || item_id || "tool_call_#{output_index}"
    name = Map.get(item, "name", "unknown")
    arguments = Map.get(item, "arguments", "")

    state =
      if is_binary(item_id) do
        %{state | item_call_ids: Map.put(state.item_call_ids, item_id, call_id)}
      else
        state
      end

    {start_events, state} =
      if MapSet.member?(state.started_calls, call_id) do
        {[], state}
      else
        {[{:tool_use_start, call_id, name}],
         %{state | started_calls: MapSet.put(state.started_calls, call_id)}}
      end

    {argument_events, state} =
      cond do
        arguments == "" ->
          {[], state}

        stage == :done and not MapSet.member?(state.calls_with_arg_deltas, call_id) ->
          {[{:input_json_delta, call_id, arguments}],
           %{state | calls_with_arg_deltas: MapSet.put(state.calls_with_arg_deltas, call_id)}}

        true ->
          {[], state}
      end

    {stop_events, state} =
      if stage == :done and not MapSet.member?(state.closed_calls, call_id) do
        {[{:content_block_stop, output_index}],
         %{state | closed_calls: MapSet.put(state.closed_calls, call_id)}}
      else
        {[], state}
      end

    {start_events ++ argument_events ++ stop_events, state}
  end

  defp process_output_item(_item, _output_index, state, _stage) do
    {[], state}
  end

  defp ensure_completed_tool_events(%{"output" => output}, state) when is_list(output) do
    Enum.with_index(output)
    |> Enum.reduce({[], state}, fn
      {%{"type" => "function_call"} = item, index}, {events, state} ->
        call_id = Map.get(item, "call_id") || Map.get(item, "id") || "tool_call_#{index}"

        if MapSet.member?(state.closed_calls, call_id) do
          {events, state}
        else
          {new_events, state} = process_output_item(item, index, state, :done)
          {events ++ new_events, state}
        end

      {_other, _index}, acc ->
        acc
    end)
  end

  defp ensure_completed_tool_events(_response, state), do: {[], state}
end
