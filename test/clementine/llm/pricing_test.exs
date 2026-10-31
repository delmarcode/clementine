defmodule Clementine.LLM.PricingTest do
  @moduledoc """
  The catalog's `pricing:` key: what a priced alias must say, checked at
  boot, and the cache write rate picked by the TTL the alias writes with.
  The rates are illustrative, not anyone's current prices.
  """

  use ExUnit.Case, async: false

  alias Clementine.LLM.{ModelRegistry, Pricing}

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
    assert_raise ArgumentError, &ModelRegistry.validate_config!/0
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
    test "picks the cache write rate for the TTL the resolved alias writes with" do
      {:ok, pricing} = Pricing.validate(@card)

      assert %Pricing{cache_write: 3_750_000} =
               Pricing.of(%{provider: :anthropic, pricing: pricing, cache: %{ttl: :five_minutes}})

      assert %Pricing{cache_write: 6_000_000} =
               Pricing.of(%{provider: :anthropic, pricing: pricing, cache: %{ttl: :one_hour}})
    end

    test "a single cache write rate holds whatever the TTL, or with none" do
      {:ok, pricing} = Pricing.validate(Keyword.put(@card, :cache_write, 3.75))

      for ttl <- [:five_minutes, :one_hour, nil] do
        assert %Pricing{cache_write: 3_750_000} =
                 Pricing.of(%{provider: :anthropic, pricing: pricing, cache: %{ttl: ttl}})
      end
    end

    test "nil for an alias without prices and a direct reference" do
      put_models(claude: [provider: :anthropic, id: "claude-sonnet-5"])

      assert Pricing.of(:claude) == nil
      assert Pricing.of({:anthropic, "claude-sonnet-5"}) == nil
      assert Pricing.of(:missing) == nil
    end
  end

  describe "at boot" do
    test "a priced catalog validates, and resolve!/1 carries the prices" do
      put_models(
        claude: [provider: :anthropic, id: "claude-sonnet-5", pricing: @one_rate],
        plain: [provider: :openai, id: "gpt-5"]
      )

      assert :ok = ModelRegistry.validate_config!()
      assert %{pricing: %Pricing{currency: "USD"}} = ModelRegistry.resolve!(:claude)
      assert %{pricing: nil} = ModelRegistry.resolve!(:plain)
      assert %{pricing: nil} = ModelRegistry.resolve!({:openai, "gpt-5"})
    end

    test "a sub-micro rate fails, naming the alias and the key" do
      error =
        boot_error(
          claude: [
            provider: :anthropic,
            id: "claude-sonnet-5",
            pricing: Keyword.put(@one_rate, :output, 0.0000003)
          ]
        )

      assert error.message =~ "Invalid model config for :claude"
      assert error.message =~ "output 3.0e-7 is finer than six decimal places"
    end

    test "a partial price list fails, naming the alias" do
      error =
        boot_error(
          claude: [
            provider: :anthropic,
            id: "claude-sonnet-5",
            pricing: Keyword.delete(@card, :output)
          ]
        )

      assert error.message =~ "Invalid model config for :claude"
      assert error.message =~ "missing [:output]"
    end

    test "a per-TTL cache_write without the rate for the alias's TTL fails" do
      error =
        boot_error(
          claude: [
            provider: :anthropic,
            id: "claude-sonnet-5",
            cache: [ttl: :one_hour],
            pricing: Keyword.put(@card, :cache_write, five_minutes: 3.75)
          ]
        )

      assert error.message =~ "Invalid model config for :claude"
      assert error.message =~ "names no rate for :one_hour"
    end

    test "a per-TTL cache_write on an alias whose writes carry no TTL fails" do
      error =
        boot_error(
          qwen: [
            provider: :bedrock,
            id: "qwen.qwen3-235b-a22b-2507-v1:0",
            pricing: [
              currency: "USD",
              input: 1,
              output: 1,
              cache_read: 0.1,
              cache_write: [five_minutes: 1]
            ]
          ]
        )

      assert error.message =~ "Invalid model config for :qwen"
      assert error.message =~ "give one cache_write rate"
    end

    test "priced aliases in two currencies fail: their costs would not add up" do
      error =
        boot_error(
          claude: [provider: :anthropic, id: "claude-sonnet-5", pricing: @one_rate],
          gpt: [
            provider: :openai,
            id: "gpt-5",
            pricing: [currency: "EUR", input: 1, output: 8, cache_read: 0.1, cache_write: 1]
          ]
        )

      assert error.message =~ "every priced alias names one currency"
      assert error.message =~ ~s(["USD", "EUR"])
    end

    test "the catalog's currency is the one its priced aliases name, or nil" do
      put_models(
        plain: [provider: :openai, id: "gpt-5"],
        claude: [provider: :anthropic, id: "claude-sonnet-5", pricing: @one_rate]
      )

      assert Pricing.currency() == "USD"

      put_models(plain: [provider: :openai, id: "gpt-5"])
      assert Pricing.currency() == nil
    end
  end
end
