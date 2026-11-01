defmodule Clementine.LLM.PricingTest do
  @moduledoc """
  A model's `prices:` fact: what a priced model must say, checked at boot,
  and the cache write rate picked by the TTL the agent writes with. The
  rates are illustrative, not anyone's current prices.
  """

  use ExUnit.Case, async: false

  alias Clementine.{Agent, Models, Trace}
  alias Clementine.LLM.{Policy, Pricing}

  defmodule HourAgent do
    @moduledoc false
    # Writes its cache for an hour: built at compile time, when no model
    # has prices, and checked again at boot against the app's.
    use Clementine.Agent,
      key: "test_pricing_hour",
      model: "claude-sonnet-5",
      instructions: "Answer.",
      cache: [ttl: :one_hour]
  end

  @card [
    currency: "USD",
    input: 3.0,
    output: 15.0,
    cache_read: 0.3,
    cache_write: [five_minutes: 3.75, one_hour: 6.0]
  ]

  @one_rate Keyword.put(@card, :cache_write, 3.75)

  setup do
    previous = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, previous) end)
    :ok
  end

  defp put_models(models), do: Application.put_env(:clementine, :models, models)

  defp boot_error(models) do
    put_models(models)
    assert_raise ArgumentError, &Models.validate_config!/0
  end

  describe "validate/1" do
    test "holds each rate in micro-units per million tokens, from integers or floats" do
      assert {:ok,
              %Pricing{
                currency: "USD",
                input: 3_000_000,
                output: 15_000_000,
                cache_read: 300_000,
                cache_write: %{five_minutes: 3_750_000, one_hour: 6_000_000}
              }} = Pricing.validate(@card)

      assert {:ok, %Pricing{input: 2_000_000, cache_read: 18_750, cache_write: 0}} =
               Pricing.validate(
                 currency: "EUR",
                 input: 2,
                 output: 10,
                 cache_read: 0.01875,
                 cache_write: 0
               )
    end

    test "rejects a partial price list, naming what is missing" do
      assert {:error, message} = Pricing.validate(Keyword.delete(@card, :cache_read))
      assert message =~ "missing [:cache_read]"

      assert {:error, message} = Pricing.validate(Keyword.delete(@card, :currency))
      assert message =~ "missing [:currency]"
    end

    test "rejects unknown keys, negative or non-numeric rates, and a currency that is not a code" do
      assert {:error, message} = Pricing.validate(Keyword.put(@card, :batch, 1.5))
      assert message =~ "unknown keys [:batch]"

      assert {:error, message} = Pricing.validate(Keyword.put(@card, :input, -1))
      assert message =~ "input must be a non-negative number, per million tokens"

      assert {:error, _} = Pricing.validate(Keyword.put(@card, :output, "15"))
      assert {:error, message} = Pricing.validate(Keyword.put(@card, :currency, "usd"))
      assert message =~ "ISO 4217"
      assert {:error, _} = Pricing.validate(%{input: 1})
    end

    test "rejects a rate finer than six decimal places, which would round away" do
      assert {:error, message} = Pricing.validate(Keyword.put(@card, :input, 0.0000003))
      assert message =~ "input 3.0e-7 is finer than six decimal places"

      assert {:error, message} =
               Pricing.validate(Keyword.put(@card, :cache_write, one_hour: 1.0000005))

      assert message =~ "cache_write :one_hour 1.0000005 is finer"

      # Six places, and large rates whose floats are not exact, are fine.
      assert {:ok, %Pricing{cache_read: 18_750, input: 0}} =
               Pricing.validate(
                 @card
                 |> Keyword.put(:cache_read, 0.01875)
                 |> Keyword.put(:input, 0.0)
               )

      assert {:ok, %Pricing{input: 123_456_789_012}} =
               Pricing.validate(Keyword.put(@card, :input, 123_456.789012))
    end

    test "rejects a per-TTL cache_write naming a TTL no provider has" do
      assert {:error, message} =
               Pricing.validate(Keyword.put(@card, :cache_write, five_minutes: 3.75, forever: 9))

      assert message =~ "unknown TTLs [:forever]"

      assert {:error, message} =
               Pricing.validate(Keyword.put(@card, :cache_write, five_minutes: -1))

      assert message =~ "cache_write :five_minutes must be a non-negative number"
    end
  end

  describe "of/1" do
    test "picks the cache write rate for the TTL the resolved model writes with" do
      {:ok, pricing} = Pricing.validate(@card)

      assert %Pricing{cache_write: 3_750_000} =
               Pricing.of(%{pricing: pricing, cache: %{ttl: :five_minutes}})

      assert %Pricing{cache_write: 6_000_000} =
               Pricing.of(%{pricing: pricing, cache: %{ttl: :one_hour}})
    end

    test "a single cache write rate holds whatever the TTL, or with none" do
      {:ok, pricing} = Pricing.validate(Keyword.put(@card, :cache_write, 3.75))

      for ttl <- [:five_minutes, :one_hour, nil] do
        assert %Pricing{cache_write: 3_750_000} =
                 Pricing.of(%{pricing: pricing, cache: %{ttl: ttl}})
      end
    end

    test "an id is priced at the model's default caching; an agent's TTL picks its own rate" do
      put_models(%{"claude-sonnet-5" => [prices: @card]})

      # Claude's shortest TTL, five minutes, is the default.
      assert %Pricing{cache_write: 3_750_000} = Pricing.of("claude-sonnet-5")

      agent = Agent.new(model: "claude-sonnet-5", cache: [ttl: :one_hour])

      assert %Pricing{cache_write: 6_000_000} =
               Pricing.of(Trace.resolve_model(agent.model, Agent.policy(agent)))
    end

    test "nil for a model without prices and an id no sheet holds" do
      put_models(%{"claude-sonnet-5" => [prices: @one_rate]})

      assert Pricing.of("claude-sonnet-5-5") == nil
      assert Pricing.of("gpt-6.1-sol") == nil
      assert Pricing.of("not-a-model") == nil
      assert Pricing.of(:claude_sonnet) == nil
    end
  end

  describe "at boot" do
    test "a priced override validates, and the model carries the prices" do
      put_models(%{"claude-sonnet-5" => [prices: @one_rate]})

      assert :ok = Models.validate_config!()

      assert %{prices: %Pricing{currency: "USD", cache_write: 3_750_000}} =
               Models.get!("claude-sonnet-5")

      assert %{pricing: %Pricing{currency: "USD"}} = Trace.resolve_model("claude-sonnet-5")
      assert %{prices: nil} = Models.get!("claude-sonnet-5-5")
      assert %{pricing: nil} = Trace.resolve_model("gpt-6.1-sol")
    end

    test "a declared model takes prices like a shipped one" do
      put_models(%{
        "deepseek/deepseek-v3.2" => [
          vendor: :deepseek,
          context: 163_840,
          max_output: 16_000,
          platforms: [openrouter: []],
          prices: Keyword.put(@one_rate, :source, "https://openrouter.ai/deepseek")
        ]
      })

      assert :ok = Models.validate_config!()

      assert %Pricing{cache_write: 3_750_000, source: "https://openrouter.ai/deepseek"} =
               Pricing.of("deepseek/deepseek-v3.2")
    end

    test "a sub-micro rate fails, naming the model and the key" do
      error =
        boot_error(%{"claude-sonnet-5" => [prices: Keyword.put(@one_rate, :output, 0.0000003)]})

      assert error.message =~ ~s(Invalid :clementine, :models entry "claude-sonnet-5")
      assert error.message =~ "output 3.0e-7 is finer than six decimal places"
    end

    test "a partial price list fails, naming the model" do
      error = boot_error(%{"claude-sonnet-5" => [prices: Keyword.delete(@card, :output)]})

      assert error.message =~ ~s(Invalid :clementine, :models entry "claude-sonnet-5")
      assert error.message =~ "missing [:output]"
    end

    test "a per-TTL cache_write without the rate for the agent's TTL fails the agent" do
      put_models(%{
        "claude-sonnet-5" => [prices: Keyword.put(@card, :cache_write, five_minutes: 3.75)]
      })

      # The model is priced at its default TTL; an agent that writes for
      # an hour is not.
      assert :ok = Models.validate_config!()
      assert %Pricing{cache_write: 3_750_000} = Pricing.of("claude-sonnet-5")

      assert {:error, message} = Policy.resolve("claude-sonnet-5", cache: [ttl: :one_hour])
      assert message =~ ~s("claude-sonnet-5": prices: cache_write names no rate for :one_hour)

      assert_raise ArgumentError, ~r/names no rate for :one_hour/, fn ->
        Agent.new(model: "claude-sonnet-5", cache: [ttl: :one_hour])
      end

      # Boot checks every agent's declared choices the same way.
      assert {:error, message} = Agent.check_declared(HourAgent)
      assert message =~ "names no rate for :one_hour"
    end

    test "GPT-5.6 and later write for thirty minutes, wherever served; caching off, none" do
      card = [
        currency: "USD",
        input: 2.0,
        output: 8.0,
        cache_read: 0.2,
        cache_write: [thirty_minutes: 2.5, twelve_hours: 5.0]
      ]

      put_models(%{
        "gpt-5.6-sol" => [prices: card],
        "openai.gpt-5.6" => [
          vendor: :openai,
          context: 1_050_000,
          max_output: 128_000,
          cache: [ttls: [:thirty_minutes, :twelve_hours]],
          platforms: [bedrock: []],
          prices: card
        ]
      })

      assert :ok = Models.validate_config!()
      assert %Pricing{cache_write: 2_500_000} = Pricing.of("gpt-5.6-sol")
      assert %Pricing{cache_write: 2_500_000} = Pricing.of("openai.gpt-5.6")

      # The first-party client sends the longer TTL, so it is billed at it;
      # the Chat Completions client sends none, so Bedrock refuses it.
      assert %Pricing{cache_write: 5_000_000} =
               Pricing.of(Trace.resolve_model("gpt-5.6-sol", cache: [ttl: :twelve_hours]))

      assert {:error, message} = Policy.resolve("openai.gpt-5.6", cache: [ttl: :twelve_hours])
      assert message =~ "is not sent on :bedrock"

      for id <- ["gpt-5.6-sol", "openai.gpt-5.6"] do
        assert {:error, message} = Policy.resolve(id, cache: false)
        assert message =~ "give one cache_write rate"
      end
    end

    test "a per-TTL cache_write on a model whose writes carry no TTL fails the agent" do
      put_models(%{
        "qwen.qwen3-235b-a22b-2507-v1:0" => [
          vendor: :qwen,
          context: 262_144,
          max_output: 16_384,
          platforms: [bedrock: []],
          prices: [
            currency: "USD",
            input: 1,
            output: 1,
            cache_read: 0.1,
            cache_write: [five_minutes: 1]
          ]
        ]
      })

      assert {:error, message} = Policy.resolve("qwen.qwen3-235b-a22b-2507-v1:0")
      assert message =~ ~s("qwen.qwen3-235b-a22b-2507-v1:0": prices:)
      assert message =~ "give one cache_write rate"

      assert_raise ArgumentError, ~r/give one cache_write rate/, fn ->
        Agent.new(model: "qwen.qwen3-235b-a22b-2507-v1:0")
      end
    end

    test "priced models in two currencies fail: their costs would not add up" do
      error =
        boot_error(%{
          "claude-sonnet-5" => [prices: @one_rate],
          "gpt-6.1-sol" => [
            prices: [currency: "EUR", input: 1, output: 8, cache_read: 0.1, cache_write: 1]
          ]
        })

      assert error.message =~ "every priced model names one currency"
      assert error.message =~ ~s("USD")
      assert error.message =~ ~s("EUR")
    end

    test "the models' currency is the one the priced ones name, or nil" do
      plain = [
        vendor: :qwen,
        context: 32_768,
        max_output: 8_192,
        platforms: [openai_compatible: [base_url: "http://localhost:8000/v1"]]
      ]

      put_models(%{"my-qwen" => plain, "claude-sonnet-5" => [prices: @one_rate]})
      assert Pricing.currency() == "USD"

      put_models(%{"my-qwen" => plain})
      assert Pricing.currency() == nil

      # No models config at all, as an app that sets none has.
      put_models(nil)
      assert Pricing.currency() == nil
    end
  end
end
