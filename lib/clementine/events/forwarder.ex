defmodule Clementine.Events.Forwarder do
  @moduledoc false
  # The sink behind `Clementine.stream/3`: mails every stamped event to the
  # stream owner named in the ephemeral lifecycle's ctx. Internal — hosts
  # observing durable runs implement their own sink.

  @behaviour Clementine.Events

  alias Clementine.{Event, Lease}

  @impl true
  def emit(%Lease{ctx: %{forward_to: pid}}, %Event{} = event) when is_pid(pid) do
    send(pid, {:clementine_stream_event, event})
    :ok
  end
end
