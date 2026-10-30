defmodule Clementine.HostCall do
  @moduledoc false
  # Host code the engine runs in the middle of an execution: the tool
  # policy (`authorize_tool`) and a skill's body. Each runs in a task of
  # its own, so the run is never held by it: the call is bounded by
  # `timeout` (the run's remaining time), and a runner signal (a cancel,
  # a drain, a lost lease) that lands meanwhile kills the task and comes
  # back at once, for the rollout to unwind with.
  #
  # The task inherits `$callers` and the run's Logger metadata, so an
  # Ecto sandbox allowance follows it and its logs name the run. A raise,
  # an exit, or a throw inside comes back as a value rather than a crash:
  # a task's crash report would log its arguments, which hold the run's
  # data.

  alias Clementine.TaskSupervisor

  @type outcome ::
          {:ok, term()}
          | {:failed, :error | :exit | :throw, term(), Exception.stacktrace()}
          | :timeout
          | {:signal, term()}

  @doc false
  @spec run((-> term()), non_neg_integer()) :: outcome()
  def run(fun, timeout) when is_function(fun, 0) and is_integer(timeout) and timeout >= 0 do
    metadata = Logger.metadata()

    task =
      Task.Supervisor.async_nolink(TaskSupervisor, fn ->
        Logger.metadata(metadata)

        try do
          {:ok, fun.()}
        catch
          kind, reason -> {:failed, kind, reason, __STACKTRACE__}
        end
      end)

    await(task, timeout)
  end

  defp await(%Task{ref: ref} = task, timeout) do
    receive do
      {^ref, outcome} ->
        Process.demonitor(ref, [:flush])
        outcome

      # Killed from outside: nothing came back.
      {:DOWN, ^ref, :process, _pid, reason} ->
        {:failed, :exit, reason, []}

      {:clementine, :lease_lost, _lease} = signal ->
        stop(task, signal)

      {:clementine, :drain} = signal ->
        stop(task, signal)

      {:clementine, :cancel, _reason} = signal ->
        stop(task, signal)
    after
      timeout ->
        Task.shutdown(task, :brutal_kill)
        :timeout
    end
  end

  defp stop(task, signal) do
    Task.shutdown(task, :brutal_kill)
    {:signal, signal}
  end

  @doc false
  # What a failure was, for a log that must not carry the run's data: the
  # exception's type (never its message, which may inspect a value), or
  # the shape of what was exited or thrown, and the stacktrace with each
  # frame's arguments replaced by their count.
  @spec describe(:error | :exit | :throw, term(), Exception.stacktrace()) :: String.t()
  def describe(kind, reason, stacktrace) do
    banner =
      case kind do
        :error -> "raised #{inspect(Exception.normalize(:error, reason, stacktrace).__struct__)}"
        :exit -> "exited with #{shape(reason)}"
        :throw -> "threw #{shape(reason)}"
      end

    case arities(stacktrace) do
      [] -> banner
      frames -> banner <> "\n" <> Exception.format_stacktrace(frames)
    end
  end

  defp arities(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, args, location} when is_list(args) ->
        {module, function, length(args), location}

      frame ->
        frame
    end)
  end

  @doc false
  # A term's shape without its data: atoms (which name code, not data) as
  # they are, containers by their shape, and everything else by its type.
  @spec shape(term()) :: String.t()
  def shape(term) when is_atom(term), do: inspect(term)
  def shape(term) when is_binary(term), do: "a string"
  def shape(term) when is_number(term), do: "a number"
  def shape(%module{}), do: "%#{inspect(module)}{}"
  def shape(term) when is_map(term), do: "a map"
  def shape(term) when is_list(term), do: "a list"

  def shape(term) when is_tuple(term) and tuple_size(term) <= 4,
    do: "{" <> Enum.map_join(Tuple.to_list(term), ", ", &shape/1) <> "}"

  def shape(term) when is_tuple(term), do: "a tuple of #{tuple_size(term)}"
  def shape(term) when is_function(term), do: "a function"
  def shape(term) when is_pid(term), do: "a pid"
  def shape(term) when is_reference(term), do: "a reference"
  def shape(_term), do: "a port"
end
