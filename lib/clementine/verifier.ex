defmodule Clementine.Verifier do
  @moduledoc """
  Behaviour for implementing verification checks.

  Verifiers are optional checks that run after the model returns a final
  response (one without tool calls). They can trigger re-attempts if
  verification fails.

  ## Example

      defmodule MyApp.Verifiers.TestsPassing do
        use Clementine.Verifier

        @impl true
        def verify(_result, context) do
          case System.cmd("mix", ["test"], cd: context.working_dir) do
            {_, 0} -> :ok
            {output, _} -> {:retry, "Tests failed:\\n\#{output}"}
          end
        end
      end

  ## Using Verifiers

  Verifiers are attached to agents and run in sequence after each final response:

      defmodule MyAgent do
        use Clementine.Agent,
          verifiers: [
            MyApp.Verifiers.TypeCheck,
            MyApp.Verifiers.TestsPassing
          ]
      end

  """

  @type context :: %{
          optional(:working_dir) => String.t(),
          optional(:agent_pid) => pid(),
          optional(atom()) => any()
        }

  @type result :: :ok | {:retry, String.t()}

  @doc """
  Verifies the result of an agent action.

  Should return:
  - `:ok` if verification passes
  - `{:retry, reason}` if verification fails and the action should be retried

  The `reason` string is fed back to the model as context for the next iteration.
  """
  @callback verify(result :: term(), context :: context()) :: result()

  @doc """
  Optional callback to determine if this verifier should run.

  Return `true` to run the verifier, `false` to skip it.
  Defaults to always running if not implemented.
  """
  @callback should_run?(result :: term(), context :: context()) :: boolean()

  @optional_callbacks [should_run?: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour Clementine.Verifier

      @doc false
      def should_run?(_result, _context), do: true

      defoverridable should_run?: 2
    end
  end

  @doc """
  Runs a list of verifiers in sequence.

  Returns `:ok` if all verifiers pass, or `{:retry, reason}` with the first failure.
  Verifiers are run in order, stopping at the first failure.
  """
  def run_all(verifiers, result, context) when is_list(verifiers) do
    Enum.reduce_while(verifiers, :ok, fn verifier, :ok ->
      if should_run?(verifier, result, context) do
        case safe_verify(verifier, result, context) do
          :ok -> {:cont, :ok}
          {:retry, _reason} = retry -> {:halt, retry}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  @doc """
  Runs a single verifier, catching any errors.
  """
  def safe_verify(verifier, result, context) do
    try do
      verifier.verify(result, context)
    rescue
      e ->
        {:retry, "Verifier crashed: #{Exception.message(e)}"}
    catch
      :exit, reason ->
        {:retry, "Verifier exited: #{inspect(reason)}"}

      kind, reason ->
        {:retry, "Verifier error (#{kind}): #{inspect(reason)}"}
    end
  end

  # Check if a verifier should run
  defp should_run?(verifier, result, context) do
    if function_exported?(verifier, :should_run?, 2) do
      try do
        verifier.should_run?(result, context)
      rescue
        _ -> true
      end
    else
      true
    end
  end
end
