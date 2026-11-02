defmodule Clementine.LLM.OpenAIStreamParser do
  @moduledoc false

  # Parses Responses API SSE streams into Clementine's provider event
  # tuples. A refusal streams as `response.refusal.delta`: it becomes the
  # turn's text, and the stop reason "refusal", which beats the turn's
  # calls: a refused turn runs none. A response that ends
  # `response.incomplete` stops on its cut (`incomplete_reason/1`), and
  # one that ends `response.failed` is an error, not an empty answer. A
  # call whose item ends `status: "incomplete"` never closes, so a turn
  # cut inside it fails on its cut instead of running it. Usage
  # leaves in the keys `Clementine.Usage` reads
  # (`Clementine.LLM.ProviderUsage.openai/1`).

  alias Clementine.LLM.ProviderUsage

  defmodule State do
    @moduledoc false
    defstruct buffer: "",
              item_call_ids: %{},
              started_calls: MapSet.new(),
              calls_with_arg_deltas: MapSet.new(),
              closed_calls: MapSet.new(),
              refused: false,
              usage_meta: %{}
  end

  # `usage_meta` names the vendor, platform, and model for the usage
  # normalizer's `usage_clamped` event (`Clementine.LLM.ProviderUsage`).
  def new(usage_meta \\ %{}) do
    %State{usage_meta: usage_meta}
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

  defp convert_event("response.refusal.delta", %{"delta" => text}, state)
       when is_binary(text) and text != "" do
    {[{:text_delta, text}], %{state | refused: true}}
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
    usage = ProviderUsage.openai(Map.get(response, "usage"), state.usage_meta)

    events =
      fallback_tool_events ++
        [
          {:message_delta, %{"stop_reason" => stop_reason(response, state)}, usage},
          {:message_stop}
        ]

    {events, state}
  end

  # Cut off: what streamed is the turn, and nothing more arrives. It
  # stops on its cut, a refusal first. The engine runs the calls that
  # closed before a cut, as any turn's, unless the cut fell inside one
  # still open: then the turn fails on its cut, and none runs.
  defp convert_event("response.incomplete", %{"response" => response}, state) do
    usage = ProviderUsage.openai(Map.get(response, "usage"), state.usage_meta)
    stop_reason = if state.refused, do: "refusal", else: incomplete_reason(response)

    {[{:message_delta, %{"stop_reason" => stop_reason}, usage}, {:message_stop}], state}
  end

  defp convert_event("response.failed", %{"response" => response}, state) do
    error =
      case Map.get(response, "error") do
        %{} = error -> error
        _ -> %{"message" => "The response failed without an error."}
      end

    {[{:error, error}], state}
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

  # A refusal or a content filter beats the calls: the provider stopped
  # the turn, and none of its calls runs.
  defp stop_reason(response, state) do
    output = Map.get(response, "output") || []

    cond do
      state.refused -> "refusal"
      incomplete_reason(response) == "content_filter" -> "content_filter"
      Enum.any?(output, &whole_call?/1) -> "tool_use"
      true -> incomplete_reason(response)
    end
  end

  @doc false
  # A function call the response finished: an item cut off mid-call ends
  # `status: "incomplete"` (`call/5` reads it too).
  def whole_call?(%{"type" => "function_call"} = item), do: item["status"] != "incomplete"
  def whole_call?(_item), do: false

  @doc false
  # The stop reason a finished response's status gives (`call/5` reads it
  # too): "max_tokens" for one cut off at max_output_tokens,
  # "content_filter" for one a content filter stopped, and "incomplete"
  # for any other incomplete response (max_messages, steered, one
  # OpenAI adds later). Each fails a final turn (Clementine.Error.stopped/2):
  # an incomplete response is never a whole answer.
  def incomplete_reason(%{"status" => "incomplete"} = response) do
    case get_in(response, ["incomplete_details", "reason"]) do
      "max_output_tokens" -> "max_tokens"
      "content_filter" -> "content_filter"
      _other -> "incomplete"
    end
  end

  def incomplete_reason(_response), do: "end_turn"

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
      if stage == :done and whole_call?(item) and not MapSet.member?(state.closed_calls, call_id) do
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

        if MapSet.member?(state.closed_calls, call_id) or not whole_call?(item) do
          {events, state}
        else
          {new_events, state} = replay_unfinished_tool_call(item, index, state)
          {events ++ new_events, state}
        end

      {_other, _index}, acc ->
        acc
    end)
  end

  defp ensure_completed_tool_events(_response, state), do: {[], state}

  # Reconstruct unfinished function calls from response.completed payload.
  # Emit a full synthetic sequence per call to keep accumulator state coherent
  # even when multiple calls were open concurrently.
  defp replay_unfinished_tool_call(item, output_index, state) do
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

    events =
      [{:tool_use_start, call_id, name}] ++
        if(arguments == "", do: [], else: [{:input_json_delta, call_id, arguments}]) ++
        [{:content_block_stop, output_index}]

    state = %{state | started_calls: MapSet.put(state.started_calls, call_id)}

    state =
      if arguments == "" do
        state
      else
        %{state | calls_with_arg_deltas: MapSet.put(state.calls_with_arg_deltas, call_id)}
      end

    {events, %{state | closed_calls: MapSet.put(state.closed_calls, call_id)}}
  end
end
