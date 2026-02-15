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
  Returns a human-readable summary of a tool invocation for logging.

  The default implementation formats as `tool_name(key=value, ...)` with
  truncation. Override this in your tool module for a more concise summary.

  ## Example

      def summarize(%{path: path}), do: "read_file(\#{path})"

  """
  @callback summarize(args :: map()) :: String.t()

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
      Returns a human-readable summary of a tool invocation for logging.
      Override this for a more concise format.
      """
      def summarize(args) when is_map(args) do
        Clementine.Tool.default_summarize(@tool_name, args)
      end

      defoverridable summarize: 1

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
    type =
      case Keyword.get(opts, :type) do
        nil ->
          raise ArgumentError, "Parameter #{param_name} must have a :type"

        type when type in @valid_types ->
          type

        invalid ->
          raise ArgumentError,
                "Parameter #{param_name} has invalid type #{inspect(invalid)}. " <>
                  "Valid types: #{inspect(@valid_types)}"
      end

    # Validate :items schema for array types
    if Keyword.has_key?(opts, :items) do
      items = Keyword.get(opts, :items)

      if type != :array do
        raise ArgumentError,
              "Parameter #{param_name} has :items but type is #{inspect(type)}, not :array"
      end

      if items != nil and items != [] do
        unless keyword_list?(items) do
          raise ArgumentError,
                "Parameter #{param_name} :items must be a keyword list, got: #{inspect(items)}"
        end

        validate_param_opts!(:"#{param_name}[]", items)
      end
    end

    # Validate :properties schema for object types
    if Keyword.has_key?(opts, :properties) do
      props = Keyword.get(opts, :properties)

      if type != :object do
        raise ArgumentError,
              "Parameter #{param_name} has :properties but type is #{inspect(type)}, not :object"
      end

      if props != nil and props != [] do
        unless keyword_list?(props) do
          raise ArgumentError,
                "Parameter #{param_name} :properties must be a keyword list, got: #{inspect(props)}"
        end

        Enum.each(props, fn {prop_name, prop_opts} ->
          unless is_atom(prop_name) do
            raise ArgumentError,
                  "Property name in #{param_name} must be an atom, got: #{inspect(prop_name)}"
          end

          validate_param_opts!(:"#{param_name}.#{prop_name}", prop_opts)
        end)
      end
    end
  end

  defp keyword_list?(list) when is_list(list) do
    Enum.all?(list, fn
      {key, _value} when is_atom(key) -> true
      _ -> false
    end)
  end

  defp keyword_list?(_), do: false

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

    case type do
      :array ->
        case Keyword.get(opts, :items) do
          nil -> schema
          [] -> schema
          item_schema -> Map.put(schema, "items", param_to_json_schema(item_schema))
        end

      :object ->
        case Keyword.get(opts, :properties) do
          nil -> schema
          [] -> schema
          properties -> Map.merge(schema, params_to_json_schema(properties))
        end

      _ ->
        schema
    end
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
    errors =
      parameters
      |> Enum.flat_map(fn {name, opts} -> validate_param(to_string(name), name, opts, args) end)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "; ")}
    end
  end

  defp validate_param(path, key, opts, args) do
    required? = Keyword.get(opts, :required, false)
    has_key? = Map.has_key?(args, key)
    value = Map.get(args, key)

    cond do
      required? and (!has_key? or value == nil) ->
        ["missing required parameter: #{path}"]

      not has_key? ->
        []

      value == nil ->
        []

      true ->
        check_value(path, opts, value)
    end
  end

  defp check_value(path, opts, value) do
    case Keyword.fetch(opts, :type) do
      {:ok, type} ->
        type_errors = validate_value(path, type, opts, value)
        if type_errors == [], do: validate_enum(path, opts, value), else: type_errors

      :error ->
        ["schema error: #{path} is missing :type"]
    end
  end

  defp validate_value(path, :string, _opts, value) do
    if is_binary(value),
      do: [],
      else: ["expected #{path} to be a string, got: #{type_name(value)}"]
  end

  defp validate_value(path, :integer, _opts, value) do
    if is_integer(value),
      do: [],
      else: ["expected #{path} to be an integer, got: #{type_name(value)}"]
  end

  defp validate_value(path, :number, _opts, value) do
    if is_number(value),
      do: [],
      else: ["expected #{path} to be a number, got: #{type_name(value)}"]
  end

  defp validate_value(path, :boolean, _opts, value) do
    if is_boolean(value),
      do: [],
      else: ["expected #{path} to be a boolean, got: #{type_name(value)}"]
  end

  defp validate_value(path, :array, opts, value) do
    if is_list(value),
      do: validate_array_items(path, opts, value),
      else: ["expected #{path} to be an array, got: #{type_name(value)}"]
  end

  defp validate_value(path, :object, opts, value) do
    if is_map(value),
      do: validate_object_properties(path, opts, value),
      else: ["expected #{path} to be an object, got: #{type_name(value)}"]
  end

  defp validate_value(path, type, _opts, _value) do
    ["schema error: #{path} has invalid type #{inspect(type)}"]
  end

  defp validate_enum(path, opts, value) do
    case Keyword.get(opts, :enum) do
      nil ->
        []

      allowed ->
        if value in allowed,
          do: [],
          else: ["#{path} must be one of #{inspect(allowed)}, got: #{inspect(value)}"]
    end
  end

  defp validate_array_items(path, opts, items) do
    case Keyword.get(opts, :items) do
      nil ->
        []

      [] ->
        []

      item_schema ->
        items
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, index} ->
          check_value("#{path}[#{index}]", item_schema, item)
        end)
    end
  end

  defp validate_object_properties(path, opts, map) do
    case Keyword.get(opts, :properties) do
      nil ->
        []

      [] ->
        []

      properties ->
        Enum.flat_map(properties, fn {prop_name, prop_opts} ->
          nested_path = "#{path}.#{prop_name}"
          required? = Keyword.get(prop_opts, :required, false)
          has_key? = Map.has_key?(map, prop_name)
          value = Map.get(map, prop_name)

          cond do
            required? and (!has_key? or value == nil) ->
              ["missing required parameter: #{nested_path}"]

            not has_key? ->
              []

            value == nil ->
              []

            true ->
              check_value(nested_path, prop_opts, value)
          end
        end)
    end
  end

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_map(value), do: "object"
  defp type_name(nil), do: "null"
  defp type_name(value), do: inspect(value)

  @doc """
  Default summarize implementation. Formats as `name(key=value, ...)`.
  Values are truncated to 60 characters.
  """
  def default_summarize(name, args) when is_map(args) do
    params =
      args
      |> Enum.reject(fn {k, _} -> k == :_clementine_iteration end)
      |> Enum.map(fn {k, v} -> "#{k}=#{truncate(inspect(v), 60)}" end)
      |> Enum.join(", ")

    "#{name}(#{params})"
  end

  defp truncate(string, max) when byte_size(string) <= max, do: string
  defp truncate(string, max), do: String.slice(string, 0, max - 1) <> "…"

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
