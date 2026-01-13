defmodule Clementine.ToolTest do
  use ExUnit.Case, async: true

  alias Clementine.Tool

  describe "params_to_json_schema/1" do
    test "converts simple string parameter" do
      params = [
        name: [type: :string, required: true, description: "A name"]
      ]

      schema = Tool.params_to_json_schema(params)

      assert schema == %{
               "type" => "object",
               "properties" => %{
                 "name" => %{
                   "type" => "string",
                   "description" => "A name"
                 }
               },
               "required" => ["name"]
             }
    end

    test "converts multiple parameters with different types" do
      params = [
        count: [type: :integer, required: true],
        enabled: [type: :boolean, required: false],
        ratio: [type: :number]
      ]

      schema = Tool.params_to_json_schema(params)

      assert schema["properties"]["count"]["type"] == "integer"
      assert schema["properties"]["enabled"]["type"] == "boolean"
      assert schema["properties"]["ratio"]["type"] == "number"
      assert schema["required"] == ["count"]
    end

    test "converts enum parameter" do
      params = [
        status: [type: :string, enum: ["active", "inactive", "pending"]]
      ]

      schema = Tool.params_to_json_schema(params)

      assert schema["properties"]["status"]["enum"] == ["active", "inactive", "pending"]
    end

    test "converts array parameter" do
      params = [
        tags: [type: :array, items: [type: :string]]
      ]

      schema = Tool.params_to_json_schema(params)

      assert schema["properties"]["tags"]["type"] == "array"
      assert schema["properties"]["tags"]["items"]["type"] == "string"
    end

    test "converts nested object parameter" do
      params = [
        config: [
          type: :object,
          properties: [
            host: [type: :string, required: true],
            port: [type: :integer]
          ]
        ]
      ]

      schema = Tool.params_to_json_schema(params)

      assert schema["properties"]["config"]["type"] == "object"
      assert schema["properties"]["config"]["properties"]["host"]["type"] == "string"
      assert schema["properties"]["config"]["properties"]["port"]["type"] == "integer"
      assert schema["properties"]["config"]["required"] == ["host"]
    end

    test "handles empty parameters" do
      schema = Tool.params_to_json_schema([])

      assert schema == %{
               "type" => "object",
               "properties" => %{},
               "required" => []
             }
    end
  end

  describe "validate_args/2" do
    test "passes when all required parameters present" do
      params = [
        name: [type: :string, required: true],
        age: [type: :integer, required: true]
      ]

      args = %{name: "Alice", age: 30}

      assert :ok = Tool.validate_args(params, args)
    end

    test "fails when required parameter missing" do
      params = [
        name: [type: :string, required: true],
        age: [type: :integer, required: true]
      ]

      args = %{name: "Alice"}

      assert {:error, message} = Tool.validate_args(params, args)
      assert message =~ "age"
    end

    test "passes with optional parameters missing" do
      params = [
        name: [type: :string, required: true],
        nickname: [type: :string, required: false]
      ]

      args = %{name: "Alice"}

      assert :ok = Tool.validate_args(params, args)
    end

    test "passes with no parameters" do
      assert :ok = Tool.validate_args([], %{})
    end
  end

  describe "validate_schema!/3" do
    test "raises on empty name" do
      assert_raise ArgumentError, ~r/name must be a non-empty string/, fn ->
        Tool.validate_schema!("", "description", [])
      end
    end

    test "raises on empty description" do
      assert_raise ArgumentError, ~r/description must be a non-empty string/, fn ->
        Tool.validate_schema!("tool", "", [])
      end
    end

    test "raises on missing parameter type" do
      assert_raise ArgumentError, ~r/must have a :type/, fn ->
        Tool.validate_schema!("tool", "description", [param: [required: true]])
      end
    end

    test "raises on invalid parameter type" do
      assert_raise ArgumentError, ~r/invalid type/, fn ->
        Tool.validate_schema!("tool", "description", [param: [type: :invalid]])
      end
    end

    test "passes with valid schema" do
      assert :ok =
               Tool.validate_schema!("tool", "description", [
                 param: [type: :string, required: true]
               ])
    end
  end

  describe "tool module macro" do
    # Define a test tool inline
    defmodule TestTool do
      use Clementine.Tool,
        name: "test_tool",
        description: "A test tool",
        parameters: [
          input: [type: :string, required: true, description: "Test input"]
        ]

      @impl true
      def run(%{input: input}, _context) do
        {:ok, "Processed: #{input}"}
      end
    end

    test "__schema__/0 returns correct schema" do
      schema = TestTool.__schema__()

      assert schema.name == "test_tool"
      assert schema.description == "A test tool"
      assert schema.input_schema["properties"]["input"]["type"] == "string"
      assert schema.input_schema["required"] == ["input"]
    end

    test "__name__/0 returns tool name" do
      assert TestTool.__name__() == "test_tool"
    end

    test "__parameters__/0 returns parameters" do
      params = TestTool.__parameters__()
      assert Keyword.get(params, :input)[:type] == :string
    end

    test "execute/2 runs the tool" do
      assert {:ok, "Processed: hello"} = TestTool.execute(%{input: "hello"})
    end

    test "execute/2 validates required arguments" do
      assert {:error, message} = TestTool.execute(%{})
      assert message =~ "Missing required parameters"
    end
  end

  describe "tool module with crash handling" do
    defmodule CrashingTool do
      use Clementine.Tool,
        name: "crasher",
        description: "A tool that crashes",
        parameters: []

      @impl true
      def run(_args, _context) do
        raise "Boom!"
      end
    end

    test "execute/2 catches crashes and returns error" do
      assert {:error, message} = CrashingTool.execute(%{})
      assert message =~ "Tool crashed"
      assert message =~ "Boom!"
    end
  end

  describe "find_by_name/2" do
    defmodule Tool1 do
      use Clementine.Tool,
        name: "tool_one",
        description: "First tool",
        parameters: []

      @impl true
      def run(_, _), do: {:ok, "one"}
    end

    defmodule Tool2 do
      use Clementine.Tool,
        name: "tool_two",
        description: "Second tool",
        parameters: []

      @impl true
      def run(_, _), do: {:ok, "two"}
    end

    test "finds tool by name" do
      tools = [Tool1, Tool2]

      assert Tool.find_by_name(tools, "tool_one") == Tool1
      assert Tool.find_by_name(tools, "tool_two") == Tool2
    end

    test "returns nil for unknown tool" do
      tools = [Tool1, Tool2]

      assert Tool.find_by_name(tools, "unknown") == nil
    end
  end

  describe "to_anthropic_format/1" do
    defmodule AnthropicTool do
      use Clementine.Tool,
        name: "anthropic_test",
        description: "Test for API format",
        parameters: [
          path: [type: :string, required: true, description: "File path"]
        ]

      @impl true
      def run(_, _), do: {:ok, "ok"}
    end

    test "returns schema in Anthropic format" do
      schema = Tool.to_anthropic_format(AnthropicTool)

      assert schema.name == "anthropic_test"
      assert schema.description == "Test for API format"
      assert is_map(schema.input_schema)
    end
  end
end
