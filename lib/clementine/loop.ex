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
        use Clementine.Loop, key: "thread", state_version: 1, vocabulary: [:reply, :retry]

        def init(%{"agent" => agent}), do: {:ok, %{"agent" => agent, "cursor" => 0}, []}

        def handle({:message, %{"email_id" => id, "prompt" => prompt}}, state) do
          {:ok, state, [{:run, {:reply, id}, %{"agent" => state["agent"], "prompt" => prompt}}]}
        end
        ...
      end

  In the durable runtime (`Clementine.Runs`) a loop is a run of its own:
  the controller module is listed in the child spec's `agents:` beside
  the agents, `Clementine.Runs.start_loop/3` inserts its row, and
  `Clementine.Runs.send/3` feeds it. Its children are runs the step
  starts, each under a two-part tag, and the runtime builds them at
  their claim from the `"agent"` key the action names.

  ## Options

  - `:key` — the string the loop's run rows store in `agent_key`, in the
    same namespace as `Clementine.Agent` keys. Required for a controller
    listed in `agents:`; a loop that only ever runs through `run_local/3`
    may leave it out. Keep it stable once loops exist.
  - `:state_version` — positive integer (default `1`), recorded in every
    envelope the loop commits. A stored version behind the declared one
    upgrades through the `handle_upgrade/2` chain when the module exports
    it; otherwise — and on any chain failure, and in the rollback
    direction — the step fails as `:incompatible_state`: parked visibly,
    never a crash, distinct from input dead-letters (inputs are innocent
    of deploys, and of broken upgrades).
  - `:vocabulary` — the atom whitelist for durable tags and payloads
    (default `[]`). Tags and payloads may use exactly these atoms.

  `dump/1`/`load/1` default to identity — state is a JSON-safe map unless
  the loop provides its own doors.

  ## Inputs and actions

      input  :: {:message, payload}
              | {:completed, tag, Clementine.Result.t()}
              | {:elapsed, tag}
              | {:input_failed, input_ref, Clementine.Error.t()}

      action :: {:run, tag, child}                 # start a child run under the tag
              | {:cancel, tag}                     # cancel the live child under the tag
              | {:timer, tag, DateTime.t() | ms}   # a durable timer; fires as {:elapsed, tag}
              | {:cancel_timer, tag}
              | {:send, loop_id, payload}          # another loop's inbox

  A child's `tag` is `{kind, id}`: a vocabulary atom and a string or
  integer id. One live child per tag; the tag re-arms once the child is
  terminal. `child` is a JSON map: `"agent"` (an agent key from the child
  spec), `"prompt"`, and optionally `"subject"` and `"actor"` as
  `[type, id]` (both default to the loop's own) and `"metadata"`.
  `{:cancel, tag}` flags the live child under the tag, and its
  `Clementine.Result.Cancelled` completion arrives like any other; a tag
  with no live child is a no-op. A child spawned earlier in the same
  step never comes to exist: its spawn is retired and `handle/2` hears
  its `Cancelled` completion at once, in the same step, so a controller
  need not know whether the child it cancels was started in this step or
  an earlier one. The lane holds inside a loop: a step that would start
  a second active turn on one thread fails. Cancels run before spawns in
  a step's commit, so a child that was never claimed ends inside the
  step and frees its lane, and `{:cancel, tag}` with the successor's
  `{:run, ...}` in one step interrupts it; a running child only takes
  the flag, and its successor starts on its `Cancelled` completion.
  `Clementine.Thread` is the thread controller that ships with the
  runtime.
  """

  alias Clementine.Result

  @type state :: term()

  @typedoc "A child's tag: a vocabulary atom and a string or integer id."
  @type tag :: {atom(), String.t() | integer()}

  @typedoc "What a step hands `handle/2`: a message, a child's end, a timer's fire, or a poisoned input."
  @type input ::
          {:message, payload :: term()}
          | {:completed, tag(), Result.t()}
          | {:elapsed, tag :: term()}
          | {:input_failed, input_ref :: term(), Clementine.Error.t()}

  @type action ::
          {:run, tag(), child :: map()}
          | {:cancel, tag()}
          | {:timer, tag :: term(), DateTime.t() | non_neg_integer()}
          | {:cancel_timer, tag :: term()}
          | {:send, loop_id :: term(), payload :: term()}

  @doc """
  The key the loop's run rows store in `agent_key`, when `use
  Clementine.Loop, key: "..."` gave one.
  """
  @callback key() :: String.t()

  @callback init(args :: map()) :: {:ok, state(), [action()]} | {:halt, Result.t()}

  @callback handle(input(), state()) ::
              {:ok, state(), [action()]} | {:halt, Result.t(), state()}

  @callback dump(state()) :: map()
  @callback load(map()) :: state()

  @doc """
  The `code_change` analog (LOOP_RFC §State Upgrade): receives the
  codec-decoded dumped state at `from_version` — exactly what `load/1`
  would receive — and returns it at `from_version + 1`. The machinery
  folds the chain `stored..declared - 1` stepwise, then `load/1`s the
  result: one clause per version bump, append-only, so a loop that slept
  through several deploys chains through all of them. Pure, like
  `init/1` and `handle/2` — the chain is part of the fold and replays.
  Any failure parks the loop `:incompatible_state`, pre-bump.
  """
  @callback handle_upgrade(from_version :: pos_integer(), state :: map()) :: {:ok, map()}

  @optional_callbacks key: 0, dump: 1, load: 1, handle_upgrade: 2

  defmacro __using__(opts) do
    key = Keyword.get(opts, :key)
    state_version = Keyword.get(opts, :state_version, 1)
    vocabulary = Keyword.get(opts, :vocabulary, [])

    unless is_nil(key) or (is_binary(key) and key != "") do
      raise ArgumentError, "key must be a non-empty string, got: #{inspect(key)}"
    end

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

      if unquote(key) do
        @impl Clementine.Loop
        def key, do: unquote(key)
      end

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
  - `:build_child` — `fn tag, child -> {:ok, %Clementine.Rollout{}} end`,
    the script's stand-in for the runtime, which builds a child's agent
    from the `"agent"` key its action names at the child's claim.
    Required if the loop emits `{:run, ...}`; `{:error, term}` from it
    raises.
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

  @doc "True when the module was compiled with `use Clementine.Loop`."
  @spec loop?(module()) :: boolean()
  def loop?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__loop__, 1)
  end

  @doc """
  Resolves a persisted loop spec (a module, or its string form) to a
  loaded loop module.

  The clean-failure half of checkpoint doctrine's deploy honesty (LOOP_RFC
  §The Behaviour, matrix row L2): a run row stores the controller's key,
  and a key the current release's `agents:` no longer carries, or a
  module name the script path persisted that no longer resolves, fails
  as `:incompatible_spec` — an operator-visible park, never a crash.
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
    module = Module.concat([name])

    if loop?(module) do
      {:ok, module}
    else
      {:error, {:incompatible_spec, %{module: name, reason: :not_a_loop}}}
    end
  end
end
