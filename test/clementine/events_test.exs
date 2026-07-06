defmodule Clementine.EventsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Clementine.Event
  alias Clementine.Events
  alias Clementine.Events.Stamper
  alias Clementine.Lease
  alias Clementine.Test.CollectingSink
  alias Clementine.Usage

  defmodule ErrorSink do
    @behaviour Clementine.Events
    @impl true
    def emit(_lease, _event), do: {:error, :transport_down}
  end

  defmodule RaisingSink do
    @behaviour Clementine.Events
    @impl true
    def emit(_lease, _event), do: raise("sink exploded")
  end

  defmodule ThrowingSink do
    @behaviour Clementine.Events
    @impl true
    def emit(_lease, _event), do: throw(:sink_bail)
  end

  defp lease(epoch \\ 1) do
    %Lease{
      run_ref: "run_1",
      epoch: epoch,
      executor_id: "test:events",
      lifecycle: Clementine.Test.MemoryLifecycle
    }
  end

  describe "the taxonomy" do
    test "is the closed execution-event set from the RFC" do
      assert Enum.sort(Event.types()) ==
               Enum.sort([
                 :iteration_start,
                 :text_delta,
                 :tool_use_start,
                 :tool_input_delta,
                 :tool_result,
                 :approval_requested,
                 :usage_delta,
                 :error
               ])
    end

    test "carries no lifecycle events — run_started/run_finished are unmintable" do
      stamper = Events.stamper(CollectingSink, lease())

      for type <- [:run_started, :run_finished, :run_claimed, :bogus] do
        assert_raise ArgumentError, ~r/transition notifications/, fn ->
          Stamper.emit(stamper, type, %{})
        end
      end

      refute_received {:clementine_event, _}
    end

    test "approval_requested refuses a resume token in its payload" do
      stamper = Events.stamper(CollectingSink, lease())

      for payload <- [%{token: "t"}, %{"token" => "t"}] do
        assert_raise ArgumentError, ~r/never broadcast/, fn ->
          Stamper.emit(stamper, :approval_requested, payload)
        end
      end

      assert :ok =
               Stamper.emit(stamper, :approval_requested, %{
                 tool_use_id: "tu_1",
                 name: "delete_records",
                 args: %{"id" => 7}
               })

      assert_received {:clementine_event, %Event{type: :approval_requested, payload: payload}}
      refute Map.has_key?(payload, :token)
    end
  end

  describe "stamping" do
    test "assigns gapless per-epoch seq starting at 1, with the lease's identity" do
      stamper = Events.stamper(CollectingSink, lease(4))

      assert :ok = Stamper.emit(stamper, :iteration_start, %{n: 1})
      assert :ok = Stamper.emit(stamper, :text_delta, %{content: "Hi"})
      assert :ok = Stamper.emit(stamper, :text_delta, %{content: "!"})

      assert_received {:clementine_event, %Event{run_ref: "run_1", epoch: 4, seq: 1}}
      assert_received {:clementine_event, %Event{epoch: 4, seq: 2}}
      assert_received {:clementine_event, %Event{epoch: 4, seq: 3}}
    end

    property "any emission sequence numbers 1..n with no gaps" do
      check all(types <- StreamData.list_of(StreamData.member_of(Event.types()), max_length: 30)) do
        stamper = Events.stamper(CollectingSink, lease())

        for type <- types do
          payload = if type == :approval_requested, do: %{tool_use_id: "tu"}, else: %{}
          assert :ok = Stamper.emit(stamper, type, payload)
        end

        seqs =
          for _ <- types do
            assert_received {:clementine_event, %Event{seq: seq}}
            seq
          end

        assert seqs == Enum.to_list(1..length(types)//1)
        assert Stamper.cursor(stamper) == {1, length(types)}
      end
    end

    test "cursor starts at {epoch, 0} and tracks the last assigned seq" do
      stamper = Events.stamper(CollectingSink, lease(7))

      assert Stamper.cursor(stamper) == {7, 0}
      Stamper.emit(stamper, :text_delta, %{content: "a"})
      assert Stamper.cursor(stamper) == {7, 1}
    end

    test "payload defaults to an empty map" do
      stamper = Events.stamper(CollectingSink, lease())

      assert :ok = Stamper.emit(stamper, :error)
      assert_received {:clementine_event, %Event{type: :error, payload: %{}}}
    end
  end

  describe "the usage counter" do
    test "accumulates usage_delta events; other types leave it untouched" do
      stamper = Events.stamper(CollectingSink, lease())

      Stamper.emit(stamper, :usage_delta, %{input_tokens: 100, output_tokens: 5})
      Stamper.emit(stamper, :text_delta, %{content: "irrelevant"})
      Stamper.emit(stamper, :usage_delta, %{input_tokens: 3, output_tokens: 40})

      assert Stamper.usage(stamper) == %Usage{input_tokens: 103, output_tokens: 45}
    end

    test "is readable from another process — the heartbeat's sampling path" do
      stamper = Events.stamper(CollectingSink, lease())
      Stamper.emit(stamper, :usage_delta, %{input_tokens: 11, output_tokens: 2})

      sampled = Task.await(Task.async(fn -> Stamper.usage(stamper) end))
      assert sampled == %Usage{input_tokens: 11, output_tokens: 2}
    end

    test "tolerates malformed usage payloads as zeros — accounting never crashes" do
      stamper = Events.stamper(CollectingSink, lease())

      assert :ok = Stamper.emit(stamper, :usage_delta, %{input_tokens: "lots", other: 1})
      assert Stamper.usage(stamper) == %Usage{}
    end
  end

  describe "advisory delivery" do
    test "a sink error is ignored and numbering continues" do
      stamper = Events.stamper(ErrorSink, lease())

      assert :ok = Stamper.emit(stamper, :text_delta, %{content: "a"})
      assert :ok = Stamper.emit(stamper, :text_delta, %{content: "b"})
      assert Stamper.cursor(stamper) == {1, 2}
    end

    test "a sink raise is isolated and logged; the stream continues" do
      stamper = Events.stamper(RaisingSink, lease())

      log =
        capture_log(fn ->
          assert :ok = Stamper.emit(stamper, :text_delta, %{content: "a"})
        end)

      assert log =~ "sink"
      assert log =~ "sink exploded"

      capture_log(fn ->
        assert :ok = Stamper.emit(stamper, :text_delta, %{content: "b"})
      end)

      assert Stamper.cursor(stamper) == {1, 2}
    end

    test "a sink throw is isolated too — delivery never affects execution" do
      stamper = Events.stamper(ThrowingSink, lease())

      log =
        capture_log(fn ->
          assert :ok = Stamper.emit(stamper, :text_delta, %{content: "a"})
        end)

      assert log =~ "throw"
      assert Stamper.cursor(stamper) == {1, 1}
    end

    test "usage still accumulates when delivery fails" do
      stamper = Events.stamper(RaisingSink, lease())

      capture_log(fn ->
        Stamper.emit(stamper, :usage_delta, %{input_tokens: 9, output_tokens: 1})
      end)

      assert Stamper.usage(stamper) == %Usage{input_tokens: 9, output_tokens: 1}
    end
  end

  describe "Clementine.Events.Null" do
    test "accepts and discards — the ephemeral path" do
      stamper = Events.stamper(Events.Null, lease())

      assert :ok = Stamper.emit(stamper, :text_delta, %{content: "gone"})
      assert Stamper.cursor(stamper) == {1, 1}
    end
  end
end
