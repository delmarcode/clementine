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
        cache: @cache
      ],
      [
        id: "gpt-5.5",
        display_name: "GPT-5.5",
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:none, :low, :medium, :high, :xhigh], :medium)
      ],
      [
        id: "gpt-5.5-pro",
        display_name: "GPT-5.5 Pro",
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:medium, :high, :xhigh], :high)
      ],
      [
        id: "gpt-5.4-mini",
        display_name: "GPT-5.4 mini",
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning([:none, :low, :medium, :high, :xhigh], :none)
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
        thinking: reasoning([:minimal, :low, :medium, :high], nil)
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
        thinking: [default: :off, types: [:off]]
      ]
    ]
    |> Enum.map(fn sheet ->
      id = Keyword.fetch!(sheet, :id)

      [vendor: :openai, features: @features, platforms: [openai: []]]
      |> Keyword.merge(sheet)
      |> Keyword.merge(source: "#{@models}/#{id}", read: @read)
    end)
  end

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
