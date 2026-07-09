defmodule Clementine.Loop do
  @moduledoc """
  The durable-receive behaviour (LOOP_RFC §The Behaviour): OTP process
  semantics lifted to organizational timescale, with the host database as
  the mailbox.

  A loop module is decision logic only. `init/1` and `handle/2` are pure
  over their arguments — no reads (a config row is not stable across a
  deploy), no clock, no randomness. Everything a decision needs arrives in
  the input payload or lives in state; everything it wants done is action
  data, constructed at host boundaries (rollouts in the child worker,
  payload decoding at the seam). Purity is what makes a crashed step
  replay from unchanged inputs to an identical commit (Governing
  Invariants 2 and 4); an impure loop forfeits replay convergence alone
  (matrix row L18).

      defmodule MyApp.ThreadAgent do
        use Clementine.Loop, state_version: 1, vocabulary: [:reply, :retry]

        def init(%{"agent_id" => id}), do: {:ok, %{"agent_id" => id, "cursor" => 0}, []}

        def handle({:message, %{"email_id" => id}}, state) do
          {:ok, state, [{:run, {:reply, id}, %{"email_id" => id}}]}
        end
        ...
      end

  ## Options

  - `:state_version` — positive integer (default `1`), recorded in every
    envelope the loop commits. A stored version the current module does
    not declare fails the step as `:incompatible_state` — parked visibly,
    never a crash, distinct from input dead-letters (inputs are innocent
    of deploys). `handle_upgrade/2` is reserved as the `code_change`
    analog and not yet part of the contract.
  - `:vocabulary` — the atom whitelist for `Clementine.Loop.Codec`
    (default `[]`). Tags and payloads may use exactly these atoms.

  `dump/1`/`load/1` default to identity — state is a JSON-safe map unless
  the loop provides its own doors.
  """

  # The doctor is inspect/2-3 by RFC name (§Operations); Kernel's
  # auto-imported inspect/2 yields the arity.
  import Kernel, except: [inspect: 2]

  alias Clementine.Loop.Input
  alias Clementine.Result

  @type state :: term()
  @type action ::
          {:run, tag :: term(), child_args :: map()}
          | {:timer, tag :: term(), DateTime.t() | non_neg_integer()}
          | {:cancel_timer, tag :: term()}
          | {:send, loop_ref :: term(), payload :: term()}

  @callback init(args :: map()) :: {:ok, state(), [action()]} | {:halt, Result.t()}

  @callback handle(Input.callback_form(), state()) ::
              {:ok, state(), [action()]} | {:halt, Result.t(), state()}

  @callback dump(state()) :: map()
  @callback load(map()) :: state()

  @optional_callbacks dump: 1, load: 1

  defmacro __using__(opts) do
    state_version = Keyword.get(opts, :state_version, 1)
    vocabulary = Keyword.get(opts, :vocabulary, [])

    unless is_integer(state_version) and state_version >= 1 do
      raise ArgumentError,
            "state_version must be a positive integer, got: #{inspect(state_version)}"
    end

    unless is_list(vocabulary) and Enum.all?(vocabulary, &is_atom/1) do
      raise ArgumentError, "vocabulary must be a list of atoms, got: #{inspect(vocabulary)}"
    end

    quote do
      @behaviour Clementine.Loop

      @doc false
      def __loop__(:state_version), do: unquote(state_version)
      def __loop__(:vocabulary), do: unquote(vocabulary)

      @impl Clementine.Loop
      def dump(state), do: state

      @impl Clementine.Loop
      def load(state), do: state

      defoverridable dump: 1, load: 1
    end
  end

  @doc """
  Runs one loop from `init(args)` to its halt result, in-process — the
  script path (LOOP_RFC §Worked Examples): production shape simulated by
  an in-memory host, deterministic for evals, animating the same
  behaviour module production runs.

      {:ok, result} = Clementine.Loop.run_local(JudgeLoop, %{"prompt" => "..."})

  Three simulations make script and production ordering agree:

  - **The inbox** is in-memory with identical FIFO/consumption semantics,
    every input round-tripping the production value codec — a payload
    outside the declared vocabulary fails here as it would against real
    storage.
  - **The hop is modeled**: children are real rollout-runs executed by
    `Clementine.Runner.execute/2` (in spawn order, in the caller's
    process), and their completions are *enqueued as inputs* by the
    terminal projection glue, never handed to `handle/2` inline.
  - **Timers ride a virtual clock** that jumps to the next deadline when
    the loop is otherwise idle — a five-minute retry timer costs nothing
    and fires in order.

  ## Options

  - `:messages` — payloads appended in order as `{:message, payload}`
    inputs before the first step: the input script (default `[]`).
  - `:build_child` — `fn tag, child_args -> {:ok, %Clementine.Rollout{}}
    end`, the host boundary where JSON-safe args become rollouts
    (`Clementine.Loop.Host.build_child/4`'s local stand-in). Required if
    the loop emits `{:run, ...}`; `{:error, term}` from it raises.
  - `:policy` — the `loop_policy` map the step runner interprets (batch
    cap, dead-letter threshold; default `%{}`).
  - `:max_steps` — step budget guarding never-halting loops, a watcher
    on a virtual clock being the canonical one (default `1000`).

  ## Returns

  - `{:ok, result}` — the halt result, whatever `Clementine.Result`
    variant the loop chose (a judge halting `Failed` on exhausted
    attempts is a halt, not a machinery error).
  - `{:error, {:parked, facts}}` — the loop parked with nothing in
    flight, no timers pending, and the script spent: production would
    wait for the world; a script has no world left to wait for.
  - `{:error, {:max_steps, n}}` — the budget elapsed first.
  - `{:error, term()}` — a step failed structurally (e.g. a `{:send, ...}`
    to a target that does not exist locally).
  """
  @spec run_local(module(), map(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def run_local(module, args, opts \\ []) when is_atom(module) and is_map(args) do
    Clementine.Loop.Local.run(module, args, opts)
  end

  @doc """
  The doctor (LOOP_RFC §Operations): one read of everything a frozen
  loop's diagnosis needs — lifecycle facts, the persisted spec with its
  version compatibility, the decoded envelope, live children with
  statuses, the timer schedule, pending inputs with ages, retained dead
  letters, and the diagnosed strands. Returns a
  `Clementine.Loop.Report`; `Clementine.Loop.Report.render/1` prints it.

      {:ok, report} =
        Clementine.Loop.inspect(MyApp.LoopHost, loop_ref, lifecycle: MyApp.ClementineLifecycle)

      report.strands
      #=> [%{class: :parked_with_pending, detail: %{pending: 3, oldest_age_ms: 42_000}}]

  Diagnosis-only: every read goes through the host seam (`load/2`,
  `pending/4`, the optional `dead_letters/3`) and the lifecycle's
  `fetch/2`; nothing is written and no lease is taken, so inspecting a
  live loop is always safe.

  ## Options

  - `:lifecycle` — the `Clementine.Lifecycle` module the loop's children
    live in (the same pairing `Clementine.Loop.Runner.step/2` takes).
    Without it children report `status: :unknown` and stranded
    completions are not detectable.
  - `:limit` — max pending inputs and dead letters fetched (default
    `50`); the strand diagnosis is bounded by the same windows.
  - `:stale_after` — milliseconds a `queued` loop may wait before it is
    diagnosed `:stale_queued` (default `:timer.minutes(5)`, the reaper
    policy's `wake_pending_after` vocabulary).
  - `:ctx` — the opaque host context (default `nil`).

  Errors pass through from the host's `load/2`:
  `{:error, :not_found | :rollout_run | term}`.
  """
  @spec inspect(module(), term(), keyword()) ::
          {:ok, Clementine.Loop.Report.t()} | {:error, term()}
  def inspect(host, loop_ref, opts \\ []) do
    Clementine.Loop.Report.gather(host, loop_ref, opts)
  end

  @doc "True when the module was compiled with `use Clementine.Loop`."
  @spec loop?(module()) :: boolean()
  def loop?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__loop__, 1)
  end

  @doc """
  Resolves a persisted `loop_module` spec (module or its string form) to a
  loaded loop module.

  The clean-failure half of checkpoint doctrine's deploy honesty (LOOP_RFC
  §The Behaviour, matrix row L2): module names persist in the spec
  columns, and a name the current release no longer carries fails as
  `:incompatible_spec` — an operator-visible park, never a crash. The
  stored name is trusted host storage, same doctrine as the Ecto codec's
  atom handling.
  """
  @spec resolve(module() | String.t()) ::
          {:ok, module()} | {:error, {:incompatible_spec, map()}}
  def resolve(module) when is_atom(module) do
    if loop?(module) do
      {:ok, module}
    else
      {:error, {:incompatible_spec, %{module: inspect(module), reason: :not_a_loop}}}
    end
  end

  def resolve(name) when is_binary(name) do
    resolve(Module.concat([name]))
  end
end
