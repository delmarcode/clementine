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

  alias Clementine.Tool

  @default_timeout :timer.minutes(2)

  @doc """
  Executes a list of tool calls in parallel.

  ## Parameters

  - `tools` - List of tool modules available
  - `tool_calls` - List of tool call maps with `:id`, `:name`, `:input`
  - `context` - Context map passed to each tool

  ## Options

  - `:timeout` - Timeout per tool in milliseconds (default: 2 minutes)
  - `:max_concurrency` - Maximum parallel tool executions (default: unlimited)

  ## Returns

  A list of `{tool_call_id, result}` tuples where result is
  `{:ok, string}` or `{:error, string}`.

  """
  def execute(tools, tool_calls, context, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    task_supervisor = Keyword.get(opts, :task_supervisor, Clementine.TaskSupervisor)

    tool_calls
    |> Enum.map(fn call ->
      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          execute_single(tools, call, context)
        end)

      {call.id, task}
    end)
    |> Enum.map(fn {id, task} ->
      result =
        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} ->
            result

          {:exit, reason} ->
            {:error, "Tool crashed: #{inspect(reason)}"}

          nil ->
            {:error, "Tool timed out after #{timeout}ms"}
        end

      {id, result}
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
        # Convert string keys to atoms for the tool
        args = atomize_keys(input)

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
        {:ok, content} ->
          %{type: :tool_result, tool_use_id: id, content: content, is_error: false}

        {:error, error} ->
          %{type: :tool_result, tool_use_id: id, content: "Error: #{error}", is_error: true}
      end
    end)
  end

  @doc """
  Checks if any tool results contain errors.
  """
  def has_errors?(results) do
    Enum.any?(results, fn {_id, result} ->
      match?({:error, _}, result)
    end)
  end

  @doc """
  Gets all error results from a list of tool results.
  """
  def get_errors(results) do
    results
    |> Enum.filter(fn {_id, result} -> match?({:error, _}, result) end)
    |> Enum.map(fn {id, {:error, error}} -> {id, error} end)
  end

  # Convert string keys to atoms
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {String.to_existing_atom(key), atomize_keys(value)}

      {key, value} when is_atom(key) ->
        {key, atomize_keys(value)}
    end)
  rescue
    ArgumentError ->
      # If atom doesn't exist, try creating it (for dynamic keys)
      Map.new(map, fn
        {key, value} when is_binary(key) ->
          {String.to_atom(key), atomize_keys(value)}

        {key, value} when is_atom(key) ->
          {key, atomize_keys(value)}
      end)
  end

  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  defp atomize_keys(value), do: value
end
