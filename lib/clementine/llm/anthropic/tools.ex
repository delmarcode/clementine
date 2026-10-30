defmodule Clementine.LLM.Anthropic.Tools do
  @moduledoc false

  alias Clementine.Tool

  # The Messages API's tool search (GA, no beta header). The regex variant
  # has Claude write a pattern over tool names, descriptions, and argument
  # names; it returns up to five matches unless Claude asks for more.
  @tool_search %{
    "type" => "tool_search_tool_regex_20251119",
    "name" => "tool_search_tool_regex"
  }

  # The models released before tool search: Claude 3.x and earlier, and
  # Opus 4, Opus 4.1, and Sonnet 4 (Anthropic's tool search model
  # compatibility table, read 2026-10-29). The set is closed, so every
  # model not in it, including any released later, has tool search.
  def searchable?(model_id) when is_binary(model_id) do
    not Regex.match?(
      ~r/^claude-(instant|2|3)|^claude-(opus|sonnet)-4(-[01])?(-\d{8})?$/,
      model_id
    )
  end

  def encode(tool) when is_atom(tool) do
    schema = Tool.to_schema(tool)

    %{
      "name" => schema.name,
      "description" => schema.description,
      "input_schema" => schema.input_schema
    }
  end

  # Tools in `deferred` go with `defer_loading: true`, and the tool search
  # tool leads the list when any do. Deferred tools are still sent whole on
  # every request: the API searches them server-side and expands the
  # references a search returns, but keeps them out of the model's context
  # until then. The search tool is never deferred, which keeps the API's
  # rule that at least one tool is not.
  def encode_all(tools, deferred \\ []) when is_list(tools) and is_list(deferred) do
    encoded =
      Enum.map(tools, fn tool ->
        if tool in deferred do
          Map.put(encode(tool), "defer_loading", true)
        else
          encode(tool)
        end
      end)

    if Enum.any?(tools, &(&1 in deferred)), do: [@tool_search | encoded], else: encoded
  end
end
