defmodule Clementine.LLM.PricingTest do
  @moduledoc """
  A model's `prices:` fact: what a priced model must say, checked at boot,
  its tier, the cache write rate picked by the TTL the call is billed at,
  and the list prices the shipped sheets carry. The `@card` rates are
  illustrative; the shipped ones are the vendors', read 2026-11-01.
  """

  use ExUnit.Case, async: false

  alias Clementine.{Agent, Models, Trace}
  alias Clementine.LLM.{Policy, Pricing}

  defmodule HourAgent do
    @moduledoc false
    # Writes its cache for an hour: built at compile time against the
    # shipped prices, and checked again at boot against the app's.
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

  describe "validate/1: a tier" do
    @haiku [
      currency: "USD",
      input: 0.10,
      output: 0.50,
      cache_read: 0.01,
      cache_write: [five_minutes: 0.125, one_hour: 0.20],
      over: [
        prompt_tokens: 100_000,
        input: 0.50,
        output: 2.50,
        cache_read: 0.05,
        cache_write: [five_minutes: 0.625, one_hour: 1.00]
      ]
    ]

    test "holds the prompt length and the tier's own four rates" do
      assert {:ok,
              %Pricing{
                input: 100_000,
                over: %{
                  prompt_tokens: 100_000,
                  input: 500_000,
                  output: 2_500_000,
                  cache_read: 50_000,
                  cache_write: %{five_minutes: 625_000, one_hour: 1_000_000}
                }
              }} = Pricing.validate(@haiku)

      assert {:ok, %Pricing{over: nil}} = Pricing.validate(Keyword.delete(@haiku, :over))
    end

    test "a tier names every rate, a positive prompt length, and nothing else" do
      tier = @haiku[:over]

      assert {:error, message} =
               Pricing.validate(Keyword.put(@haiku, :over, Keyword.delete(tier, :cache_read)))

      assert message =~ "over: missing [:cache_read]"

      assert {:error, message} =
               Pricing.validate(Keyword.put(@haiku, :over, Keyword.delete(tier, :prompt_tokens)))

      assert message =~ "over: missing [:prompt_tokens]"

      for bad <- [0, -1, 100_000.0, "100k"] do
        assert {:error, message} =
                 Pricing.validate(
                   Keyword.put(@haiku, :over, Keyword.put(tier, :prompt_tokens, bad))
                 )

        assert message =~ "over: prompt_tokens must be a positive integer"
      end

      assert {:error, message} =
               Pricing.validate(Keyword.put(@haiku, :over, Keyword.put(tier, :currency, "USD")))

      assert message =~ "over: unknown keys [:currency]"

      assert {:error, message} = Pricing.validate(Keyword.put(@haiku, :over, 2.5))
      assert message =~ "over: expected a keyword list"
    end

    test "a tier's rates are held to six decimal places, as the base rates are" do
      tier = Keyword.put(@haiku[:over], :output, 2.5000004)
      assert {:error, message} = Pricing.validate(Keyword.put(@haiku, :over, tier))
      assert message =~ "over: output 2.5000004 is finer than six decimal places"
    end

    test "a tier prices writes the way the base rates do, for the same TTLs" do
      tier = @haiku[:over]

      assert {:error, message} =
               Pricing.validate(
                 Keyword.put(@haiku, :over, Keyword.put(tier, :cache_write, five_minutes: 0.625))
               )

      assert message =~ "over: cache_write names TTLs [:five_minutes]"

      assert {:error, message} =
               Pricing.validate(
                 Keyword.put(@haiku, :over, Keyword.put(tier, :cache_write, 0.625))
               )

      assert message =~ "a tier prices writes the same way"

      one_rate = Keyword.put(@haiku, :cache_write, 0.125)

      assert {:ok, %Pricing{cache_write: 125_000, over: %{cache_write: 625_000}}} =
               Pricing.validate(
                 Keyword.put(one_rate, :over, Keyword.put(tier, :cache_write, 0.625))
               )
    end
  end

  describe "at_ttl/2 and billed_ttl/2" do
    test "picks the cache write rate for the call's TTL, in the base rates and the tier" do
      {:ok, pricing} =
        Pricing.validate(
          Keyword.put(@card, :over,
            prompt_tokens: 200_000,
            input: 6.0,
            output: 22.5,
            cache_read: 0.6,
            cache_write: [five_minutes: 7.5, one_hour: 12.0]
          )
        )

      assert %Pricing{cache_write: 3_750_000, over: %{cache_write: 7_500_000}} =
               Pricing.at_ttl(pricing, :five_minutes)

      assert %Pricing{cache_write: 6_000_000, over: %{cache_write: 12_000_000}} =
               Pricing.at_ttl(pricing, :one_hour)

      # A TTL the prices name no rate for has no price, never a guess.
      assert Pricing.at_ttl(pricing, :thirty_minutes) == nil
      assert Pricing.at_ttl(pricing, nil) == nil
      assert Pricing.at_ttl(nil, :five_minutes) == nil
    end

    test "a single cache write rate holds whatever the TTL, or with none" do
      {:ok, pricing} = Pricing.validate(Keyword.put(@card, :cache_write, 3.75))

      for ttl <- [:five_minutes, :one_hour, nil] do
        assert %Pricing{cache_write: 3_750_000} = Pricing.at_ttl(pricing, ttl)
      end
    end

    test "a call is billed at its agent's TTL, or with caching off at the model's shortest" do
      sonnet = Models.get!("claude-sonnet-5-5")
      assert Pricing.billed_ttl(sonnet, :one_hour) == :one_hour
      assert Pricing.billed_ttl(sonnet, nil) == :five_minutes
      assert Pricing.billed_ttl(Models.get!("gpt-6.1-sol"), nil) == :thirty_minutes
      assert Pricing.billed_ttl(Models.get!("gpt-5.5"), nil) == nil
    end
  end

  describe "of/2" do
    test "an id is priced at its sheet's list prices, at the model's shortest TTL" do
      put_models(nil)

      # Claude Sonnet 5.5: $2 in, $10 out, $0.10 cache hits (0.05x), and
      # writes at $2.50 for five minutes or $4 for an hour.
      assert %Pricing{
               currency: "USD",
               input: 2_000_000,
               output: 10_000_000,
               cache_read: 100_000,
               cache_write: 2_500_000,
               over: nil,
               source: "https://platform.claude.com/docs/en/about-claude/pricing",
               read: ~D[2026-11-01]
             } = Pricing.of("claude-sonnet-5-5")

      assert %Pricing{cache_write: 4_000_000} =
               Pricing.of("claude-sonnet-5-5", cache_ttl: :one_hour)

      # As a trace entry stores them: strings.
      assert %Pricing{cache_write: 4_000_000} =
               Pricing.of("claude-sonnet-5-5", platform: "anthropic", cache_ttl: "one_hour")
    end

    test "an override's prices win, and a resolved agent's TTL picks its own rate" do
      put_models(%{"claude-sonnet-5" => [prices: @card]})

      assert %Pricing{input: 3_000_000, cache_write: 3_750_000} = Pricing.of("claude-sonnet-5")

      agent = Agent.new(model: "claude-sonnet-5", cache: [ttl: :one_hour])

      assert %{cache_ttl: :one_hour, pricing: %Pricing{cache_write: 6_000_000}} =
               Trace.resolve_model(agent.model, Agent.policy(agent))
    end

    test "the platform is the model's default unless named; one it is not served on has none" do
      put_models(nil)

      assert Pricing.of("claude-opus-5-5", platform: :anthropic) == Pricing.of("claude-opus-5-5")
      assert %Pricing{} = Pricing.of("claude-opus-5-5", platform: :bedrock)
      assert Pricing.of("claude-opus-5-5", platform: :openai) == nil
      assert Pricing.of("claude-opus-5-5", platform: "nowhere") == nil
      assert Pricing.of("claude-opus-5-5", cache_ttl: :twelve_hours) == nil
      assert Pricing.of("claude-opus-5-5", cache_ttl: "forever") == nil
    end

    test "nil for a declared model without prices, an id no sheet holds, and an atom" do
      put_models(%{
        "my-qwen" => [
          vendor: :qwen,
          context: 32_768,
          max_output: 8_192,
          platforms: [openai_compatible: [base_url: "http://localhost:8000/v1"]]
        ],
        "claude-sonnet-5" => [prices: nil]
      })

      assert Pricing.of("my-qwen") == nil
      assert Pricing.of("claude-sonnet-5") == nil
      assert Pricing.of("not-a-model") == nil
      assert Pricing.of(:claude_sonnet) == nil
    end
  end

  describe "the shipped sheets" do
    test "every sheet a request can go to carries list prices, with the page and the day read" do
      put_models(nil)

      # Mythos Preview's page gives no cache rates; a retired sheet serves
      # nothing, and carries prices only where the page still lists them.
      unpriced = ["claude-mythos-preview"]

      for model <- Models.list(),
          model.lifecycle.status != :retired,
          model.id not in unpriced do
        assert %Pricing{currency: "USD", source: source, read: ~D[2026-11-01]} = model.prices,
               "#{model.id} ships no prices"

        assert source in [
                 "https://platform.claude.com/docs/en/about-claude/pricing",
                 "https://developers.openai.com/api/docs/pricing"
               ]
      end

      assert Models.get!("claude-mythos-preview").prices == nil

      retired_priced =
        for %{lifecycle: %{status: :retired}, prices: %Pricing{}, id: id} <- Models.list(),
            do: id

      assert Enum.sort(retired_priced) ==
               Enum.sort([
                 "claude-opus-4-1-20250805",
                 "claude-opus-4-20250514",
                 "claude-sonnet-4-20250514",
                 "claude-3-5-haiku-20241022",
                 "o4-mini",
                 "gpt-4.1-nano"
               ])
    end

    test "each sheet prices exactly the TTLs its model offers" do
      put_models(nil)

      for %{prices: %Pricing{}} = model <- Models.list() do
        assert Enum.sort(Pricing.priced_ttls(model.prices)) == Enum.sort(model.cache.ttls),
               "#{model.id} prices other TTLs than it offers"
      end
    end

    test "an override that narrows a model's TTLs keeps its shipped prices" do
      put_models(%{"claude-sonnet-5" => [cache: [ttls: [:five_minutes]]]})

      assert :ok = Models.validate_config!()
      assert %Pricing{cache_write: 2_500_000} = Pricing.of("claude-sonnet-5")
    end

    test "each model's cache hit rate is its own, never derived from its input rate" do
      put_models(nil)

      read = fn id -> Models.get!(id).prices.cache_read / Models.get!(id).prices.input end

      assert read.("claude-fable-5-1") == 0.025
      assert read.("claude-opus-5-5") == 0.05
      assert read.("claude-sonnet-5-5") == 0.05
      assert read.("claude-sonnet-5") == 0.1
      assert read.("claude-haiku-5-5") == 0.1
      assert read.("gpt-6.1-terra") == 0.05
      assert read.("gpt-6-astra") == 0.1
    end

    test "Haiku 5.5 and the GPT-6 family carry their tiers; no other model has one" do
      put_models(nil)

      tiers =
        for %{prices: %Pricing{over: %{prompt_tokens: line}}, id: id} <- Models.list(),
            into: %{},
            do: {id, line}

      assert tiers == %{
               "claude-haiku-5-5" => 100_000,
               "gpt-6.1-terra" => 272_000,
               "gpt-6.1-sol" => 272_000,
               "gpt-6-luna" => 272_000,
               "gpt-6-sol" => 272_000,
               "gpt-6-astra" => 272_000,
               "gpt-5.6-sol" => 272_000,
               "gpt-5.6-terra" => 272_000,
               "gpt-5.6-luna" => 272_000,
               "gpt-5.5" => 272_000,
               "gpt-5.5-pro" => 272_000,
               "gpt-5.4" => 272_000,
               "gpt-5.4-pro" => 272_000
             }

      assert %{
               input: 500_000,
               output: 2_500_000,
               cache_read: 50_000,
               cache_write: %{five_minutes: 625_000, one_hour: 1_000_000}
             } = Models.get!("claude-haiku-5-5").prices.over

      assert %{
               input: 20_000_000,
               output: 75_000_000,
               cache_read: 2_000_000,
               cache_write: %{thirty_minutes: 25_000_000, twelve_hours: 50_000_000}
             } = Models.get!("gpt-6-astra").prices.over
    end
  end

  describe "at boot" do
    test "a priced override validates, and replaces the sheet's prices whole" do
      put_models(%{"claude-sonnet-5" => [prices: @one_rate]})

      assert :ok = Models.validate_config!()

      assert %{prices: %Pricing{currency: "USD", cache_write: 3_750_000, source: nil}} =
               Models.get!("claude-sonnet-5")

      assert %{pricing: %Pricing{input: 3_000_000}} = Trace.resolve_model("claude-sonnet-5")
      assert %{prices: %Pricing{input: 2_000_000}} = Models.get!("claude-sonnet-5-5")
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

      tier = Keyword.put(@card, :over, prompt_tokens: 1_000, input: 1, output: 1, cache_read: 1)
      error = boot_error(%{"claude-sonnet-5" => [prices: tier]})
      assert error.message =~ "over: missing [:cache_write]"
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

    test "GPT-5.6 and later write for thirty minutes, wherever served; caching off, the same" do
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
      assert %{pricing: %Pricing{cache_write: 5_000_000}} =
               Trace.resolve_model("gpt-5.6-sol", cache: [ttl: :twelve_hours])

      assert {:error, message} = Policy.resolve("openai.gpt-5.6", cache: [ttl: :twelve_hours])
      assert message =~ "is not sent on :bedrock"

      # With caching off a write the provider makes on its own is billed at
      # the shortest TTL, so a per-TTL price list serves it too.
      for id <- ["gpt-5.6-sol", "openai.gpt-5.6"] do
        assert {:ok, _policy} = Policy.resolve(id, cache: false)

        assert %{cache_ttl: :thirty_minutes, pricing: %Pricing{cache_write: 2_500_000}} =
                 Trace.resolve_model(id, cache: false)
      end

      assert %Clementine.Agent{} = Agent.new(model: "claude-haiku-5-5", cache: false)
    end

    test "caching off bills at the shortest TTL the prices name, so any priced model serves it" do
      # An app that prices only the hour's writes.
      put_models(%{
        "claude-sonnet-5" => [prices: Keyword.put(@card, :cache_write, one_hour: 6.0)]
      })

      assert :ok = Models.validate_config!()
      assert {:ok, _policy} = Policy.resolve("claude-sonnet-5", cache: false)

      assert %{cache_ttl: :one_hour, pricing: %Pricing{cache_write: 6_000_000}} =
               Trace.resolve_model("claude-sonnet-5", cache: false)

      # Asking for a TTL it has no rate for is still refused.
      assert {:error, message} = Policy.resolve("claude-sonnet-5")
      assert message =~ "names no rate for :five_minutes"
    end

    test "an agent with caching off runs on a model with per-TTL prices" do
      put_models(%{
        "claude-opus-5-5" => [
          prices: [
            currency: "USD",
            input: 3.60,
            output: 18.00,
            cache_read: 0.18,
            cache_write: [one_hour: 7.20, five_minutes: 4.50]
          ]
        ]
      })

      agent = Agent.new(model: "claude-opus-5-5", cache: false)
      assert Agent.policy(agent) == [cache: false]

      assert %{pricing: %Pricing{cache_write: 4_500_000}} =
               Trace.resolve_model(agent.model, Agent.policy(agent))

      # A write the provider reports anyway costs the five-minute rate.
      usage = %Clementine.Usage{input_tokens: 1_000_000, cache_write_tokens: 1_000_000}
      %{pricing: pricing} = Trace.resolve_model(agent.model, cache: false)
      assert %Clementine.Cost{micros: 4_500_000} = Clementine.Cost.price(usage, pricing)
    end

    test "a per-TTL cache_write on a model that offers no TTL fails the agent and boot" do
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

      # An agent that sets its caching is refused at build; boot refuses
      # the price list itself, which no agent's TTL could use.
      assert_raise ArgumentError, ~r/give one cache_write rate/, fn ->
        Agent.new(model: "qwen.qwen3-235b-a22b-2507-v1:0", cache: true)
      end

      assert_raise ArgumentError, ~r/the model does not offer/, fn ->
        Clementine.Models.validate_config!()
      end
    end

    test "priced models in two currencies fail, the shipped USD sheets among them" do
      error =
        boot_error(%{
          "gpt-6.1-sol" => [
            prices: [currency: "EUR", input: 1, output: 8, cache_read: 0.1, cache_write: 1]
          ]
        })

      assert error.message =~ "every priced model names one currency"
      assert error.message =~ ~s("USD")
      assert error.message =~ ~s("EUR" on "gpt-6.1-sol")
      assert error.message =~ "Clementine's sheets are priced in USD"
    end

    test "the models' currency is the one the priced ones name, or nil" do
      # No models config at all, as an app that sets none has: the sheets'.
      put_models(nil)
      assert Pricing.currency() == "USD"

      # An app that unprices every model has none.
      put_models(Map.new(Models.list(), &{&1.id, [prices: nil]}))
      assert :ok = Models.validate_config!()
      assert Pricing.currency() == nil
    end
  end
end
