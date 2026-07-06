defmodule Clementine.ToolTest do
  use ExUnit.Case, async: true

  alias Clementine.{Tool, ToolResult}

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

    test "converts string and numeric bounds" do
      params = [
        code: [type: :string, min_length: 2, max_length: 8],
        score: [type: :number, minimum: 0, maximum: 1.5]
      ]

      schema = Tool.params_to_json_schema(params)

      assert schema["properties"]["code"]["minLength"] == 2
      assert schema["properties"]["code"]["maxLength"] == 8
      assert schema["properties"]["score"]["minimum"] == 0
      assert schema["properties"]["score"]["maximum"] == 1.5
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

    # Bounds validation

    test "numeric bounds: valid values pass" do
      params = [count: [type: :integer, required: true, minimum: 1, maximum: 5]]
      assert :ok = Tool.validate_args(params, %{count: 3})
    end

    test "numeric bounds: values outside bounds rejected" do
      params = [count: [type: :integer, required: true, minimum: 1, maximum: 5]]

      assert {:error, low_msg} = Tool.validate_args(params, %{count: 0})
      assert low_msg =~ "count must be greater than or equal to 1"

      assert {:error, high_msg} = Tool.validate_args(params, %{count: 6})
      assert high_msg =~ "count must be less than or equal to 5"
    end

    test "string bounds: valid values pass" do
      params = [code: [type: :string, required: true, min_length: 2, max_length: 4]]
      assert :ok = Tool.validate_args(params, %{code: "abc"})
    end

    test "string bounds: values outside bounds rejected" do
      params = [code: [type: :string, required: true, min_length: 2, max_length: 4]]

      assert {:error, short_msg} = Tool.validate_args(params, %{code: "a"})
      assert short_msg =~ "code length must be at least 2"

      assert {:error, long_msg} = Tool.validate_args(params, %{code: "abcde"})
      assert long_msg =~ "code length must be at most 4"
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

      assert {:error, msg} =
               Tool.validate_args(params, %{config: %{host: "localhost", port: "not-int"}})

      assert msg =~ "expected config.port to be an integer, got: string"
    end

    test "object: no properties schema means no nested validation" do
      params = [config: [type: :object, required: true]]
      assert :ok = Tool.validate_args(params, %{config: %{anything: "goes"}})
    end

    test "object: empty properties passes with string-keyed nested map" do
      params = [data: [type: :object, required: true, properties: []]]
      assert :ok = Tool.validate_args(params, %{data: %{"foo" => "bar"}})
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
        Tool.validate_schema!("tool", "description", param: [required: true])
      end
    end

    test "raises on invalid parameter type" do
      assert_raise ArgumentError, ~r/invalid type/, fn ->
        Tool.validate_schema!("tool", "description", param: [type: :invalid])
      end
    end

    test "raises on unknown parameter option" do
      assert_raise ArgumentError, ~r/unknown options \[:format\]/, fn ->
        Tool.validate_schema!("tool", "description", param: [type: :string, format: :email])
      end
    end

    test "passes with valid schema" do
      assert :ok =
               Tool.validate_schema!("tool", "description",
                 param: [type: :string, required: true]
               )
    end

    test "raises on missing :type in nested items schema" do
      assert_raise ArgumentError, ~r/must have a :type/, fn ->
        Tool.validate_schema!("tool", "description",
          tags: [type: :array, items: [description: "no type"]]
        )
      end
    end

    test "raises on invalid type in nested items schema" do
      assert_raise ArgumentError, ~r/invalid type/, fn ->
        Tool.validate_schema!("tool", "description",
          tags: [type: :array, items: [type: :invalid]]
        )
      end
    end

    test "raises on missing :type in nested properties schema" do
      assert_raise ArgumentError, ~r/must have a :type/, fn ->
        Tool.validate_schema!("tool", "description",
          config: [type: :object, properties: [host: [required: true]]]
        )
      end
    end

    test "raises on unknown option in nested properties schema" do
      assert_raise ArgumentError, ~r/parameter config\.host.*unknown options \[:format\]/, fn ->
        Tool.validate_schema!("tool", "description",
          config: [
            type: :object,
            properties: [host: [type: :string, format: :hostname]]
          ]
        )
      end
    end

    test "raises on :items with non-array type" do
      assert_raise ArgumentError, ~r/has :items but type is :string, not :array/, fn ->
        Tool.validate_schema!("tool", "description",
          name: [type: :string, items: [type: :string]]
        )
      end
    end

    test "raises on :properties with non-object type" do
      assert_raise ArgumentError, ~r/has :properties but type is :string, not :object/, fn ->
        Tool.validate_schema!("tool", "description",
          name: [type: :string, properties: [foo: [type: :string]]]
        )
      end
    end

    test "raises on empty :items with non-array type" do
      assert_raise ArgumentError, ~r/has :items but type is :string, not :array/, fn ->
        Tool.validate_schema!("tool", "description", name: [type: :string, items: []])
      end
    end

    test "raises on empty :properties with non-object type" do
      assert_raise ArgumentError, ~r/has :properties but type is :integer, not :object/, fn ->
        Tool.validate_schema!("tool", "description", count: [type: :integer, properties: []])
      end
    end

    test "raises on non-keyword-list :items" do
      assert_raise ArgumentError,
                   ~r/invalid value for :items option: expected keyword list/,
                   fn ->
                     Tool.validate_schema!("tool", "description",
                       tags: [type: :array, items: %{type: :string}]
                     )
                   end
    end

    test "raises on non-keyword-list :properties" do
      assert_raise ArgumentError,
                   ~r/invalid value for :properties option: expected keyword list/,
                   fn ->
                     Tool.validate_schema!("tool", "description",
                       config: [type: :object, properties: %{host: [type: :string]}]
                     )
                   end
    end

    test "raises on enum with non-string type" do
      assert_raise ArgumentError, ~r/has :enum but type is :integer, not :string/, fn ->
        Tool.validate_schema!("tool", "description", count: [type: :integer, enum: ["1", "2"]])
      end
    end

    test "raises on empty enum" do
      assert_raise ArgumentError, ~r/:enum must contain at least one value/, fn ->
        Tool.validate_schema!("tool", "description", status: [type: :string, enum: []])
      end
    end

    test "raises on non-string enum values" do
      assert_raise ArgumentError, ~r/invalid list in :enum option/, fn ->
        Tool.validate_schema!("tool", "description", status: [type: :string, enum: [:ok]])
      end
    end

    test "raises on numeric bounds with non-numeric type" do
      assert_raise ArgumentError, ~r/has numeric bounds but type is :string/, fn ->
        Tool.validate_schema!("tool", "description", name: [type: :string, minimum: 1])
      end
    end

    test "raises on inverted numeric bounds" do
      assert_raise ArgumentError, ~r/:minimum must be less than or equal to :maximum/, fn ->
        Tool.validate_schema!("tool", "description",
          score: [type: :number, minimum: 10, maximum: 1]
        )
      end
    end

    test "raises on string length bounds with non-string type" do
      assert_raise ArgumentError, ~r/has string length bounds but type is :integer/, fn ->
        Tool.validate_schema!("tool", "description", count: [type: :integer, min_length: 1])
      end
    end

    test "raises on inverted string length bounds" do
      assert_raise ArgumentError, ~r/:min_length must be less than or equal to :max_length/, fn ->
        Tool.validate_schema!("tool", "description",
          code: [type: :string, min_length: 5, max_length: 2]
        )
      end
    end

    test "passes with valid nested array and object schemas" do
      assert :ok =
               Tool.validate_schema!("tool", "description",
                 tags: [type: :array, items: [type: :string]],
                 config: [
                   type: :object,
                   properties: [
                     host: [type: :string, required: true],
                     port: [type: :integer]
                   ]
                 ]
               )
    end

    test "passes with valid enum and bounds" do
      assert :ok =
               Tool.validate_schema!("tool", "description",
                 status: [type: :string, enum: ["open", "closed"]],
                 code: [type: :string, min_length: 2, max_length: 8],
                 score: [type: :number, minimum: 0, maximum: 1.0]
               )
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
      assert {:ok, %ToolResult{content: "Processed: hello", is_error: false}} =
               TestTool.execute(%{input: "hello"})
    end

    test "execute/2 validates required arguments" do
      assert {:error, message} = TestTool.execute(%{})
      assert message =~ "missing required parameter"
    end

    test "invalid schemas raise during module compilation" do
      assert_raise ArgumentError, ~r/unknown options \[:format\]/, fn ->
        Code.compile_quoted(
          quote do
            defmodule InvalidCompileTimeTool do
              use Clementine.Tool,
                name: "invalid_compile_time_tool",
                description: "Invalid compile-time tool",
                parameters: [
                  input: [type: :string, format: :email]
                ]

              @impl true
              def run(_, _), do: {:ok, "ok"}
            end
          end
        )
      end
    end
  end

  describe "execution metadata" do
    defmodule DefaultMetaTool do
      use Clementine.Tool,
        name: "default_meta",
        description: "Declares no metadata",
        parameters: []

      @impl true
      def run(_args, _context), do: {:ok, "ok"}
    end

    defmodule SafeReadTool do
      use Clementine.Tool,
        name: "safe_read",
        description: "Declares itself effect-free",
        retry: :safe,
        parameters: []

      @impl true
      def run(_args, _context), do: {:ok, "ok"}
    end

    defmodule GatedDeployTool do
      use Clementine.Tool,
        name: "gated_deploy",
        description: "Requires human approval",
        approval: :required,
        retry: :unsafe,
        parameters: []

      @impl true
      def run(_args, _context), do: {:ok, "ok"}
    end

    defmodule PolicyGatedTool do
      use Clementine.Tool,
        name: "policy_gated",
        description: "Reserved policy approval shape",
        approval: {:policy, :prod_only},
        parameters: []

      @impl true
      def run(_args, _context), do: {:ok, "ok"}
    end

    test "defaults: approval :never, retry :unknown" do
      assert DefaultMetaTool.__approval__() == :never
      assert DefaultMetaTool.__retry__() == :unknown
    end

    test "declared metadata round-trips through the accessors" do
      assert SafeReadTool.__retry__() == :safe
      assert GatedDeployTool.__approval__() == :required
      assert GatedDeployTool.__retry__() == :unsafe
      assert PolicyGatedTool.__approval__() == {:policy, :prod_only}
    end

    test "Tool.approval/1 and Tool.retry/1 read declared metadata" do
      assert Tool.approval(GatedDeployTool) == :required
      assert Tool.retry(SafeReadTool) == :safe
    end

    test "modules without the metadata functions fall back to the conservative defaults" do
      # A hand-rolled tool module predating the metadata: approval gating
      # is opt-in, retryability is unknown (treated as unsafe).
      assert Tool.approval(String) == :never
      assert Tool.retry(String) == :unknown
    end

    test "an invalid :retry raises at compile time" do
      assert_raise ArgumentError, ~r/invalid :retry :sometimes/, fn ->
        Code.compile_quoted(
          quote do
            defmodule InvalidRetryTool do
              use Clementine.Tool,
                name: "invalid_retry",
                description: "Invalid retry metadata",
                retry: :sometimes

              @impl true
              def run(_, _), do: {:ok, "ok"}
            end
          end
        )
      end
    end

    test "an invalid :approval raises at compile time" do
      assert_raise ArgumentError, ~r/invalid :approval :ask_nicely/, fn ->
        Code.compile_quoted(
          quote do
            defmodule InvalidApprovalTool do
              use Clementine.Tool,
                name: "invalid_approval",
                description: "Invalid approval metadata",
                approval: :ask_nicely

              @impl true
              def run(_, _), do: {:ok, "ok"}
            end
          end
        )
      end
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

  describe "to_schema/1" do
    defmodule SchemaTool do
      use Clementine.Tool,
        name: "schema_test",
        description: "Test for API format",
        parameters: [
          path: [type: :string, required: true, description: "File path"]
        ]

      @impl true
      def run(_, _), do: {:ok, "ok"}
    end

    test "returns provider-neutral tool schema" do
      schema = Tool.to_schema(SchemaTool)

      assert schema.name == "schema_test"
      assert schema.description == "Test for API format"
      assert is_map(schema.input_schema)
    end
  end
end
