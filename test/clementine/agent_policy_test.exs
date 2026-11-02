defmodule Clementine.AgentPolicyTest do
  @moduledoc """
  How an agent's choices for its model are completed and checked: what
  reaches the request body in process, how `use`'s choices meet the ones
  `agent/1` makes, where each error says it came from, and what
  `Agent.new/1` leaves to the run's start.
  `Clementine.AgentPolicyDurableTest` has the durable claim.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Clementine.Agent
  alias Clementine.LLM.{Anthropic, Policy}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    models = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, models) end)
    :ok
  end

  defmodule UseCacheOff do
    @moduledoc false
    use Clementine.Agent,
      key: "policy_use_cache_off",
      model: "claude-sonnet-5-5",
      instructions: "Be brief.",
      cache: false
  end

  defmodule NewCacheOff do
    @moduledoc false
    use Clementine.Agent, key: "policy_new_cache_off", model: "claude-sonnet-5-5"

    @impl true
    def agent(_run), do: Agent.new(instructions: "Be brief.", cache: false)
  end

  defmodule Sonnet do
    @moduledoc false
    use Clementine.Agent,
      key: "policy_sonnet",
      model: "claude-sonnet-5-5",
      effort: :xhigh,
      max_tokens: 32_000,
      cache: [ttl: :one_hour],
      provider_options: [prefix_mismatch: :drop_block]

    @impl true
    def agent(run), do: Agent.new(Map.get(run.metadata, "new", []))
  end

  defmodule Budgeted do
    @moduledoc false
    use Clementine.Agent,
      key: "policy_budgeted",
      model: "claude-opus-4-6",
      max_tokens: 32_000,
      provider_options: [budget_tokens: 20_000]

    @impl true
    def agent(_run), do: Agent.new(thinking: :enabled, model: "claude-opus-4-6")
  end

  defp run_with(new), do: %Clementine.Runs.AgentRun{metadata: %{"new" => new}}

  defp expect_body do
    test = self()

    expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
      {body, _binding, _dropped} = Anthropic.request(model, system, messages, tools, opts)
      send(test, {:body, body})

      [
        {:text_delta, "Done."},
        {:message_delta, %{"stop_reason" => "end_turn"},
         %{"input_tokens" => 10, "output_tokens" => 5}}
      ]
    end)
  end

  describe "cache: false" do
    test "is a choice the agent keeps" do
      assert Agent.policy(Agent.new(model: "claude-sonnet-5-5", cache: false)) == [cache: false]
    end

    test "reaches the request body in process, from new/1, use, and agent/1" do
      for agent <- [Agent.new(model: "claude-sonnet-5-5", cache: false), UseCacheOff, NewCacheOff] do
        expect_body()
        assert {:ok, _completed} = Clementine.run(agent, "Hi")
        assert_received {:body, body}
        refute Map.has_key?(body, "cache_control"), inspect(agent)
        refute body |> Map.get("system", []) |> List.wrap() |> Enum.any?(&is_map/1)
      end

      # And caching on, for contrast.
      expect_body()
      assert {:ok, _completed} = Clementine.run(Agent.new(model: "claude-sonnet-5-5"), "Hi")
      assert_received {:body, %{"cache_control" => %{"type" => "ephemeral"}}}
    end
  end

  describe "use's choices and agent/1's" do
    test "fill what agent/1 leaves unset when it leaves the model to use or names the same" do
      for new <- [[], [model: "claude-sonnet-5-5"]] do
        assert %Agent{effort: :xhigh, max_tokens: 32_000, cache: [ttl: :one_hour]} =
                 Agent.declared!(Sonnet, Sonnet.agent(run_with(new)))
      end

      # agent/1's own choice wins over use's.
      assert %Agent{effort: :low, max_tokens: 32_000} =
               Agent.declared!(Sonnet, Sonnet.agent(run_with(effort: :low)))
    end

    test "merge provider_options key by key" do
      agent =
        Agent.declared!(
          Sonnet,
          Sonnet.agent(run_with(provider_options: [prefix_mismatch: :error]))
        )

      assert agent.provider_options == [prefix_mismatch: :error]

      agent = Agent.declared!(Budgeted, Budgeted.agent(%{}))
      assert agent.provider_options == [budget_tokens: 20_000]
      assert agent.thinking == :enabled
      assert agent.max_tokens == 32_000
    end

    test "do not apply when agent/1 picks another model for the run" do
      # use's xhigh effort and one-hour TTL are Sonnet 5.5's; Haiku 4.5,
      # gpt-6-astra, and Opus 4.6 take neither as use states them.
      for model <- ["claude-haiku-4-5", "gpt-6-astra", "claude-opus-4-6"] do
        agent = Agent.declared!(Sonnet, Sonnet.agent(run_with(model: model)))
        assert %Agent{model: ^model, effort: nil, max_tokens: nil, cache: nil} = agent
        assert agent.provider_options == nil
      end
    end

    test "an error names where the choice came from" do
      # The per-run model, with agent/1's own choices.
      message =
        assert_raise ArgumentError, fn ->
          Agent.declared!(Sonnet, %Agent{model: "claude-haiku-4-5", effort: :xhigh})
        end

      assert message.message =~
               ~s(picked "claude-haiku-4-5" for this run, not the "claude-sonnet-5-5")

      assert message.message =~ "only agent/1's own choices apply"
      assert message.message =~ "takes no effort setting"

      # agent/1's Agent.new/1 choices on the declared model.
      message =
        assert_raise ArgumentError, fn ->
          Agent.declared!(Sonnet, %Agent{thinking: :off})
        end

      assert message.message =~ "Sonnet.agent/1's Clementine.Agent.new/1 choices"

      # use's choices, under agent/1's: between_tools caps the effort at
      # high, and use declares xhigh.
      message =
        assert_raise ArgumentError, fn ->
          Agent.declared!(Sonnet, %Agent{thinking: :between_tools})
        end

      assert message.message =~ "Sonnet's use Clementine.Agent choices"
      assert message.message =~ "with agent/1's [thinking: :between_tools]"
      assert message.message =~ "takes effort up to :high"

      # new/1 and use name themselves.
      message =
        assert_raise ArgumentError, fn -> Agent.new(model: "claude-opus-5-5", thinking: :off) end

      assert message.message =~
               "Clementine.Agent.new/1: \"claude-opus-5-5\": refuses thinking: :off"

      message =
        assert_raise ArgumentError, fn ->
          Code.compile_string("""
          defmodule Clementine.AgentPolicyTest.BadUse do
            use Clementine.Agent, key: "bad_use", model: "claude-opus-5-5", thinking: :off
          end
          """)
        end

      assert message.message =~ "use Clementine.Agent (Clementine.AgentPolicyTest.BadUse)"
    end

    test "use's choices need its model" do
      message =
        assert_raise ArgumentError, fn ->
          Code.compile_string("""
          defmodule Clementine.AgentPolicyTest.NoModel do
            use Clementine.Agent, key: "no_model", effort: :high
          end
          """)
        end

      assert message.message =~ "[:effort] are choices for a model; declare it with model: too"
    end
  end

  describe "new/1 leaves what needs an unset choice to the run's start" do
    test "thinking: :enabled without the budget use gives, and a budget over the default max" do
      # Inside Budgeted.agent/1: the budget and max_tokens come from use.
      assert %Agent{} = Agent.new(model: "claude-opus-4-6", thinking: :enabled)

      assert %Agent{} =
               Agent.new(model: "claude-opus-4-6", provider_options: [budget_tokens: 20_000])

      # The run's start checks the whole: 20,000 against the default
      # 16,000 max_tokens is refused there.
      agent = Agent.new(model: "claude-opus-4-6", provider_options: [budget_tokens: 20_000])
      message = assert_raise ArgumentError, fn -> Clementine.run(agent, "Hi") end

      assert message.message =~
               "Clementine.run/3: \"claude-opus-4-6\": provider_options: [budget_tokens: 20000] must be below max_tokens (16000)"

      # A choice the sheet refuses outright still fails new/1.
      assert_raise ArgumentError, ~r/refuses thinking: :between_tools/, fn ->
        Agent.new(model: "claude-opus-4-6", thinking: :between_tools)
      end
    end
  end

  describe "budget_tokens" do
    test "is at least 1,024 and below max_tokens" do
      assert {:error, message} =
               Policy.resolve("claude-opus-4-6", provider_options: [budget_tokens: 1000])

      assert message =~ "under the minimum of 1024"

      assert {:error, message} =
               Policy.resolve("claude-opus-4-6",
                 max_tokens: 16_000,
                 provider_options: [budget_tokens: 16_000]
               )

      assert message =~ "must be below max_tokens (16000)"

      assert {:ok, %Policy{thinking: :enabled, max_tokens: 32_000}} =
               Policy.resolve("claude-opus-4-6",
                 max_tokens: 32_000,
                 provider_options: [budget_tokens: 20_000]
               )
    end
  end

  describe "in process" do
    test "an agent with no model raises before anything runs" do
      message =
        assert_raise ArgumentError, fn -> Clementine.run(Agent.new(instructions: "x"), "hi") end

      assert message.message =~ "Clementine.run/3: the agent names no model"

      assert_raise ArgumentError, ~r/Clementine.stream\/3: the agent names no model/, fn ->
        Clementine.stream(Agent.new(instructions: "x"), "hi")
      end
    end

    test "a module's agent is completed from its use, as the runtime does" do
      expect_body()
      assert {:ok, _completed} = Clementine.run(Sonnet, "Hi")
      assert_received {:body, body}
      assert body["model"] == "claude-sonnet-5-5"
      assert body["max_tokens"] == 32_000
      assert body["output_config"] == %{"effort" => "xhigh"}
      assert body["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}

      # A run its agent/1 reads: the per-run model takes its own defaults.
      expect_body()

      assert {:ok, _completed} =
               Clementine.run(Sonnet, "Hi", run: run_with(model: "claude-haiku-4-5"))

      assert_received {:body, %{"model" => "claude-haiku-4-5", "max_tokens" => 16_000} = body}
      refute Map.has_key?(body, "output_config")
    end
  end

  describe "compile time" do
    test "use leaves a model compile-time config does not know to boot" do
      Application.put_env(:clementine, :models, %{})

      [{module, _binary}] =
        Code.compile_string("""
        defmodule Clementine.AgentPolicyTest.RuntimeDeclared do
          use Clementine.Agent, key: "runtime_declared", model: "acme-chat-1", max_tokens: 4_000
        end
        """)

      assert module.__model__() == "acme-chat-1"

      # Boot reads runtime config: undeclared, it fails there.
      assert {:error, message} = Agent.check_declared(module)
      assert message =~ ~s(unknown model "acme-chat-1")

      Application.put_env(:clementine, :models, %{
        "acme-chat-1" => [
          vendor: :acme,
          context: 32_000,
          max_output: 8_000,
          platforms: [openai_compatible: [base_url: "http://localhost:1/v1"]]
        ]
      })

      assert :ok = Agent.check_declared(module)
    end
  end
end
