defmodule Clementine.LLM.StreamParser do
  @moduledoc """
  Parses Server-Sent Events (SSE) streams from Anthropic's streaming API.

  The parser handles the following Anthropic event types:
  - `message_start` - Start of a new message
  - `content_block_start` - Start of a content block (text or tool_use)
  - `content_block_delta` - Delta update to a content block
  - `content_block_stop` - End of a content block
  - `message_delta` - Delta update to message metadata (stop_reason, usage)
  - `message_stop` - End of the message
  - `ping` - Keepalive ping
  - `error` - Error event

  ## Emitted Events

  The parser emits the following event tuples:

  - `{:message_start, message_data}` - Message metadata
  - `{:text_delta, text}` - Text content chunk
  - `{:tool_use_start, id, name}` - Start of tool use
  - `{:input_json_delta, id, json_chunk}` - Tool input JSON chunk
  - `{:content_block_stop, index}` - End of content block
  - `{:message_delta, delta, usage}` - Message update (stop_reason)
  - `{:message_stop}` - End of message
  - `{:ping}` - Keepalive
  - `{:error, error}` - Error event
  """

  @type event ::
          {:message_start, map()}
          | {:text_delta, String.t()}
          | {:tool_use_start, String.t(), String.t()}
          | {:input_json_delta, String.t(), String.t()}
          | {:content_block_stop, non_neg_integer()}
          | {:message_delta, map(), map()}
          | {:message_stop}
          | {:ping}
          | {:error, map()}

  defmodule State do
    @moduledoc false
    defstruct buffer: "",
              current_block_index: nil,
              current_tool_id: nil
  end

  @doc """
  Creates a new parser state.
  """
  def new do
    %State{}
  end

  @doc """
  Parses SSE data and returns events.

  Takes raw SSE data (which may contain multiple events or partial events)
  and returns a list of parsed events along with the updated parser state.

  ## Example

      state = StreamParser.new()
      {events, state} = StreamParser.parse(state, sse_data)

  """
  def parse(%State{buffer: buffer} = state, data) when is_binary(data) do
    full_data = buffer <> data

    # Split on double newline (SSE event separator)
    # Keep the last chunk if it doesn't end with \n\n (incomplete event)
    {events_data, remaining} = split_events(full_data)

    raw_events =
      events_data
      |> Enum.flat_map(&parse_event/1)

    {events, state} = enrich_events(raw_events, %{state | buffer: remaining})

    {events, state}
  end

  defp parse_event(event_str) when is_binary(event_str) do
    event_str = String.trim(event_str)

    if event_str == "" do
      []
    else
      case parse_sse_event(event_str) do
        {:ok, event_type, data} ->
          convert_event(event_type, data)

        :ignore ->
          []

        {:error, _reason} ->
          []
      end
    end
  end

  # Enrich raw events with tracked state (attaches tool IDs to input_json_delta)
  defp enrich_events(events, state) do
    Enum.map_reduce(events, state, fn
      {:tool_use_start, id, _name} = event, state ->
        {event, %{state | current_tool_id: id}}

      {:input_json_delta, json}, state ->
        {{:input_json_delta, state.current_tool_id, json}, state}

      {:content_block_stop, _} = event, state ->
        {event, %{state | current_tool_id: nil}}

      event, state ->
        {event, state}
    end)
  end

  # Split SSE data into complete events and remaining buffer
  defp split_events(data) do
    parts = String.split(data, "\n\n")

    case parts do
      [] ->
        {[], ""}

      [single] ->
        # No complete event yet
        if String.ends_with?(data, "\n\n") do
          {[single], ""}
        else
          {[], single}
        end

      multiple ->
        # Check if the last part is complete
        if String.ends_with?(data, "\n\n") do
          {multiple, ""}
        else
          {Enum.drop(multiple, -1), List.last(multiple)}
        end
    end
  end

  # Parse SSE format: "event: type\ndata: json"
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
      event_type == nil ->
        :ignore

      data_lines == [] ->
        :ignore

      true ->
        json_str = Enum.join(data_lines, "\n")

        case Jason.decode(json_str) do
          {:ok, data} -> {:ok, event_type, data}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end
    end
  end

  # Convert parsed SSE events to our event format
  defp convert_event("message_start", %{"message" => message}) do
    [{:message_start, message}]
  end

  defp convert_event("content_block_start", %{
         "index" => index,
         "content_block" => %{"type" => "text"}
       }) do
    [{:content_block_start, index, :text}]
  end

  defp convert_event("content_block_start", %{
         "index" => index,
         "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
       }) do
    [{:content_block_start, index, :tool_use}, {:tool_use_start, id, name}]
  end

  defp convert_event("content_block_delta", %{
         "index" => _index,
         "delta" => %{"type" => "text_delta", "text" => text}
       }) do
    [{:text_delta, text}]
  end

  defp convert_event("content_block_delta", %{
         "index" => _index,
         "delta" => %{"type" => "input_json_delta", "partial_json" => json}
       }) do
    [{:input_json_delta, json}]
  end

  defp convert_event("content_block_stop", %{"index" => index}) do
    [{:content_block_stop, index}]
  end

  defp convert_event("message_delta", %{"delta" => delta, "usage" => usage}) do
    [{:message_delta, delta, usage}]
  end

  defp convert_event("message_delta", %{"delta" => delta}) do
    [{:message_delta, delta, %{}}]
  end

  defp convert_event("message_stop", _data) do
    [{:message_stop}]
  end

  defp convert_event("ping", _data) do
    [{:ping}]
  end

  defp convert_event("error", %{"error" => error}) do
    [{:error, error}]
  end

  defp convert_event(_unknown_type, _data) do
    []
  end

  defmodule Accumulator do
    @moduledoc """
    Accumulates streaming events into a complete response.

    This is useful when you want to collect all stream events
    and get the final message content.
    """

    defstruct text: "",
              tool_uses: [],
              current_tool: nil,
              current_tool_input: "",
              stop_reason: nil,
              usage: %{},
              error: nil

    @doc "Creates a new accumulator"
    def new, do: %__MODULE__{}

    @doc "Processes an event and returns updated accumulator"
    def process(%__MODULE__{} = acc, {:text_delta, text}) do
      %{acc | text: acc.text <> text}
    end

    def process(%__MODULE__{} = acc, {:tool_use_start, id, name}) do
      %{acc | current_tool: %{id: id, name: name}, current_tool_input: ""}
    end

    def process(%__MODULE__{} = acc, {:input_json_delta, _id, json}) do
      %{acc | current_tool_input: acc.current_tool_input <> json}
    end

    def process(%__MODULE__{current_tool: tool, current_tool_input: input} = acc, {:content_block_stop, _})
        when tool != nil do
      parsed_input =
        case Jason.decode(input) do
          {:ok, parsed} -> parsed
          {:error, _} -> %{}
        end

      tool_use = Map.put(tool, :input, parsed_input)
      %{acc | tool_uses: acc.tool_uses ++ [tool_use], current_tool: nil, current_tool_input: ""}
    end

    def process(%__MODULE__{} = acc, {:content_block_stop, _}) do
      acc
    end

    def process(%__MODULE__{} = acc, {:message_delta, %{"stop_reason" => reason}, usage}) do
      %{acc | stop_reason: reason, usage: Map.merge(acc.usage, usage)}
    end

    def process(%__MODULE__{} = acc, {:message_delta, _, usage}) do
      %{acc | usage: Map.merge(acc.usage, usage)}
    end

    def process(%__MODULE__{error: nil} = acc, {:error, reason}) do
      %{acc | error: reason}
    end

    def process(%__MODULE__{} = acc, {:error, _reason}) do
      # Only capture the first error
      acc
    end

    def process(%__MODULE__{} = acc, _event) do
      acc
    end

    @doc "Returns true if the accumulator has captured an error"
    def error?(%__MODULE__{error: nil}), do: false
    def error?(%__MODULE__{}), do: true

    @doc "Returns the accumulated response as a map"
    def to_response(%__MODULE__{} = acc) do
      content =
        cond do
          acc.tool_uses != [] and acc.text != "" ->
            [%{type: :text, text: acc.text}] ++
              Enum.map(acc.tool_uses, fn t ->
                %{type: :tool_use, id: t.id, name: t.name, input: t.input}
              end)

          acc.tool_uses != [] ->
            Enum.map(acc.tool_uses, fn t ->
              %{type: :tool_use, id: t.id, name: t.name, input: t.input}
            end)

          true ->
            [%{type: :text, text: acc.text}]
        end

      %{
        content: content,
        stop_reason: acc.stop_reason,
        usage: acc.usage
      }
    end
  end
end
