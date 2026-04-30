defmodule Clementine.LLM.ProviderStreamTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.ProviderStream

  defmodule TestParser do
    def new, do: []

    def parse(parser, data) do
      {[{:chunk, data}], [data | parser]}
    end
  end

  test "starts the request worker lazily when the stream is consumed" do
    test = self()

    stream =
      ProviderStream.new(TestParser, fn consumer, ref ->
        send(test, :started)
        send(consumer, {ref, {:data, "first"}})
        send(consumer, {ref, :done})
      end)

    refute_receive :started, 20

    assert Enum.to_list(stream) == [{:chunk, "first"}]
    assert_receive :started
  end

  test "normalizes request worker exceptions into stream errors" do
    stream =
      ProviderStream.new(TestParser, fn _consumer, _ref ->
        raise "stream failed"
      end)

    assert [
             {:error,
              {:llm_exception,
               %{
                 kind: :error,
                 exception: %RuntimeError{},
                 message: "stream failed"
               }}}
           ] = Enum.to_list(stream)
  end

  test "stops the request worker when the consumer halts early" do
    test = self()

    stream =
      ProviderStream.new(TestParser, fn consumer, ref ->
        send(test, {:worker, self()})
        send(consumer, {ref, {:data, "first"}})

        receive do
          :finish -> :ok
        after
          5_000 -> :ok
        end
      end)

    assert Enum.take(stream, 1) == [{:chunk, "first"}]
    assert_receive {:worker, worker}

    monitor_ref = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}, 500
  end

  test "terminates the request worker when the stream consumer exits" do
    test = self()

    stream =
      ProviderStream.new(TestParser, fn consumer, _ref ->
        send(test, {:worker_started, self(), consumer})

        receive do
          :finish -> :ok
        after
          5_000 -> :ok
        end
      end)

    consumer =
      spawn(fn ->
        Enum.take(stream, 1)
      end)

    assert_receive {:worker_started, worker, ^consumer}

    monitor_ref = Process.monitor(worker)
    Process.exit(consumer, :kill)

    assert_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}, 500
  end
end
