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
