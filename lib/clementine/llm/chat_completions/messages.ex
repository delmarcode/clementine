defmodule Clementine.LLM.ChatCompletions.Messages do
  @moduledoc false

  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}

  def encode_all(messages) when is_list(messages) do
    Enum.flat_map(messages, &encode/1)
  end

  def encode(%UserMessage{content: content}) when is_binary(content) do
    [%{"role" => "user", "content" => content}]
  end

  def encode(%UserMessage{content: content}) when is_list(content) do
    encode_content_blocks("user", content)
  end

  def encode(%AssistantMessage{content: content}) when is_list(content) do
    encode_content_blocks("assistant", content)
  end

  def encode(%ToolResultMessage{content: content}) do
    Enum.map(content, &tool_result_message/1)
  end

  def decode_message(message) when is_map(message) do
    text_blocks =
      case Map.get(message, "content") do
        text when is_binary(text) and text != "" -> [Content.text(text)]
        _ -> []
      end

    tool_use_blocks =
      message
      |> Map.get("tool_calls")
      |> List.wrap()
      |> Enum.flat_map(&decode_tool_call/1)

    text_blocks ++ tool_use_blocks
  end

  # An assistant turn folds trailing text and tool uses into one chat
  # message: text becomes content, tool uses become tool_calls. Tool
  # results always leave as their own role:"tool" messages.
  defp encode_content_blocks(role, blocks) do
    {messages, text_buffer, tool_calls} =
      Enum.reduce(blocks, {[], [], []}, fn
        %Content.Text{text: text}, {messages, text_buffer, tool_calls} ->
          {messages, [text | text_buffer], tool_calls}

        %Content.ToolUse{} = block, {messages, text_buffer, tool_calls} ->
          {messages, text_buffer, [tool_call(block) | tool_calls]}

        %Content.ToolResult{} = block, {messages, text_buffer, tool_calls} ->
          {messages, text_buffer, tool_calls} =
            flush_message(role, text_buffer, tool_calls, messages)

          {[tool_result_message(block) | messages], text_buffer, tool_calls}

        # Anthropic reasoning artifacts have no chat-completions encoding;
        # a history carried across providers drops them rather than crashing.
        %Content.Thinking{}, acc ->
          acc

        %Content.RedactedThinking{}, acc ->
          acc
      end)

    {messages, [], []} = flush_message(role, text_buffer, tool_calls, messages)
    Enum.reverse(messages)
  end

  defp flush_message(_role, [], [], messages), do: {messages, [], []}

  defp flush_message(role, text_buffer, tool_calls, messages) do
    text = text_buffer |> Enum.reverse() |> Enum.join("")

    message =
      %{"role" => role, "content" => if(text == "", do: nil, else: text)}
      |> put_tool_calls(Enum.reverse(tool_calls))

    {[message | messages], [], []}
  end

  defp put_tool_calls(message, []), do: message
  defp put_tool_calls(message, tool_calls), do: Map.put(message, "tool_calls", tool_calls)

  defp tool_call(%Content.ToolUse{id: id, name: name, input: input}) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(input)}
    }
  end

  defp tool_result_message(%Content.ToolResult{tool_use_id: id, content: content}) do
    %{"role" => "tool", "tool_call_id" => id, "content" => content}
  end

  defp decode_tool_call(%{"type" => "function"} = call) do
    decode_function_call(call)
  end

  defp decode_tool_call(%{"function" => _} = call) do
    decode_function_call(call)
  end

  defp decode_tool_call(_call), do: []

  defp decode_function_call(call) do
    function = Map.get(call, "function", %{})
    id = Map.get(call, "id") || "tool_call"
    name = Map.get(function, "name", "unknown")
    arguments = Map.get(function, "arguments", "{}")

    input =
      case Jason.decode(arguments) do
        {:ok, parsed} when is_map(parsed) -> parsed
        _ -> %{}
      end

    [Content.tool_use(id, name, input)]
  end
end
