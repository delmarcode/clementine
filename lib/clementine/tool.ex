defmodule Clementine.Tool do
  @moduledoc """
  Behaviour and macro for defining tools that agents can use.

  A tool is a function with a schema that an LLM can call. Tools are the primary
  building blocks of agent execution.

  ## Example

      defmodule MyApp.Tools.ReadFile do
        use Clementine.Tool,
          name: "read_file",
          description: "Read the contents of a file",
          parameters: [
            path: [type: :string, required: true, description: "Path to the file"]
          ]

        @impl true
        def run(%{path: path}, _context) do
          case File.read(path) do
            {:ok, content} -> {:ok, content}
            {:error, reason} -> {:error, "Failed to read \#{path}: \#{inspect(reason)}"}
          end
        end
      end

  ## Parameters

  Parameters are defined using a keyword list with the following options per parameter:

  - `:type` - The parameter type. One of: `:string`, `:integer`, `:number`, `:boolean`, `:array`, `:object`
  - `:required` - Whether the parameter is required (default: `false`)
  - `:description` - Human-readable description of the parameter
  - `:enum` - For string types, a list of allowed values
  - `:items` - For array types, the schema of array items
  - `:properties` - For object types, nested parameter definitions
  """

  @type context :: %{
          optional(:working_dir) => String.t(),
          optional(:agent_pid) => pid(),
          optional(atom()) => any()
        }

  @type result :: {:ok, String.t()} | {:ok, String.t(), keyword()} | {:error, String.t()}

  @doc """
  Execute the tool with the given arguments and context.

  Arguments are passed as a map with atom keys. The context provides
  additional information about the execution environment.

  Returns `{:ok, result}` where result is always a string, or
  `{:error, reason}` where reason is a string description of the error.

  A tool may also return `{:ok, result, opts}` where opts is a keyword list.
  Use `is_error: true` to signal a command-level failure (e.g. non-zero exit)
  that should be surfaced to the model as an error, while distinguishing it
  from an invocation failure (`{:error, reason}`).
  """
  @callback run(args :: map(), context :: context()) :: result()

  @doc """
  Invoked when using the tool module.

  ## Options

  - `:name` - Required. The tool name as it will appear to the LLM.
  - `:description` - Required. A description of what the tool does.
  - `:parameters` - Optional. A keyword list defining the tool's parameters.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Clementine.Tool

      @tool_name Keyword.fetch!(opts, :name)
      @tool_description Keyword.fetch!(opts, :description)
      @tool_parameters Keyword.get(opts, :parameters, [])

      # Validate at compile time
      Clementine.Tool.validate_schema!(@tool_name, @tool_description, @tool_parameters)

      @doc """
      Returns the tool's schema as a map suitable for the Anthropic API.
      """
      def __schema__ do
        %{
          name: @tool_name,
          description: @tool_description,
          input_schema: Clementine.Tool.params_to_json_schema(@tool_parameters)
        }
      end

      @doc """
      Returns the tool's name.
      """
      def __name__, do: @tool_name

      @doc """
      Returns the tool's parameter definitions.
      """
      def __parameters__, do: @tool_parameters

      @doc """
      Executes the tool with argument validation.
      """
      def execute(args, context \\ %{}) when is_map(args) do
        case Clementine.Tool.validate_args(@tool_parameters, args) do
          :ok ->
            try do
              run(args, context)
            rescue
              e ->
                {:error, "Tool crashed: #{Exception.message(e)}"}
            end

          {:error, reason} ->
            {:error, "Invalid arguments: #{reason}"}
        end
      end
    end
  end

  @doc """
  Validates the tool schema at compile time.
  """
  def validate_schema!(name, description, parameters) do
    unless is_binary(name) and byte_size(name) > 0 do
      raise ArgumentError, "Tool name must be a non-empty string"
    end

    unless is_binary(description) and byte_size(description) > 0 do
      raise ArgumentError, "Tool description must be a non-empty string"
    end

    unless is_list(parameters) do
      raise ArgumentError, "Tool parameters must be a keyword list"
    end

    Enum.each(parameters, fn {param_name, opts} ->
      unless is_atom(param_name) do
        raise ArgumentError, "Parameter name must be an atom, got: #{inspect(param_name)}"
      end

      validate_param_opts!(param_name, opts)
    end)
  end

  @valid_types [:string, :integer, :number, :boolean, :array, :object]

  defp validate_param_opts!(param_name, opts) do
    case Keyword.get(opts, :type) do
      nil ->
        raise ArgumentError, "Parameter #{param_name} must have a :type"

      type when type in @valid_types ->
        :ok

      invalid ->
        raise ArgumentError,
              "Parameter #{param_name} has invalid type #{inspect(invalid)}. " <>
                "Valid types: #{inspect(@valid_types)}"
    end
  end

  @doc """
  Converts parameter definitions to JSON Schema format.
  """
  def params_to_json_schema(parameters) do
    properties =
      parameters
      |> Enum.map(fn {name, opts} ->
        {Atom.to_string(name), param_to_json_schema(opts)}
      end)
      |> Map.new()

    required =
      parameters
      |> Enum.filter(fn {_name, opts} -> Keyword.get(opts, :required, false) end)
      |> Enum.map(fn {name, _opts} -> Atom.to_string(name) end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required
    }
  end

  defp param_to_json_schema(opts) do
    type = Keyword.fetch!(opts, :type)

    schema =
      %{"type" => type_to_json_type(type)}
      |> maybe_add("description", Keyword.get(opts, :description))
      |> maybe_add("enum", Keyword.get(opts, :enum))

    schema =
      case type do
        :array ->
          items = Keyword.get(opts, :items, [])
          Map.put(schema, "items", param_to_json_schema(items))

        :object ->
          properties = Keyword.get(opts, :properties, [])
          nested = params_to_json_schema(properties)
          Map.merge(schema, nested)

        _ ->
          schema
      end

    schema
  end

  defp type_to_json_type(:string), do: "string"
  defp type_to_json_type(:integer), do: "integer"
  defp type_to_json_type(:number), do: "number"
  defp type_to_json_type(:boolean), do: "boolean"
  defp type_to_json_type(:array), do: "array"
  defp type_to_json_type(:object), do: "object"

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  @doc """
  Validates arguments against parameter definitions.
  """
  def validate_args(parameters, args) do
    required_params =
      parameters
      |> Enum.filter(fn {_name, opts} -> Keyword.get(opts, :required, false) end)
      |> Enum.map(fn {name, _opts} -> name end)

    missing =
      required_params
      |> Enum.reject(fn name -> Map.has_key?(args, name) end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, "Missing required parameters: #{inspect(missing)}"}
    end
  end

  @doc """
  Converts a tool module to Anthropic API format.
  """
  def to_anthropic_format(tool_module) when is_atom(tool_module) do
    tool_module.__schema__()
  end

  @doc """
  Finds a tool module by name from a list of tool modules.
  """
  def find_by_name(tools, name) when is_list(tools) and is_binary(name) do
    Enum.find(tools, fn tool -> tool.__name__() == name end)
  end
end
