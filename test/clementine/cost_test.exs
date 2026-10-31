defmodule Clementine.CostTest do
  @moduledoc """
  `Clementine.Cost`: the pure function from usage and prices to a cost,
  across each provider's usage shape (cache reads and writes, both of
  Anthropic's TTLs and both of OpenAI's), `nil` for what is not priced,
  and sums. The rates are illustrative, not anyone's current prices.
  """

  use ExUnit.Case, async: false

  alias Clementine.{Cost, Usage}
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

  # Prices as `Pricing.of/1` gives them for a resolved alias writing with `ttl`.
  defp at_ttl(pricing, provider, ttl) do
    Pricing.of(%{provider: provider, pricing: pricing!(pricing), cache: %{ttl: ttl}})
  end

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
      assert Cost.price(usage, at_ttl(@card, :anthropic, :five_minutes)) ==
               %Cost{currency: "USD", micros: 16_650}

      # The same call writing for an hour: 1,000 × 6.00 per million more.
      assert Cost.price(usage, at_ttl(@card, :anthropic, :one_hour)) ==
               %Cost{currency: "USD", micros: 18_900}
    end

    test "sums the parts exactly and rounds once, half up, to the micro-unit" do
      pricing = at_ttl(@card, :anthropic, :five_minutes)

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
      pricing = at_ttl(@card, :anthropic, :five_minutes)

      assert Cost.price(%Usage{input_tokens: 10, cache_read_tokens: 20}, pricing) ==
               Cost.price(%Usage{input_tokens: 20, cache_read_tokens: 20}, pricing)
    end

    test "nothing burned costs zero" do
      assert %Cost{currency: "USD", micros: 0} =
               Cost.price(%Usage{}, at_ttl(@card, :anthropic, :five_minutes))
    end
  end

  # Each test starts from the provider's own usage object, normalized as
  # its client normalizes it, so what is priced is what a run records.
  describe "of/2: each provider's usage, from the wire, priced from the catalog" do
    test "Anthropic: reads and writes are parts of input, writes at the alias's TTL" do
      put_models(
        claude: [provider: :anthropic, id: "claude-sonnet-5", pricing: @card],
        claude_hour: [
          provider: :anthropic,
          id: "claude-sonnet-5",
          cache: [ttl: :one_hour],
          pricing: @card
        ]
      )

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
      assert Cost.of(usage, :claude) == %Cost{currency: "USD", micros: 9_975}
      # 900 × 6.00 in place of 900 × 3.75: 2,025 more.
      assert Cost.of(usage, :claude_hour) == %Cost{currency: "USD", micros: 12_000}
    end

    test "OpenAI Responses: thirty-minute and twelve-hour writes on GPT-5.6 and later" do
      card = [
        currency: "USD",
        input: 2.0,
        output: 8.0,
        cache_read: 0.2,
        cache_write: [thirty_minutes: 2.5, twelve_hours: 5.0]
      ]

      put_models(
        gpt: [provider: :openai, id: "gpt-5.6", pricing: card],
        gpt_day: [provider: :openai, id: "gpt-5.6", cache: [ttl: :twelve_hours], pricing: card]
      )

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
      assert Cost.of(usage, :gpt) == %Cost{currency: "USD", micros: 13_100}
      assert Cost.of(usage, :gpt_day) == %Cost{currency: "USD", micros: 15_600}
    end

    test "OpenAI before GPT-5.6: reads only, and a single write rate that never applies" do
      put_models(
        gpt_old: [
          provider: :openai,
          id: "gpt-5",
          pricing: [
            currency: "USD",
            input: 1.25,
            output: 10.0,
            cache_read: 0.125,
            cache_write: 1.25
          ]
        ]
      )

      usage =
        ProviderUsage.openai(%{
          "input_tokens" => 4_000,
          "input_tokens_details" => %{"cached_tokens" => 3_000},
          "output_tokens" => 100
        })

      # 1,000 × 1.25 + 3,000 × 0.125 + 100 × 10.00 = 2,625.
      assert Cost.of(usage, :gpt_old) == %Cost{currency: "USD", micros: 2_625}
    end

    test "Chat Completions: OpenRouter writes priced at the single rate when no TTL applies" do
      put_models(
        deepseek: [
          provider: :openrouter,
          id: "deepseek/deepseek-v3.2",
          pricing: [
            currency: "USD",
            input: 0.28,
            output: 0.42,
            cache_read: 0.028,
            cache_write: 0.28
          ]
        ]
      )

      usage =
        ProviderUsage.chat_completions(%{
          "prompt_tokens" => 20_000,
          "prompt_tokens_details" => %{"cached_tokens" => 15_000, "cache_write_tokens" => 4_000},
          "completion_tokens" => 1_000
        })

      # 1,000 × 0.28 + 15,000 × 0.028 + 4,000 × 0.28 + 1,000 × 0.42 = 2,240.
      assert Cost.of(usage, :deepseek) == %Cost{currency: "USD", micros: 2_240}
    end

    test "Chat Completions: Bedrock, Vertex, and a self-hosted server" do
      cheap = [currency: "USD", input: 0.5, output: 1.5, cache_read: 0.05, cache_write: 0]

      put_models(
        qwen_bedrock: [provider: :bedrock, id: "qwen.qwen3-235b-a22b-2507-v1:0", pricing: cheap],
        glm_vertex: [provider: :vertex, id: "zai/glm-4.7-maas", pricing: cheap],
        local: [
          provider: :openai_compatible,
          id: "my-qwen",
          base_url: "http://localhost:8000/v1",
          pricing: [currency: "USD", input: 0, output: 0, cache_read: 0, cache_write: 0]
        ]
      )

      # Vertex MaaS and vLLM report reads only.
      reads =
        ProviderUsage.chat_completions(%{
          "prompt_tokens" => 10_000,
          "prompt_tokens_details" => %{"cached_tokens" => 6_000},
          "completion_tokens" => 2_000
        })

      # 4,000 × 0.50 + 6,000 × 0.05 + 2,000 × 1.50 = 5,300.
      assert Cost.of(reads, :glm_vertex) == %Cost{currency: "USD", micros: 5_300}
      assert Cost.of(reads, :qwen_bedrock) == %Cost{currency: "USD", micros: 5_300}

      # A host that prices its own server at zero gets zero, not nil.
      assert Cost.of(reads, :local) == %Cost{currency: "USD", micros: 0}
    end

    test "an alias as the trace records it, a string" do
      put_models(claude: [provider: :anthropic, id: "claude-sonnet-5", pricing: @one_rate])

      assert %Cost{micros: 3_000} = Cost.of(%Usage{input_tokens: 1_000}, "claude")
    end
  end

  describe "what is not priced costs nil, never zero" do
    test "an alias without prices, a direct reference, and a reference the catalog lacks" do
      put_models(claude: [provider: :anthropic, id: "claude-sonnet-5"])
      usage = %Usage{input_tokens: 1_000, output_tokens: 10}

      assert Cost.of(usage, :claude) == nil
      assert Cost.of(usage, {:anthropic, "claude-sonnet-5"}) == nil
      assert Cost.of(usage, :not_in_the_catalog) == nil
      assert Cost.of(usage, "not_an_existing_atom_#{System.unique_integer([:positive])}") == nil
      assert Cost.of(usage, nil) == nil
    end

    test "no usage on a priced alias is zero" do
      put_models(claude: [provider: :anthropic, id: "claude-sonnet-5", pricing: @one_rate])

      assert Cost.of(%Usage{}, :claude) == %Cost{currency: "USD", micros: 0}
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

    test "nothing is zero in the catalog's currency, or nil when the catalog prices nothing" do
      put_models(
        plain: [provider: :anthropic, id: "claude-haiku-4-5"],
        claude: [provider: :anthropic, id: "claude-sonnet-5", pricing: @card]
      )

      assert Cost.sum([]) == %Cost{currency: "USD", micros: 0}

      put_models(plain: [provider: :anthropic, id: "claude-haiku-4-5"])
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
