defmodule Clementine.RunViewPropertyTest do
  @moduledoc """
  Generative check of the fold's ordering discipline (RFC §Events And
  Observation): arbitrary event streams — junk payloads included — can
  never violate it.

  The whole contract compresses to one lexicographic statement, checked
  event by event: an event strictly above the cursor is applied and the
  cursor jumps to it; anything else is identity. Layered on top:
  superseded epochs never speak again, closure rejects everything, and
  replaying anything already presented is a no-op.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Clementine.Event
  alias Clementine.Lifecycle.Facts
  alias Clementine.RunView

  defp payload_gen do
    scalar =
      StreamData.one_of([
        StreamData.integer(-10..200),
        StreamData.string(:printable, max_length: 8),
        StreamData.member_of([:junk, nil, true, %{}])
      ])

    StreamData.one_of([
      StreamData.constant(%{}),
      StreamData.fixed_map(%{content: StreamData.string(:printable, max_length: 6)}),
      StreamData.fixed_map(%{
        tool_use_id: StreamData.string(:alphanumeric, min_length: 1, max_length: 3),
        name: StreamData.string(:alphanumeric, max_length: 6),
        content: StreamData.string(:printable, max_length: 6)
      }),
      StreamData.fixed_map(%{n: StreamData.integer(-2..6)}),
      StreamData.fixed_map(%{
        input_tokens: StreamData.integer(-5..100),
        output_tokens: scalar
      }),
      StreamData.map_of(StreamData.atom(:alphanumeric), scalar, max_length: 3)
    ])
  end

  defp event_gen(epoch_range) do
    gen all(
          epoch <- StreamData.integer(epoch_range),
          seq <- StreamData.integer(1..20),
          type <- StreamData.member_of(Event.types()),
          payload <- payload_gen()
        ) do
      %Event{run_ref: "run", epoch: epoch, seq: seq, type: type, payload: payload}
    end
  end

  defp stream_gen(opts \\ []) do
    StreamData.list_of(
      event_gen(1..3),
      Keyword.merge([max_length: 50], opts)
    )
  end

  defp terminal_facts_gen do
    gen all(
          status <- StreamData.member_of(Facts.terminal_statuses()),
          epoch <- StreamData.integer(0..4)
        ) do
      %Facts{ref: "run", status: status, epoch: epoch}
    end
  end

  defp fold(view \\ RunView.new("run"), events) do
    Enum.reduce(events, view, &RunView.apply(&2, &1))
  end

  property "lexicographic (epoch, seq) ordering: strictly-above-cursor applies and moves the cursor there; everything else is identity" do
    check all(events <- stream_gen()) do
      Enum.reduce(events, RunView.new("run"), fn event, view ->
        cursor = RunView.cursor(view)
        after_view = RunView.apply(view, event)

        if {event.epoch, event.seq} > cursor do
          assert RunView.cursor(after_view) == {event.epoch, event.seq}
        else
          assert after_view == view
        end

        assert RunView.cursor(after_view) >= cursor
        after_view
      end)
    end
  end

  property "superseded-epoch drop: once a higher epoch has spoken, a lower epoch never changes the view" do
    check all(
            events <- stream_gen(min_length: 1),
            stragglers <- StreamData.list_of(event_gen(0..3), min_length: 1, max_length: 15)
          ) do
      view = fold(events)
      {current_epoch, _seq} = RunView.cursor(view)

      for straggler <- stragglers, straggler.epoch < current_epoch do
        assert RunView.apply(view, straggler) == view
      end
    end
  end

  property "post-closure rejection: a closed view is frozen against every event, whatever its epoch" do
    check all(
            events <- stream_gen(),
            facts <- terminal_facts_gen(),
            ghosts <- StreamData.list_of(event_gen(0..6), max_length: 15)
          ) do
      closed = events |> fold() |> RunView.close(facts)

      assert RunView.closed?(closed)

      for ghost <- ghosts ++ events do
        assert RunView.apply(closed, ghost) == closed
      end
    end
  end

  property "duplicate tolerance: replaying anything already presented is a no-op" do
    check all(
            events <- stream_gen(min_length: 1),
            replay_picks <- StreamData.list_of(StreamData.integer(0..255), max_length: 30)
          ) do
      view = fold(events)

      # The stream again, front to back — and any multiset of its elements
      # in any order (reconnect overlap, at-least-once transport).
      assert fold(view, events) == view

      replay = Enum.map(replay_picks, &Enum.at(events, rem(&1, length(events))))
      assert fold(view, replay) == view

      # Immediate duplication folds to the same view as the clean stream.
      doubled = Enum.flat_map(events, &[&1, &1])
      assert fold(doubled) == view
    end
  end
end
