if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.Config do
    @moduledoc false
    # The child spec's options, validated once at start and held in
    # :persistent_term for every caller of the runtime.

    alias Clementine.Lifecycle.Ecto, as: EctoLifecycle
    alias Clementine.Runs.AgentRun

    @schema NimbleOptions.new!(
              repo: [type: :atom, required: true, doc: "The Ecto repo that holds `agent_runs`."],
              oban: [type: :atom, default: Oban, doc: "The name of the Oban instance."],
              queue: [type: :atom, default: :agents, doc: "The Oban queue runs execute on."],
              agents: [
                type: {:list, :atom},
                default: [],
                doc: "The `Clementine.Agent` modules this app runs."
              ],
              host: [
                type: {:or, [:atom, nil]},
                default: nil,
                doc: "The optional `Clementine.Host` module."
              ]
            )

    @key {__MODULE__, :config}

    defstruct [:repo, :oban, :queue, :agents, :host, :lifecycle]

    @type t :: %__MODULE__{
            repo: module(),
            oban: term(),
            queue: atom(),
            agents: %{String.t() => module()},
            host: module() | nil,
            lifecycle: map()
          }

    @doc false
    def docs, do: NimbleOptions.docs(@schema)

    @spec new!(keyword()) :: t()
    def new!(opts) do
      opts = NimbleOptions.validate!(opts, @schema)
      repo = loaded!(opts[:repo], "repo")

      %__MODULE__{
        repo: repo,
        oban: opts[:oban],
        queue: opts[:queue],
        agents: agents!(opts[:agents]),
        host: host!(opts[:host]),
        lifecycle: EctoLifecycle.config(repo, AgentRun, [])
      }
    end

    @spec put(t()) :: :ok
    def put(%__MODULE__{} = config), do: :persistent_term.put(@key, config)

    @spec fetch() :: {:ok, t()} | :error
    def fetch do
      case :persistent_term.get(@key, nil) do
        %__MODULE__{} = config -> {:ok, config}
        nil -> :error
      end
    end

    @spec fetch!() :: t()
    def fetch! do
      case fetch() do
        {:ok, config} ->
          config

        :error ->
          raise RuntimeError,
                "Clementine's durable runtime is not running: add " <>
                  "{Clementine, repo: MyApp.Repo, agents: [...]} to your application's " <>
                  "children, after Oban"
      end
    end

    # Agents and loop controllers share one key namespace: a run row's
    # agent_key names either, and its kind says which.
    defp agents!(modules) do
      Enum.reduce(modules, %{}, fn module, acc ->
        loaded!(module, "agent")

        unless agent?(module) or controller?(module) do
          raise ArgumentError,
                "#{inspect(module)} is not a Clementine.Agent or a Clementine.Loop with a key " <>
                  "(use Clementine.Agent, key: ..., or use Clementine.Loop, key: ...)"
        end

        key = module.key()

        case acc do
          %{^key => other} ->
            raise ArgumentError,
                  "#{inspect(module)} and #{inspect(other)} share the agent key #{inspect(key)}"

          _new ->
            Map.put(acc, key, module)
        end
      end)
    end

    @doc "True for a `use Clementine.Agent` module."
    @spec agent?(module()) :: boolean()
    def agent?(module) do
      function_exported?(module, :key, 0) and function_exported?(module, :turn, 0) and
        function_exported?(module, :agent, 1)
    end

    @doc "True for a `use Clementine.Loop, key: ...` module."
    @spec controller?(module()) :: boolean()
    def controller?(module) do
      Clementine.Loop.loop?(module) and function_exported?(module, :key, 0)
    end

    defp host!(nil), do: nil
    defp host!(module), do: loaded!(module, "host")

    defp loaded!(module, what) do
      case Code.ensure_loaded(module) do
        {:module, module} ->
          module

        {:error, reason} ->
          raise ArgumentError, "#{what} #{inspect(module)} is unavailable (#{reason})"
      end
    end
  end
end
