defmodule Clementine.ToolRunner do
  @moduledoc """
  Executes tools in supervised tasks for isolation and parallelism.

  The ToolRunner provides:
  - Parallel execution of multiple tool calls
  - Crash isolation (a crashing tool doesn't kill the agent)
  - Per-tool timeout handling
  - Clean error messages for the LLM

  ## Usage

      tool_calls = [
        %{id: "toolu_1", name: "read_file", input: %{"path" => "foo.ex"}},
        %{id: "toolu_2", name: "list_dir", input: %{"path" => "lib"}}
      ]

      results = Clementine.ToolRunner.execute(tools, tool_calls, context)
      # => [{"toolu_1", {:ok, "file contents"}}, {"toolu_2", {:ok, "foo.ex\\nbar.ex"}}]

  """

  alias Clementine.LLM.Message.Content
  alias Clementine.Tool

  @default_timeout :timer.minutes(2)

  @doc """
  Executes a list of tool calls in parallel.

  ## Parameters

  - `tools` - List of tool modules available
  - `tool_calls` - List of tool call maps with `:id`, `:name`, `:input`
  - `context` - Context map passed to each tool

  ## Options

  - `:timeout` - Timeout per tool in milliseconds (default: 2 minutes).
    The timeout is measured from when each task is spawned, not from when
    results are collected. With a low `:max_concurrency`, queued tasks
    do not start their timeout until they are actually spawned.
  - `:max_concurrency` - Maximum parallel tool executions (default: `length(tool_calls)`)

  ## Returns

  A list of `{tool_call_id, result}` tuples where result is
  `{:ok, string}`, `{:ok, string, opts}`, or `{:error, string}`.
  The 3-tuple form passes options through (e.g. `is_error: true`).

  """
  def execute(tools, tool_calls, context, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_concurrency = Keyword.get(opts, :max_concurrency, length(tool_calls))
    task_supervisor = Keyword.get(opts, :task_supervisor, Clementine.TaskSupervisor)

    # Ensure max_concurrency is at least 1 (async_stream_nolink requires > 0)
    max_concurrency = max(max_concurrency, 1)

    task_supervisor
    |> Task.Supervisor.async_stream_nolink(
      tool_calls,
      fn call -> execute_single(tools, call, context) end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(tool_calls)
    |> Enum.map(fn
      {{:ok, result}, call} ->
        {call.id, result}

      {{:exit, :timeout}, call} ->
        {call.id, {:error, "Tool timed out after #{timeout}ms"}}

      {{:exit, reason}, call} ->
        {call.id, {:error, "Tool crashed: #{inspect(reason)}"}}
    end)
  end

  @doc """
  Executes a single tool call synchronously.

  This is useful when you want to run tools one at a time
  or when you're already in a supervised context.
  """
  def execute_single(tools, %{name: name, input: input} = _call, context) do
    case Tool.find_by_name(tools, name) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      tool ->
        # Convert string keys to atoms using the tool's parameter schema.
        # Only keys declared in the schema are atomized; unknown keys are dropped
        # to avoid unbounded atom creation from untrusted LLM input.
        args = cast_keys(input, tool.__parameters__())

        try do
          tool.execute(args, context)
        rescue
          e ->
            {:error, "Tool execution failed: #{Exception.message(e)}"}
        catch
          :exit, reason ->
            {:error, "Tool exited: #{inspect(reason)}"}

          kind, reason ->
            {:error, "Tool error (#{kind}): #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Formats tool results for inclusion in the conversation.

  Converts the result tuples into a format suitable for the LLM.
  """
  def format_results(results) do
    Enum.map(results, fn {id, result} ->
      case result do
        {:ok, content, opts} when is_list(opts) ->
          Content.tool_result(id, content, Keyword.get(opts, :is_error, false))

        {:ok, content} ->
          Content.tool_result(id, content, false)

        {:error, error} ->
          Content.tool_result(id, "Error: #{error}", true)
      end
    end)
  end

  @doc """
  Checks if any tool results contain errors.
  """
  def has_errors?(results) do
    Enum.any?(results, fn {_id, result} -> error_result?(result) end)
  end

  @doc """
  Gets all error results from a list of tool results.
  """
  def get_errors(results) do
    results
    |> Enum.filter(fn {_id, result} -> error_result?(result) end)
    |> Enum.map(fn {id, result} ->
      case result do
        {:error, error} -> {id, error}
        {:ok, content, _opts} -> {id, content}
      end
    end)
  end

  defp error_result?({:error, _}), do: true
  defp error_result?({:ok, _, opts}) when is_list(opts), do: Keyword.get(opts, :is_error, false)
  defp error_result?(_), do: false

  # Build a map from string key names to their atom + nested schema,
  # derived from the tool's compile-time parameter definitions.
  defp allowed_keys(parameters) do
    Map.new(parameters, fn {atom_key, opts} ->
      {Atom.to_string(atom_key), {atom_key, opts}}
    end)
  end

  # Convert string keys to atoms using the tool's parameter schema.
  # Only keys present in the schema are converted; unknown keys are dropped.
  # Nested :object parameters are handled recursively.
  defp cast_keys(map, parameters) when is_map(map) and is_list(parameters) do
    allowed = allowed_keys(parameters)

    map
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_binary(key) ->
        case Map.fetch(allowed, key) do
          {:ok, {atom_key, opts}} ->
            Map.put(acc, atom_key, cast_value(value, opts))

          :error ->
            acc
        end

      {key, value}, acc when is_atom(key) ->
        # Already an atom key (e.g. from internal calls) — keep if in schema
        if Keyword.has_key?(parameters, key) do
          opts = Keyword.fetch!(parameters, key)
          Map.put(acc, key, cast_value(value, opts))
        else
          acc
        end
    end)
  end

  defp cast_keys(map, _parameters) when is_map(map), do: map

  defp cast_value(value, opts) do
    case Keyword.get(opts, :type) do
      :object ->
        case Keyword.get(opts, :properties) do
          props when is_list(props) and props != [] -> cast_keys(value, props)
          _ -> value
        end

      :array ->
        case Keyword.get(opts, :items) do
          items when is_list(items) and items != [] ->
            if is_list(value),
              do: Enum.map(value, fn item -> cast_value(item, items) end),
              else: value

          _ ->
            value
        end

      _ ->
        value
    end
  end
end
