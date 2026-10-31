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
  - `{:thinking_delta, text}` - Thinking content chunk (reasoning-enabled models)
  - `{:signature_delta, signature}` - Thinking block signature chunk
  - `{:redacted_thinking, data}` - Complete encrypted thinking block
  - `{:tool_use_start, id, name}` - Start of tool use
  - `{:input_json_delta, id, json_chunk}` - Tool input JSON chunk
  - `{:server_tool_use_start, id, name}` - Start of a call the API runs
    itself (the tool search for deferred tools)
  - `{:server_tool_input_delta, id, json_chunk}` - That call's input JSON chunk
  - `{:server_tool_result, block}` - Its complete result block, as sent
  - `{:content_block_stop, index}` - End of content block
  - `{:message_delta, delta, usage}` - Message update (stop_reason)
  - `{:message_stop}` - End of message
  - `{:ping}` - Keepalive
  - `{:error, error}` - Error event

  Usage, in `message_start`'s message and in `message_delta`, is in the
  keys `Clementine.Usage` reads: `input_tokens` counts the cache reads
  and writes Anthropic reports apart from it.
  """

  alias Clementine.LLM.ProviderUsage

  @type event ::
          {:message_start, map()}
          | {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:signature_delta, String.t()}
          | {:redacted_thinking, String.t()}
          | {:tool_use_start, String.t(), String.t()}
          | {:input_json_delta, String.t(), String.t()}
          | {:server_tool_use_start, String.t(), String.t()}
          | {:server_tool_input_delta, String.t(), String.t()}
          | {:server_tool_result, map()}
          | {:content_block_stop, non_neg_integer()}
          | {:message_delta, map(), map()}
          | {:message_stop}
          | {:ping}
          | {:error, map()}

  defmodule State do
    @moduledoc false
    defstruct buffer: "",
              current_block_index: nil,
              current_tool_id: nil,
              current_tool_kind: nil,
              usage: %{}
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

        {:error, reason} ->
          [{:error, parse_error("Malformed SSE JSON", reason)}]
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

  # Enrich raw events with tracked state: attaches the open call's id to
  # input_json_delta, and keeps a server tool's input apart from a client
  # tool's, since the engine executes only the latter. Usage leaves
  # normalized (`Clementine.LLM.ProviderUsage.anthropic/1`): the start and
  # the end each report counts, the end's cumulative and sometimes only
  # its output, so each event carries what the stream has reported so far.
  defp enrich_events(events, state) do
    Enum.map_reduce(events, state, fn
      {:message_start, %{"usage" => usage} = message}, state when is_map(usage) ->
        state = %{state | usage: Map.merge(state.usage, usage)}
        {{:message_start, %{message | "usage" => ProviderUsage.anthropic(state.usage)}}, state}

      {:message_delta, delta, usage}, state ->
        state = %{state | usage: Map.merge(state.usage, usage)}
        {{:message_delta, delta, ProviderUsage.anthropic(state.usage)}, state}

      {:tool_use_start, id, _name} = event, state ->
        {event, %{state | current_tool_id: id, current_tool_kind: :client}}

      {:server_tool_use_start, id, _name} = event, state ->
        {event, %{state | current_tool_id: id, current_tool_kind: :server}}

      {:input_json_delta, json}, %State{current_tool_kind: :server} = state ->
        {{:server_tool_input_delta, state.current_tool_id, json}, state}

      {:input_json_delta, json}, state ->
        {{:input_json_delta, state.current_tool_id, json}, state}

      {:content_block_stop, _} = event, state ->
        {event, %{state | current_tool_id: nil, current_tool_kind: nil}}

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

  defp convert_event("content_block_start", %{
         "index" => index,
         "content_block" => %{"type" => "thinking"}
       }) do
    [{:content_block_start, index, :thinking}]
  end

  # Redacted thinking arrives complete in the start event; no deltas follow.
  defp convert_event("content_block_start", %{
         "index" => index,
         "content_block" => %{"type" => "redacted_thinking", "data" => data}
       }) do
    [{:content_block_start, index, :redacted_thinking}, {:redacted_thinking, data}]
  end

  # A call the API runs itself (the tool search for deferred tools). Its
  # input streams as input_json_delta, like a client tool's.
  defp convert_event("content_block_start", %{
         "index" => index,
         "content_block" => %{"type" => "server_tool_use", "id" => id, "name" => name}
       }) do
    [{:content_block_start, index, :server_tool_use}, {:server_tool_use_start, id, name}]
  end

  # The search's result arrives complete in the start event, once the
  # search has run; no deltas follow.
  defp convert_event("content_block_start", %{
         "index" => index,
         "content_block" =>
           %{"type" => "tool_search_tool_result", "tool_use_id" => _, "content" => _} = block
       }) do
    [{:content_block_start, index, :server_tool_result}, {:server_tool_result, block}]
  end

  defp convert_event("content_block_delta", %{
         "index" => _index,
         "delta" => %{"type" => "text_delta", "text" => text}
       }) do
    [{:text_delta, text}]
  end

  defp convert_event("content_block_delta", %{
         "index" => _index,
         "delta" => %{"type" => "thinking_delta", "thinking" => text}
       }) do
    [{:thinking_delta, text}]
  end

  defp convert_event("content_block_delta", %{
         "index" => _index,
         "delta" => %{"type" => "signature_delta", "signature" => signature}
       }) do
    [{:signature_delta, signature}]
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

    Content keeps the order the provider streamed it in. A replayed
    assistant turn must match what the model produced: a tool search's
    result follows its call, the text on either side of a search stays on
    its side, and a provider that binds a thinking block to what precedes
    it sees exactly that.

    `usage` is what the stream reported so far: the counts its start
    carried (the input count), under whatever its end reports. A stream
    cut off before its end, by a cancel or a provider error, still has
    the input it burned.
    """

    alias Clementine.LLM.Message.Content
    alias Clementine.LLM.Response

    # `blocks` holds finished content blocks, newest first. `text` is the
    # open text run: any other block's start closes it into `blocks`.
    defstruct blocks: [],
              text: "",
              current_thinking: nil,
              open_tools: %{},
              open_tool_ids: [],
              stop_reason: nil,
              usage: %{},
              error: nil

    @doc "Creates a new accumulator"
    def new, do: %__MODULE__{}

    @doc "Processes an event and returns updated accumulator"
    def process(%__MODULE__{} = acc, {:text_delta, text}) do
      %{acc | text: acc.text <> text}
    end

    def process(%__MODULE__{} = acc, {:content_block_start, _index, :thinking}) do
      %{close_text(acc) | current_thinking: %{thinking: "", signature: nil}}
    end

    def process(%__MODULE__{} = acc, {:content_block_start, _index, _kind}) do
      close_text(acc)
    end

    def process(%__MODULE__{current_thinking: nil} = acc, {:thinking_delta, _} = event) do
      process(%{close_text(acc) | current_thinking: %{thinking: "", signature: nil}}, event)
    end

    def process(%__MODULE__{current_thinking: current} = acc, {:thinking_delta, text}) do
      %{acc | current_thinking: %{current | thinking: current.thinking <> text}}
    end

    def process(%__MODULE__{} = acc, {:signature_delta, signature}) do
      current = acc.current_thinking || %{thinking: "", signature: nil}
      %{acc | current_thinking: %{current | signature: (current.signature || "") <> signature}}
    end

    def process(%__MODULE__{} = acc, {:redacted_thinking, data}) do
      push(close_text(acc), Content.redacted_thinking(data))
    end

    # Open tool calls are tracked by id: the Chat Completions parser can
    # stream several calls in one turn before any stop event, and their
    # input deltas may interleave. Ids route the deltas; stops close calls
    # oldest-first, matching every parser's stop order. A server tool's
    # call (the API's tool search) is tracked the same way and closes into
    # its own block, which the engine never executes.
    def process(%__MODULE__{} = acc, {:tool_use_start, id, name}) do
      open_tool(acc, id, name, :client)
    end

    def process(%__MODULE__{} = acc, {:server_tool_use_start, id, name}) do
      open_tool(acc, id, name, :server)
    end

    def process(%__MODULE__{} = acc, {:input_json_delta, id, json}) do
      append_input(acc, id, json)
    end

    def process(%__MODULE__{} = acc, {:server_tool_input_delta, id, json}) do
      append_input(acc, id, json)
    end

    def process(%__MODULE__{} = acc, {:server_tool_result, block}) do
      %{"type" => block_type, "tool_use_id" => id, "content" => content} = block
      push(close_text(acc), Content.server_tool_result(id, block_type, content))
    end

    def process(%__MODULE__{open_tool_ids: [id | rest]} = acc, {:content_block_stop, _}) do
      {tool, open_tools} = Map.pop(acc.open_tools, id)
      acc = %{acc | open_tools: open_tools, open_tool_ids: rest}

      case decode_tool_input(tool.input) do
        {:ok, parsed_input} ->
          push(acc, tool_block(tool, parsed_input))

        {:error, reason} ->
          %{acc | error: acc.error || tool_input_error(tool, reason)}
      end
    end

    def process(
          %__MODULE__{current_thinking: thinking} = acc,
          {:content_block_stop, _}
        )
        when thinking != nil do
      acc
      |> push(Content.thinking(thinking.thinking, thinking.signature))
      |> Map.put(:current_thinking, nil)
    end

    def process(%__MODULE__{} = acc, {:content_block_stop, _}) do
      close_text(acc)
    end

    # The start's counts go under any already seen; the end's go over
    # them (message_delta below).
    def process(%__MODULE__{} = acc, {:message_start, %{"usage" => usage}}) when is_map(usage) do
      %{acc | usage: Map.merge(usage, acc.usage)}
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

    defp open_tool(%__MODULE__{} = acc, id, name, kind) do
      if Map.has_key?(acc.open_tools, id) do
        acc
      else
        acc = close_text(acc)

        %{
          acc
          | open_tools: Map.put(acc.open_tools, id, %{id: id, name: name, input: "", kind: kind}),
            open_tool_ids: acc.open_tool_ids ++ [id]
        }
      end
    end

    defp append_input(%__MODULE__{} = acc, id, json) do
      case acc.open_tools do
        %{^id => tool} ->
          %{acc | open_tools: Map.put(acc.open_tools, id, %{tool | input: tool.input <> json})}

        _ ->
          acc
      end
    end

    defp tool_block(%{kind: :client} = tool, input),
      do: Content.tool_use(tool.id, tool.name, input)

    defp tool_block(%{kind: :server} = tool, input),
      do: Content.server_tool_use(tool.id, tool.name, input)

    defp push(%__MODULE__{} = acc, block), do: %{acc | blocks: [block | acc.blocks]}

    defp close_text(%__MODULE__{text: ""} = acc), do: acc

    defp close_text(%__MODULE__{} = acc) do
      %{push(acc, Content.text(acc.text)) | text: ""}
    end

    defp decode_tool_input(""), do: {:ok, %{}}

    defp decode_tool_input(input) do
      case Jason.decode(input) do
        {:ok, parsed} when is_map(parsed) ->
          {:ok, parsed}

        {:ok, parsed} ->
          {:error, {:not_an_object, parsed}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp tool_input_error(tool, reason) do
      %{
        "type" => "stream_parse_error",
        "message" => "Malformed streamed tool input JSON",
        "tool_use_id" => tool.id,
        "tool_name" => tool.name,
        "reason" => error_reason(reason)
      }
    end

    defp error_reason({:not_an_object, parsed}) do
      "expected a JSON object, got: #{inspect(parsed)}"
    end

    defp error_reason(%_{} = reason), do: Exception.message(reason)
    defp error_reason(reason), do: inspect(reason)

    @doc "Returns true if the accumulator has captured an error"
    def error?(%__MODULE__{error: nil}), do: false
    def error?(%__MODULE__{}), do: true

    @doc """
    Returns the accumulated response as a Response struct: the finished
    blocks in the order they streamed, then any text still open. A call
    or thinking block whose stop never arrived is left out.
    """
    def to_response(%__MODULE__{} = acc) do
      content =
        case Enum.reverse(close_text(acc).blocks) do
          [] -> [Content.text("")]
          content -> content
        end

      %Response{
        content: content,
        stop_reason: acc.stop_reason,
        usage: acc.usage
      }
    end
  end
end
