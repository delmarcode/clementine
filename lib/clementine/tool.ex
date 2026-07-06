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
  - `:minimum` / `:maximum` - For integer and number types, inclusive bounds
  - `:min_length` / `:max_length` - For string types, inclusive length bounds

  ## Execution Metadata

  Beyond the wire schema, a tool declares how the execution machinery may
  treat it (RFC §Attempts, Retries, And The Effect Fence):

  - `:retry` - `:safe | :unsafe | :unknown` (default `:unknown`, treated as
    `:unsafe`). `:safe` declares the tool free of external effects: running
    it twice is as good as once, and killing it mid-flight loses nothing.
    The engine raises the effect fence only for batches containing a
    non-`:safe` tool, and a cooperative cancel kills `:safe` tools
    immediately while unsafe ones run out their own timeout.
  - `:approval` - `:never | :required | {:policy, term()}` (default
    `:never`). Anything but `:never` asks the engine to pause for a human
    decision before executing; `{:policy, term}` is a reserved shape. The
    suspend-for-approval flow arrives with gated tools — until then the
    engine fails closed rather than execute an approval-gated tool ungated.
  """

  @type context :: %{
          optional(:working_dir) => String.t(),
          optional(:workspace_root) => String.t(),
          optional(:capabilities) => %{
            optional(:read) => boolean(),
            optional(:write) => boolean(),
            optional(:shell) => boolean()
          },
          optional(:agent_pid) => pid(),
          optional(atom()) => any()
        }

  @type callback_result :: {:ok, String.t()} | {:ok, String.t(), keyword()} | {:error, String.t()}
  @type result :: {:ok, Clementine.ToolResult.t()} | {:error, String.t()}

  @doc """
  Execute the tool with the given arguments and context.

  Arguments are passed as a map with atom keys. The context provides
  additional information about the execution environment.

  Returns `{:ok, %Clementine.ToolResult{}}`, or `{:error, reason}` where
  reason is a string description of the error.

  A tool may also return `{:ok, result, opts}` where opts is a keyword list.
  Use `is_error: true` to signal a command-level failure (e.g. non-zero exit)
  that should be surfaced to the model as an error, while distinguishing it
  from an invocation failure (`{:error, reason}`).
  `execute/2` normalizes `{:ok, result}` callback returns into
  `{:ok, %Clementine.ToolResult{content: result, is_error: false}}`.
  """
  @callback run(args :: map(), context :: context()) :: callback_result()

  @doc """
  Returns a human-readable summary of a tool invocation for logging.

  The default implementation formats as `tool_name(key=value, ...)` with
  truncation. Override this in your tool module for a more concise summary.

  ## Example

      def summarize(%{path: path}), do: "read_file(\#{path})"

  """
  @callback summarize(args :: map()) :: String.t()

  @type approval :: :never | :required | {:policy, term()}
  @type retry :: :safe | :unsafe | :unknown

  @doc """
  Invoked when using the tool module.

  ## Options

  - `:name` - Required. The tool name as it will appear to the LLM.
  - `:description` - Required. A description of what the tool does.
  - `:parameters` - Optional. A keyword list defining the tool's parameters.
  - `:approval` - Optional. `:never | :required | {:policy, term()}`
    (default `:never`). See "Execution Metadata" above.
  - `:retry` - Optional. `:safe | :unsafe | :unknown` (default `:unknown`,
    treated as `:unsafe`). See "Execution Metadata" above.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Clementine.Tool

      @tool_name Keyword.fetch!(opts, :name)
      @tool_description Keyword.fetch!(opts, :description)
      @tool_parameters Keyword.get(opts, :parameters, [])
      @tool_approval Keyword.get(opts, :approval, :never)
      @tool_retry Keyword.get(opts, :retry, :unknown)

      # Validate at compile time
      Clementine.Tool.validate_schema!(@tool_name, @tool_description, @tool_parameters)
      Clementine.Tool.validate_metadata!(@tool_name, @tool_approval, @tool_retry)

      @doc """
      Returns the tool's provider-neutral schema.
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
      Returns the tool's approval metadata.
      """
      def __approval__, do: @tool_approval

      @doc """
      Returns the tool's retry metadata.
      """
      def __retry__, do: @tool_retry

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
              __MODULE__
              |> apply(:run, [args, context])
              |> Clementine.ToolResult.normalize()
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

    validate_parameters!(parameters, :parameter, nil, [])

    :ok
  end

  @doc """
  Validates the tool's execution metadata at compile time.
  """
  def validate_metadata!(name, approval, retry) do
    unless approval in [:never, :required] or match?({:policy, _}, approval) do
      raise ArgumentError,
            "Tool #{name} has invalid :approval #{inspect(approval)}. " <>
              "Valid: :never, :required, or {:policy, term}"
    end

    unless retry in [:safe, :unsafe, :unknown] do
      raise ArgumentError,
            "Tool #{name} has invalid :retry #{inspect(retry)}. " <>
              "Valid: :safe, :unsafe, or :unknown"
    end

    :ok
  end

  @valid_types [:string, :integer, :number, :boolean, :array, :object]
  @numeric_bound_type {:or, [:integer, :float]}
  @parameter_option_schema NimbleOptions.new!(
                             type: [
                               type: {:in, @valid_types},
                               required: true
                             ],
                             required: [
                               type: :boolean,
                               default: false
                             ],
                             description: [
                               type: :string
                             ],
                             enum: [
                               type: {:list, :string}
                             ],
                             items: [
                               type: :keyword_list
                             ],
                             properties: [
                               type: :keyword_list
                             ],
                             minimum: [
                               type: @numeric_bound_type
                             ],
                             maximum: [
                               type: @numeric_bound_type
                             ],
                             min_length: [
                               type: :non_neg_integer
                             ],
                             max_length: [
                               type: :non_neg_integer
                             ]
                           )

  defp validate_parameters!(parameters, key_kind, parent_path, path_segments) do
    Enum.each(parameters, fn
      {name, opts} when is_atom(name) ->
        validate_param_opts!(path_segments ++ [name], opts)

      {name, _opts} ->
        raise ArgumentError, invalid_schema_key_message(key_kind, parent_path, name)

      other ->
        raise ArgumentError,
              "Tool parameters must be a keyword list, got entry: #{inspect(other)}"
    end)
  end

  defp validate_param_opts!(path_segments, opts) do
    path = schema_path(path_segments)

    unless keyword_list?(opts) do
      raise ArgumentError,
            "Parameter #{path} options must be a keyword list, got: #{inspect(opts)}"
    end

    opts =
      case NimbleOptions.validate(opts, @parameter_option_schema) do
        {:ok, opts} ->
          opts

        {:error, %NimbleOptions.ValidationError{} = error} ->
          raise_param_schema_error!(path, error)
      end

    type = Keyword.fetch!(opts, :type)

    validate_enum_schema!(path, type, opts)
    validate_numeric_bounds_schema!(path, type, opts)
    validate_string_bounds_schema!(path, type, opts)
    validate_items_schema!(path_segments, path, type, opts)
    validate_properties_schema!(path_segments, path, type, opts)
  end

  defp validate_items_schema!(path_segments, path, type, opts) do
    case Keyword.fetch(opts, :items) do
      :error ->
        :ok

      {:ok, _items} when type != :array ->
        raise ArgumentError,
              "Parameter #{path} has :items but type is #{inspect(type)}, not :array"

      {:ok, []} ->
        :ok

      {:ok, items} ->
        validate_param_opts!(path_segments ++ [:array_item], items)
    end
  end

  defp validate_properties_schema!(path_segments, path, type, opts) do
    case Keyword.fetch(opts, :properties) do
      :error ->
        :ok

      {:ok, _properties} when type != :object ->
        raise ArgumentError,
              "Parameter #{path} has :properties but type is #{inspect(type)}, not :object"

      {:ok, []} ->
        :ok

      {:ok, properties} ->
        validate_parameters!(properties, :property, path, path_segments)
    end
  end

  defp validate_enum_schema!(path, :string, opts) do
    case Keyword.fetch(opts, :enum) do
      :error ->
        :ok

      {:ok, []} ->
        raise ArgumentError, "Parameter #{path} :enum must contain at least one value"

      {:ok, _enum} ->
        :ok
    end
  end

  defp validate_enum_schema!(path, type, opts) do
    if Keyword.has_key?(opts, :enum) do
      raise ArgumentError,
            "Parameter #{path} has :enum but type is #{inspect(type)}, not :string"
    end

    :ok
  end

  defp validate_numeric_bounds_schema!(path, type, opts) when type in [:integer, :number] do
    minimum = Keyword.get(opts, :minimum)
    maximum = Keyword.get(opts, :maximum)

    if is_number(minimum) and is_number(maximum) and minimum > maximum do
      raise ArgumentError,
            "Parameter #{path} :minimum must be less than or equal to :maximum"
    end

    :ok
  end

  defp validate_numeric_bounds_schema!(path, type, opts) do
    if Keyword.has_key?(opts, :minimum) or Keyword.has_key?(opts, :maximum) do
      raise ArgumentError,
            "Parameter #{path} has numeric bounds but type is #{inspect(type)}, not :integer or :number"
    end

    :ok
  end

  defp validate_string_bounds_schema!(path, :string, opts) do
    min_length = Keyword.get(opts, :min_length)
    max_length = Keyword.get(opts, :max_length)

    if is_integer(min_length) and is_integer(max_length) and min_length > max_length do
      raise ArgumentError,
            "Parameter #{path} :min_length must be less than or equal to :max_length"
    end

    :ok
  end

  defp validate_string_bounds_schema!(path, type, opts) do
    if Keyword.has_key?(opts, :min_length) or Keyword.has_key?(opts, :max_length) do
      raise ArgumentError,
            "Parameter #{path} has string length bounds but type is #{inspect(type)}, not :string"
    end

    :ok
  end

  defp raise_param_schema_error!(path, %NimbleOptions.ValidationError{key: :type, value: nil}) do
    raise ArgumentError, "Parameter #{path} must have a :type"
  end

  defp raise_param_schema_error!(path, %NimbleOptions.ValidationError{key: :type, value: invalid}) do
    raise ArgumentError,
          "Parameter #{path} has invalid type #{inspect(invalid)}. " <>
            "Valid types: #{inspect(@valid_types)}"
  end

  defp raise_param_schema_error!(path, %NimbleOptions.ValidationError{} = error) do
    raise ArgumentError, "Invalid schema for parameter #{path}: #{Exception.message(error)}"
  end

  defp invalid_schema_key_message(:parameter, _parent_path, name) do
    "Parameter name must be an atom, got: #{inspect(name)}"
  end

  defp invalid_schema_key_message(:property, parent_path, name) do
    "Property name in #{parent_path} must be an atom, got: #{inspect(name)}"
  end

  defp schema_path(path_segments) do
    Enum.reduce(path_segments, "", fn
      :array_item, "" -> "[]"
      :array_item, acc -> acc <> "[]"
      segment, "" -> Atom.to_string(segment)
      segment, acc -> acc <> "." <> Atom.to_string(segment)
    end)
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
      |> maybe_add("minimum", Keyword.get(opts, :minimum))
      |> maybe_add("maximum", Keyword.get(opts, :maximum))
      |> maybe_add("minLength", Keyword.get(opts, :min_length))
      |> maybe_add("maxLength", Keyword.get(opts, :max_length))

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
        if type_errors == [], do: validate_constraints(path, type, opts, value), else: type_errors

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

  defp validate_constraints(path, type, opts, value) do
    validate_enum(path, type, opts, value) ++
      validate_numeric_bounds(path, type, opts, value) ++
      validate_string_bounds(path, type, opts, value)
  end

  defp validate_enum(path, :string, opts, value) do
    case Keyword.fetch(opts, :enum) do
      :error ->
        []

      {:ok, allowed} when is_list(allowed) ->
        if value in allowed,
          do: [],
          else: ["#{path} must be one of #{inspect(allowed)}, got: #{inspect(value)}"]

      {:ok, invalid} ->
        ["schema error: #{path} has invalid :enum #{inspect(invalid)}"]
    end
  end

  defp validate_enum(path, type, opts, _value) do
    if Keyword.has_key?(opts, :enum),
      do: ["schema error: #{path} has :enum but type is #{inspect(type)}, not :string"],
      else: []
  end

  defp validate_numeric_bounds(path, type, opts, value) when type in [:integer, :number] do
    min_errors =
      case Keyword.fetch(opts, :minimum) do
        :error ->
          []

        {:ok, minimum} when is_number(minimum) ->
          if value >= minimum,
            do: [],
            else: [
              "#{path} must be greater than or equal to #{inspect(minimum)}, got: #{inspect(value)}"
            ]

        {:ok, invalid} ->
          ["schema error: #{path} has invalid :minimum #{inspect(invalid)}"]
      end

    max_errors =
      case Keyword.fetch(opts, :maximum) do
        :error ->
          []

        {:ok, maximum} when is_number(maximum) ->
          if value <= maximum,
            do: [],
            else: [
              "#{path} must be less than or equal to #{inspect(maximum)}, got: #{inspect(value)}"
            ]

        {:ok, invalid} ->
          ["schema error: #{path} has invalid :maximum #{inspect(invalid)}"]
      end

    min_errors ++ max_errors
  end

  defp validate_numeric_bounds(path, type, opts, _value) do
    if Keyword.has_key?(opts, :minimum) or Keyword.has_key?(opts, :maximum),
      do: [
        "schema error: #{path} has numeric bounds but type is #{inspect(type)}, not :integer or :number"
      ],
      else: []
  end

  defp validate_string_bounds(path, :string, opts, value) do
    length = String.length(value)

    min_errors =
      case Keyword.fetch(opts, :min_length) do
        :error ->
          []

        {:ok, min_length} when is_integer(min_length) and min_length >= 0 ->
          if length >= min_length,
            do: [],
            else: ["#{path} length must be at least #{min_length}, got: #{length}"]

        {:ok, invalid} ->
          ["schema error: #{path} has invalid :min_length #{inspect(invalid)}"]
      end

    max_errors =
      case Keyword.fetch(opts, :max_length) do
        :error ->
          []

        {:ok, max_length} when is_integer(max_length) and max_length >= 0 ->
          if length <= max_length,
            do: [],
            else: ["#{path} length must be at most #{max_length}, got: #{length}"]

        {:ok, invalid} ->
          ["schema error: #{path} has invalid :max_length #{inspect(invalid)}"]
      end

    min_errors ++ max_errors
  end

  defp validate_string_bounds(path, type, opts, _value) do
    if Keyword.has_key?(opts, :min_length) or Keyword.has_key?(opts, :max_length),
      do: [
        "schema error: #{path} has string length bounds but type is #{inspect(type)}, not :string"
      ],
      else: []
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
  Returns a tool module's provider-neutral schema.
  """
  def to_schema(tool_module) when is_atom(tool_module) do
    tool_module.__schema__()
  end

  @doc """
  Finds a tool module by name from a list of tool modules.
  """
  def find_by_name(tools, name) when is_list(tools) and is_binary(name) do
    Enum.find(tools, fn tool -> tool.__name__() == name end)
  end

  @doc """
  A tool module's approval metadata. Modules predating the metadata (or
  hand-rolled without the macro) default to `:never` — approval gating is
  strictly opt-in.
  """
  @spec approval(module()) :: approval()
  def approval(tool_module) when is_atom(tool_module) do
    if Code.ensure_loaded?(tool_module) and function_exported?(tool_module, :__approval__, 0) do
      tool_module.__approval__()
    else
      :never
    end
  end

  @doc """
  A tool module's retry metadata. Modules that do not declare it are
  `:unknown` — which the execution machinery treats as `:unsafe`.
  """
  @spec retry(module()) :: retry()
  def retry(tool_module) when is_atom(tool_module) do
    if Code.ensure_loaded?(tool_module) and function_exported?(tool_module, :__retry__, 0) do
      tool_module.__retry__()
    else
      :unknown
    end
  end
end
