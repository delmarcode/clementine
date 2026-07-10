defmodule Clementine.LLM.ChatCompletions.Tools do
  @moduledoc false

  alias Clementine.Tool

  def encode(tool) when is_atom(tool) do
    schema = Tool.to_schema(tool)

    %{
      "type" => "function",
      "function" => %{
        "name" => schema.name,
        "description" => schema.description,
        "parameters" => schema.input_schema
      }
    }
  end

  def encode_all(tools) when is_list(tools) do
    Enum.map(tools, &encode/1)
  end
end
