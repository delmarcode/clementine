defmodule Clementine.Events do
  @moduledoc """
  The execution-event sink contract, and the stamper that feeds it.

  Observation travels two roads. Execution events — things an executor
  observes while animating a rollout, typed by the closed taxonomy in
  `Clementine.Event` — flow through this behaviour, stamped `{epoch, seq}`
  by the runner's stamper. Lifecycle transitions travel the other road:
  every transition flows through the host's `Clementine.Lifecycle.apply/2`,
  and hosts broadcast the resulting facts post-commit as transition
  notifications (the Ecto adapter exposes an `after_transition/3` hook for
  exactly this). Notifications need no sequence numbers — a notification
  *is* the new facts, and `(status, epoch)` orders itself; see
  `Clementine.Lifecycle.Facts.supersedes?/2`. A terminal notification is
  what closes a `Clementine.RunView`.

  Delivery is separate from lifecycle storage, and advisory by the first
  governing invariant: anything an observer derives from events must be
  re-derivable from the terminal result plus lifecycle facts. The stamper
  therefore ignores `emit/2` error returns and isolates raises — delivery
  never affects execution. Durability tiers are the host's choice
  (live-only PubSub, a RunView cache, a durable log); nothing in the
  protocol requires persistence, because nothing derived from events is
  truth.
  """

  alias Clementine.{Event, Lease}

  @doc """
  Delivers one stamped event. Hosts implement this with PubSub, an ETS
  cache, a trace exporter, or any combination; the lease carries the
  routing identity (`run_ref`, epoch, host `ctx`). Advisory: the return
  value is ignored and a raise is isolated at the call site.
  """
  @callback emit(Lease.t(), Event.t()) :: :ok | {:error, term()}

  @doc """
  Mints the emit handle for one execution: gapless per-epoch `seq`
  assignment plus the usage counter the heartbeat samples — one source,
  two consumers. See `Clementine.Events.Stamper`.
  """
  @spec stamper(module(), Lease.t()) :: Clementine.Events.Stamper.t()
  defdelegate stamper(sink, lease), to: Clementine.Events.Stamper, as: :new
end
