defmodule Clementine.LLM.ProviderToolsTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.Anthropic
  alias Clementine.LLM.OpenAI

  defmodule WeatherTool do
    use Clementine.Tool,
      name: "weather",
      description: "Get weather",
      parameters: [
        location: [type: :string, required: true]
      ]

    @impl true
    def run(_args, _context), do: {:ok, "sunny"}
  end

  test "Anthropic.Tools encodes provider wire schema" do
    assert %{
             "name" => "weather",
             "description" => "Get weather",
             "input_schema" => %{"type" => "object"}
           } = Anthropic.Tools.encode(WeatherTool)
  end

  test "OpenAI.Tools encodes provider wire schema" do
    assert %{
             "type" => "function",
             "name" => "weather",
             "description" => "Get weather",
             "parameters" => %{"type" => "object"}
           } = OpenAI.Tools.encode(WeatherTool)
  end
end
