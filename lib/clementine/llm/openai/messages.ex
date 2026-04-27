defmodule Clementine.LLM.OpenAI.Messages do
  @moduledoc false

  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}

  def encode_all(messages) when is_list(messages) do
    Enum.flat_map(messages, &encode/1)
  end

  def encode(%UserMessage{content: content}) when is_binary(content) do
    [%{"type" => "message", "role" => "user", "content" => content}]
  end

  def encode(%UserMessage{content: content}) when is_list(content) do
    encode_content_blocks("user", content)
  end

  def encode(%AssistantMessage{content: content}) when is_list(content) do
    encode_content_blocks("assistant", content)
  end

  def encode(%ToolResultMessage{content: content}) do
    Enum.map(content, &tool_result_to_openai/1)
  end

  def decode_output_items(output) when is_list(output) do
    Enum.flat_map(output, &decode_output_item/1)
  end

  defp encode_content_blocks(role, blocks) do
    {items, text_buffer} =
      Enum.reduce(blocks, {[], []}, fn
        %Content.Text{text: text}, {items, text_buffer} ->
          {items, [text | text_buffer]}

        %Content.ToolUse{} = block, {items, text_buffer} ->
          items = flush_text_message(role, text_buffer, items)
          {[tool_use_to_openai(block) | items], []}

        %Content.ToolResult{} = block, {items, text_buffer} ->
          items = flush_text_message(role, text_buffer, items)
          {[tool_result_to_openai(block) | items], []}
      end)

    items
    |> then(&flush_text_message(role, text_buffer, &1))
    |> Enum.reverse()
  end

  defp flush_text_message(_role, [], items), do: items

  defp flush_text_message(role, text_buffer, items) do
    text = text_buffer |> Enum.reverse() |> Enum.join("")
    [%{"type" => "message", "role" => role, "content" => text} | items]
  end

  defp tool_use_to_openai(%Content.ToolUse{id: id, name: name, input: input}) do
    %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => Jason.encode!(input)
    }
  end

  defp tool_result_to_openai(%Content.ToolResult{tool_use_id: id, content: content}) do
    %{
      "type" => "function_call_output",
      "call_id" => id,
      "output" => content
    }
  end

  defp decode_output_item(%{"type" => "message", "content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> [Content.text(text)]
      _ -> []
    end)
  end

  defp decode_output_item(%{"type" => "function_call"} = item) do
    call_id = Map.get(item, "call_id") || Map.get(item, "id") || "tool_call"
    name = Map.get(item, "name", "unknown")
    arguments = Map.get(item, "arguments", "{}")

    input =
      case Jason.decode(arguments) do
        {:ok, parsed} when is_map(parsed) -> parsed
        _ -> %{}
      end

    [Content.tool_use(call_id, name, input)]
  end

  defp decode_output_item(_item), do: []
end
