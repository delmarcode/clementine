defmodule Clementine.Test.CollectingSink do
  @moduledoc """
  An event sink that mails every emission back to the emitting process as
  `{:clementine_event, event}`. Emit runs in the caller, so a test that
  emits and then folds in the same process collects its own stream with
  `assert_received`.
  """

  @behaviour Clementine.Events

  @impl true
  def emit(_lease, event) do
    send(self(), {:clementine_event, event})
    :ok
  end
end
