defmodule Clementine.Events.Forwarder do
  @moduledoc false
  # The sink behind `Clementine.stream/3`: mails every stamped event to the
  # stream owner named in the ephemeral lifecycle's ctx, tagged with that
  # stream's identity so concurrent streams consumed by one process never
  # cross-deliver. Internal — hosts observing durable runs implement their
  # own sink.

  @behaviour Clementine.Events

  alias Clementine.{Event, Lease}

  @impl true
  def emit(%Lease{ctx: %{forward_to: {pid, tag}}}, %Event{} = event)
      when is_pid(pid) and is_reference(tag) do
    send(pid, {:clementine_stream_event, tag, event})
    :ok
  end
end
