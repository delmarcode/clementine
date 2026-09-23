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
      # => [{"toolu_1", {:ok, %Clementine.ToolResult{content: "file contents", is_error: false}}},
      #     {"toolu_2", {:ok, %Clementine.ToolResult{content: "foo.ex\\nbar.ex", is_error: false}}}]

  """

  alias Clementine.LLM.Message.Content
  alias Clementine.Tool
  alias Clementine.ToolResult

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
  `{:ok, %Clementine.ToolResult{}}` or `{:error, string}`.

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
        {call.id, timeout_result(call, context, timeout)}

      {{:exit, reason}, call} ->
        {call.id, exit_result(call, context, reason)}
    end)
  end

  @doc """
  The per-tool timeout `execute/4` and `run_batch/4` default to. Exposed so
  callers capping timeouts to an external budget (the rollout's execution
  deadline) can shrink from the same base.
  """
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @doc """
  Executes a tool batch as a blocking point in the calling process: the
  same per-call supervised tasks, timeouts, and crash normalization as
  `execute/4`, plus batch-level handling of runner-directed signals
  arriving in the caller's mailbox.

  Signals (RFC §Cancellation):

  - `{:clementine, :cancel, reason}` — the cooperative kill policy: tools
    whose `retry` metadata is `:safe` are killed immediately (running them
    is free, so is losing them); non-`:safe` tools run out their own
    timeout, because killing an effectful tool mid-flight creates
    unknowable external state. When the batch settles, returns
    `{:cancelled, reason}` — settled results are abandoned, the run is
    terminal-bound and the terminal result is truth.
  - `{:clementine, :lease_lost, _}` / `{:clementine, :drain}` — a
    superseded or draining executor must unwind *now*: every task is
    killed and `:lost_lease` / `:drained` returns immediately.

  With no signal, returns `{:ok, results}` shaped exactly like
  `execute/4`. All calls run concurrently (no `:max_concurrency`); each
  task's timeout counts from spawn.
  """
  @spec run_batch([module()], [map()], map(), keyword()) ::
          {:ok, [{String.t(), term()}]}
          | {:cancelled, reason :: term()}
          | :lost_lease
          | :drained
  def run_batch(tools, tool_calls, context, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    task_supervisor = Keyword.get(opts, :task_supervisor, Clementine.TaskSupervisor)

    entries =
      Enum.map(tool_calls, fn call ->
        task =
          Task.Supervisor.async_nolink(task_supervisor, fn ->
            execute_single(tools, call, context)
          end)

        %{
          call: call,
          task: task,
          timer: Process.send_after(self(), {__MODULE__, :timeout, task.ref}, timeout),
          killable?: killable?(tools, call),
          result: nil
        }
      end)

    await_batch(%{
      entries: entries,
      awaiting: Map.new(Enum.with_index(entries), fn {e, i} -> {e.task.ref, i} end),
      context: context,
      timeout: timeout,
      cancelled: nil
    })
  end

  defp await_batch(%{awaiting: awaiting} = state) when map_size(awaiting) == 0 do
    case state.cancelled do
      nil -> {:ok, Enum.map(state.entries, fn e -> {e.call.id, e.result} end)}
      reason -> {:cancelled, reason}
    end
  end

  defp await_batch(%{awaiting: awaiting} = state) do
    receive do
      {ref, result} when is_map_key(awaiting, ref) ->
        Process.demonitor(ref, [:flush])
        state |> settle(ref, result) |> await_batch()

      {:DOWN, ref, :process, _pid, reason} when is_map_key(awaiting, ref) ->
        %{call: call} = entry(state, ref)
        state |> settle(ref, exit_result(call, state.context, reason)) |> await_batch()

      {__MODULE__, :timeout, ref} when is_map_key(awaiting, ref) ->
        %{call: call, task: task} = entry(state, ref)
        Task.shutdown(task, :brutal_kill)
        state |> settle(ref, timeout_result(call, state.context, state.timeout)) |> await_batch()

      {:clementine, :lease_lost, _lease} ->
        kill_awaiting(state, fn _entry -> true end)
        :lost_lease

      {:clementine, :drain} ->
        kill_awaiting(state, fn _entry -> true end)
        :drained

      {:clementine, :cancel, reason} ->
        state
        |> kill_awaiting(fn entry -> entry.killable? end)
        |> Map.update!(:cancelled, fn existing -> existing || reason end)
        |> await_batch()
    end
  end

  defp entry(state, ref), do: Enum.at(state.entries, Map.fetch!(state.awaiting, ref))

  defp settle(state, ref, result) do
    {index, awaiting} = Map.pop!(state.awaiting, ref)
    drop_timer(Enum.at(state.entries, index))

    %{
      state
      | entries: List.update_at(state.entries, index, &%{&1 | result: result}),
        awaiting: awaiting
    }
  end

  defp kill_awaiting(state, kill?) do
    {killed, awaiting} =
      Enum.split_with(state.awaiting, fn {_ref, index} ->
        kill?.(Enum.at(state.entries, index))
      end)

    Enum.each(killed, fn {_ref, index} ->
      %{task: task} = e = Enum.at(state.entries, index)
      Task.shutdown(task, :brutal_kill)
      drop_timer(e)
    end)

    %{state | awaiting: Map.new(awaiting)}
  end

  # A settled or killed entry's timer must not fire later as an unmatchable
  # mailbox leak: cancel it and flush an already-delivered message.
  defp drop_timer(%{timer: timer, task: %Task{ref: ref}}) do
    Process.cancel_timer(timer)

    receive do
      {__MODULE__, :timeout, ^ref} -> :ok
    after
      0 -> :ok
    end
  end

  # Cancellation may kill only tools that declared themselves effect-free.
  # An unresolvable name is not killable — its task settles instantly with
  # an "Unknown tool" error anyway.
  defp killable?(tools, %{name: name}) do
    case Tool.find_by_name(tools, name) do
      nil -> false
      tool -> Tool.retry(tool) == :safe
    end
  end

  defp timeout_result(call, context, timeout) do
    :telemetry.execute(
      [:clementine, :tool, :exception],
      %{duration: System.convert_time_unit(timeout, :millisecond, :native)},
      %{
        tool: call.name,
        tool_call_id: call.id,
        iteration: Map.get(context, :_clementine_iteration, 0),
        kind: :exit,
        reason: :timeout
      }
    )

    {:error, "Tool timed out after #{timeout}ms"}
  end

  defp exit_result(call, context, reason) do
    :telemetry.execute(
      [:clementine, :tool, :exception],
      %{duration: 0},
      %{
        tool: call.name,
        tool_call_id: call.id,
        iteration: Map.get(context, :_clementine_iteration, 0),
        kind: :exit,
        reason: reason
      }
    )

    {:error, "Tool crashed: #{inspect(reason)}"}
  end

  @doc """
  Executes a single tool call synchronously.

  This is useful when you want to run tools one at a time
  or when you're already in a supervised context.
  """
  def execute_single(tools, %{name: name, input: input} = call, context) do
    case Tool.find_by_name(tools, name) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      tool ->
        # Convert string keys to atoms using the tool's parameter schema.
        # Only keys declared in the schema are atomized; unknown keys are dropped
        # to avoid unbounded atom creation from untrusted LLM input.
        args = cast_keys(input, tool.__parameters__())

        tool_call_id = Map.get(call, :id)
        iteration = Map.get(context, :_clementine_iteration, 0)

        telemetry_meta = %{
          tool: name,
          tool_call_id: tool_call_id,
          iteration: iteration,
          tool_module: tool,
          args: args
        }

        :telemetry.execute(
          [:clementine, :tool, :start],
          %{system_time: System.system_time()},
          telemetry_meta
        )

        tool_start = System.monotonic_time()

        try do
          result =
            tool
            |> apply(:execute, [args, context])
            |> ToolResult.normalize()

          :telemetry.execute(
            [:clementine, :tool, :stop],
            %{duration: System.monotonic_time() - tool_start},
            Map.put(telemetry_meta, :result, tool_result_status(result))
          )

          result
        rescue
          e ->
            :telemetry.execute(
              [:clementine, :tool, :exception],
              %{duration: System.monotonic_time() - tool_start},
              Map.merge(telemetry_meta, %{kind: :error, reason: e})
            )

            {:error, "Tool execution failed: #{Exception.message(e)}"}
        catch
          :exit, reason ->
            :telemetry.execute(
              [:clementine, :tool, :exception],
              %{duration: System.monotonic_time() - tool_start},
              Map.merge(telemetry_meta, %{kind: :exit, reason: reason})
            )

            {:error, "Tool exited: #{inspect(reason)}"}

          kind, reason ->
            :telemetry.execute(
              [:clementine, :tool, :exception],
              %{duration: System.monotonic_time() - tool_start},
              Map.merge(telemetry_meta, %{kind: kind, reason: reason})
            )

            {:error, "Tool error (#{kind}): #{inspect(reason)}"}
        end
    end
  end

  defp tool_result_status(result) do
    normalized = ToolResult.normalize(result)
    if ToolResult.error?(normalized), do: :error, else: :ok
  end

  @doc """
  Formats tool results for inclusion in the conversation.

  Converts the result tuples into a format suitable for the LLM.
  """
  def format_results(results) do
    Enum.map(results, fn {id, result} ->
      normalized = ToolResult.normalize(result)
      Content.tool_result(id, ToolResult.content(normalized), ToolResult.error?(normalized))
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
    |> Enum.map(fn {id, result} -> {id, ToolResult.normalize(result)} end)
    |> Enum.filter(fn {_id, result} -> ToolResult.error?(result) end)
    |> Enum.map(fn {id, result} ->
      {id, ToolResult.error_value(result)}
    end)
  end

  defp error_result?(result) do
    result
    |> ToolResult.normalize()
    |> ToolResult.error?()
  end

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
