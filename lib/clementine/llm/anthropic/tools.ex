defmodule Clementine.LLM.Anthropic.Tools do
  @moduledoc false

  alias Clementine.Tool

  def encode(tool) when is_atom(tool) do
    schema = Tool.to_schema(tool)

    %{
      "name" => schema.name,
      "description" => schema.description,
      "input_schema" => schema.input_schema
    }
  end

  def encode_all(tools) when is_list(tools) do
    Enum.map(tools, &encode/1)
  end
end
