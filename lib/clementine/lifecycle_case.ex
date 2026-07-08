defmodule Clementine.LifecycleCase do
  @moduledoc """
  The generated conformance suite for `Clementine.Lifecycle`
  implementations (RFC §Deliverables: The Conformance Suite).

  The entire correctness burden the contract places on a host is one
  sentence — *the `apply` write must be atomic and conditional on
  `(status, epoch)` exactly matching `expect`, with the projection in the
  same atomic unit* — and this module exists to verify that sentence. A
  host that hand-writes its lifecycle and forgets half the guard fails
  this suite on day one:

      defmodule Meli.ClementineLifecycleTest do
        use Clementine.LifecycleCase,
          lifecycle: Meli.ClementineLifecycle,
          create_run: fn attrs -> Meli.Factory.queued_conversation_run(attrs).id end,
          storage_now: &Meli.Runs.db_now!/0,
          nonexistent_ref: -1,
          moduletag: :postgres

        # See "Racing writers and Ecto.Adapters.SQL.Sandbox" below.
        setup do
          pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Meli.Repo, shared: true)
          on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
          :ok
        end
      end

  ## Options

    * `:lifecycle` (required) — the `Clementine.Lifecycle` implementation
      under test.
    * `:create_run` (required) — an arity-1 function receiving a keyword
      list and returning the *run reference* (the value `fetch/2` accepts)
      of a freshly inserted `queued` run. See the contract below.
    * `:storage_now` (optional) — a zero-arity function returning the
      storage clock's current `DateTime` (in Postgres, `SELECT now()`).
      Enables the storage-clock battery: without it the suite cannot tell
      the storage clock from the node clock, and those tests are not
      generated.
    * `:nonexistent_ref` (optional) — a run reference guaranteed to match
      no run (for integer keys, `-1`; for UUIDs, the nil UUID). Enables the
      `:not_found` tests; not generated when omitted.
    * `:ctx` (optional, default `nil`) — the host context threaded through
      every `fetch`/`apply`. A literal term, or a zero-arity function
      evaluated per test (for per-test contexts).
    * `:moduletag` (optional) — an atom or list of atoms applied as
      `@moduletag` to the generated tests. Tags must ride this option: a
      `@moduletag` written after `use` does not reach tests that were
      already generated (ExUnit reads tags at test registration), while
      `setup` blocks after `use` apply normally.
    * `:async` (optional, default `false`) — forwarded to
      `use ExUnit.Case`. Leave `false` unless every test in the module can
      genuinely share storage with concurrent test modules.

  ## The `create_run` contract

  `create_run.(attrs)` inserts one queued run and returns its reference.
  Repeated calls must not collide with the host's own uniqueness
  constraints (a single-active-per-scope index means each call needs a
  fresh scope). The row should stamp `queued_at` the way production
  enqueue does (the column recipe defaults it to `now()`).

  The suite passes two documented keys. The host's projection must honor
  the first for the projection battery to run:

    * `projection: :raise` — the returned run's projection raises on
      every invocation.
    * `projection: {:raise_on, variant}` with `variant` one of
      `:completed | :failed | :cancelled | :interrupted` — the projection
      raises exactly when invoked with that `Clementine.Result` variant.

  And the second for the per-kind batteries (cancel refusal, external
  park):

    * `kind: :loop` — the returned run is loop-kind (the factory writes
      the recipe's `kind` column); omitted means `:rollout`.

  The projection convention costs a marker column (or any equivalent) the
  projection can read; wiring it is fiddly exactly once, in this file's
  factory. The probes are how a storage-agnostic suite observes
  projections: an aborted commit proves the projection ran inside the
  atomic unit and received precisely that result variant — no message
  passing, no adapter hooks.

  ## Racing writers and `Ecto.Adapters.SQL.Sandbox`

  The concurrency battery runs genuinely racing writers — concurrent
  processes each issuing their own claim — which the SQL sandbox cannot
  host in its default `:manual` checkout (sibling processes are not
  allowed onto the test's connection). Two documented setups work; both
  are per-module, so the rest of the suite keeps its usual isolation:

  Shared ownership (with `async: false`, the default) — the setup from
  the example above:

      setup do
        pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: true)
        on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
        :ok
      end

  Racing processes then share one sandboxed connection: queries serialize
  at the connection, but every logical interleaving the CAS must survive —
  N claimers fetching the same epoch before any of them writes — still
  occurs, and everything rolls back after each test. Under the sandbox
  there is a bonus: `now()` is the transaction timestamp, frozen for the
  whole test, so the storage-clock assertions tighten from a bracket to
  exact equality.

  A dedicated non-sandbox repo pointed at the test database is the
  alternative — true connection-level parallelism, no rollback (rely on
  per-run row isolation, which `create_run`'s fresh-scope rule provides):

      setup do
        # MyApp.ConformanceRepo: same database, pool: DBConnection.ConnectionPool
        start_supervised!(MyApp.ConformanceRepo)
        :ok
      end

  The racing tests are tagged `racing_writers: true`; a host whose
  environment cannot run them excludes the tag
  (`ExUnit.configure(exclude: [:racing_writers])`) rather than skipping
  the suite.

  ## What the battery covers

  The full battery from the RFC, driven through
  `Clementine.Lifecycle.Protocol` exactly as the runner, reaper, and
  control plane drive production writes:

    * N concurrent claimers — exactly one winner (matrix row 6's claim
      CAS), losers told who holds the run.
    * Zombie fencing after suspend/resume/re-claim and after
      requeue/re-claim — status recurs, the epoch fences (matrix row 2),
      probed at both the protocol surface and the raw `apply` guard.
    * Double finish, finish-after-reap (`:already_terminal`), heartbeat
      after an epoch bump (`:lost_lease`).
    * Projection atomicity — a raising projection commits nothing — and
      uniform firing with the correct `Result` variant for finish, reaper
      interrupt, and direct cancel.
    * Suspension round-trip (checkpoint stored bit-for-bit) and every
      stale-token error variant (matrix row 7).
    * External-park round-trip — a checkpoint-less `{:external, _}`
      suspension (the loop park shape) stores `nil` exactly and resumes
      by token (LOOP_RFC amendment A4).
    * Cancel racing suspend, both orders, converging to `cancelled` and
      never stranding a flagged run in `waiting` (matrix row 17).
    * Cancel refusal per kind — `request_cancel` refuses a live loop-kind
      run with `{:error, :loop_run}` in both flavors, writing nothing
      (LOOP_RFC amendment A2, matrix L8 support); rollout runs keep the
      shipped flavors.
    * Requeue — `:effects_present` refusal (matrix row 18's guard),
      `queued_at` stamping, epoch untouched until the next claim.
    * Field hygiene after suspend and requeue — no `executor_id`,
      `deadline`, or `heartbeat_at` left behind — plus the complement:
      suspend re-stamps `queued_at`, the unowned-state entry time the
      reaper's `max_wait` ceiling measures from.
    * Reaper interrupt losing cleanly to a concurrent finish (matrix
      row 3), with no projection side effects from the loser.
    * With `:storage_now`, symbolic `:now`/`{:now_plus, ms}` resolution
      against the storage clock — including stamps nested inside flag
      values — asserted against the database's `now()`, never the node's.
  """

  defmacro __using__(opts) do
    lifecycle = Keyword.fetch!(opts, :lifecycle)
    create_run = Keyword.fetch!(opts, :create_run)
    storage_now = Keyword.get(opts, :storage_now)
    nonexistent_ref = Keyword.fetch(opts, :nonexistent_ref)
    ctx = Keyword.get(opts, :ctx)
    async = Keyword.get(opts, :async, false)
    moduletags = opts |> Keyword.get(:moduletag) |> List.wrap()

    [
      prelude(lifecycle, create_run, storage_now, ctx, async, moduletags),
      battery(),
      not_found_battery(nonexistent_ref),
      storage_clock_battery(storage_now)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp prelude(lifecycle, create_run, storage_now, ctx, async, moduletags) do
    quote do
      use ExUnit.Case, async: unquote(async)

      unquote_splicing(
        for tag <- moduletags do
          quote do: @moduletag(unquote(tag))
        end
      )

      alias Clementine.LifecycleCase.Battery

      @doc false
      def __conformance__ do
        %{
          lifecycle: unquote(lifecycle),
          create_run: unquote(create_run),
          ctx: Clementine.LifecycleCase.resolve_ctx(unquote(ctx)),
          storage_now: unquote(storage_now)
        }
      end
    end
  end

  defp battery do
    quote do
      describe "conformance: fetch/2" do
        test "round-trips a freshly enqueued queued run into Facts" do
          Battery.fetch_round_trip(__conformance__())
        end
      end

      describe "conformance: claim" do
        test "claim mints epoch 1 and the lease; stamps land in the facts" do
          Battery.claim_mints_execution(__conformance__())
        end

        test "a lost claim race and unclaimable statuses report who holds the run" do
          Battery.claim_refuses_unclaimable(__conformance__())
        end

        @tag racing_writers: true
        test "matrix row 6: N concurrent claimers, exactly one winner" do
          Battery.concurrent_claimers(__conformance__())
        end
      end

      describe "conformance: heartbeat" do
        test "renews liveness, piggybacks usage, and never writes absent keys" do
          Battery.heartbeat_renews_and_piggybacks(__conformance__())
        end

        test "heartbeat after an epoch bump returns :lost_lease" do
          Battery.heartbeat_after_epoch_bump(__conformance__())
        end
      end

      describe "conformance: zombie fencing" do
        test "matrix row 2: writes from a superseded epoch are fenced after suspend/resume/re-claim" do
          Battery.zombie_fencing(__conformance__())
        end
      end

      describe "conformance: finish" do
        test "commits each terminal variant with its detail fields" do
          Battery.finish_terminal_variants(__conformance__())
        end

        test "double finish is refused with :already_terminal" do
          Battery.double_finish(__conformance__())
        end

        test "finish after a reap maps to :already_terminal" do
          Battery.finish_after_reap(__conformance__())
        end
      end

      describe "conformance: projection" do
        test "a raising projection aborts the transition: nothing commits" do
          Battery.projection_atomicity(__conformance__())
        end

        test "the projection fires for every finish Result variant" do
          Battery.projection_fires_for_finish(__conformance__())
        end

        test "the projection fires for a reaper interrupt with Result.Interrupted" do
          Battery.projection_fires_for_interrupt(__conformance__())
        end

        test "the projection fires for a direct cancel with Result.Cancelled" do
          Battery.projection_fires_for_direct_cancel(__conformance__())
        end
      end

      describe "conformance: suspend and resume" do
        test "suspend stores an exactly round-trippable suspension" do
          Battery.suspension_round_trip(__conformance__())
        end

        test "field hygiene: suspend clears the execution fields and re-stamps queued_at" do
          Battery.suspend_field_hygiene(__conformance__())
        end

        test "resume validates the token, stamps the payload, and the next claim restores the checkpoint" do
          Battery.resume_round_trip(__conformance__())
        end

        test "amendment A4: a checkpoint-less external park round-trips and resumes by reference" do
          Battery.external_park_round_trip(__conformance__())
        end

        test "matrix row 7: a resume token fires once — replay dies with :already_resumed" do
          Battery.resume_already_resumed(__conformance__())
        end

        test "a token from a superseded suspension dies with :stale_reference" do
          Battery.resume_stale_reference(__conformance__())
        end

        test "a token with a mismatched reason type dies with :wrong_reference_type" do
          Battery.resume_wrong_reference_type(__conformance__())
        end

        test "a token for a terminal run dies with :run_not_waiting" do
          Battery.resume_run_not_waiting(__conformance__())
        end
      end

      describe "conformance: cancellation" do
        test "flags a running run; the flag round-trips reason and stamp" do
          Battery.cancel_flags_running(__conformance__())
        end

        test "directly cancels an unowned queued run" do
          Battery.cancel_direct_queued(__conformance__())
        end

        test "cancel on a terminal run is refused with :already_terminal" do
          Battery.cancel_already_terminal(__conformance__())
        end

        test "matrix row 17: a cancel flag landing before suspend converges to cancelled" do
          Battery.cancel_racing_suspend_flag_first(__conformance__())
        end

        test "matrix row 17: a cancel arriving after suspend takes the direct flavor" do
          Battery.cancel_racing_suspend_suspend_first(__conformance__())
        end

        test "matrix L8 support: request_cancel refuses a live loop-kind run in both flavors" do
          Battery.cancel_refuses_loop_kind(__conformance__())
        end
      end

      describe "conformance: requeue" do
        test "requeues with queued_at stamped and the epoch untouched until the next claim" do
          Battery.requeue_requeues(__conformance__())
        end

        test "field hygiene: requeue leaves no executor_id, deadline, or heartbeat_at" do
          Battery.requeue_field_hygiene(__conformance__())
        end

        test "matrix row 18 guard: refused with :effects_present once the fence is set" do
          Battery.requeue_refused_effects_present(__conformance__())
        end
      end

      describe "conformance: reaper" do
        test "matrix row 3: an interrupt guarded by observed facts loses cleanly to a concurrent finish" do
          Battery.interrupt_loses_to_finish(__conformance__())
        end
      end
    end
  end

  @doc false
  # The :ctx option is a literal term or a zero-arity function evaluated
  # per test; the generated `__conformance__/0` resolves it here.
  def resolve_ctx(fun) when is_function(fun, 0), do: fun.()
  def resolve_ctx(term), do: term

  defp not_found_battery(:error), do: nil

  defp not_found_battery({:ok, missing_ref}) do
    quote do
      describe "conformance: unknown references" do
        test "fetch and claim report :not_found" do
          Battery.fetch_not_found(__conformance__(), unquote(missing_ref))
        end

        test "a resume token naming no run dies with :not_found" do
          Battery.resume_not_found(__conformance__(), unquote(missing_ref))
        end
      end
    end
  end

  defp storage_clock_battery(nil), do: nil

  defp storage_clock_battery(_storage_now) do
    quote do
      describe "conformance: storage clock" do
        test "symbolic :now and {:now_plus, ms} stamps resolve against the storage clock" do
          Battery.storage_clock_stamps(__conformance__())
        end

        test "suspend, requeue, and resume entry stamps resolve against the storage clock" do
          Battery.storage_clock_unowned_entry_stamps(__conformance__())
        end
      end
    end
  end
end
