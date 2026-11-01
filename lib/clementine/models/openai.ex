defmodule Clementine.Models.OpenAI do
  @moduledoc """
  The fact sheets of OpenAI's models (`Clementine.Model`), read from
  OpenAI's documentation on 2026-11-01.

  Each sheet names its model page. The facts across sheets come from
  these pages, all read that day:

  - [Models](https://developers.openai.com/api/docs/models) and each
    model's page: context, output, effort levels, supported features.
  - [Reasoning](https://developers.openai.com/api/docs/guides/reasoning):
    default efforts, where the guide states one.
  - [Deprecations](https://developers.openai.com/api/docs/deprecations):
    shutdown dates and replacements.
  - [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching):
    `prompt_cache_options` and its TTLs on GPT-5.6 and later, the 1,024
    token minimum.
  - [Changelog](https://developers.openai.com/api/docs/changelog):
    release dates, which the model pages do not show.
  - [Pricing](https://developers.openai.com/api/docs/pricing): Standard
    list prices, short and long context. Every model the page lists long
    rates for (GPT-6, GPT-6.1, GPT-5.6, and GPT-5.5) bills a request over
    272,000 input tokens at them, cached tokens counted (the Responses
    API's `input_tokens` holds them): 2x input and cache, 1.5x output
    (each model's page). Batch, Flex, fast mode, and regional processing
    price otherwise; an app on them overrides `prices`.

  Every OpenAI reasoning model reasons on its own (`thinking` is
  `:adaptive` only); an effort of `:none`, where the model takes it, is
  how a call asks for no reasoning. `line` is the model's tier
  (`:astra`, `:sol`, `:terra`, `:luna`) from GPT-5.6 on. A model older
  than GPT-5.6 keeps its own cache retention and takes no
  `prompt_cache_options`, so its sheet offers no TTL. `tool_search` and
  `mid_conversation_system` are Anthropic's mechanisms and stay off.
  """

  @read ~D[2026-11-01]
  @models "https://developers.openai.com/api/docs/models"
  @pricing "https://developers.openai.com/api/docs/pricing"
  # "Long context: >272K input tokens", priced at the long rates for the
  # whole request. K is a thousand: GPT-5's 400,000-token window is
  # 272,000 of input and 128,000 of output.
  @long_context 272_000

  @gpt_6_efforts [:low, :medium, :high, :xhigh, :max]
  @features [structured_outputs: true]
  @cache [min_prefix: 1024, ttls: [:thirty_minutes, :twelve_hours]]

  @doc false
  # The sheets in keyword form, newest first within each line.
  @spec sheets() :: [keyword()]
  def sheets do
    [
      [
        id: "gpt-6.1-terra",
        line: :terra,
        display_name: "GPT-6.1 Terra",
        released_on: ~D[2026-10-26],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:none | @gpt_6_efforts], :medium),
        prices: prices({1, 5, 0.05, {1.25, 2.50}}, {2, 7.50, 0.10, {2.50, 5}}),
        cache: @cache
      ],
      [
        id: "gpt-6.1-sol",
        line: :sol,
        display_name: "GPT-6.1 Sol",
        released_on: ~D[2026-09-29],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning(@gpt_6_efforts, :medium),
        prices: prices({2, 10, 0.10, {2.50, 5}}, {4, 15, 0.20, {5, 10}}),
        cache: @cache
      ],
      [
        id: "gpt-6-luna",
        line: :luna,
        display_name: "GPT-6 Luna",
        released_on: ~D[2026-09-22],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:none | @gpt_6_efforts], :medium),
        prices: prices({0.10, 0.50, 0.01, {0.125, 0.25}}, {0.20, 0.75, 0.02, {0.25, 0.50}}),
        cache: @cache
      ],
      [
        # OpenAI publishes no default effort for Astra.
        id: "gpt-6-astra",
        line: :astra,
        display_name: "GPT-6 Astra",
        released_on: ~D[2026-09-03],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning(@gpt_6_efforts, nil),
        prices: prices({10, 50, 1, {12.50, 25}}, {20, 75, 2, {25, 50}}),
        cache: @cache
      ],
      [
        id: "gpt-5.6-sol",
        line: :sol,
        display_name: "GPT-5.6 Sol",
        released_on: ~D[2026-07-09],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:none | @gpt_6_efforts], :medium),
        prices: prices({4, 20, 0.40, {5, 10}}, {8, 30, 0.80, {10, 20}}),
        cache: @cache
      ],
      [
        id: "gpt-5.5",
        display_name: "GPT-5.5",
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:none, :low, :medium, :high, :xhigh], :medium),
        prices: prices({5, 30, 0.50, 5}, {10, 45, 1, 10})
      ],
      [
        id: "gpt-5.5-pro",
        display_name: "GPT-5.5 Pro",
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:medium, :high, :xhigh], :high),
        prices: prices({30, 180, 30, 30}, {60, 270, 60, 60})
      ],
      [
        id: "gpt-5.4-mini",
        display_name: "GPT-5.4 mini",
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning([:none, :low, :medium, :high, :xhigh], :none),
        prices: prices({0.75, 4.50, 0.075, 0.75})
      ],
      [
        # The deprecations page names GPT-5.6 Sol as the replacement; the
        # model page recommends GPT-6 Astra. OpenAI publishes no default
        # effort for it.
        id: "gpt-5",
        display_name: "GPT-5",
        lifecycle: [
          status: :deprecated,
          deprecated_on: ~D[2026-06-11],
          retires_on: ~D[2026-12-11],
          replacement: "gpt-5.6-sol"
        ],
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning([:minimal, :low, :medium, :high], nil),
        prices: prices({1.25, 10, 0.125, 1.25})
      ],
      [
        id: "gpt-4.1",
        display_name: "GPT-4.1",
        lifecycle: [
          status: :deprecated,
          deprecated_on: ~D[2026-10-14],
          retires_on: ~D[2027-01-14],
          replacement: "gpt-6-luna"
        ],
        context: 1_047_576,
        max_output: 32_768,
        thinking: [default: :off, types: [:off]],
        prices: prices({2, 8, 0.50, 2})
      ]
    ]
    |> Enum.map(fn sheet ->
      id = Keyword.fetch!(sheet, :id)

      [vendor: :openai, features: @features, platforms: [openai: []]]
      |> Keyword.merge(sheet)
      |> Keyword.merge(source: "#{@models}/#{id}", read: @read)
    end)
  end

  # Standard-tier list prices in USD per million tokens, as the pricing
  # page states them: `{input, output, cached input, cache write}`, the
  # write a `{30-minute, 12-hour}` pair on GPT-5.6 and later, and the long
  # context rates where the page lists them. Before GPT-5.6 a cache write
  # is billed as plain input (the page lists none), so its rate is the
  # input rate; GPT-5.5 Pro lists no cached input, so a read is too.
  defp prices(rates, long \\ nil) do
    base = [currency: "USD"] ++ rates(rates) ++ [source: @pricing, read: @read]

    if long,
      do: base ++ [over: [prompt_tokens: @long_context] ++ rates(long)],
      else: base
  end

  defp rates({input, output, cache_read, cache_write}) do
    [input: input, output: output, cache_read: cache_read, cache_write: writes(cache_write)]
  end

  defp writes({thirty_minutes, twelve_hours}),
    do: [thirty_minutes: thirty_minutes, twelve_hours: twelve_hours]

  defp writes(rate), do: rate

  defp reasoning(efforts, default_effort) do
    [
      default: :adaptive,
      types: [:adaptive],
      efforts: efforts,
      default_effort: default_effort,
      binding: :none
    ]
  end
end
