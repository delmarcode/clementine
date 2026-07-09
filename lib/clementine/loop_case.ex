defmodule Clementine.LoopCase do
  @moduledoc """
  The generated conformance battery for `Clementine.Loop.Host`
  implementations (LOOP_RFC §The Loop Host Contract) — the loop layer's
  analog of `Clementine.LifecycleCase`.

  The loop host's correctness burden is the two atomicity sentences:
  *`apply_step/2` executes the entire StepCommit in one atomic unit,
  re-verifying a park's pending-emptiness (and, for `:any` scope, the
  cancel flag) inside that unit*, and *`append/4` commits the input row,
  the wake, and the step-job enqueue in one atomic unit.* This battery
  exists to verify those sentences and the machinery that leans on them —
  driven through `Clementine.Loop.Runner.step/2`, `Clementine.Loop.Protocol`,
  and the host callbacks exactly as production drives them, with mid-step
  interleavings (crash windows, zombie commits, the park race)
  manufactured by the pure step core. A host that hand-writes its seam and
  misses either sentence fails this suite on day one:

      defmodule Meli.LoopHostConformanceTest do
        use Clementine.LoopCase,
          host: Meli.LoopHost,
          lifecycle: Meli.ClementineLifecycle,
          create_loop: &Meli.Factory.create_loop/1,
          step_jobs: &Meli.Factory.step_job_count/1,
          nonexistent_ref: -1,
          moduletag: :postgres

        # See "Racing writers and Ecto.Adapters.SQL.Sandbox" below.
        setup do
          pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Meli.Repo, shared: true)
          on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
          :ok
        end
      end

  The battery's first two tests are the two the loop RFC's cold read said
  must lead: the park-vs-append interleaving (matrix row L4) and the
  crash-replay early-completion (matrix row L5).

  ## Options

    * `:host` (required) — the `Clementine.Loop.Host` implementation under
      test.
    * `:lifecycle` (required) — the paired `Clementine.Lifecycle` module
      the host's run rows live in (for `use Clementine.Loop.Ecto` hosts,
      the module the adapter was configured with). The battery claims,
      requeues, and interrupts through it exactly as the step runner and
      reaper do.
    * `:create_loop` (required) — an arity-1 function receiving a keyword
      list and returning the *loop reference* of a freshly created
      `queued` loop. See the contract below.
    * `:ctx` (optional, default `nil`) — the host context threaded through
      every seam call. A literal term, or a zero-arity function evaluated
      per test.
    * `:step_jobs` (optional) — an arity-1 function receiving a loop
      reference and returning how many step jobs the host has recorded
      for it (for the Ecto pairing, a count over the job table; a
      monotonic ledger is fine — the battery asserts deltas). Enables the
      enqueue-observation battery: the step-job half of the atomic units
      (create's first job, append's wake, the park downgrade, cancel's
      wake) is host storage the seam cannot read, so without this hook
      those enqueues go unobserved — a host that forgets them still
      passes, stranding loops until the reaper's `:reenqueue` verdict
      heals each one at claim-timeout latency.
    * `:nonexistent_ref` (optional) — a reference guaranteed to match no
      run (for integer keys, `-1`). Enables the `:not_found` tests; not
      generated when omitted.
    * `:moduletag` (optional) — an atom or list of atoms applied as
      `@moduletag` to the generated tests. Tags must ride this option: a
      `@moduletag` written after `use` does not reach tests that were
      already generated, while `setup` blocks after `use` apply normally.
    * `:async` (optional, default `false`) — forwarded to
      `use ExUnit.Case`.

  ## The `create_loop` contract

  `create_loop.(attrs)` creates one loop and returns its reference —
  typically a thin wrapper over `Clementine.Loop.Protocol.create/3` that
  supplies the host's scope format and any product columns its table
  demands. The battery passes these keys:

    * `:module`, `:args`, `:policy` — the loop spec, passed through
      verbatim. The module is always `Clementine.LoopCase.ConformanceLoop`
      (shipped in the library, so the persisted name resolves in any host
      application); `args` and `policy` are JSON-safe maps.
    * `:scope_token` (optional) — when present, compose the scope
      deterministically from it: two calls sharing a token must target the
      same scope, so the second exercises create's insert-or-get. Absent,
      mint a fresh scope per call — repeated calls must never collide.
    * `:completion_glue` (optional) — when `:dropped`, the returned loop's
      *children* must terminalize WITHOUT the completion-append glue (the
      host's projection skips `append_completion` for them), simulating
      the lost-delivery substrate the reaper's `:reconcile_children`
      verdict heals (matrix row L13). The conventional wiring: mark the
      loop row, propagate the mark to child rows in `child_attrs`, and
      check it in the projection — fiddly exactly once, in the host's
      factory and lifecycle.

  ## Racing writers and `Ecto.Adapters.SQL.Sandbox`

  Carried over from `Clementine.LifecycleCase`, which documents the full
  argument: the concurrency battery runs genuinely racing writers, which
  the SQL sandbox cannot host in its default `:manual` checkout. Shared
  ownership is the per-module setup that works (with `async: false`, the
  default):

      setup do
        pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: true)
        on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
        :ok
      end

  A dedicated non-sandbox repo pointed at the test database is the
  alternative (rely on per-loop row isolation, which `create_loop`'s
  fresh-scope rule provides). The racing tests are tagged
  `racing_writers: true`; a host whose environment cannot run them
  excludes the tag rather than skipping the suite.

  ## What the battery covers

  Matrix rows L1, L3, L4, L5, L7–L11, L13, and L15 as named tests, plus
  the wrong-state calls every operation must refuse:

    * The park-vs-append interleaving — an append landing between drain
      and park never strands: the park re-check downgrades to continue in
      its own commit (L4), and the same re-check covers a cancel flag the
      claim never saw.
    * The crash-replay early-completion — a fast child's completion
      drained alongside its replayed spawn is delivered exactly once by
      in-fold dedup, and the spawn's cargo retires (L5).
    * Crash-before-commit replay: nothing durable but the attempts bump
      precedes the commit; the replay produces one child, one send, one
      delivery (L1). Zombie commits are fenced on both guard halves and
      write nothing (L11).
    * Append semantics: FIFO commit-visibility order, codec round-trips,
      per-loop `dedup_key` uniqueness over live and dead rows,
      `:dead_lettered` for post-terminal appends (L10), the atomic wake
      under racing appenders (L3), and appends racing steps never
      stranding a parked loop with pending inputs.
    * Wrong-state calls: rollout-kind refusals for every loop verb (a
      parked rollout's suspension survives a miswired wake), `:not_found`
      variants, cancel on terminal loops, idempotent first-cause-wins
      flags, and the step runner's discard union.
    * Poison isolation: head blame, batch-1 degrade, dead-letter at the
      threshold with synthesized `{:input_failed}` evidence, innocents
      never dead-lettered (L7) — and the drain-time attempts bump
      committing outside both units, so VM-death poison is counted.
    * Cascade orders: children reach terminals before the loop, queued
      children direct-terminalize as cargo, running children get the
      cooperative flag without spinning the cascade park, halts hold
      their result against later cancels, the `:completions` window reads
      past a longer-than-cap backlog, and the terminal sweep leaves
      nothing consumable — retained as dead letters, never deleted
      (L8, L9).
    * The loop-kind reaper verdicts: `:reenqueue` re-inserts a lost step
      job and never terminalizes (L15), `:reconcile_children` synthesizes
      a lost completion under the canonical dedup key — healing the strand
      once and collapsing to `:duplicate` against a real delivery (L13) —
      and `:wake_pending` wakes a park stranded over pending inputs, the
      backstop for substrates that cannot honor sentence 1's re-check
      (L4's degraded half).
    * With `:step_jobs`, the enqueue half of the atomic units: create's
      first step job, the append wake's job (exactly one under a pending
      wake), the park downgrade's, and cancel's.
  """

  defmacro __using__(opts) do
    host = Keyword.fetch!(opts, :host)
    lifecycle = Keyword.fetch!(opts, :lifecycle)
    create_loop = Keyword.fetch!(opts, :create_loop)
    step_jobs = Keyword.get(opts, :step_jobs)
    nonexistent_ref = Keyword.fetch(opts, :nonexistent_ref)
    ctx = Keyword.get(opts, :ctx)
    async = Keyword.get(opts, :async, false)
    moduletags = opts |> Keyword.get(:moduletag) |> List.wrap()

    [
      prelude(host, lifecycle, create_loop, ctx, async, moduletags),
      battery(),
      step_jobs_battery(step_jobs),
      not_found_battery(nonexistent_ref)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp prelude(host, lifecycle, create_loop, ctx, async, moduletags) do
    quote do
      use ExUnit.Case, async: unquote(async)

      unquote_splicing(
        for tag <- moduletags do
          quote do: @moduletag(unquote(tag))
        end
      )

      alias Clementine.LoopCase.Battery

      @doc false
      def __loop_conformance__ do
        %{
          host: unquote(host),
          lifecycle: unquote(lifecycle),
          create_loop: unquote(create_loop),
          ctx: Clementine.LoopCase.resolve_ctx(unquote(ctx))
        }
      end
    end
  end

  defp battery do
    quote do
      describe "loop conformance: the two lead interleavings" do
        test "matrix row L4: the park-vs-append interleaving — an append landing between drain and park never strands" do
          Battery.park_vs_append_interleaving(__loop_conformance__())
        end

        test "matrix row L5: the crash-replay early-completion — the replayed step delivers the fast child's completion exactly once" do
          Battery.crash_replay_early_completion(__loop_conformance__())
        end
      end

      describe "loop conformance: create" do
        test "create is insert-or-get on the scope key; init runs in the first step, exactly once" do
          Battery.create_insert_or_get(__loop_conformance__())
        end
      end

      describe "loop conformance: append" do
        test "appends round-trip the codec in FIFO commit-visibility order; the wake rides the unit" do
          Battery.append_round_trip(__loop_conformance__())
        end

        test "duplicate appends by dedup_key return :duplicate and change nothing; keys are per-loop" do
          Battery.dedup_key_duplicates(__loop_conformance__())
        end

        test "matrix row L10: an append racing or trailing the finish returns :dead_lettered — the sender observes the outcome" do
          Battery.append_to_terminal_observability(__loop_conformance__())
        end

        @tag racing_writers: true
        test "matrix row L3: appends race each other and the wake — one step drains all, none lost, none doubled" do
          Battery.concurrent_appends(__loop_conformance__())
        end

        @tag racing_writers: true
        test "matrix rows L3/L4 (load): appends racing steps never strand a parked loop with pending inputs" do
          Battery.appends_racing_steps_never_strand(__loop_conformance__())
        end
      end

      describe "loop conformance: wrong-state calls" do
        test "every loop verb refuses rollout-kind refs; a parked rollout's suspension survives a miswired wake" do
          Battery.kind_guards(__loop_conformance__())
        end

        test "cancel is idempotent and first-cause-wins; terminal loops answer :already_terminal" do
          Battery.cancel_wrong_states(__loop_conformance__())
        end

        test "the step runner discards lost claim races and terminal loops without writing" do
          Battery.step_discards_wrong_states(__loop_conformance__())
        end
      end

      describe "loop conformance: the step commit" do
        test "matrix row L1: a step crashing before its commit replays identically — the bump counted, no duplicate children or sends" do
          Battery.crash_replay_no_duplicates(__loop_conformance__())
        end

        test "matrix row L11: a zombie step's commit is fenced :stale on both guard halves and writes nothing" do
          Battery.zombie_step_fenced(__loop_conformance__())
        end

        test "a cancel flag landing between drain and park downgrades the park in its own commit — never stranded" do
          Battery.cancel_flag_racing_park(__loop_conformance__())
        end
      end

      describe "loop conformance: poison isolation" do
        # The poison path logs each failed step at error level by design;
        # captured so a host's suite output stays clean.
        @tag capture_log: true
        test "matrix row L7: head blame, batch-1 degrade, dead-letter at the threshold, the decision layer informed, innocents untouched" do
          Battery.poison_isolation(__loop_conformance__())
        end

        test "matrix row L7 (VM death): the drain-time attempts bump commits outside both units and survives the crash" do
          Battery.vm_death_attempts_counted(__loop_conformance__())
        end
      end

      describe "loop conformance: cascade and halt" do
        test "matrix row L8: loop cancelled with children in flight — children terminal first, loop last, sweep leaves nothing" do
          Battery.cascade_orders_queued_child(__loop_conformance__())
        end

        test "matrix row L8 (running child): the cascade flags cooperatively and its park never spins on the cancel flag" do
          Battery.cascade_running_child_cooperative(__loop_conformance__())
        end

        test "matrix row L9: halt with children in flight and inputs behind the halt — the halt's result wins, leftovers dead-letter" do
          Battery.halt_with_children_in_flight(__loop_conformance__())
        end

        test "the cascade's :completions window reads past a backlog longer than the batch cap — never a livelock" do
          Battery.cascade_completion_behind_long_backlog(__loop_conformance__())
        end

        test "cancelling a loop that never stepped short-circuits its queued inputs into the sweep" do
          Battery.cancel_never_stepped_short_circuits(__loop_conformance__())
        end
      end

      describe "loop conformance: reaper verdicts" do
        test "matrix row L15: a lost step enqueue never kills the loop — :reenqueue re-inserts the job standalone" do
          Battery.reenqueue_verdict(__loop_conformance__())
        end

        test "matrix row L13: a lost completion self-heals — :reconcile_children synthesizes the append under the canonical dedup key" do
          Battery.reconcile_children_heals_lost_glue(__loop_conformance__())
        end

        test "matrix row L13 (race): the synthesized completion collapses to :duplicate against a real delivery" do
          Battery.reconcile_collapses_on_real_delivery(__loop_conformance__())
        end

        test "matrix row L4 (backstop): the :wake_pending verdict wakes a park stranded over pending inputs" do
          Battery.wake_pending_backstop(__loop_conformance__())
        end
      end
    end
  end

  @doc false
  # The :ctx option is a literal term or a zero-arity function evaluated
  # per test; the generated `__loop_conformance__/0` resolves it here.
  def resolve_ctx(fun) when is_function(fun, 0), do: fun.()
  def resolve_ctx(term), do: term

  defp step_jobs_battery(nil), do: nil

  defp step_jobs_battery(step_jobs) do
    quote do
      describe "loop conformance: step-job enqueues" do
        test "create, the append wake, the park downgrade, and cancel each enqueue the step job inside their units" do
          Battery.step_job_enqueues(__loop_conformance__(), unquote(step_jobs))
        end
      end
    end
  end

  defp not_found_battery(:error), do: nil

  defp not_found_battery({:ok, missing_ref}) do
    quote do
      describe "loop conformance: unknown references" do
        test "append, load, cancel, and the step runner report :not_found" do
          Battery.not_found(__loop_conformance__(), unquote(missing_ref))
        end
      end
    end
  end
end
