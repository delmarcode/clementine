defmodule Clementine.LLM.ProviderStream do
  @moduledoc false

  alias Clementine.LLM.Error

  @idle_timeout 300_000

  # `parser` is a parser module, which starts from its `new/0`, or
  # `{module, state}` for a parser that needs more than that to start. A
  # retried request starts it over from the same state. `idle_timeout` is
  # how long the stream waits for the provider's next chunk.
  def new(parser, request_fun, idle_timeout \\ @idle_timeout)
      when is_function(request_fun, 2) do
    {parser_module, initial} =
      case parser do
        {module, state} when is_atom(module) -> {module, state}
        module when is_atom(module) -> {module, module.new()}
      end

    Stream.resource(
      fn -> start(initial, request_fun) end,
      &receive_chunk(&1, parser_module, initial, idle_timeout),
      &cleanup/1
    )
  end

  defp start(initial, request_fun) do
    parent = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        run_request(request_fun, parent, ref)
      end)

    {ref, pid, initial}
  end

  defp run_request(request_fun, parent, ref) do
    request_fun.(parent, ref)
  rescue
    e ->
      send(parent, {ref, {:error, Error.normalize_exception(:error, e)}})
  catch
    kind, reason ->
      send(parent, {ref, {:error, Error.normalize_exception(kind, reason)}})
  end

  defp receive_chunk({ref, pid, parser}, parser_module, initial, idle_timeout) do
    receive do
      {^ref, {:data, data}} ->
        {events, new_parser} = parser_module.parse(parser, data)
        {events, {ref, pid, new_parser}}

      {^ref, :retry_reset} ->
        {[], {ref, pid, initial}}

      {^ref, :done} ->
        {:halt, :done}

      {^ref, {:error, reason}} ->
        {[{:error, reason}], {:halting, pid}}

      # Runner-directed signals (lease lost, drain, cancel push) must be able
      # to interrupt a blocked stream consumer; halting kills the request
      # process, aborting the in-flight HTTP stream.
      {:clementine, _} = signal ->
        {[{:signal, signal}], {:halting, pid}}

      {:clementine, _, _} = signal ->
        {[{:signal, signal}], {:halting, pid}}
    after
      # A provider that stalls is a timeout the same request may get
      # past (Clementine.Error), as an HTTP 408 or a timeout_error is.
      idle_timeout ->
        {[{:error, {:stream_timeout, idle_timeout}}], {:halting, pid}}
    end
  end

  defp receive_chunk({:halting, pid}, _parser_module, _initial, _idle_timeout) do
    {:halt, {:halting, pid}}
  end

  defp cleanup({_ref, pid, _parser}), do: stop(pid)
  defp cleanup({:halting, pid}), do: stop(pid)
  defp cleanup(_state), do: :ok

  defp stop(pid) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    :ok
  end
end
