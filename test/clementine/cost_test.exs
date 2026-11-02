defmodule Clementine.CostTest do
  @moduledoc """
  `Clementine.Cost`: the pure function from usage and prices to a cost,
  across each provider's usage shape (cache reads and writes, both of
  Anthropic's TTLs and both of OpenAI's), the tier a call's prompt
  reaches, `nil` for what is not priced, and sums. The `@card` rates are
  illustrative; the shipped sheets' are the vendors' list prices.
  """

  use ExUnit.Case, async: false

  alias Clementine.{Agent, Cost, Trace, Usage}
  alias Clementine.LLM.{Pricing, ProviderUsage}

  # Per million tokens: input 3.00, output 15.00, cache read 0.30, cache
  # write 3.75 at five minutes and 6.00 at one hour.
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

  defp pricing!(pricing) do
    {:ok, %Pricing{} = validated} = Pricing.validate(pricing)
    validated
  end

  # Prices as a call writing with `ttl` is billed at them.
  defp at_ttl(pricing, ttl), do: Pricing.at_ttl(pricing!(pricing), ttl)

  describe "price/2" do
    test "charges uncached input, cache reads, cache writes, and output each at its rate" do
      # 10,000 input: 8,000 read from the cache, 1,000 written to it, 1,000
      # uncached; 500 output.
      usage = %Usage{
        input_tokens: 10_000,
        cache_read_tokens: 8_000,
        cache_write_tokens: 1_000,
        output_tokens: 500
      }

      # 1,000 × 3.00 + 8,000 × 0.30 + 1,000 × 3.75 + 500 × 15.00, per million:
      # 0.003 + 0.0024 + 0.00375 + 0.0075 = $0.01665.
      assert Cost.price(usage, at_ttl(@card, :five_minutes)) ==
               %Cost{currency: "USD", micros: 16_650}

      # The same call writing for an hour: 1,000 × 6.00 per million more.
      assert Cost.price(usage, at_ttl(@card, :one_hour)) ==
               %Cost{currency: "USD", micros: 18_900}
    end

    test "sums the parts exactly and rounds once, half up, to the micro-unit" do
      pricing = at_ttl(@card, :five_minutes)

      # One cache read is 0.3 of a micro-unit; five are 1.5.
      assert %Cost{micros: 0} =
               Cost.price(%Usage{input_tokens: 1, cache_read_tokens: 1}, pricing)

      assert %Cost{micros: 2} =
               Cost.price(%Usage{input_tokens: 5, cache_read_tokens: 5}, pricing)

      # Three parts of 0.3 round to 1 together, where each alone rounds to 0.
      fine = pricing!(input: 0.3, output: 0.3, cache_read: 0.3, cache_write: 0.3, currency: "USD")

      assert %Cost{micros: 1} =
               Cost.price(
                 %Usage{
                   input_tokens: 2,
                   cache_read_tokens: 1,
                   cache_write_tokens: 0,
                   output_tokens: 1
                 },
                 fine
               )
    end

    test "never charges negative uncached input when a provider's cache parts exceed it" do
      pricing = at_ttl(@card, :five_minutes)

      assert Cost.price(%Usage{input_tokens: 10, cache_read_tokens: 20}, pricing) ==
               Cost.price(%Usage{input_tokens: 20, cache_read_tokens: 20}, pricing)
    end

    test "nothing burned costs zero" do
      assert %Cost{currency: "USD", micros: 0} =
               Cost.price(%Usage{}, at_ttl(@card, :five_minutes))
    end

    test "prices still per TTL, as a sheet holds them, fail naming the way to reduce them" do
      put_models(nil)
      usage = %Usage{input_tokens: 1_000, cache_write_tokens: 500, output_tokens: 100}
      sheet = Clementine.Models.get!("claude-sonnet-5").prices

      assert_raise ArgumentError,
                   ~r/per TTL \(\[:five_minutes, :one_hour\]\).*Pricing\.of/s,
                   fn ->
                     Cost.price(usage, sheet)
                   end

      assert Cost.price(usage, Pricing.at_ttl(sheet, :one_hour)) ==
               Cost.price(usage, Pricing.of("claude-sonnet-5", cache_ttl: :one_hour))
    end
  end

  # Each test starts from the provider's own usage object, normalized as
  # its client normalizes it, so what is priced is what a run records.
  describe "of/2: each provider's usage, from the wire, priced from the models' prices" do
    test "Anthropic: reads and writes are parts of input, writes at the agent's TTL" do
      put_models(%{"claude-sonnet-5" => [prices: @card]})

      # A second step of a run: the prefix read, the new turn written. The
      # Messages API's input_tokens is only what follows the last breakpoint.
      usage =
        ProviderUsage.anthropic(%{
          "input_tokens" => 100,
          "cache_read_input_tokens" => 11_000,
          "cache_creation_input_tokens" => 900,
          "cache_creation" => %{
            "ephemeral_5m_input_tokens" => 900,
            "ephemeral_1h_input_tokens" => 0
          },
          "output_tokens" => 200
        })

      # 100 × 3.00 + 11,000 × 0.30 + 900 × 3.75 + 200 × 15.00 = 9,975 micros.
      assert Cost.of(usage, "claude-sonnet-5") == %Cost{currency: "USD", micros: 9_975}

      # An agent that writes for an hour: 900 × 6.00 in place of 900 × 3.75,
      # 2,025 more.
      agent = Agent.new(model: "claude-sonnet-5", cache: [ttl: :one_hour])
      hour = Trace.resolve_model(agent.model, Agent.policy(agent))
      assert Cost.of(usage, hour) == %Cost{currency: "USD", micros: 12_000}
    end

    test "OpenAI Responses: thirty-minute and twelve-hour writes on GPT-5.6 and later" do
      card = [
        currency: "USD",
        input: 2.0,
        output: 8.0,
        cache_read: 0.2,
        cache_write: [thirty_minutes: 2.5, twelve_hours: 5.0],
        over: nil
      ]

      put_models(%{"gpt-5.6-sol" => [prices: card]})

      # The Responses API's input_tokens counts the cached and written tokens.
      usage =
        ProviderUsage.openai(%{
          "input_tokens" => 5_000,
          "input_tokens_details" => %{
            "cached_tokens" => 3_000,
            "cache_write_tokens" => 1_000
          },
          "output_tokens" => 1_000,
          "output_tokens_details" => %{"reasoning_tokens" => 400}
        })

      # 1,000 × 2.00 + 3,000 × 0.20 + 1,000 × 2.50 + 1,000 × 8.00 = 13,100.
      assert Cost.of(usage, "gpt-5.6-sol") == %Cost{currency: "USD", micros: 13_100}

      day = Trace.resolve_model("gpt-5.6-sol", cache: [ttl: :twelve_hours])
      assert Cost.of(usage, day) == %Cost{currency: "USD", micros: 15_600}
    end

    test "OpenAI before GPT-5.6: reads only, and a single write rate that never applies" do
      put_models(%{
        "gpt-5.5" => [
          prices: [
            currency: "USD",
            input: 1.25,
            output: 10.0,
            cache_read: 0.125,
            cache_write: 1.25,
            over: nil
          ]
        ]
      })

      usage =
        ProviderUsage.openai(%{
          "input_tokens" => 4_000,
          "input_tokens_details" => %{"cached_tokens" => 3_000},
          "output_tokens" => 100
        })

      # 1,000 × 1.25 + 3,000 × 0.125 + 100 × 10.00 = 2,625.
      assert Cost.of(usage, "gpt-5.5") == %Cost{currency: "USD", micros: 2_625}
    end

    test "Chat Completions: OpenRouter writes priced at the single rate when no TTL applies" do
      put_models(%{
        "deepseek/deepseek-v3.2" => [
          vendor: :deepseek,
          context: 163_840,
          max_output: 16_000,
          platforms: [openrouter: []],
          prices: [
            currency: "USD",
            input: 0.28,
            output: 0.42,
            cache_read: 0.028,
            cache_write: 0.28
          ]
        ]
      })

      usage =
        ProviderUsage.chat_completions(%{
          "prompt_tokens" => 20_000,
          "prompt_tokens_details" => %{"cached_tokens" => 15_000, "cache_write_tokens" => 4_000},
          "completion_tokens" => 1_000
        })

      # 1,000 × 0.28 + 15,000 × 0.028 + 4,000 × 0.28 + 1,000 × 0.42 = 2,240.
      assert Cost.of(usage, "deepseek/deepseek-v3.2") == %Cost{currency: "USD", micros: 2_240}
    end

    test "Chat Completions: Bedrock, Vertex, and a self-hosted server" do
      cheap = [currency: "USD", input: 0.5, output: 1.5, cache_read: 0.05, cache_write: 0]

      declared = fn platform, prices ->
        [
          vendor: :open,
          context: 131_072,
          max_output: 8_192,
          platforms: [platform],
          prices: prices
        ]
      end

      put_models(%{
        "qwen.qwen3-235b-a22b-2507-v1:0" => declared.({:bedrock, []}, cheap),
        "zai/glm-4.7-maas" => declared.({:vertex, []}, cheap),
        "my-qwen" =>
          declared.(
            {:openai_compatible, [base_url: "http://localhost:8000/v1"]},
            currency: "USD",
            input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0
          )
      })

      # Vertex MaaS and vLLM report reads only.
      reads =
        ProviderUsage.chat_completions(%{
          "prompt_tokens" => 10_000,
          "prompt_tokens_details" => %{"cached_tokens" => 6_000},
          "completion_tokens" => 2_000
        })

      # 4,000 × 0.50 + 6,000 × 0.05 + 2,000 × 1.50 = 5,300.
      assert Cost.of(reads, "zai/glm-4.7-maas") == %Cost{currency: "USD", micros: 5_300}

      assert Cost.of(reads, "qwen.qwen3-235b-a22b-2507-v1:0") == %Cost{
               currency: "USD",
               micros: 5_300
             }

      # A host that prices its own server at zero gets zero, not nil.
      assert Cost.of(reads, "my-qwen") == %Cost{currency: "USD", micros: 0}
    end

    test "a model id as the trace records it, and the model resolved for a call" do
      put_models(%{"claude-sonnet-5" => [prices: @one_rate]})

      assert %Cost{micros: 3_000} = Cost.of(%Usage{input_tokens: 1_000}, "claude-sonnet-5")

      assert %Cost{micros: 3_000} =
               Cost.of(%Usage{input_tokens: 1_000}, Trace.resolve_model("claude-sonnet-5"))
    end
  end

  describe "a tier: the call's prompt picks the rates" do
    # A Haiku 5.5 call: its prompt is every input token it sent, cache
    # reads and writes included, as Anthropic counts it toward the line.
    defp haiku(input, read, write, output) do
      ProviderUsage.anthropic(%{
        "input_tokens" => input - read - write,
        "cache_read_input_tokens" => read,
        "cache_creation_input_tokens" => write,
        "output_tokens" => output
      })
      |> Usage.new()
    end

    test "Haiku 5.5 on the shipped sheet: up to 100,000 prompt tokens, then the higher rates" do
      put_models(nil)

      # 100,000 exactly is "up to": 40,000 uncached × 0.10 + 50,000 read ×
      # 0.01 + 10,000 written × 0.125 + 2,000 out × 0.50, per million:
      # 4,000 + 500 + 1,250 + 1,000 = 6,750 micros.
      at_line = haiku(100_000, 50_000, 10_000, 2_000)
      assert Cost.of(at_line, "claude-haiku-5-5") == %Cost{currency: "USD", micros: 6_750}

      # One token over, and every token of the call pays the tier: 40,001
      # × 0.50 + 50,000 × 0.05 + 10,000 × 0.625 + 2,000 × 2.50 =
      # 20,000.5 + 2,500 + 6,250 + 5,000, rounded once: 33,751.
      over = haiku(100_001, 50_000, 10_000, 2_000)
      assert Cost.of(over, "claude-haiku-5-5") == %Cost{currency: "USD", micros: 33_751}

      # Cache reads and writes count toward the line: a prompt that is
      # mostly a cache hit is still over it.
      mostly_cached = haiku(150_000, 140_000, 0, 0)

      # 10,000 × 0.50 + 140,000 × 0.05 = 5,000 + 7,000.
      assert Cost.of(mostly_cached, "claude-haiku-5-5") == %Cost{currency: "USD", micros: 12_000}

      # An hour's writes on each side: 10,000 × 0.20 in place of 0.125
      # below the line (750 more), × 1.00 in place of 0.625 above (3,750).
      assert Cost.of(at_line, "claude-haiku-5-5", cache_ttl: :one_hour) ==
               %Cost{currency: "USD", micros: 7_500}

      assert Cost.of(over, "claude-haiku-5-5", cache_ttl: :one_hour) ==
               %Cost{currency: "USD", micros: 37_501}
    end

    test "Haiku 5.5 with an override: the app's own tier, on each side of its line" do
      put_models(%{
        "claude-haiku-5-5" => [
          prices: [
            currency: "USD",
            input: 0.08,
            output: 0.40,
            cache_read: 0.008,
            cache_write: [five_minutes: 0.10, one_hour: 0.16],
            over: [
              prompt_tokens: 100_000,
              input: 0.40,
              output: 2.00,
              cache_read: 0.04,
              cache_write: [five_minutes: 0.50, one_hour: 0.80]
            ],
            source: "contract 2026-10",
            read: ~D[2026-10-15]
          ]
        ]
      })

      assert :ok = Clementine.Models.validate_config!()

      # 40,000 × 0.08 + 50,000 × 0.008 + 10,000 × 0.10 + 2,000 × 0.40 =
      # 3,200 + 400 + 1,000 + 800.
      assert Cost.of(haiku(100_000, 50_000, 10_000, 2_000), "claude-haiku-5-5") ==
               %Cost{currency: "USD", micros: 5_400}

      # 40,001 × 0.40 + 50,000 × 0.04 + 10,000 × 0.50 + 2,000 × 2.00 =
      # 16,000.4 + 2,000 + 5,000 + 4,000.
      assert Cost.of(haiku(100_001, 50_000, 10_000, 2_000), "claude-haiku-5-5") ==
               %Cost{currency: "USD", micros: 27_000}

      # An override that clears the tier with over: nil prices every call
      # at its one set of rates.
      flat = [
        currency: "USD",
        input: 0.08,
        output: 0.40,
        cache_read: 0.008,
        cache_write: [five_minutes: 0.10, one_hour: 0.16]
      ]

      put_models(%{"claude-haiku-5-5" => [prices: flat ++ [over: nil]]})

      assert :ok = Clementine.Models.validate_config!()

      assert Cost.of(haiku(100_001, 50_000, 10_000, 2_000), "claude-haiku-5-5") ==
               %Cost{currency: "USD", micros: 5_400}
    end

    test "an override that leaves out a shipped tier fails, rather than undercount long calls" do
      flat = [
        currency: "USD",
        input: 0.08,
        output: 0.40,
        cache_read: 0.008,
        cache_write: [five_minutes: 0.10, one_hour: 0.16]
      ]

      # Without over:, a 200,000-token Haiku 5.5 call would pay the base
      # rates, a fifth of the tier's.
      put_models(%{"claude-haiku-5-5" => [prices: flat]})

      assert_raise ArgumentError,
                   ~r/"claude-haiku-5-5".*over 100000 prompt tokens.*restate the tier, or write over: nil/s,
                   fn -> Clementine.Models.validate_config!() end

      assert {:error, _message} = Clementine.Models.fetch("claude-haiku-5-5")
      assert Cost.of(haiku(200_000, 0, 0, 1_000), "claude-haiku-5-5") == nil

      assert_raise ArgumentError, ~r/restate the tier/, fn ->
        Agent.new(model: "claude-haiku-5-5")
      end

      # The GPT-6 family's 272,000 line holds the same way.
      gpt = [currency: "USD", input: 9, output: 45, cache_read: 0.9]
      writes = [cache_write: [thirty_minutes: 11.25, twelve_hours: 22.5]]
      put_models(%{"gpt-6-astra" => [prices: gpt ++ writes]})

      assert_raise ArgumentError, ~r/"gpt-6-astra".*over 272000 prompt tokens/s, fn ->
        Clementine.Models.validate_config!()
      end

      # A sheet with no tier takes an override without over:, and
      # prices: nil opts out whatever the sheet has.
      put_models(%{
        "claude-sonnet-5" => [prices: flat],
        "claude-haiku-5-5" => [prices: nil]
      })

      assert :ok = Clementine.Models.validate_config!()
      assert Cost.of(haiku(200_000, 0, 0, 1_000), "claude-haiku-5-5") == nil
    end

    test "GPT-6 Astra over 272,000 input tokens, cached ones counted, as OpenAI counts them" do
      put_models(nil)

      usage = fn input, cached ->
        ProviderUsage.openai(%{
          "input_tokens" => input,
          "input_tokens_details" => %{"cached_tokens" => cached},
          "output_tokens" => 1_000
        })
      end

      # 72,000 × 10 + 200,000 × 1 + 1,000 × 50 = 720,000 + 200,000 + 50,000.
      assert Cost.of(usage.(272_000, 200_000), "gpt-6-astra") ==
               %Cost{currency: "USD", micros: 970_000}

      # 72,001 × 20 + 200,000 × 2 + 1,000 × 75.
      assert Cost.of(usage.(272_001, 200_000), "gpt-6-astra") ==
               %Cost{currency: "USD", micros: 1_440_020 + 400_000 + 75_000}
    end

    test "a summed usage picks the tier by its sum: price each call, not a run's total" do
      put_models(nil)
      call = haiku(60_000, 0, 0, 0)
      run = Usage.add(call, call)

      # Two 60,000-token calls each stay under the line; their sum is over.
      assert Cost.sum([Cost.of(call, "claude-haiku-5-5"), Cost.of(call, "claude-haiku-5-5")]) ==
               %Cost{currency: "USD", micros: 12_000}

      assert Cost.of(run, "claude-haiku-5-5") == %Cost{currency: "USD", micros: 60_000}
    end
  end

  describe "of/3: where the call ran, and the TTL it wrote with" do
    test "the platform and TTL a trace entry records, as strings or atoms" do
      put_models(nil)
      usage = %Usage{input_tokens: 10_000, cache_write_tokens: 10_000}

      # Sonnet 5.5's writes: $2.50 for five minutes, $4 for an hour.
      assert %Cost{micros: 25_000} = Cost.of(usage, "claude-sonnet-5-5")
      assert %Cost{micros: 40_000} = Cost.of(usage, "claude-sonnet-5-5", cache_ttl: :one_hour)

      assert %Cost{micros: 40_000} =
               Cost.of(usage, "claude-sonnet-5-5", platform: "anthropic", cache_ttl: "one_hour")

      # A platform it is not served on, or a TTL it has no rate for, has
      # no cost to state.
      assert Cost.of(usage, "claude-sonnet-5-5", platform: :openai) == nil
      assert Cost.of(usage, "claude-sonnet-5-5", cache_ttl: :thirty_minutes) == nil
    end
  end

  describe "what is not priced costs nil, never zero" do
    test "a declared model without prices, an unpriced override, an id no sheet holds, an atom" do
      put_models(%{
        "my-qwen" => [
          vendor: :qwen,
          context: 32_768,
          max_output: 8_192,
          platforms: [openai_compatible: [base_url: "http://localhost:8000/v1"]]
        ],
        "claude-sonnet-5" => [prices: nil]
      })

      usage = %Usage{input_tokens: 1_000, output_tokens: 10}

      assert Cost.of(usage, "my-qwen") == nil

      # Resolved for a call: its vendor and the platform it is served on.
      assert %{provider: :qwen, platform: :openai_compatible, cache_ttl: nil, pricing: nil} =
               Trace.resolve_model("my-qwen")

      assert Cost.of(usage, Trace.resolve_model("my-qwen")) == nil
      assert Cost.of(usage, "claude-sonnet-5") == nil
      assert Cost.of(usage, "not-a-model") == nil
      assert Cost.of(usage, Trace.resolve_model("not-a-model")) == nil
      assert Cost.of(usage, :claude_sonnet) == nil
      assert Cost.of(usage, nil) == nil

      # A shipped sheet is priced without any config.
      assert %Cost{currency: "USD"} = Cost.of(usage, "claude-sonnet-5-5")
    end

    test "no usage on a priced model is zero" do
      put_models(%{"claude-sonnet-5" => [prices: @one_rate]})

      assert Cost.of(%Usage{}, "claude-sonnet-5") == %Cost{currency: "USD", micros: 0}
    end
  end

  describe "sum/1" do
    test "adds costs in one currency" do
      assert Cost.sum([
               %Cost{currency: "USD", micros: 1_500},
               %Cost{currency: "USD", micros: 2_500}
             ]) == %Cost{currency: "USD", micros: 4_000}
    end

    test "an unpriced part makes the total unknown, never an undercount" do
      assert Cost.sum([%Cost{currency: "USD", micros: 1_500}, nil]) == nil
      assert Cost.sum([nil, %Cost{currency: "USD", micros: 1_500}]) == nil
    end

    test "costs in different currencies have no total" do
      assert Cost.sum([%Cost{currency: "USD", micros: 1}, %Cost{currency: "EUR", micros: 1}]) ==
               nil
    end

    test "nothing is zero in the models' currency, or nil when no model has prices" do
      put_models(nil)
      assert Cost.sum([]) == %Cost{currency: "USD", micros: 0}

      # An app that unprices every model has no currency to state zero in.
      put_models(Map.new(Clementine.Models.list(), &{&1.id, [prices: nil]}))
      assert Cost.sum([]) == nil
    end
  end

  test "to_map/1 and from_map/1 round-trip, and nil stays nil" do
    cost = %Cost{currency: "USD", micros: 16_650}

    assert Cost.to_map(cost) == %{"currency" => "USD", "micros" => 16_650}
    assert cost |> Cost.to_map() |> Cost.from_map() == cost
    assert Cost.to_map(nil) == nil
    assert Cost.from_map(nil) == nil
    assert Cost.from_map(%{"micros" => 1}) == nil
  end
end
