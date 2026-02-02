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

    test "array without :items omits items key from schema" do
      params = [tags: [type: :array]]
      schema = Tool.params_to_json_schema(params)

      assert schema["properties"]["tags"] == %{"type" => "array"}
      refute Map.has_key?(schema["properties"]["tags"], "items")
    end

    test "object without :properties omits properties key from schema" do
      params = [config: [type: :object]]
      schema = Tool.params_to_json_schema(params)

      assert schema["properties"]["config"] == %{"type" => "object"}
      refute Map.has_key?(schema["properties"]["config"], "properties")
      refute Map.has_key?(schema["properties"]["config"], "required")
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

    # Type checking: correct types pass

    test "string type passes with binary value" do
      params = [name: [type: :string, required: true]]
      assert :ok = Tool.validate_args(params, %{name: "Alice"})
    end

    test "integer type passes with integer value" do
      params = [count: [type: :integer, required: true]]
      assert :ok = Tool.validate_args(params, %{count: 42})
    end

    test "number type passes with integer value" do
      params = [ratio: [type: :number, required: true]]
      assert :ok = Tool.validate_args(params, %{ratio: 42})
    end

    test "number type passes with float value" do
      params = [ratio: [type: :number, required: true]]
      assert :ok = Tool.validate_args(params, %{ratio: 3.14})
    end

    test "boolean type passes with boolean value" do
      params = [verbose: [type: :boolean, required: true]]
      assert :ok = Tool.validate_args(params, %{verbose: true})
      assert :ok = Tool.validate_args(params, %{verbose: false})
    end

    test "array type passes with list value" do
      params = [tags: [type: :array, required: true, items: [type: :string]]]
      assert :ok = Tool.validate_args(params, %{tags: ["a", "b"]})
    end

    test "object type passes with map value" do
      params = [
        config: [
          type: :object,
          required: true,
          properties: [host: [type: :string, required: true]]
        ]
      ]

      assert :ok = Tool.validate_args(params, %{config: %{host: "localhost"}})
    end

    # Type checking: wrong types rejected

    test "rejects string where integer expected" do
      params = [count: [type: :integer, required: true]]
      assert {:error, msg} = Tool.validate_args(params, %{count: "five"})
      assert msg =~ "expected count to be an integer, got: string"
    end

    test "rejects integer where string expected" do
      params = [name: [type: :string, required: true]]
      assert {:error, msg} = Tool.validate_args(params, %{name: 123})
      assert msg =~ "expected name to be a string, got: integer"
    end

    test "rejects float for integer type" do
      params = [count: [type: :integer, required: true]]
      assert {:error, msg} = Tool.validate_args(params, %{count: 3.14})
      assert msg =~ "expected count to be an integer, got: float"
    end

    test "rejects string 'true' for boolean type" do
      params = [verbose: [type: :boolean, required: true]]
      assert {:error, msg} = Tool.validate_args(params, %{verbose: "true"})
      assert msg =~ "expected verbose to be a boolean, got: string"
    end

    test "rejects string for array type" do
      params = [tags: [type: :array, required: true]]
      assert {:error, msg} = Tool.validate_args(params, %{tags: "not-a-list"})
      assert msg =~ "expected tags to be an array, got: string"
    end

    test "rejects list for object type" do
      params = [config: [type: :object, required: true]]
      assert {:error, msg} = Tool.validate_args(params, %{config: [1, 2]})
      assert msg =~ "expected config to be an object, got: array"
    end

    # Enum validation

    test "enum: valid value passes" do
      params = [format: [type: :string, required: true, enum: ["json", "csv"]]]
      assert :ok = Tool.validate_args(params, %{format: "json"})
    end

    test "enum: invalid value rejected with message" do
      params = [format: [type: :string, required: true, enum: ["json", "csv"]]]
      assert {:error, msg} = Tool.validate_args(params, %{format: "xml"})
      assert msg =~ "format must be one of"
      assert msg =~ "json"
      assert msg =~ "csv"
      assert msg =~ "xml"
    end

    # Array item validation

    test "array: valid items pass" do
      params = [tags: [type: :array, required: true, items: [type: :string]]]
      assert :ok = Tool.validate_args(params, %{tags: ["a", "b", "c"]})
    end

    test "array: wrong item type rejected with index" do
      params = [tags: [type: :array, required: true, items: [type: :string]]]
      assert {:error, msg} = Tool.validate_args(params, %{tags: ["a", 42, "c"]})
      assert msg =~ "tags[1]"
      assert msg =~ "expected tags[1] to be a string, got: integer"
    end

    test "array: empty array passes" do
      params = [tags: [type: :array, required: true, items: [type: :string]]]
      assert :ok = Tool.validate_args(params, %{tags: []})
    end

    test "array: no items schema means no item validation" do
      params = [tags: [type: :array, required: true]]
      assert :ok = Tool.validate_args(params, %{tags: [1, "mixed", true]})
    end

    # Object property validation

    test "object: valid nested properties pass" do
      params = [
        config: [
          type: :object,
          required: true,
          properties: [
            host: [type: :string, required: true],
            port: [type: :integer]
          ]
        ]
      ]

      assert :ok = Tool.validate_args(params, %{config: %{host: "localhost", port: 8080}})
    end

    test "object: missing required nested property fails" do
      params = [
        config: [
          type: :object,
          required: true,
          properties: [
            host: [type: :string, required: true],
            port: [type: :integer]
          ]
        ]
      ]

      assert {:error, msg} = Tool.validate_args(params, %{config: %{port: 8080}})
      assert msg =~ "missing required parameter: config.host"
    end

    test "object: wrong nested property type rejected with path prefix" do
      params = [
        config: [
          type: :object,
          required: true,
          properties: [
            host: [type: :string, required: true],
            port: [type: :integer]
          ]
        ]
      ]

      assert {:error, msg} = Tool.validate_args(params, %{config: %{host: "localhost", port: "not-int"}})
      assert msg =~ "expected config.port to be an integer, got: string"
    end

    test "object: no properties schema means no nested validation" do
      params = [config: [type: :object, required: true]]
      assert :ok = Tool.validate_args(params, %{config: %{anything: "goes"}})
    end

    # Multiple errors

    test "multiple errors collected and joined" do
      params = [
        name: [type: :string, required: true],
        age: [type: :integer, required: true]
      ]

      assert {:error, msg} = Tool.validate_args(params, %{name: 123, age: "thirty"})
      assert msg =~ "expected name to be a string"
      assert msg =~ "expected age to be an integer"
      assert msg =~ "; "
    end

    # Optional param edge cases

    test "optional param omitted passes" do
      params = [
        name: [type: :string, required: true],
        nickname: [type: :string]
      ]

      assert :ok = Tool.validate_args(params, %{name: "Alice"})
    end

    test "optional param with wrong type rejected" do
      params = [
        name: [type: :string, required: true],
        nickname: [type: :string]
      ]

      assert {:error, msg} = Tool.validate_args(params, %{name: "Alice", nickname: 42})
      assert msg =~ "expected nickname to be a string, got: integer"
    end

    # Nil handling

    test "nil for required param treated as missing" do
      params = [name: [type: :string, required: true]]
      assert {:error, msg} = Tool.validate_args(params, %{name: nil})
      assert msg =~ "missing required parameter: name"
    end

    test "nil for optional param allowed" do
      params = [nickname: [type: :string]]
      assert :ok = Tool.validate_args(params, %{nickname: nil})
    end

    # Malformed schema at runtime (defensive)

    test "missing :type in items schema returns error instead of raising" do
      params = [tags: [type: :array, required: true, items: [description: "no type"]]]
      assert {:error, msg} = Tool.validate_args(params, %{tags: ["a"]})
      assert msg =~ "schema error"
      assert msg =~ "missing :type"
    end

    test "missing :type in nested properties schema returns error instead of raising" do
      params = [
        config: [
          type: :object,
          required: true,
          properties: [host: [description: "no type"]]
        ]
      ]

      assert {:error, msg} = Tool.validate_args(params, %{config: %{host: "localhost"}})
      assert msg =~ "schema error"
      assert msg =~ "missing :type"
    end

    test "invalid :type in dynamic schema returns error instead of raising" do
      params = [name: [type: :foo, required: true]]
      assert {:error, msg} = Tool.validate_args(params, %{name: "Alice"})
      assert msg =~ "schema error"
      assert msg =~ "invalid type"
      assert msg =~ ":foo"
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

    test "raises on missing :type in nested items schema" do
      assert_raise ArgumentError, ~r/must have a :type/, fn ->
        Tool.validate_schema!("tool", "description", [
          tags: [type: :array, items: [description: "no type"]]
        ])
      end
    end

    test "raises on invalid type in nested items schema" do
      assert_raise ArgumentError, ~r/invalid type/, fn ->
        Tool.validate_schema!("tool", "description", [
          tags: [type: :array, items: [type: :invalid]]
        ])
      end
    end

    test "raises on missing :type in nested properties schema" do
      assert_raise ArgumentError, ~r/must have a :type/, fn ->
        Tool.validate_schema!("tool", "description", [
          config: [type: :object, properties: [host: [required: true]]]
        ])
      end
    end

    test "raises on :items with non-array type" do
      assert_raise ArgumentError, ~r/has :items but type is :string, not :array/, fn ->
        Tool.validate_schema!("tool", "description", [
          name: [type: :string, items: [type: :string]]
        ])
      end
    end

    test "raises on :properties with non-object type" do
      assert_raise ArgumentError, ~r/has :properties but type is :string, not :object/, fn ->
        Tool.validate_schema!("tool", "description", [
          name: [type: :string, properties: [foo: [type: :string]]]
        ])
      end
    end

    test "raises on empty :items with non-array type" do
      assert_raise ArgumentError, ~r/has :items but type is :string, not :array/, fn ->
        Tool.validate_schema!("tool", "description", [
          name: [type: :string, items: []]
        ])
      end
    end

    test "raises on empty :properties with non-object type" do
      assert_raise ArgumentError, ~r/has :properties but type is :integer, not :object/, fn ->
        Tool.validate_schema!("tool", "description", [
          count: [type: :integer, properties: []]
        ])
      end
    end

    test "raises on non-keyword-list :items" do
      assert_raise ArgumentError, ~r/:items must be a keyword list/, fn ->
        Tool.validate_schema!("tool", "description", [
          tags: [type: :array, items: %{type: :string}]
        ])
      end
    end

    test "raises on non-keyword-list :properties" do
      assert_raise ArgumentError, ~r/:properties must be a keyword list/, fn ->
        Tool.validate_schema!("tool", "description", [
          config: [type: :object, properties: %{host: [type: :string]}]
        ])
      end
    end

    test "passes with valid nested array and object schemas" do
      assert :ok =
               Tool.validate_schema!("tool", "description", [
                 tags: [type: :array, items: [type: :string]],
                 config: [
                   type: :object,
                   properties: [
                     host: [type: :string, required: true],
                     port: [type: :integer]
                   ]
                 ]
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
      assert message =~ "missing required parameter"
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
