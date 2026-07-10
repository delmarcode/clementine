defmodule Clementine.LLM.Message do
  @moduledoc """
  Message types for LLM communication.

  This module defines the structs and functions for representing messages
  exchanged with LLM providers.
  """

  @serialized_version 1

  defmodule Content do
    @moduledoc "Message content variants."

    @type json_value ::
            nil
            | boolean()
            | number()
            | String.t()
            | [json_value()]
            | %{String.t() => json_value()}

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
              input: Content.json_object()
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

    defmodule Thinking do
      @moduledoc """
      Model reasoning content block (Anthropic extended/adaptive thinking).

      The signature must round-trip unmodified: providers verify it when a
      thinking block is replayed in a later turn of a tool-use loop.
      """
      @enforce_keys [:thinking]
      defstruct [:thinking, :signature]

      @type t :: %__MODULE__{thinking: String.t(), signature: String.t() | nil}
    end

    defmodule RedactedThinking do
      @moduledoc """
      Encrypted reasoning content block (Anthropic `redacted_thinking`).

      Opaque to the host; preserved only so it can be replayed verbatim.
      """
      @enforce_keys [:data]
      defstruct [:data]

      @type t :: %__MODULE__{data: String.t()}
    end

    @type text :: Text.t()
    @type tool_use :: ToolUse.t()
    @type tool_result :: ToolResult.t()
    @type thinking :: Thinking.t()
    @type redacted_thinking :: RedactedThinking.t()
    @type t :: text() | tool_use() | tool_result() | thinking() | redacted_thinking()
    @type json_object :: %{String.t() => json_value()}

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

    @doc "Creates a thinking content block"
    def thinking(thinking, signature \\ nil)
        when is_binary(thinking) and (is_binary(signature) or is_nil(signature)) do
      %Thinking{thinking: thinking, signature: signature}
    end

    @doc "Creates a redacted thinking content block"
    def redacted_thinking(data) when is_binary(data) do
      %RedactedThinking{data: data}
    end

    @doc "Checks whether a struct is a known message content variant."
    def valid?(%Text{}), do: true
    def valid?(%ToolUse{}), do: true
    def valid?(%ToolResult{}), do: true
    def valid?(%Thinking{}), do: true
    def valid?(%RedactedThinking{}), do: true
    def valid?(_other), do: false

    @doc """
    Converts a content block into a JSON-safe, string-keyed map tagged with a
    `"type"` discriminator (`"text"`, `"tool_use"`, or `"tool_result"`).

    The output contains only JSON-serializable values, so it survives
    `Jason.encode!/1`/`Jason.decode!/1` round trips and storage in Postgres
    `jsonb` or Oban args. `ToolUse.input` must already be a JSON object with
    string keys.
    """
    @spec to_map(t()) :: map()
    def to_map(%Text{text: text}) do
      %{"type" => "text", "text" => text}
    end

    def to_map(%ToolUse{id: id, name: name, input: input}) do
      validate_json_object!(input, "tool_use.input")
      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
    end

    def to_map(%ToolResult{tool_use_id: tool_use_id, content: content, is_error: is_error}) do
      %{
        "type" => "tool_result",
        "tool_use_id" => tool_use_id,
        "content" => content,
        "is_error" => is_error
      }
    end

    def to_map(%Thinking{thinking: thinking, signature: signature}) do
      %{"type" => "thinking", "thinking" => thinking, "signature" => signature}
    end

    def to_map(%RedactedThinking{data: data}) do
      %{"type" => "redacted_thinking", "data" => data}
    end

    @doc """
    Reconstructs a content block from a string-keyed map produced by `to_map/1`
    (or returned by `Jason.decode!/1`), dispatching on the `"type"` field.

    `ToolUse.input` is passed through unchanged after validating that it is a
    JSON object with string keys. Raises `ArgumentError` on an unknown or
    missing `"type"`, unknown fields, or malformed required fields.
    """
    @spec from_map(map()) :: t()
    def from_map(%{"type" => type} = data) do
      case type do
        "text" ->
          validate_keys!(data, ["type", "text"], "text content")

          data
          |> fetch_binary!("text", "text content")
          |> text()

        "tool_use" ->
          validate_keys!(data, ["type", "id", "name", "input"], "tool_use content")
          input = fetch_json_object!(data, "input", "tool_use.input")

          data
          |> fetch_binary!("id", "tool use id")
          |> tool_use(fetch_binary!(data, "name", "tool use name"), input)

        "tool_result" ->
          validate_keys!(
            data,
            ["type", "tool_use_id", "content", "is_error"],
            "tool_result content"
          )

          data
          |> fetch_binary!("tool_use_id", "tool result tool_use_id")
          |> tool_result(
            fetch_binary!(data, "content", "tool result content"),
            fetch_boolean!(data, "is_error", "tool result is_error")
          )

        "thinking" ->
          validate_keys!(data, ["type", "thinking", "signature"], "thinking content")

          data
          |> fetch_binary!("thinking", "thinking content")
          |> thinking(fetch_optional_binary!(data, "signature", "thinking signature"))

        "redacted_thinking" ->
          validate_keys!(data, ["type", "data"], "redacted_thinking content")

          data
          |> fetch_binary!("data", "redacted thinking data")
          |> redacted_thinking()

        _other ->
          raise ArgumentError, "unknown content type: #{inspect(type)}"
      end
    end

    def from_map(other) do
      raise ArgumentError, "expected a content map with a \"type\" key, got: #{inspect(other)}"
    end

    defp validate_keys!(map, allowed_keys, label) do
      case Map.keys(map) -- allowed_keys do
        [] ->
          :ok

        keys ->
          raise ArgumentError, "unexpected #{label} field(s): #{inspect(keys)}"
      end
    end

    defp fetch_binary!(map, key, label) do
      case Map.fetch(map, key) do
        {:ok, value} when is_binary(value) ->
          value

        {:ok, value} ->
          raise ArgumentError, "expected #{label} to be a string, got: #{inspect(value)}"

        :error ->
          raise ArgumentError, "expected content map to include #{inspect(key)}"
      end
    end

    defp fetch_optional_binary!(map, key, label) do
      case Map.get(map, key) do
        nil ->
          nil

        value when is_binary(value) ->
          value

        value ->
          raise ArgumentError, "expected #{label} to be a string or nil, got: #{inspect(value)}"
      end
    end

    defp fetch_boolean!(map, key, label) do
      case Map.fetch(map, key) do
        {:ok, value} when is_boolean(value) ->
          value

        {:ok, value} ->
          raise ArgumentError, "expected #{label} to be a boolean, got: #{inspect(value)}"

        :error ->
          raise ArgumentError, "expected content map to include #{inspect(key)}"
      end
    end

    defp fetch_json_object!(map, key, label) do
      case Map.fetch(map, key) do
        {:ok, value} when is_map(value) ->
          validate_json_object!(value, label)
          value

        {:ok, value} ->
          raise ArgumentError, "expected #{label} to be a JSON object, got: #{inspect(value)}"

        :error ->
          raise ArgumentError, "expected content map to include #{inspect(key)}"
      end
    end

    defp validate_json_object!(value, label) when is_map(value) do
      Enum.each(value, fn
        {key, nested} when is_binary(key) ->
          validate_json_value!(nested, "#{label}.#{key}")

        {key, _nested} ->
          raise ArgumentError, "expected #{label} to have string keys, got: #{inspect(key)}"
      end)

      :ok
    end

    defp validate_json_value!(value, _label)
         when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
         do: :ok

    defp validate_json_value!(value, label) when is_list(value) do
      Enum.each(value, &validate_json_value!(&1, label))
    end

    defp validate_json_value!(value, label) when is_map(value) do
      validate_json_object!(value, label)
    end

    defp validate_json_value!(value, label) do
      raise ArgumentError, "expected #{label} to be JSON-safe, got: #{inspect(value)}"
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

  @doc """
  Converts a message struct into a JSON-safe, string-keyed map.

  The map carries an explicit `"kind"` discriminator (`"user"`, `"assistant"`,
  or `"tool_result"`) because `UserMessage` and `ToolResultMessage` both use
  `role: :user`, so `role` alone cannot reconstruct the struct.

  `UserMessage.content` may be a plain string or a list of content blocks; both
  forms are preserved (a string stays a string, a list stays a list of tagged
  block maps). The result survives a `Jason.encode!/1`/`Jason.decode!/1` round
  trip and storage in Postgres `jsonb` or Oban args.

  Maps include `"version"` for durable storage. `"role"` is derived from
  `"kind"` and validated when decoding. Unknown fields are rejected so version 1
  stays a tight contract.
  """
  @spec to_map(message()) :: map()
  def to_map(%UserMessage{role: :user, content: content}) when is_binary(content) do
    %{"version" => @serialized_version, "kind" => "user", "role" => "user", "content" => content}
  end

  def to_map(%UserMessage{role: :user, content: content}) when is_list(content) do
    %{
      "version" => @serialized_version,
      "kind" => "user",
      "role" => "user",
      "content" => Enum.map(content, &Content.to_map/1)
    }
  end

  def to_map(%AssistantMessage{role: :assistant, content: content}) do
    %{
      "version" => @serialized_version,
      "kind" => "assistant",
      "role" => "assistant",
      "content" => Enum.map(content, &Content.to_map/1)
    }
  end

  def to_map(%ToolResultMessage{role: :user, content: content}) do
    %{
      "version" => @serialized_version,
      "kind" => "tool_result",
      "role" => "user",
      "content" => Enum.map(content, &Content.to_map/1)
    }
  end

  @doc """
  Reconstructs a message struct from a string-keyed map produced by `to_map/1`
  (or returned by `Jason.decode!/1`), dispatching on the `"kind"` field.

  Raises `ArgumentError` on an unknown or missing `"kind"`, unsupported
  `"version"`, missing or inconsistent `"role"`, unknown fields, or invalid
  content.
  """
  @spec from_map(map()) :: message()
  def from_map(%{"kind" => kind} = data) do
    validate_version!(data)
    validate_message_keys!(data)

    case kind do
      "user" ->
        validate_role!(data, "user")
        decode_user_content!(Map.get(data, "content"))

      "assistant" ->
        validate_role!(data, "assistant")
        %AssistantMessage{content: decode_content_list!(data, "assistant")}

      "tool_result" ->
        validate_role!(data, "user")
        %ToolResultMessage{content: decode_content_list!(data, "tool_result")}

      _other ->
        raise ArgumentError, "unknown message kind: #{inspect(kind)}"
    end
  end

  def from_map(other) do
    raise ArgumentError, "expected a message map with a \"kind\" key, got: #{inspect(other)}"
  end

  defp validate_version!(%{"version" => @serialized_version}), do: :ok

  defp validate_version!(%{} = data) when not is_map_key(data, "version") do
    raise ArgumentError, "expected message map to include \"version\""
  end

  defp validate_version!(%{"version" => version}) do
    raise ArgumentError,
          "unsupported message serialization version: #{inspect(version)}"
  end

  defp validate_message_keys!(map) do
    allowed_keys = ["version", "kind", "role", "content"]

    case Map.keys(map) -- allowed_keys do
      [] ->
        :ok

      keys ->
        raise ArgumentError, "unexpected message field(s): #{inspect(keys)}"
    end
  end

  defp validate_role!(%{"role" => expected}, expected), do: :ok

  defp validate_role!(%{} = data, _expected) when not is_map_key(data, "role") do
    raise ArgumentError, "expected message map to include \"role\""
  end

  defp validate_role!(%{"kind" => kind, "role" => role}, expected) do
    raise ArgumentError,
          "message role #{inspect(role)} does not match kind #{inspect(kind)}; expected #{inspect(expected)}"
  end

  defp decode_user_content!(content) when is_binary(content), do: UserMessage.new(content)

  defp decode_user_content!(content) when is_list(content) do
    UserMessage.new(Enum.map(content, &Content.from_map/1))
  end

  defp decode_user_content!(content) do
    raise ArgumentError,
          "expected user message content to be a string or content list, got: #{inspect(content)}"
  end

  defp decode_content_list!(%{"content" => content}, _kind) when is_list(content) do
    Enum.map(content, &Content.from_map/1)
  end

  defp decode_content_list!(%{"content" => content}, kind) do
    raise ArgumentError,
          "expected #{kind} message content to be a content list, got: #{inspect(content)}"
  end

  defp decode_content_list!(%{}, kind) do
    raise ArgumentError, "expected #{kind} message map to include \"content\""
  end
end
