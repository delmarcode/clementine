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

  - [Claude in Amazon Bedrock](https://platform.claude.com/docs/en/build-with-claude/claude-in-amazon-bedrock)
    and its [legacy page](https://platform.claude.com/docs/en/build-with-claude/claude-on-amazon-bedrock-legacy),
    [Google managed](https://platform.claude.com/docs/en/build-with-claude/claude-models-on-google-cloud/google-managed),
    [Microsoft Foundry](https://platform.claude.com/docs/en/build-with-claude/claude-in-microsoft-foundry),
    and [Claude Platform on AWS](https://platform.claude.com/docs/en/build-with-claude/claude-platform-on-aws):
    which platforms serve each model, under which id.

  `line` is the model's family as its name and Anthropic's Models API
  give it. Bedrock and Google Cloud set their own retirement dates
  (`lifecycle: :partner` on those platforms); Foundry and Claude
  Platform on AWS follow Anthropic's.

  The platform ids follow one scheme, the endpoint each platform's
  Messages client sends to:

  - `bedrock:` is Bedrock's Messages endpoint (`bedrock-mantle`), whose
    ids are `anthropic.<id>`. A model Bedrock serves only through
    InvokeModel (Opus 4.6, Sonnet 4.6, the 4.5 snapshots, and older,
    with `-v1:0` ids behind an inference profile) has no `bedrock:`
    entry, since Clementine's Bedrock client will send to the Messages
    endpoint (OPS-195).
  - `vertex:` takes the dateless id from the 4.6 generation on and
    `<alias>@<date>` before it.
  - `foundry:` takes the id as its default deployment name, and has no
    mid-conversation system messages (the page lists the Claude API,
    Bedrock, Google managed, and Claude Platform on AWS).
  - `claude_on_aws:` takes the Claude API's id.

  A retired id keeps a stub sheet (`lifecycle: [status: :retired]`) so
  naming it fails with the replacement Anthropic names.
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

  # Foundry has no mid-conversation system messages, on any model.
  @foundry [features: [mid_conversation_system: false]]

  # Anthropic's retired ids, with the dates and replacement the
  # deprecations page gives.
  @retired [
    {"claude-opus-4-1-20250805", "Claude Opus 4.1", :opus, ~D[2026-06-05], ~D[2026-08-05],
     "claude-opus-4-8"},
    {"claude-opus-4-20250514", "Claude Opus 4", :opus, ~D[2026-04-14], ~D[2026-06-15],
     "claude-opus-4-8"},
    {"claude-sonnet-4-20250514", "Claude Sonnet 4", :sonnet, ~D[2026-04-14], ~D[2026-06-15],
     "claude-sonnet-5-5"},
    {"claude-3-7-sonnet-20250219", "Claude Sonnet 3.7", :sonnet, ~D[2025-10-28], ~D[2026-02-19],
     "claude-sonnet-5-5"},
    {"claude-3-5-haiku-20241022", "Claude Haiku 3.5", :haiku, ~D[2025-12-19], ~D[2026-02-19],
     "claude-haiku-4-5-20251001"},
    {"claude-3-haiku-20240307", "Claude Haiku 3", :haiku, ~D[2026-02-19], ~D[2026-04-20],
     "claude-haiku-4-5-20251001"},
    {"claude-3-5-sonnet-20241022", "Claude Sonnet 3.5", :sonnet, ~D[2025-08-13], ~D[2025-10-28],
     "claude-sonnet-5-5"},
    {"claude-3-5-sonnet-20240620", "Claude Sonnet 3.5", :sonnet, ~D[2025-08-13], ~D[2025-10-28],
     "claude-sonnet-5-5"},
    {"claude-3-opus-20240229", "Claude Opus 3", :opus, ~D[2025-06-30], ~D[2026-01-05],
     "claude-opus-4-8"},
    {"claude-3-sonnet-20240229", "Claude Sonnet 3", :sonnet, ~D[2025-01-21], ~D[2025-07-21],
     "claude-sonnet-5-5"},
    {"claude-2.1", "Claude 2.1", nil, ~D[2025-01-21], ~D[2025-07-21], "claude-opus-4-8"},
    {"claude-2.0", "Claude 2.0", nil, ~D[2025-01-21], ~D[2025-07-21], "claude-opus-4-8"}
  ]
  @retired_1 ["claude-1.0", "claude-1.1", "claude-1.2", "claude-1.3"] ++
               ["claude-instant-1.0", "claude-instant-1.1", "claude-instant-1.2"]

  @doc false
  # The sheets in keyword form, newest first within each line.
  @spec sheets() :: [keyword()]
  def sheets do
    # Not on Claude Platform on AWS.
    # The same model as Fable 5, for verified customers.
    # Not on Claude Platform on AWS.
    # An invitation-only research preview with no model page; the
    # deprecations page sets no retirement date and names no
    # replacement. Its system-message support is in the page's table
    # but not its prose, so skill loads fold here.
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
         platforms: Keyword.delete(platforms("claude-mythos-5-1"), :claude_on_aws),
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
         id: "claude-fable-5",
         vendor: :anthropic,
         line: :fable,
         display_name: "Claude Fable 5",
         released_on: ~D[2026-06-09],
         lifecycle: [status: :active, retires_not_before: ~D[2027-06-09]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: thinking(:adaptive, [:adaptive]),
         rejects: @rejects_4_7,
         features: [mid_conversation_system: true] ++ @features,
         cache: [min_prefix: 512, ttls: @ttls],
         platforms: platforms("claude-fable-5"),
         source: "#{@models}/fable-5/overview"
       ],
       [
         id: "claude-mythos-5",
         vendor: :anthropic,
         line: :mythos,
         display_name: "Claude Mythos 5",
         released_on: ~D[2026-06-09],
         lifecycle: [status: :active, retires_not_before: ~D[2027-06-09]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: thinking(:adaptive, [:adaptive]),
         rejects: @rejects_4_7,
         features: [mid_conversation_system: true] ++ @features,
         cache: [min_prefix: 512, ttls: @ttls],
         platforms: Keyword.delete(platforms("claude-mythos-5"), :claude_on_aws),
         source: "#{@models}/mythos-5/overview"
       ],
       [
         id: "claude-mythos-preview",
         vendor: :anthropic,
         line: :mythos,
         display_name: "Claude Mythos Preview",
         released_on: ~D[2026-04-07],
         lifecycle: [status: :deprecated, deprecated_on: ~D[2026-06-09]],
         context: 1_000_000,
         max_output: 128_000,
         thinking:
           thinking(:adaptive, [:adaptive, :enabled], efforts: [:low, :medium, :high, :max]),
         rejects: [:temperature, :top_p, :top_k, :prefill],
         features: [mid_conversation_system: false] ++ @features,
         cache: [min_prefix: 2048, ttls: @ttls],
         platforms: [
           anthropic: [],
           bedrock: [id: "anthropic.claude-mythos-preview", lifecycle: :partner]
         ],
         source: @deprecations
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
         id: "claude-opus-4-7",
         vendor: :anthropic,
         line: :opus,
         display_name: "Claude Opus 4.7",
         released_on: ~D[2026-04-16],
         lifecycle: [status: :active, retires_not_before: ~D[2027-04-16]],
         context: 1_000_000,
         max_output: 128_000,
         thinking: thinking(:off, [:adaptive, :off]),
         rejects: @rejects_4_7,
         features: [mid_conversation_system: false] ++ @features,
         cache: [min_prefix: 2048, ttls: @ttls],
         platforms: platforms("claude-opus-4-7"),
         source: "#{@models}/opus-4-7/overview"
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
         platforms: [
           anthropic: [],
           vertex: [lifecycle: :partner],
           foundry: @foundry,
           claude_on_aws: []
         ],
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
         platforms: [
           anthropic: [],
           vertex: [lifecycle: :partner],
           foundry: @foundry,
           claude_on_aws: []
         ],
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
         # Bedrock's Messages endpoint serves the alias only; the
         # snapshot is InvokeModel's.
         alias: [bedrock: [id: "anthropic.claude-haiku-4-5", lifecycle: :partner]]
       ) ++
       Enum.map(@retired, &retired/1) ++
       Enum.map(
         @retired_1,
         &retired({&1, nil, nil, ~D[2024-09-04], ~D[2024-11-06], "claude-haiku-4-5-20251001"})
       ))
    |> Enum.map(&Keyword.put(&1, :read, @read))
  end

  # Opus 4.7 on: dateless ids everywhere, `anthropic.<id>` on Bedrock's
  # Messages endpoint.
  defp platforms(id) do
    [
      anthropic: [],
      bedrock: [id: "anthropic." <> id, lifecycle: :partner],
      vertex: [lifecycle: :partner],
      foundry: @foundry,
      claude_on_aws: []
    ]
  end

  # A stub for an id Anthropic retired: naming it fails with the
  # replacement. Bedrock and Google Cloud may still serve some, on their
  # own schedules, through endpoints Clementine does not send to.
  defp retired({id, display_name, line, deprecated_on, retired_on, replacement}) do
    [
      id: id,
      vendor: :anthropic,
      line: line,
      display_name: display_name,
      lifecycle: [
        status: :retired,
        deprecated_on: deprecated_on,
        retires_on: retired_on,
        replacement: replacement
      ],
      platforms: [anthropic: []],
      source: @deprecations
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
  # `alias:` names platforms that serve the alias only.
  defp dated(sheet, date, opts \\ []) do
    alias_id = Keyword.fetch!(sheet, :id)
    snapshot = "#{alias_id}-#{date}"

    platforms = [
      anthropic: [],
      vertex: [id: "#{alias_id}@#{date}", lifecycle: :partner],
      foundry: [id: alias_id] ++ @foundry,
      claude_on_aws: [id: alias_id]
    ]

    [
      Keyword.put(sheet, :platforms, platforms ++ Keyword.get(opts, :alias, [])),
      sheet
      |> Keyword.put(:id, snapshot)
      |> Keyword.put(:platforms, platforms)
    ]
  end
end
