defmodule Clementine.LLM.ProviderStream do
  @moduledoc false

  alias Clementine.LLM.Error

  @receive_timeout 300_000

  def new(parser_module, request_fun)
      when is_atom(parser_module) and is_function(request_fun, 2) do
    Stream.resource(
      fn -> start(parser_module, request_fun) end,
      &receive_chunk(&1, parser_module),
      &cleanup/1
    )
  end

  defp start(parser_module, request_fun) do
    parent = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        run_request(request_fun, parent, ref)
      end)

    {ref, pid, parser_module.new()}
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

  defp receive_chunk({ref, pid, parser}, parser_module) do
    receive do
      {^ref, {:data, data}} ->
        {events, new_parser} = parser_module.parse(parser, data)
        {events, {ref, pid, new_parser}}

      {^ref, :retry_reset} ->
        {[], {ref, pid, parser_module.new()}}

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
      @receive_timeout ->
        {[{:error, :timeout}], {:halting, pid}}
    end
  end

  defp receive_chunk({:halting, pid}, _parser_module) do
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
