defmodule Clementine.LLM.PolicyTest do
  # Section 5 of the model-selection design: every finding boot makes about
  # an agent's model, each with its outcome. Errors come from the sheets
  # and the app's config only; a date never makes one. Config is global,
  # so these run alone.
  use ExUnit.Case, async: false

  alias Clementine.LLM.Policy
  alias Clementine.Models

  setup do
    models = Application.get_env(:clementine, :models)
    client = Application.get_env(:clementine, :llm_client)
    key = Application.get_env(:clementine, :anthropic_api_key)

    on_exit(fn ->
      Application.put_env(:clementine, :models, models)
      Application.put_env(:clementine, :llm_client, client)
      Application.put_env(:clementine, :anthropic_api_key, key)
    end)

    :ok
  end

  defp put_models(models), do: Application.put_env(:clementine, :models, models)

  defp refused(model, opts \\ []) do
    assert {:error, message} = Policy.resolve(model, opts)
    message
  end

  # Boot is the child spec's start: it builds the agents map, checking
  # each agent's declared model and choices.
  defp boot(agents) do
    Clementine.Runs.Config.new!(repo: Clementine.TestRepo, agents: agents)
  end

  # An agent is checked when it is built, so a bad `use` fails the
  # build; boot checks again because config can change after it (an
  # override in runtime.exs, a declaration dropped). Each agent here
  # compiles under one config and boots under another.
  defp compile_agent(key, use_opts) do
    module = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Clementine.Agent, key: #{inspect(key)}, #{use_opts}
    end
    """)

    module
  end

  defmodule Sonnet do
    use Clementine.Agent, key: "policy_sonnet", model: "claude-sonnet-5-5", effort: :high
  end

  describe "errors" do
    test "a model no sheet or declaration knows names the nearest ids" do
      message = refused("claude-sonnet-5-6")
      assert message =~ ~s(unknown model "claude-sonnet-5-6")
      assert message =~ ~s("claude-sonnet-5-5", "claude-sonnet-5")

      put_models(%{
        "qwen3-ft" => [
          vendor: :qwen,
          context: 1_000,
          max_output: 1_000,
          platforms: [openrouter: []]
        ]
      })

      agent = compile_agent("policy_unknown", ~s(model: "qwen3-ft"))
      put_models(%{})

      error = assert_raise ArgumentError, fn -> boot([agent]) end
      assert error.message =~ ~s(agent "policy_unknown")
      assert error.message =~ "unknown model"
    end

    test "a platform that does not serve the model, or lacks credentials" do
      put_models(%{
        "phi-4-azure" => [
          vendor: :microsoft,
          context: 16_000,
          max_output: 4_000,
          platforms: [foundry: []]
        ]
      })

      assert refused("phi-4-azure") =~ "none of which Clementine can send to"

      # Credentials are checked for the clients Clementine routes to, by
      # their presence in config: {:system, "VAR"} passes unresolved.
      Application.put_env(:clementine, :llm_client, Clementine.LLM.Router)
      Application.put_env(:clementine, :anthropic_api_key, {:system, "UNSET_IN_TESTS"})
      assert boot([Sonnet])

      Application.delete_env(:clementine, :anthropic_api_key)
      error = assert_raise ArgumentError, fn -> boot([Sonnet]) end
      assert error.message =~ "anthropic_api_key: is not set"
    end

    test "thinking the model refuses names what it takes instead" do
      assert refused("claude-opus-5-5", thinking: :off) =~ "lower the effort (effort: :low)"
      assert refused("claude-fable-5-1", thinking: :off) =~ "it always thinks"
      assert refused("claude-sonnet-5-5", thinking: :off) =~ "thinking: :between_tools"
      assert refused("gpt-6.1-terra", thinking: :off) =~ "effort: :none asks for no reasoning"

      assert refused("claude-haiku-4-5", thinking: :adaptive) =~
               "thinking: :enabled with provider_options: [budget_tokens: n]"

      for id <- ["claude-opus-4-8", "claude-sonnet-5-5", "claude-haiku-5-5"] do
        assert refused(id, provider_options: [budget_tokens: 2048]) =~ "budget_tokens"
      end

      assert refused("claude-haiku-4-5", thinking: :enabled) =~ "needs provider_options"

      agent = compile_agent("policy_sonnet_off", "model: \"claude-sonnet-5\", thinking: :off")
      put_models(%{"claude-sonnet-5" => [thinking: [types: [:adaptive]]]})

      error = assert_raise ArgumentError, fn -> boot([agent]) end
      assert error.message =~ ~s(agent "policy_sonnet_off")
      assert error.message =~ "refuses thinking: :off"
    end

    test "an effort the model lacks, and between_tools above high" do
      assert refused("gpt-6-astra", effort: :none) =~ "takes effort [:low, :medium"
      assert refused("claude-haiku-4-5", effort: :low) =~ "takes no effort setting"

      assert refused("claude-sonnet-5", effort: :extreme) =~
               "takes effort [:low, :medium, :high, :xhigh, :max], got: :extreme"

      assert refused("claude-sonnet-5", effort: "high") =~
               "effort: takes one of the model's levels"

      assert refused("claude-sonnet-5-5", thinking: :between_tools, effort: :xhigh) =~
               "thinking: :between_tools takes effort up to :high, got: :xhigh"

      assert refused("claude-haiku-5-5", thinking: :off, effort: :max) =~ "up to :high"
    end

    test "max_tokens over the model's ceiling" do
      assert refused("claude-haiku-4-5", max_tokens: 64_001) =~
               "over the model's ceiling of 64000"

      assert {:ok, %Policy{max_tokens: 64_000}} =
               Policy.resolve("claude-haiku-4-5", max_tokens: 64_000)
    end

    test "a TTL the platform does not offer, and a price list missing the agent's TTL" do
      assert refused("claude-sonnet-5-5", cache: [ttl: :twelve_hours]) =~
               "on :anthropic it offers [:five_minutes, :one_hour]"

      assert refused("gpt-5", cache: [ttl: :thirty_minutes]) =~ "caches on its own"

      put_models(%{
        "claude-sonnet-5-5" => [
          prices: [
            currency: "USD",
            input: 2.0,
            output: 10.0,
            cache_read: 0.1,
            cache_write: [five_minutes: 2.5]
          ]
        ]
      })

      assert refused("claude-sonnet-5-5", cache: [ttl: :one_hour]) =~
               "names no rate for :one_hour"
    end

    test "an override's price list partial, finer than six decimals, or in a second currency" do
      card = [currency: "USD", input: 1.0, output: 2.0, cache_read: 0.1, cache_write: 1.25]

      for {models, pattern} <- [
            {%{"claude-sonnet-5" => [prices: Keyword.delete(card, :cache_read)]}, ~r/missing/},
            {%{"claude-sonnet-5" => [prices: Keyword.put(card, :input, 0.0000001)]},
             ~r/six decimal places/},
            {%{
               "claude-sonnet-5" => [prices: card],
               "claude-opus-5" => [prices: Keyword.put(card, :currency, "EUR")]
             }, ~r/one currency/}
          ] do
        put_models(models)
        assert_raise ArgumentError, pattern, fn -> Models.validate_config!() end
      end
    end

    test "a sheet the release marks retired names its replacement" do
      assert refused("claude-sonnet-4-20250514") =~
               ~s(is retired; its replacement is "claude-sonnet-5-5")

      assert refused("claude-opus-4-1-20250805") =~ ~s("claude-opus-4-8")
    end
  end

  describe "what never errors" do
    defmodule HandWritten do
      # The behaviour by hand, without `use`: no __model__/0, no
      # __policy__/0. Boot has nothing of its declared to check.
      @behaviour Clementine.Agent

      @impl true
      def key, do: "policy_hand_written"

      @impl true
      def turn, do: false

      @impl true
      def agent(_run), do: Clementine.Agent.new(model: "claude-sonnet-5-5")

      @impl true
      def history(_run), do: []
    end

    test "boot checks credentials with the agent's own choices, not the defaults" do
      # Priced at one hour only: an agent that writes at one hour is
      # valid, and the credential check must not re-resolve it at five
      # minutes.
      put_models(%{
        "claude-sonnet-5" => [
          prices: [
            currency: "USD",
            input: 2.0,
            output: 10.0,
            cache_read: 0.2,
            cache_write: [one_hour: 4.0]
          ]
        ]
      })

      agent =
        compile_agent("policy_one_hour", ~s(model: "claude-sonnet-5", cache: [ttl: :one_hour]))

      Application.put_env(:clementine, :llm_client, Clementine.LLM.Router)
      Application.put_env(:clementine, :anthropic_api_key, {:system, "UNSET_IN_TESTS"})
      assert %{agents: %{"policy_one_hour" => ^agent}} = boot([agent])
    end

    test "an agent/1 that leaves cache: to its use is priced at the declared TTL" do
      put_models(%{
        "claude-sonnet-5" => [
          prices: [
            currency: "USD",
            input: 2.0,
            output: 10.0,
            cache_read: 0.2,
            cache_write: [one_hour: 4.0]
          ]
        ]
      })

      module = Module.concat(__MODULE__, "Dynamic#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Clementine.Agent, key: "policy_dynamic", model: "claude-sonnet-5", cache: [ttl: :one_hour]

        @impl true
        def agent(_run), do: Clementine.Agent.new(model: __model__(), instructions: "Go.")
      end
      """)

      # agent/1 builds without the declared cache:, and the claim fills it.
      built = module.agent(nil)
      assert %Clementine.Agent{cache: nil} = built

      assert %Clementine.Agent{cache: [ttl: :one_hour]} =
               Clementine.Agent.declared!(module, built)

      # The default TTL has no price, so an agent that keeps it is still
      # refused where it runs: at the claim, and on every request.
      assert {:error, message} = Policy.resolve("claude-sonnet-5")
      assert message =~ "names no rate for :five_minutes"

      assert_raise ArgumentError, ~r/names no rate for :five_minutes/, fn ->
        Clementine.Agent.new(model: "claude-sonnet-5", cache: true)
      end

      plain = Module.concat(__MODULE__, "Plain#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(plain)} do
        use Clementine.Agent, key: "policy_plain"

        @impl true
        def agent(_run), do: Clementine.Agent.new(model: "claude-sonnet-5", instructions: "Go.")
      end
      """)

      assert_raise ArgumentError, ~r/names no rate for :five_minutes/, fn ->
        Clementine.Agent.declared!(plain, plain.agent(nil))
      end
    end

    test "an agent module written by hand, without use, boots" do
      Application.put_env(:clementine, :llm_client, Clementine.LLM.Router)
      assert %{agents: %{"policy_hand_written" => HandWritten}} = boot([HandWritten])
      assert :ok = Clementine.Agent.check_declared(HandWritten)

      assert %Clementine.Agent{model: "claude-sonnet-5-5"} =
               Clementine.Agent.declared!(HandWritten, HandWritten.agent(nil))
    end

    test "a deprecated model, and one whose dates have passed, resolve" do
      # gpt-5 shuts down 2026-12-11; Haiku 4.5 is past its
      # retire-not-before date of 2026-10-15; Sonnet 4.5 is deprecated.
      for id <- ["gpt-5", "claude-haiku-4-5", "claude-sonnet-4-5", "gpt-4.1"] do
        assert {:ok, %Policy{}} = Policy.resolve(id), id
      end
    end

    test "every shipped model that is not retired resolves with no choices at all" do
      for model <- Models.list(), model.lifecycle.status != :retired do
        # A model that does not stream resolves for a call that does not.
        stream? = model.features.streaming
        assert {:ok, %Policy{}} = Policy.resolve(model, [], stream: stream?), model.id
      end
    end

    test "no check reads the clock: boot is clock-independent" do
      sources =
        ~w(lib/clementine/llm/policy.ex lib/clementine/models.ex lib/clementine/model.ex
           lib/clementine/agent.ex lib/clementine/runs/config.ex)

      for path <- sources do
        refute File.read!(path) =~ ~r/Date\.utc_today|DateTime\.utc_now|NaiveDateTime\.utc_now/,
               path
      end
    end
  end

  describe "defaults" do
    test "max_tokens min(16_000, max_output), the model's effort, adaptive where it takes it" do
      assert {:ok, policy} = Policy.resolve("claude-sonnet-5-5")

      assert %Policy{
               platform: :anthropic,
               max_tokens: 16_000,
               effort: :high,
               thinking: :adaptive,
               display: :omitted,
               cache: %{enabled: true, ttl: :five_minutes, markers: true}
             } = policy

      assert {:ok, %Policy{thinking: :off, effort: nil, display: :summarized}} =
               Policy.resolve("claude-haiku-4-5")

      assert {:ok, %Policy{thinking: :adaptive, effort: :medium, cache: %{ttl: :thirty_minutes}}} =
               Policy.resolve("gpt-6.1-sol")

      assert {:ok, %Policy{max_tokens: 16_000, effort: nil}} = Policy.resolve("gpt-6-astra")
      assert {:ok, %Policy{max_tokens: 16_000, thinking: :off}} = Policy.resolve("gpt-4.1")
    end
  end

  describe "OpenAI facts read 2026-11-01" do
    test "a model that does not stream is refused for an agent, not for call/5" do
      assert refused("gpt-5.5-pro") =~ "does not stream, and an agent's runs always do"

      assert_raise ArgumentError, ~r/new\/1: "gpt-5.5-pro": does not stream/, fn ->
        Clementine.Agent.new(model: "gpt-5.5-pro")
      end

      assert {:ok, %Policy{}} = Policy.resolve("gpt-5.5-pro", [], stream: false)
    end

    test "summary: :concise is for reasoning models after gpt-5; generate_summary is gone" do
      assert {:ok, %Policy{}} = Policy.resolve("gpt-5.1", provider_options: [summary: :concise])

      for id <- ~w(gpt-5 gpt-5-mini gpt-5-pro) do
        assert refused(id, provider_options: [summary: :concise]) =~
                 "refuses provider_options: [summary: :concise]"

        assert {:ok, %Policy{}} = Policy.resolve(id, provider_options: [summary: :detailed])
      end

      assert refused("gpt-4.1", provider_options: [summary: :auto]) =~ "does not reason"

      assert refused("gpt-6.1-sol", provider_options: [generate_summary: :auto]) =~
               "unknown options"
    end
  end
end
