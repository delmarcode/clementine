defmodule Clementine.ToolResult do
  @moduledoc """
  Validated successful output from a tool invocation.

  Tool authors may return either `{:ok, content}`, `{:ok, content, opts}`, or
  `{:error, reason}` from `run/2`. Execution code normalizes those callback
  returns into `{:ok, %__MODULE__{}}` or `{:error, reason}` before telemetry or
  message formatting see them.
  """

  @enforce_keys [:content, :is_error]
  defstruct [:content, :is_error]

  @type t :: %__MODULE__{
          content: String.t(),
          is_error: boolean()
        }

  @type normalized :: {:ok, t()} | {:error, String.t()}

  @doc """
  Builds a successful tool result.
  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(content, opts \\ [])

  def new(content, opts) when is_binary(content) and is_list(opts) do
    normalize_success_opts(content, opts)
  end

  def new(content, _opts) do
    invalid("expected successful tool content to be a string, got: #{type_name(content)}")
  end

  @doc """
  Converts a tool callback return into the canonical result shape.
  """
  @spec normalize(term()) :: normalized()
  def normalize(%__MODULE__{} = result) do
    validate_struct(result)
  end

  def normalize({:ok, %__MODULE__{} = result}) do
    validate_struct(result)
  end

  def normalize({:ok, content}), do: new(content)

  def normalize({:ok, content, opts}), do: new(content, opts)

  def normalize({:error, reason}) when is_binary(reason) do
    {:error, reason}
  end

  def normalize({:error, reason}) do
    invalid("expected tool error reason to be a string, got: #{type_name(reason)}")
  end

  def normalize(result) do
    invalid(
      "expected {:ok, string}, {:ok, string, opts}, {:error, string}, or #{inspect(__MODULE__)}, got: " <>
        inspect(result)
    )
  end

  @doc """
  Returns the content that should be sent to the model.
  """
  @spec content(normalized()) :: String.t()
  def content({:ok, %__MODULE__{content: content}}), do: content
  def content({:error, reason}), do: "Error: #{reason}"

  @doc """
  Returns whether a normalized result should be marked as an error for the model.
  """
  @spec error?(normalized()) :: boolean()
  def error?({:ok, %__MODULE__{is_error: is_error}}), do: is_error
  def error?({:error, _reason}), do: true

  @doc """
  Returns the error value used by error reporting helpers.
  """
  @spec error_value(normalized()) :: String.t() | nil
  def error_value({:ok, %__MODULE__{content: content, is_error: true}}), do: content
  def error_value({:ok, %__MODULE__{is_error: false}}), do: nil
  def error_value({:error, reason}), do: reason

  defp validate_struct(%__MODULE__{content: content, is_error: is_error} = result)
       when is_binary(content) and is_boolean(is_error) do
    {:ok, result}
  end

  defp validate_struct(%__MODULE__{content: content}) when not is_binary(content) do
    invalid("expected successful tool content to be a string, got: #{type_name(content)}")
  end

  defp validate_struct(%__MODULE__{is_error: is_error}) do
    invalid("expected :is_error to be a boolean, got: #{type_name(is_error)}")
  end

  defp normalize_success_opts(content, opts) do
    cond do
      not Keyword.keyword?(opts) ->
        invalid("expected successful tool options to be a keyword list, got: #{type_name(opts)}")

      unknown_opts(opts) != [] ->
        invalid("unknown successful tool option(s): #{inspect(unknown_opts(opts))}")

      not is_boolean(Keyword.get(opts, :is_error, false)) ->
        invalid("expected :is_error option to be a boolean")

      true ->
        {:ok, %__MODULE__{content: content, is_error: Keyword.get(opts, :is_error, false)}}
    end
  end

  defp unknown_opts(opts) do
    opts
    |> Keyword.keys()
    |> Enum.uniq()
    |> Kernel.--([:is_error])
  end

  defp invalid(reason), do: {:error, "Invalid tool result: #{reason}"}

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(nil), do: "nil"
  defp type_name(value), do: inspect(value)
end
