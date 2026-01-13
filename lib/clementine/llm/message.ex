defmodule Clementine.LLM.Message do
  @moduledoc """
  Message types for LLM communication.

  This module defines the structs and functions for representing messages
  exchanged with LLM providers.
  """

  defmodule Content do
    @moduledoc "Represents a content block in a message"

    @type text :: %__MODULE__{type: :text, text: String.t()}
    @type tool_use :: %__MODULE__{
            type: :tool_use,
            id: String.t(),
            name: String.t(),
            input: map()
          }
    @type tool_result :: %__MODULE__{
            type: :tool_result,
            tool_use_id: String.t(),
            content: String.t(),
            is_error: boolean()
          }

    @type t :: text() | tool_use() | tool_result()

    defstruct [:type, :text, :id, :name, :input, :tool_use_id, :content, :is_error]

    @doc "Creates a text content block"
    def text(text) when is_binary(text) do
      %__MODULE__{type: :text, text: text}
    end

    @doc "Creates a tool use content block"
    def tool_use(id, name, input) when is_binary(id) and is_binary(name) and is_map(input) do
      %__MODULE__{type: :tool_use, id: id, name: name, input: input}
    end

    @doc "Creates a tool result content block"
    def tool_result(tool_use_id, content, is_error \\ false)
        when is_binary(tool_use_id) and is_binary(content) and is_boolean(is_error) do
      %__MODULE__{type: :tool_result, tool_use_id: tool_use_id, content: content, is_error: is_error}
    end

    @doc "Converts content to Anthropic API format"
    def to_anthropic(%__MODULE__{type: :text, text: text}) do
      %{"type" => "text", "text" => text}
    end

    def to_anthropic(%__MODULE__{type: :tool_use, id: id, name: name, input: input}) do
      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
    end

    def to_anthropic(%__MODULE__{
          type: :tool_result,
          tool_use_id: id,
          content: content,
          is_error: is_error
        }) do
      base = %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
      if is_error, do: Map.put(base, "is_error", true), else: base
    end

    @doc "Parses content from Anthropic API format"
    def from_anthropic(%{"type" => "text", "text" => text}) do
      text(text)
    end

    def from_anthropic(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
      tool_use(id, name, input)
    end

    def from_anthropic(%{
          "type" => "tool_result",
          "tool_use_id" => id,
          "content" => content
        } = data) do
      tool_result(id, content, Map.get(data, "is_error", false))
    end
  end

  defmodule UserMessage do
    @moduledoc "Represents a user message"

    @type t :: %__MODULE__{
            role: :user,
            content: String.t() | [Content.t()]
          }

    defstruct role: :user, content: nil

    @doc "Creates a user message with text content or structured content"
    def new(content)

    def new(content) when is_binary(content) do
      %__MODULE__{content: content}
    end

    def new(content) when is_list(content) do
      %__MODULE__{content: content}
    end

    @doc "Converts to Anthropic API format"
    def to_anthropic(%__MODULE__{content: content}) when is_binary(content) do
      %{"role" => "user", "content" => content}
    end

    def to_anthropic(%__MODULE__{content: content}) when is_list(content) do
      %{"role" => "user", "content" => Enum.map(content, &Content.to_anthropic/1)}
    end
  end

  defmodule AssistantMessage do
    @moduledoc "Represents an assistant message"

    @type t :: %__MODULE__{
            role: :assistant,
            content: [Content.t()]
          }

    defstruct role: :assistant, content: []

    @doc "Creates an assistant message from content blocks"
    def new(content) when is_list(content) do
      %__MODULE__{content: content}
    end

    @doc "Creates an assistant message with just text"
    def text(text) when is_binary(text) do
      %__MODULE__{content: [Content.text(text)]}
    end

    @doc "Converts to Anthropic API format"
    def to_anthropic(%__MODULE__{content: content}) do
      %{"role" => "assistant", "content" => Enum.map(content, &Content.to_anthropic/1)}
    end

    @doc "Parses from Anthropic API format"
    def from_anthropic(%{"role" => "assistant", "content" => content}) when is_list(content) do
      %__MODULE__{content: Enum.map(content, &Content.from_anthropic/1)}
    end

    @doc "Extracts text content from the message"
    def get_text(%__MODULE__{content: content}) do
      content
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map(& &1.text)
      |> Enum.join("")
    end

    @doc "Extracts tool use blocks from the message"
    def get_tool_uses(%__MODULE__{content: content}) do
      Enum.filter(content, &(&1.type == :tool_use))
    end

    @doc "Checks if the message contains tool uses"
    def has_tool_use?(%__MODULE__{content: content}) do
      Enum.any?(content, &(&1.type == :tool_use))
    end
  end

  defmodule ToolResultMessage do
    @moduledoc "Represents a message containing tool results"

    @type t :: %__MODULE__{
            role: :user,
            content: [Content.t()]
          }

    defstruct role: :user, content: []

    @doc "Creates a tool result message from a list of {tool_use_id, result} tuples"
    def new(results) when is_list(results) do
      content =
        Enum.map(results, fn
          {id, {:ok, result}} -> Content.tool_result(id, result, false)
          {id, {:error, error}} -> Content.tool_result(id, "Error: #{error}", true)
        end)

      %__MODULE__{content: content}
    end

    @doc "Converts to Anthropic API format"
    def to_anthropic(%__MODULE__{content: content}) do
      %{"role" => "user", "content" => Enum.map(content, &Content.to_anthropic/1)}
    end
  end

  @type message ::
          UserMessage.t()
          | AssistantMessage.t()
          | ToolResultMessage.t()

  @doc """
  Converts any message type to Anthropic API format.
  """
  def to_anthropic(%UserMessage{} = msg), do: UserMessage.to_anthropic(msg)
  def to_anthropic(%AssistantMessage{} = msg), do: AssistantMessage.to_anthropic(msg)
  def to_anthropic(%ToolResultMessage{} = msg), do: ToolResultMessage.to_anthropic(msg)

  # Also handle raw maps (for backwards compatibility)
  def to_anthropic(%{role: "user", content: content}) do
    %{"role" => "user", "content" => content}
  end

  def to_anthropic(%{role: "assistant", content: content}) when is_list(content) do
    %{"role" => "assistant", "content" => Enum.map(content, &Content.to_anthropic/1)}
  end
end
