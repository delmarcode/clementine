defmodule Clementine.Lifecycle do
  @moduledoc """
  The host application's storage contract for durable runs. Two functions.

  `fetch/2` reads a run's lifecycle state into `Clementine.Lifecycle.Facts`.

  `apply/2` executes one `Clementine.Lifecycle.Transition`: atomically write
  `set` if and only if the stored facts match `expect` on `status` and
  `epoch` exactly. A non-match returns `{:error, :stale}` and changes
  nothing. When the transition carries a `result` (every transition into a
  terminal status), the host's product projection must commit in the same
  atomic unit — if the projection raises, the transition must not commit.

  That one conditional write is the entire correctness burden on the host.
  Everything subtle — which transitions are legal, when the epoch
  increments, what each operation expects and sets, how races resolve —
  lives in `Clementine.Lifecycle.Protocol`, implemented once against this
  behaviour. Hosts on Ecto should reach for the adapter rather than
  hand-writing these callbacks; the conformance suite verifies either path.

  Additional obligations on `apply/2`, stated in full in the `Transition`
  moduledoc: absent `set` keys are left untouched while explicit `nil`
  writes NULL, and symbolic timestamps (`:now`, `{:now_plus, ms}`) resolve
  against the *storage* clock, never the app node's.

  Because every transition — runner-driven or not — flows through
  `apply/2`, it is the one universal observation point: hosts broadcast
  the committed facts post-commit as *transition notifications* (the Ecto
  adapter exposes an `after_transition/3` hook for this; hand-written
  lifecycles broadcast from their own `apply` wrapper). This is how
  observers learn about resume, reap, and direct cancel — transitions no
  executor was alive to announce as events. A notification is the new
  facts and needs no sequence number: `(status, epoch)` orders itself
  (`Clementine.Lifecycle.Facts.supersedes?/2`), and a terminal
  notification closes the run's `Clementine.RunView` fold.

  `ctx` is an opaque host context threaded from runner options (commonly
  `nil`; useful for multi-repo or tenant routing).

  ## The optional cancel push channel

  Cooperative cancellation's guarantee is the runner's boundary poll —
  worst case one iteration of latency. A lifecycle may additionally export
  `subscribe_cancel/1`: the runner calls it once after claim, and the
  lifecycle arranges for `{:clementine, :cancel, reason}` to reach the
  subscribing process when a cooperative cancel is flagged. The rollout's
  blocking points treat the message like the poll result, aborting the
  in-flight provider stream — a mid-stream cancel becomes effectively
  instant. Push is best-effort by design: a missed or failed delivery
  costs latency, never correctness (the Ecto adapter implements it over
  `Phoenix.PubSub` when configured with `pubsub:`).
  """

  alias Clementine.Lifecycle.{Facts, Transition}

  @callback fetch(run_ref :: term(), ctx :: term()) ::
              {:ok, Facts.t()} | {:error, :not_found} | {:error, term()}

  @callback apply(Transition.t(), ctx :: term()) ::
              {:ok, Facts.t()} | {:error, :stale} | {:error, term()}

  @callback subscribe_cancel(lease :: Clementine.Lease.t()) :: :ok | {:error, term()}

  @optional_callbacks subscribe_cancel: 1
end
