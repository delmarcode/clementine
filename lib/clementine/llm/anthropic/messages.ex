defmodule Clementine.LLM.Anthropic.Messages do
  @moduledoc false

  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}

  def encode(%UserMessage{content: content}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  def encode(%UserMessage{content: content}) when is_list(content) do
    %{"role" => "user", "content" => Enum.map(content, &encode_content/1)}
  end

  def encode(%AssistantMessage{content: content}) do
    %{"role" => "assistant", "content" => Enum.map(content, &encode_content/1)}
  end

  def encode(%ToolResultMessage{content: content}) do
    %{"role" => "user", "content" => Enum.map(content, &encode_content/1)}
  end

  def encode_all(messages) when is_list(messages) do
    Enum.map(messages, &encode/1)
  end

  def decode_assistant(%{"role" => "assistant", "content" => content}) when is_list(content) do
    AssistantMessage.new(Enum.map(content, &decode_content/1))
  end

  def decode_content(%{"type" => "text", "text" => text}) do
    Content.text(text)
  end

  def decode_content(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    Content.tool_use(id, name, input)
  end

  def decode_content(
        %{
          "type" => "tool_result",
          "tool_use_id" => id,
          "content" => content
        } = data
      ) do
    Content.tool_result(id, content, Map.get(data, "is_error", false))
  end

  def decode_content(%{"type" => "thinking", "thinking" => thinking} = data) do
    Content.thinking(thinking, Map.get(data, "signature"))
  end

  def decode_content(%{"type" => "redacted_thinking", "data" => data}) do
    Content.redacted_thinking(data)
  end

  def decode_content(%{"type" => "server_tool_use", "id" => id, "name" => name} = data) do
    Content.server_tool_use(id, name, Map.get(data, "input", %{}))
  end

  def decode_content(%{
        "type" => "tool_search_tool_result" = type,
        "tool_use_id" => id,
        "content" => content
      }) do
    Content.server_tool_result(id, type, content)
  end

  defp encode_content(%Content.Text{text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp encode_content(%Content.ToolUse{id: id, name: name, input: input}) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp encode_content(%Content.ToolResult{tool_use_id: id, content: content, is_error: is_error}) do
    base = %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
    if is_error, do: Map.put(base, "is_error", true), else: base
  end

  defp encode_content(%Content.Thinking{thinking: thinking, signature: signature}) do
    base = %{"type" => "thinking", "thinking" => thinking}
    if signature, do: Map.put(base, "signature", signature), else: base
  end

  defp encode_content(%Content.RedactedThinking{data: data}) do
    %{"type" => "redacted_thinking", "data" => data}
  end

  # Replayed as the provider sent them: the API reads a tool search's
  # references from history to keep the tools it loaded in context.
  defp encode_content(%Content.ServerToolUse{id: id, name: name, input: input}) do
    %{"type" => "server_tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp encode_content(%Content.ServerToolResult{} = result) do
    %{
      "type" => result.block_type,
      "tool_use_id" => result.tool_use_id,
      "content" => result.content
    }
  end
end
