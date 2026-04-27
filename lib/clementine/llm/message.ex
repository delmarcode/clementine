defmodule Clementine.LLM.Message do
  @moduledoc """
  Message types for LLM communication.

  This module defines the structs and functions for representing messages
  exchanged with LLM providers.
  """

  defmodule Content do
    @moduledoc "Message content variants."

    defmodule Text do
      @moduledoc "Text content block."
      @enforce_keys [:text]
      defstruct [:text]

      @type t :: %__MODULE__{text: String.t()}
    end

    defmodule ToolUse do
      @moduledoc "Tool-use content block."
      @enforce_keys [:id, :name, :input]
      defstruct [:id, :name, :input]

      @type t :: %__MODULE__{
              id: String.t(),
              name: String.t(),
              input: map()
            }
    end

    defmodule ToolResult do
      @moduledoc "Tool-result content block."
      @enforce_keys [:tool_use_id, :content, :is_error]
      defstruct [:tool_use_id, :content, :is_error]

      @type t :: %__MODULE__{
              tool_use_id: String.t(),
              content: String.t(),
              is_error: boolean()
            }
    end

    @type text :: Text.t()
    @type tool_use :: ToolUse.t()
    @type tool_result :: ToolResult.t()
    @type t :: text() | tool_use() | tool_result()

    @doc "Creates a text content block"
    def text(text) when is_binary(text) do
      %Text{text: text}
    end

    @doc "Creates a tool use content block"
    def tool_use(id, name, input) when is_binary(id) and is_binary(name) and is_map(input) do
      %ToolUse{id: id, name: name, input: input}
    end

    @doc "Creates a tool result content block"
    def tool_result(tool_use_id, content, is_error \\ false)
        when is_binary(tool_use_id) and is_binary(content) and is_boolean(is_error) do
      %ToolResult{tool_use_id: tool_use_id, content: content, is_error: is_error}
    end

    @doc "Checks whether a struct is a known message content variant."
    def valid?(%Text{}), do: true
    def valid?(%ToolUse{}), do: true
    def valid?(%ToolResult{}), do: true
    def valid?(_other), do: false
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
      validate_content!(content)
      %__MODULE__{content: content}
    end

    defp validate_content!(blocks) do
      Enum.each(blocks, fn block ->
        unless Content.valid?(block) do
          raise ArgumentError, "expected message content variant, got: #{inspect(block)}"
        end
      end)
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
      validate_content!(content)
      %__MODULE__{content: content}
    end

    defp validate_content!(blocks) do
      Enum.each(blocks, fn block ->
        unless Content.valid?(block) do
          raise ArgumentError, "expected message content variant, got: #{inspect(block)}"
        end
      end)
    end

    @doc "Creates an assistant message with just text"
    def text(text) when is_binary(text) do
      %__MODULE__{content: [Content.text(text)]}
    end

    @doc "Extracts text content from the message"
    def get_text(%__MODULE__{content: content}) do
      content
      |> Enum.filter(&match?(%Content.Text{}, &1))
      |> Enum.map(& &1.text)
      |> Enum.join("")
    end

    @doc "Extracts tool use blocks from the message"
    def get_tool_uses(%__MODULE__{content: content}) do
      Enum.filter(content, &match?(%Content.ToolUse{}, &1))
    end

    @doc "Checks if the message contains tool uses"
    def has_tool_use?(%__MODULE__{content: content}) do
      Enum.any?(content, &match?(%Content.ToolUse{}, &1))
    end
  end

  defmodule ToolResultMessage do
    @moduledoc "Represents a message containing tool results"

    @type t :: %__MODULE__{
            role: :user,
            content: [Content.t()]
          }

    defstruct role: :user, content: []

    @doc """
    Creates a tool result message from a list of `{tool_use_id, result}` tuples.

    Supports all result forms returned by `Clementine.ToolRunner.execute/4`:

      * `{id, {:ok, content}}` — successful callback result
      * `{id, {:ok, %Clementine.ToolResult{}}}` — normalized successful result
      * `{id, {:ok, content, opts}}` — successful result with options (e.g. `is_error: true`)
      * `{id, {:error, reason}}` — error result
    """
    def new(results) when is_list(results) do
      content =
        Enum.map(results, fn {id, result} ->
          normalized = Clementine.ToolResult.normalize(result)

          Content.tool_result(
            id,
            Clementine.ToolResult.content(normalized),
            Clementine.ToolResult.error?(normalized)
          )
        end)

      %__MODULE__{content: content}
    end
  end

  @type message ::
          UserMessage.t()
          | AssistantMessage.t()
          | ToolResultMessage.t()
end
