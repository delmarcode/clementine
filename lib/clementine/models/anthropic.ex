defmodule Clementine.Models.Anthropic do
  @moduledoc """
  The fact sheets of Anthropic's models (`Clementine.Model`), read from
  Anthropic's documentation on 2026-11-01.

  Each sheet names the page it was read from. The facts across sheets
  come from these pages, all read that day:

  - [Models overview](https://platform.claude.com/docs/en/models/overview)
    and each model's own page: ids, platform ids, context, output,
    release dates.
  - [Model deprecations](https://platform.claude.com/docs/en/about-claude/model-deprecations):
    lifecycle status and dates, replacements.
  - [Extended thinking](https://platform.claude.com/docs/en/build-with-claude/thinking)
    and [Effort](https://platform.claude.com/docs/en/build-with-claude/effort):
    thinking defaults and types, effort levels and defaults, display
    defaults, rejected parameters.
  - [Preserved thinking](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking)
    and [Mid-conversation system messages](https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages):
    which models bind their thinking and take system messages in place.
  - [Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching):
    minimum prefixes and TTLs.
  - [Tool search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool)
    and [Structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs):
    which models have them.

  `line` is the model's family as its name and Anthropic's Models API
  give it. Bedrock and Google Cloud set their own retirement dates
  (`lifecycle: :partner` on those platforms); Foundry and Claude
  Platform on AWS follow Anthropic's. Platform entries carry ids only
  where a page gave one; Bedrock's are its Messages endpoint's.
  """

  @read ~D[2026-11-01]
  @models "https://platform.claude.com/docs/en/models"
  @deprecations "https://platform.claude.com/docs/en/about-claude/model-deprecations"

  @efforts [:low, :medium, :high, :xhigh, :max]
  @ttls [:five_minutes, :one_hour]

  # From Claude 5.1 on: sampling, prefill, a forced tool_choice, and
  # budget_tokens are all refused.
  @rejects_5_1 [:temperature, :top_p, :top_k, :prefill, :forced_tool_choice, :budget_tokens]
  # Claude 4.7 and later before 5.1, and Haiku 5.5, which takes a forced
  # tool_choice (the forced call skips thinking).
  @rejects_4_7 [:temperature, :top_p, :top_k, :prefill, :budget_tokens]

  @features [tool_search: true, structured_outputs: true]

  @doc false
  # The sheets in keyword form, newest first within each line.
  @spec sheets() :: [keyword()]
  def sheets do
    ([
       [
         id: "claude-fable-5-1",
         vendor: :anthropic,
         line: :fable,
         display_name: "Claude Fable 5.1",
         released_on: ~D[2026-09-01],
         lifecycle: [status: :active, retires_not_before: ~D[2027-09-01]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: binding_thinking([:adaptive], :high),
         rejects: @rejects_5_1,
         features: [mid_conversation_system: true] ++ @features,
         cache: [min_prefix: 512, ttls: @ttls],
         platforms: platforms("claude-fable-5-1"),
         source: "#{@models}/fable-5-1/overview"
       ],
       [
         id: "claude-mythos-5-1",
         vendor: :anthropic,
         line: :mythos,
         display_name: "Claude Mythos 5.1",
         released_on: ~D[2026-09-01],
         lifecycle: [status: :active, retires_not_before: ~D[2027-09-01]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: binding_thinking([:adaptive], :high),
         rejects: @rejects_5_1,
         features: [mid_conversation_system: true] ++ @features,
         cache: [min_prefix: 512, ttls: @ttls],
         platforms:
           [anthropic: [], bedrock: [id: "anthropic.claude-mythos-5-1", lifecycle: :partner]] ++
             [vertex: [lifecycle: :partner], foundry: []],
         source: "#{@models}/mythos-5-1/overview"
       ],
       [
         id: "claude-opus-5-5",
         vendor: :anthropic,
         line: :opus,
         display_name: "Claude Opus 5.5",
         released_on: ~D[2026-09-22],
         lifecycle: [status: :active, retires_not_before: ~D[2027-09-22]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: binding_thinking([:adaptive], :medium),
         rejects: @rejects_5_1,
         features: [mid_conversation_system: true] ++ @features,
         cache: [min_prefix: 512, ttls: @ttls],
         platforms: platforms("claude-opus-5-5"),
         source: "#{@models}/opus-5-5/overview"
       ],
       [
         id: "claude-sonnet-5-5",
         vendor: :anthropic,
         line: :sonnet,
         display_name: "Claude Sonnet 5.5",
         released_on: ~D[2026-09-28],
         lifecycle: [status: :active, retires_not_before: ~D[2027-09-28]],
         context: 1_000_000,
         max_output: 128_000,
         thinking:
           binding_thinking([:adaptive, :between_tools], :high,
             max_effort: [between_tools: :high]
           ),
         rejects: @rejects_5_1,
         features: [mid_conversation_system: true] ++ @features,
         cache: [min_prefix: 512, ttls: @ttls],
         platforms: platforms("claude-sonnet-5-5"),
         source: "#{@models}/sonnet-5-5/overview"
       ],
       [
         id: "claude-haiku-5-5",
         vendor: :anthropic,
         line: :haiku,
         display_name: "Claude Haiku 5.5",
         released_on: ~D[2026-10-07],
         lifecycle: [status: :active, retires_not_before: ~D[2027-10-07]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: binding_thinking([:adaptive, :off], :medium, max_effort: [off: :high]),
         rejects: @rejects_4_7,
         features: [mid_conversation_system: true] ++ @features,
         cache: [min_prefix: 512, ttls: @ttls],
         platforms: platforms("claude-haiku-5-5"),
         source: "#{@models}/haiku-5-5/overview"
       ],
       [
         id: "claude-opus-5",
         vendor: :anthropic,
         line: :opus,
         display_name: "Claude Opus 5",
         released_on: ~D[2026-07-24],
         lifecycle: [status: :active, retires_not_before: ~D[2027-07-24]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: thinking(:adaptive, [:adaptive, :off], max_effort: [off: :high]),
         rejects: @rejects_4_7,
         features: [mid_conversation_system: true] ++ @features,
         cache: [min_prefix: 512, ttls: @ttls],
         platforms: platforms("claude-opus-5"),
         source: "#{@models}/opus-5/overview"
       ],
       [
         id: "claude-sonnet-5",
         vendor: :anthropic,
         line: :sonnet,
         display_name: "Claude Sonnet 5",
         released_on: ~D[2026-06-30],
         lifecycle: [status: :active, retires_not_before: ~D[2027-06-30]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: thinking(:adaptive, [:adaptive, :off]),
         rejects: @rejects_4_7,
         features: [mid_conversation_system: false] ++ @features,
         cache: [min_prefix: 1024, ttls: @ttls],
         platforms: platforms("claude-sonnet-5"),
         source: "#{@models}/sonnet-5/overview"
       ],
       [
         id: "claude-opus-4-8",
         vendor: :anthropic,
         line: :opus,
         display_name: "Claude Opus 4.8",
         released_on: ~D[2026-05-28],
         lifecycle: [status: :active, retires_not_before: ~D[2027-05-28]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: thinking(:off, [:adaptive, :off]),
         rejects: @rejects_4_7,
         features: [mid_conversation_system: true] ++ @features,
         cache: [min_prefix: 1024, ttls: @ttls],
         platforms: platforms("claude-opus-4-8"),
         source: "#{@models}/opus-4-8/overview"
       ],
       [
         id: "claude-opus-4-6",
         vendor: :anthropic,
         line: :opus,
         display_name: "Claude Opus 4.6",
         released_on: ~D[2026-02-05],
         lifecycle: [status: :active, retires_not_before: ~D[2027-02-05]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: thinking_4_6(),
         rejects: [:prefill],
         features: @features,
         cache: [min_prefix: 4096, ttls: @ttls],
         platforms: [anthropic: [], vertex: [lifecycle: :partner], foundry: [], claude_on_aws: []],
         source: "#{@models}/opus-4-6/overview"
       ],
       [
         id: "claude-sonnet-4-6",
         vendor: :anthropic,
         line: :sonnet,
         display_name: "Claude Sonnet 4.6",
         released_on: ~D[2026-02-17],
         lifecycle: [status: :active, retires_not_before: ~D[2027-02-17]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: thinking_4_6(),
         rejects: [:prefill],
         features: @features,
         cache: [min_prefix: 1024, ttls: @ttls],
         platforms: [anthropic: [], vertex: [lifecycle: :partner], foundry: [], claude_on_aws: []],
         source: "#{@models}/sonnet-4-6/overview"
       ]
     ] ++
       dated(
         [
           id: "claude-opus-4-5",
           vendor: :anthropic,
           line: :opus,
           display_name: "Claude Opus 4.5",
           released_on: ~D[2025-11-24],
           lifecycle: [status: :active, retires_not_before: ~D[2026-11-24]],
           context: 200_000,
           max_output: 64_000,
           thinking: thinking_4_5([:low, :medium, :high], :high),
           features: @features,
           cache: [min_prefix: 4096, ttls: @ttls],
           source: "#{@models}/opus-4-5/overview"
         ],
         "20251101"
       ) ++
       dated(
         [
           id: "claude-sonnet-4-5",
           vendor: :anthropic,
           line: :sonnet,
           display_name: "Claude Sonnet 4.5",
           released_on: ~D[2025-09-29],
           lifecycle: [
             status: :deprecated,
             deprecated_on: ~D[2026-09-30],
             retires_on: ~D[2026-11-30],
             replacement: "claude-sonnet-5-5"
           ],
           context: 200_000,
           max_output: 64_000,
           thinking: thinking_4_5([], nil),
           features: @features,
           cache: [min_prefix: 1024, ttls: @ttls],
           source: "#{@models}/sonnet-4-5/overview"
         ],
         "20250929"
       ) ++
       dated(
         [
           id: "claude-haiku-4-5",
           vendor: :anthropic,
           line: :haiku,
           display_name: "Claude Haiku 4.5",
           released_on: ~D[2025-10-15],
           lifecycle: [status: :active, retires_not_before: ~D[2026-10-15]],
           context: 200_000,
           max_output: 64_000,
           thinking: thinking_4_5([], nil),
           features: @features,
           cache: [min_prefix: 4096, ttls: @ttls],
           source: "#{@models}/haiku-4-5/overview"
         ],
         "20251001",
         bedrock: [id: "anthropic.claude-haiku-4-5", lifecycle: :partner]
       ) ++
       [
         # Retired on the Claude API; Bedrock and Google Cloud still serve
         # them on their own schedules. No page still lists their ceilings.
         [
           id: "claude-opus-4-1-20250805",
           vendor: :anthropic,
           line: :opus,
           display_name: "Claude Opus 4.1",
           lifecycle: [
             status: :retired,
             deprecated_on: ~D[2026-06-05],
             retires_on: ~D[2026-08-05],
             replacement: "claude-opus-4-8"
           ],
           features: [tool_search: false],
           cache: [min_prefix: 1024],
           platforms: [
             anthropic: [],
             bedrock: [id: "anthropic.claude-opus-4-1-20250805-v1:0", lifecycle: :partner]
           ],
           source: @deprecations
         ],
         [
           id: "claude-sonnet-4-20250514",
           vendor: :anthropic,
           line: :sonnet,
           display_name: "Claude Sonnet 4",
           lifecycle: [
             status: :retired,
             deprecated_on: ~D[2026-04-14],
             retires_on: ~D[2026-06-15],
             replacement: "claude-sonnet-5-5"
           ],
           features: [tool_search: false],
           cache: [min_prefix: 1024],
           platforms: [
             anthropic: [],
             bedrock: [id: "anthropic.claude-sonnet-4-20250514-v1:0", lifecycle: :partner]
           ],
           source: @deprecations
         ]
       ])
    |> Enum.map(&Keyword.put(&1, :read, @read))
  end

  # The 4.8 generation on: dateless ids everywhere, `anthropic.<id>` on
  # Bedrock's Messages endpoint.
  defp platforms(id) do
    [
      anthropic: [],
      bedrock: [id: "anthropic." <> id, lifecycle: :partner],
      vertex: [lifecycle: :partner],
      foundry: [],
      claude_on_aws: []
    ]
  end

  defp thinking(default, types, opts \\ []) do
    [
      default: default,
      types: types,
      efforts: @efforts,
      default_effort: :high,
      binding: :none,
      display: :omitted
    ]
    |> Keyword.merge(opts)
  end

  defp binding_thinking(types, default_effort, opts \\ []) do
    thinking(:adaptive, types, [default_effort: default_effort, binding: :prefix] ++ opts)
  end

  defp thinking_4_6 do
    [
      default: :off,
      types: [:adaptive, :enabled, :off],
      efforts: [:low, :medium, :high, :max],
      default_effort: :high,
      binding: :none,
      display: :summarized
    ]
  end

  defp thinking_4_5(efforts, default_effort) do
    [
      default: :off,
      types: [:enabled, :off],
      efforts: efforts,
      default_effort: default_effort,
      binding: :none,
      display: :summarized
    ]
  end

  # A model before the 4.6 generation goes by a dateless alias and a
  # dated snapshot: two ids, one set of facts. Vertex takes
  # `<alias>@<date>`; Foundry and Claude Platform on AWS take the alias.
  defp dated(sheet, date, extra \\ []) do
    alias_id = Keyword.fetch!(sheet, :id)
    snapshot = "#{alias_id}-#{date}"

    platforms =
      [
        vertex: [id: "#{alias_id}@#{date}", lifecycle: :partner],
        foundry: [id: alias_id],
        claude_on_aws: [id: alias_id]
      ] ++ extra

    [
      Keyword.put(sheet, :platforms, [{:anthropic, []} | platforms]),
      sheet
      |> Keyword.put(:id, snapshot)
      |> Keyword.put(:platforms, [{:anthropic, []} | platforms])
    ]
  end
end
