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
  - [Using GPT-6](https://developers.openai.com/api/docs/guides/latest-model)
    and the [Responses API reference](https://developers.openai.com/api/reference/resources/responses/methods/create):
    rejected sampling parameters, `reasoning.summary`.

  A model the deprecations page lists as shut down keeps a stub sheet
  (`lifecycle: [status: :retired]`), so naming it fails with the
  replacement OpenAI names.

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
  @gpt_5_4_efforts [:none, :low, :medium, :high, :xhigh]
  @gpt_5_efforts [:minimal, :low, :medium, :high]
  @features [structured_outputs: true]

  # Clementine sends neither, so these record the vendor's rule: the GPT-6
  # guide's "when reasoning effort is not none, remove temperature,
  # top_p" (every GPT-6 model, at its default effort and above), and
  # Astra's changelog entry.
  @sampling [:temperature, :top_p]
  # GPT-5 and its mini, nano, and pro refuse sampling parameters, and
  # `summary: :concise` is for reasoning models after GPT-5.
  @gpt_5_rejects [:temperature, :top_p, :concise_summary]
  # The caching guide, the 2026-10-20 changelog, and the pricing page
  # offer "12h"; the API reference's request-level
  # `prompt_cache_options.ttl` still says "30m" is the only value, while
  # its per-breakpoint TTL takes both. The three agree, so 12h stays.
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
        rejects: @sampling,
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
        rejects: @sampling,
        cache: @cache
      ],
      [
        id: "gpt-6-sol",
        line: :sol,
        display_name: "GPT-6 Sol",
        released_on: ~D[2026-09-22],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:none | @gpt_6_efforts], :medium),
        rejects: @sampling,
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
        rejects: @sampling,
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
        rejects: @sampling,
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
        id: "gpt-5.6-terra",
        line: :terra,
        display_name: "GPT-5.6 Terra",
        released_on: ~D[2026-07-09],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:none | @gpt_6_efforts], :medium),
        cache: @cache
      ],
      [
        id: "gpt-5.6-luna",
        line: :luna,
        display_name: "GPT-5.6 Luna",
        released_on: ~D[2026-07-09],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:none | @gpt_6_efforts], :medium),
        cache: @cache
      ],
      [
        id: "gpt-5.5",
        display_name: "GPT-5.5",
        released_on: ~D[2026-04-24],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:none, :low, :medium, :high, :xhigh], :medium)
      ],
      [
        # Its page lists streaming as not supported, and an agent's runs
        # stream.
        id: "gpt-5.5-pro",
        display_name: "GPT-5.5 Pro",
        released_on: ~D[2026-04-24],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:medium, :high, :xhigh], :high),
        features: [structured_outputs: true, streaming: false]
      ],
      [
        id: "gpt-5.4",
        display_name: "GPT-5.4",
        released_on: ~D[2026-03-05],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning(@gpt_5_4_efforts, :none)
      ],
      [
        id: "gpt-5.4-pro",
        display_name: "GPT-5.4 Pro",
        released_on: ~D[2026-03-05],
        context: 1_050_000,
        max_output: 128_000,
        thinking: reasoning([:medium, :high, :xhigh], :medium),
        features: [structured_outputs: false]
      ],
      [
        id: "gpt-5.4-mini",
        display_name: "GPT-5.4 mini",
        released_on: ~D[2026-03-17],
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning(@gpt_5_4_efforts, :none)
      ],
      [
        id: "gpt-5.4-nano",
        display_name: "GPT-5.4 nano",
        released_on: ~D[2026-03-17],
        lifecycle: deprecated(~D[2026-10-01], ~D[2027-04-01], "gpt-6-luna"),
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning(@gpt_5_4_efforts, :none)
      ],
      [
        id: "gpt-5.2",
        display_name: "GPT-5.2",
        released_on: ~D[2025-12-11],
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning(@gpt_5_4_efforts, :none)
      ],
      [
        # The changelog gives no release date, nor the page a default
        # effort.
        id: "gpt-5.2-pro",
        display_name: "GPT-5.2 Pro",
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning([:medium, :high, :xhigh], nil),
        features: [structured_outputs: false]
      ],
      [
        id: "gpt-5.1",
        display_name: "GPT-5.1",
        released_on: ~D[2025-11-13],
        lifecycle: deprecated(~D[2026-10-01], ~D[2027-04-01], "gpt-6-sol"),
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning([:none, :low, :medium, :high], :none)
      ],
      [
        # The deprecations page names GPT-5.6 Sol as the replacement; the
        # model page recommends GPT-6 Astra. OpenAI publishes no default
        # effort for it.
        id: "gpt-5",
        display_name: "GPT-5",
        released_on: ~D[2025-08-07],
        lifecycle: deprecated(~D[2026-06-11], ~D[2026-12-11], "gpt-5.6-sol"),
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning(@gpt_5_efforts, nil),
        rejects: @gpt_5_rejects
      ],
      [
        id: "gpt-5-mini",
        display_name: "GPT-5 mini",
        released_on: ~D[2025-08-07],
        lifecycle: deprecated(~D[2026-06-11], ~D[2026-12-11], "gpt-5.6-terra"),
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning(@gpt_5_efforts, nil),
        rejects: @gpt_5_rejects
      ],
      [
        id: "gpt-5-nano",
        display_name: "GPT-5 nano",
        released_on: ~D[2025-08-07],
        lifecycle: deprecated(~D[2026-06-11], ~D[2026-12-11], "gpt-5.6-luna"),
        context: 400_000,
        max_output: 128_000,
        thinking: reasoning(@gpt_5_efforts, nil),
        rejects: @gpt_5_rejects
      ],
      [
        # The replacement is GPT-5.6 Sol with `reasoning.mode: "pro"`.
        id: "gpt-5-pro",
        display_name: "GPT-5 Pro",
        released_on: ~D[2025-10-06],
        lifecycle: deprecated(~D[2026-06-11], ~D[2026-12-11], "gpt-5.6-sol"),
        context: 400_000,
        max_output: 272_000,
        thinking: reasoning([:high], :high),
        rejects: @gpt_5_rejects
      ],
      [
        id: "gpt-4.1",
        display_name: "GPT-4.1",
        released_on: ~D[2025-04-14],
        lifecycle: deprecated(~D[2026-10-14], ~D[2027-01-14], "gpt-6-luna"),
        context: 1_047_576,
        max_output: 32_768,
        thinking: [default: :off, types: [:off]]
      ],
      [
        id: "gpt-4.1-mini",
        display_name: "GPT-4.1 mini",
        released_on: ~D[2025-04-14],
        lifecycle: deprecated(~D[2026-10-14], ~D[2027-01-14], "gpt-6-luna"),
        context: 1_047_576,
        max_output: 32_768,
        thinking: [default: :off, types: [:off]]
      ],
      shut_down("o4-mini", "o4-mini", ~D[2026-04-22], ~D[2026-10-23], "gpt-5.6-terra"),
      shut_down("gpt-4.1-nano", "GPT-4.1 nano", ~D[2026-04-22], ~D[2026-10-23], "gpt-5.6-luna")
    ]
    |> Enum.map(fn sheet ->
      id = Keyword.fetch!(sheet, :id)

      [vendor: :openai, features: @features, platforms: [openai: []]]
      |> Keyword.merge(sheet)
      |> Keyword.merge(read: @read)
      |> Keyword.put_new(:source, "#{@models}/#{id}")
    end)
  end

  defp shut_down(id, display_name, deprecated_on, shutdown_on, replacement) do
    [
      id: id,
      display_name: display_name,
      lifecycle: [
        status: :retired,
        deprecated_on: deprecated_on,
        retires_on: shutdown_on,
        replacement: replacement
      ],
      source: "https://developers.openai.com/api/docs/deprecations"
    ]
  end

  defp deprecated(deprecated_on, shutdown_on, replacement) do
    [
      status: :deprecated,
      deprecated_on: deprecated_on,
      retires_on: shutdown_on,
      replacement: replacement
    ]
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
