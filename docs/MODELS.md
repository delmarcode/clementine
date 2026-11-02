# Models: Fact Sheets, Agents, and Adopting a New One

An agent names its model by the vendor's own id and makes its own
choices for it. Clementine ships a fact sheet for each current Anthropic
and OpenAI model, and reads it to decide what each request sends and
what it withholds, so an app never encodes what a model accepts. An app
overrides a fact it knows better (its prices), or declares a model
Clementine does not ship (an open model on OpenRouter, a fine-tune on a
self-hosted server), under `config :clementine, :models`.

The code: `Clementine.Model` (the sheet), `Clementine.Models` (the read
side, and the merge of an app's config), `Clementine.Models.Anthropic`
and `Clementine.Models.OpenAI` (the sheets), `Clementine.LLM.Policy` (an
agent's choices checked against a sheet), `Clementine.LLM.Reasoning`
(the choices on each wire), `Clementine.LLM.Router`, and the three
clients: `Clementine.LLM.Anthropic`, `Clementine.LLM.OpenAI`,
`Clementine.LLM.ChatCompletions`.

## The agent names its model and its policy

```elixir
defmodule MyApp.Agents.Screener do
  use Clementine.Agent,
    key: "triage",
    model: "claude-sonnet-5-5",
    effort: :high,
    max_tokens: 16_000

  @impl true
  def agent(run) do
    Clementine.Agent.new(
      # An eval's --model for this run, else the declared one.
      model: run.metadata["model"] || __model__(),
      instructions: MyApp.Prompts.triage(run.subject)
    )
  end
end
```

There is no alias, no job registry, and no default model. The agent is
the job: its key labels its runs, its traces, and its metrics, and two
agents that share a choice share a module attribute. `use` defines
`__model__/0`.

`use`'s choices are for `use`'s model. The runtime fills them in when an
`agent/1` leaves the model to `use` or names the same one: each choice
`agent/1` leaves unset, and `provider_options` key by key. When
`agent/1` picks another model for a run (an eval's `--model`), none of
them applies, since an effort or a TTL one model takes another may
refuse; that run takes the model's defaults and whatever `agent/1`
sets. An error says where the refused choice came from: `use`,
`Agent.new/1`, or the model `agent/1` picked for the run.

`Clementine.run/3` and `stream/3` take the module as well as a struct
(`Clementine.run(MyApp.Agents.Triage, prompt, run: run)`), and complete
its agent the same way. Either form is checked whole before anything
runs; an agent with no model raises there rather than at the first
call.

Where each check runs: `use` at compile time, with compile-time config,
so a model only `config/runtime.exs` declares compiles and is checked at
boot; `Agent.new/1` as far as the choices it has allow (a
`thinking: :enabled` whose `budget_tokens` `use` gives passes there);
boot, for every agent's `use`; the start of every run, whole; and each
request.

| Choice | Default | Checked against the sheet |
|---|---|---|
| `model` | required (here or on `use`) | a shipped sheet or a declaration |
| `max_tokens` | `min(16_000, max_output)`: thinking counts toward it, so 8,192 is too low on a thinking model | `max_output` |
| `effort` | the model's `default_effort`, sent explicitly, so a vendor's recalibrated default never moves an agent | `thinking.efforts`, and `thinking.max_effort` for the thinking setting |
| `thinking` | `:adaptive` where the model takes it, else the model's own default | `thinking.types`; a refusal names what to use instead |
| `display` | the model's own (`:omitted` from Claude 4.7 on, `:summarized` before) | `:omitted`, `:summarized`, `:updates` (sends its beta), with adaptive or enabled thinking |
| `cache` | `true`: the model's shortest TTL on its platform | `cache.ttls`, and the model's prices per TTL |
| `provider_options` | `[]` | per vendor: Anthropic's `budget_tokens` (implies `thinking: :enabled`; at least 1,024 and below `max_tokens`) and `prefix_mismatch`; OpenAI's `summary` (`:concise` only after GPT-5; the reference deprecates `generate_summary`, which Clementine no longer takes); OpenRouter's `max_tokens`, `exclude`, `enabled` |

`Clementine.LLM.call/5` and `stream/5` take the same keys as per-call
opts, for scripts and evals.

What the clients do with the facts: send no `thinking` field where the
model's default is what the agent asked for; send `thinking: :off` as
`disabled` on a model that thinks by default, and refuse it at build on
one that always thinks (Opus 5.5, Fable 5.1), naming a lower effort or
`:between_tools`; send `prompt_cache_options` only where the sheet's
TTLs are OpenAI's; send `defer_loading` only where
`features.tool_search`; check thinking bindings only where
`thinking.binding == :prefix`; send a skill's tools in a
mid-conversation system message only where
`features.mid_conversation_system`; send `response_format` on Chat
Completions only where `features.structured_outputs`.

## The sheets

```elixir
Clementine.Models.get!("claude-sonnet-5-5")
#=> %Clementine.Model{
#=>   id: "claude-sonnet-5-5", vendor: :anthropic, line: :sonnet,
#=>   display_name: "Claude Sonnet 5.5", released_on: ~D[2026-09-28],
#=>   lifecycle: %{status: :active, retires_not_before: ~D[2027-09-28], ...},
#=>   context: 1_000_000, max_output: 128_000,
#=>   thinking: %{default: :adaptive, types: [:adaptive, :between_tools],
#=>               efforts: [:low, :medium, :high, :xhigh, :max], default_effort: :high,
#=>               max_effort: %{between_tools: :high}, binding: :prefix, display: :omitted},
#=>   rejects: [:temperature, :top_p, :top_k, :prefill, :forced_tool_choice, :budget_tokens],
#=>   features: %{tool_search: true, structured_outputs: true, mid_conversation_system: true,
#=>               streaming: true},
#=>   cache: %{min_prefix: 512, ttls: [:five_minutes, :one_hour]},
#=>   platforms: [anthropic: %{...}, bedrock: %{id: "anthropic.claude-sonnet-5-5", lifecycle: :partner}, ...],
#=>   source: "https://platform.claude.com/docs/en/models/sonnet-5-5/overview", read: ~D[2026-11-01]
#=> }
```

`Clementine.Model` documents every fact. Each sheet carries the page it
was read from and the date; the vendor modules list the pages behind
the facts. Shipped today, read 2026-11-01:

| Vendor | Active | Deprecated | Retired |
|---|---|---|---|
| Anthropic | `claude-fable-5-1`, `claude-mythos-5-1`, `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-opus-5`, `claude-sonnet-5`, `claude-fable-5`, `claude-mythos-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-opus-4-5` (and `-20251101`), `claude-haiku-4-5` (and `-20251001`) | `claude-mythos-preview` (no date set), `claude-sonnet-4-5` (and `-20250929`), retiring 2026-11-30 | `claude-opus-4-1-20250805`, `claude-opus-4-20250514`, `claude-sonnet-4-20250514`, and every older id the deprecations page lists (Claude 3.x, 2.x, 1.x, Instant), each naming its replacement |
| OpenAI | `gpt-6.1-terra`, `gpt-6.1-sol`, `gpt-6-sol`, `gpt-6-luna`, `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.5-pro` (does not stream, so no agent runs it), `gpt-5.4`, `gpt-5.4-pro`, `gpt-5.4-mini`, `gpt-5.2`, `gpt-5.2-pro` | `gpt-5`, `gpt-5-mini`, `gpt-5-nano`, `gpt-5-pro` (shut down 2026-12-11), `gpt-4.1`, `gpt-4.1-mini` (2027-01-14), `gpt-5.1`, `gpt-5.4-nano` (2027-04-01) | `o4-mini`, `gpt-4.1-nano` (shut down 2026-10-23) |

The read side:

- `Clementine.Models.get/1` and `get!/1`: one model, with the app's
  override merged in.
- `list/1`: every model, filtered by `line:`, `vendor:`, `lifecycle:`
  (a status), or `platform:`.
- `newest/1`: the active model in a line released last
  (`Clementine.Models.newest(:sonnet)`).
- `for_platform/2`: a model's facts on one platform, with that
  platform's id (`Clementine.Model.platform_id/1`) and deltas.

A request goes to the vendor's own platform (`:anthropic`, `:openai`),
or, for a model an app declares, the first platform it lists that
Clementine can send to: `:openrouter`, `:bedrock`, `:vertex`, or
`:openai_compatible`. The `bedrock`, `vertex`, `foundry`, and
`claude_on_aws` entries on Claude sheets are facts for now; an agent
picks a platform when `Clementine.Platform` arrives. Their ids follow
one scheme, the endpoint each platform's Messages client will send to:
`bedrock:` is Bedrock's Messages endpoint (`anthropic.<id>`), so a
model Bedrock serves only through InvokeModel (Opus 4.6, Sonnet 4.6,
the 4.5 snapshots, older) has no entry; `vertex:` is the dateless id
from the 4.6 generation on and `<alias>@<date>` before it; `foundry:`
is the default deployment name, and takes no mid-conversation system
messages; `claude_on_aws:` is the Claude API's id.

## Boot, build, and the clock

`Clementine.Agent.new/1` checks an agent's model and choices against
the sheet, so `use Clementine.Agent` with a typo fails the build. Boot
checks them again for every agent in the child spec's `agents:`, since
config can change after a build, and checks
`config :clementine, :models` when Clementine starts.

| Finding | Outcome |
|---|---|
| a model no sheet and no declaration knows | error, naming the nearest known ids |
| a model on no platform Clementine can send to, or whose platform has no credential configured | error |
| a thinking setting the model refuses (`:off` on Opus 5.5 or Fable 5.1, `:adaptive` on Haiku 4.5, `budget_tokens` on Claude 4.7 and later) | error, naming what it takes instead |
| an effort the model lacks, or above a thinking setting's cap (`:between_tools` above `:high`) | error, naming the levels |
| `max_tokens` over `max_output` | error, naming the ceiling |
| a cache TTL the model does not offer on its platform, or a per-TTL price without the agent's TTL | error, naming the TTLs |
| a price list partial, finer than six decimals, or in a second currency | error |
| a sheet whose status is `:retired` in this Clementine release | error, naming the replacement |
| a deprecated model, or a date that has passed (a retire-not-before date, a shutdown date) | never an error |

**Boot is clock-independent.** Every error comes from the sheets and the
app's config, never from the date. A node that restarts after a
vendor's shutdown date still boots, its non-AI parts included; the
vendor's own error ends the run that reaches the model, and the next
Clementine release marks it retired. Warnings for deprecated models and
passed dates come with `mix clementine.models`.

At request time a provider error the facts did not predict ends the run
as `invalid_request`, as before: a sheet is a best effort, and the API
stays the judge.

## Overrides and declarations

`config :clementine, :models` is a map from model id to facts. A key
Clementine ships is an override, merged over its sheet; any other key
is a model the app declares.

```elixir
config :clementine, :models, %{
  # Override: a negotiated rate. Everything else stays shipped.
  "claude-opus-5-5" => [
    prices: [
      currency: "USD", input: 3.60, output: 18.00, cache_read: 0.18,
      cache_write: [five_minutes: 4.50, one_hour: 7.20],
      source: "contract 2026-10", read: ~D[2026-10-15]
    ]
  ],

  # Declaration: an open model on OpenRouter.
  "deepseek/deepseek-v3.2" => [
    vendor: :deepseek,
    context: 163_840,
    max_output: 16_000,
    thinking: [default: :adaptive, types: [:adaptive], efforts: [:low, :medium, :high]],
    features: [structured_outputs: true],
    platforms: [openrouter: []]
  ],

  # Declaration: a fine-tune on an OpenAI-compatible server.
  "qwen3-triage-ft" => [
    vendor: :qwen,
    context: 128_000,
    max_output: 16_000,
    platforms: [
      openai_compatible: [
        id: "tinker://run:train:0/sampler_weights/000080",
        base_url: "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1",
        api_key: {:system, "TINKER_API_KEY"}
      ]
    ]
  ]
}
```

An override merges key by key into `lifecycle`, `thinking`, `features`,
`cache`, and each entry of `platforms`, and replaces any other fact
(`prices` whole). A declaration needs `vendor`, `context`, `max_output`,
and `platforms`. The rest default to a model that does not think, binds
nothing, takes no system message in place, has no structured outputs
(so no `response_format` goes; the agent's instructions describe its
answer, and the engine checks it), and caches on its own. Say what is
true of it:

- A model that reasons: `thinking: [default: :adaptive, types:
  [:adaptive], efforts: [...]]`, and `default_effort:` if it has one.
- A Claude model Clementine lacks (5.1 or later):
  `thinking: [binding: :prefix]`, and
  `features: [mid_conversation_system: true]` where its platform takes
  them.
- A Claude model behind OpenRouter or a proxy:
  `cache: [ttls: [:five_minutes, :one_hour]]`, so `cache_control`
  markers go.
- An OpenAI GPT-5.6 or later model on OpenRouter or Bedrock:
  `cache: [ttls: [:thirty_minutes]]`. Clementine sends it no TTL, and the
  platform bills writes at thirty minutes; `cache: false` sends
  `prompt_cache_options.mode: "explicit"`, which turns caching off.
- A server whose grammar enforces `response_format` over the whole
  completion (vLLM, SGLang, Ollama, llama.cpp) would leave the model no
  way to call a tool: leave `structured_outputs` off.

A platform entry takes `id:` (default: the model's id), `features:` and
`cache:` deltas, `lifecycle: :partner` (the platform sets its own
retirement dates), and, on the Chat Completions platforms, `base_url:`
and `api_key:` over the platform's app config. Those two are a stopgap
until platforms own their endpoints and credentials (OPS-195): prefer
`{:system, "VAR"}` to a literal key, which `inspect/2` on the model
redacts but which still sits in config.

### A new model the day it ships

A vendor's new model needs no Clementine release. Declare it with
`based_on:` the shipped sheet it succeeds: the declaration starts from
that sheet's facts (thinking, efforts, binding, rejects, features,
cache, platforms), overrides what it names, and goes by the new id.

```elixir
config :clementine, :models, %{
  "claude-sonnet-6" => [
    based_on: "claude-sonnet-5-5",
    display_name: "Claude Sonnet 6",
    released_on: ~D[2027-01-12],
    thinking: [default_effort: :medium]
  ]
}
```

What names the base model stays behind: its `display_name`,
`released_on`, `lifecycle`, `prices`, `source`, and `read`, and the id
each platform gives it, so every platform takes the new id unless the
declaration gives one (`platforms: [bedrock: [id: "anthropic.claude-sonnet-6"]]`).
A bare declaration, without `based_on:`, knows none of a Claude model's
facts: no efforts, no binding, no tool search, no TTLs. When the next
Clementine release ships the model's sheet, delete the declaration.

A declaration may name an effort level Clementine does not
(`thinking: [efforts: [..., :ultra]]`): it goes to the wire as written,
and ranks where the sheet lists it. Thinking types, TTLs, platforms,
and rejected features stay closed, because each needs the client to do
something new; a vendor's new one waits for a Clementine release.

## Platforms and credentials

| Platform | Client | App config |
|---|---|---|
| `:anthropic` | Messages | `anthropic_api_key`; `anthropic_base_url` overrides the endpoint |
| `:openai` | Responses | `openai_api_key`; `openai_base_url` |
| `:openrouter` | Chat Completions | `openrouter_api_key`; `openrouter_base_url` (default `https://openrouter.ai/api/v1`). Ids are OpenRouter's `vendor/model` slugs |
| `:bedrock` | Chat Completions, for the open models Bedrock serves over it | `bedrock_api_key` (a Bedrock API key as a bearer token; no SigV4), `bedrock_region` or `bedrock_base_url` |
| `:vertex` | Chat Completions, for Vertex MaaS open models | `vertex_access_token` (usually `{MyApp.GcpAuth, :access_token, []}`: tokens expire hourly), `vertex_project` and `vertex_region`, or `vertex_base_url` |
| `:openai_compatible` | Chat Completions, any other server | `openai_compatible_base_url` and an optional `openai_compatible_api_key`, or `base_url:`/`api_key:` on the model's platform entry |

A credential is a literal string, `{:system, "ENV_VAR"}`, or
`{module, function, args}` resolved per request. Boot checks that the
platform an agent's model goes to has one configured (not resolved:
`{:system, ...}` passes before the variable is set), except under a
test's mock client.

## Adopting a new model

1. Clementine releases the sheet, or the app declares the model the
   same day under `config :clementine, :models`, keyed by id, with the
   facts it needs.
2. Compare it with the agent's model: `Clementine.Models.newest(line)`
   and the two sheets (`mix clementine.models` will show this per
   agent).
3. Change `model:` on one agent. The build and boot say if its
   `thinking`, `effort`, `max_tokens`, or TTL no longer fit, and name
   the fix.
4. Run its evals with the new id first, where it has them (an
   `agent/1` that reads `run.metadata["model"]`).
5. A turn agent moving onto a model that binds its thinking needs
   nothing more: the binding check drops stale thinking rather than
   failing, and the Anthropic fake refuses an invalidating edit in the
   app's tests (the runtime guide's
   [Models that bind their thinking](../guides/runtime.md#models-that-bind-their-thinking)).
6. A tenant-facing app adds the id to its offer, and moves its rows when
   it chooses: ids are pinned snapshots that never rename.

## Structured output

An agent's `output_schema:` goes to the provider as its own structured
output, which constrains the model's text answer to the schema (tool
calls are unaffected):

| Client | Request field |
|---|---|
| Anthropic | `output_config.format`: `{"type": "json_schema", "schema": ...}`, beside the `effort` |
| OpenAI | `text.format`: `{"type": "json_schema", "name": "output", "schema": ..., "strict": true}` |
| Chat Completions | `response_format`: `{"type": "json_schema", "json_schema": {"name": "output", "schema": ..., "strict": true}}`, only where the sheet says `features.structured_outputs` |

The engine checks the answer either way (`Clementine.OutputSchema`), so
a declared model without structured outputs still answers in shape when
its instructions describe the answer. A refusal is the turn's text with
stop reason `"refusal"`, and an answer that ran out of output tokens
stops with `"max_tokens"`; a schema agent's `:invalid_output` error
says which.

## Prompt caching

Every step of the model–tool cycle sends the tools, the system prompt,
and the conversation so far, and each step's prompt starts with the
last one's. Caching is on by default: each client sends what its
provider needs for the provider to reuse that prefix, and reports what
the provider says it read from and wrote to its cache in
`Clementine.Usage`. `input_tokens` is every input token the request
processed, and `cache_read_tokens` and `cache_write_tokens` are parts of
it, whatever the provider's own convention; the trace's `:model_call`
entries, results, checkpoints, and `[:clementine, :llm, :stop]`
telemetry carry all four. A provider that reports a total smaller than
its own cache parts has the total raised to their sum, and
`[:clementine, :llm, :usage_clamped]` fires, so a provider that changed
its convention shows up instead of undercounting quietly.

| Provider | What Clementine sends | What's reported | Limits |
|---|---|---|---|
| `:anthropic` | `cache_control` on the system prompt (on the last tool loaded up front when there is none), and the top-level `cache_control` the API moves to the last cacheable block. TTL: `:five_minutes` (default) or `:one_hour`, as the sheet offers. | `cache_read_input_tokens` and `cache_creation_input_tokens`, added to `input_tokens`, which excludes them. | 2 of the 4 breakpoints a request may carry. A prefix under the model's minimum (512 to 4,096 tokens) is not cached and costs nothing extra. Each breakpoint looks back 20 positions for an earlier write. Writes cost 1.25× input (5 minutes) or 2× (1 hour); reads 0.1× or less. |
| `:openai` | `prompt_cache_key` (see "The key" below). On a sheet offering `:thirty_minutes` (GPT-5.6 and later), `prompt_cache_options.ttl` (`:thirty_minutes` default, or `:twelve_hours`); with `cache: false`, `prompt_cache_options.mode: "explicit"` and no breakpoints, which turns caching off. | `input_tokens_details.cached_tokens` and `cache_write_tokens`, parts of `input_tokens`. | Caching is automatic (from 1,024 tokens on GPT-5.6 and later). Writes cost nothing before GPT-5.6, and 1.25× (30 minutes) or 2.5× (12 hours) from it. Older models keep their own retention; `cache: false` cannot turn their caching off. |
| `:openrouter` | A model declared with `cache: [ttls: [:five_minutes, :one_hour]]` (Claude): a `cache_control` content part on the system prompt and the top-level `cache_control`, as on Anthropic. Every model: `prompt_cache_key`, which OpenRouter uses for sticky provider routing. A model declared with `cache: [ttls: [:thirty_minutes]]` (OpenAI GPT-5.6 and later) and `cache: false`: `prompt_cache_options.mode: "explicit"`, which turns its caching off. | `prompt_tokens_details.cached_tokens` and `cache_write_tokens`, parts of `prompt_tokens`. | Other models cache on their own (OpenAI, DeepSeek, Gemini 2.5 and later, Grok, Moonshot); a declaration's marker TTLs send the markers to any model. GPT-5.6 and later bill writes at 1.25× for 30 minutes. |
| `:bedrock` | Nothing, except `prompt_cache_options.mode: "explicit"` for a model declared with `cache: [ttls: [:thirty_minutes]]` (OpenAI GPT-5.6 and later) and `cache: false`, which turns its caching and its write charge off. | `prompt_tokens_details.cached_tokens`, and `cache_write_tokens` where reported (GPT-5.6 and later). | Implicit caching where the model has it, from 1,024 tokens for OpenAI models; GPT-5.6 and later bill writes at 1.25× for 30 minutes. They also take explicit `prompt_cache_breakpoint`s, which Clementine does not send: implicit mode already marks the latest message. |
| `:vertex` | Nothing. | `prompt_tokens_details.cached_tokens` where reported. | Implicit caching only, in Preview, for some MaaS open models, from 4,096 tokens; Vertex names no request field. Its docs call the count `cachedContentTokenCount` and do not say how the OpenAI-compatible endpoint reports it. |
| `:openai_compatible` | Nothing, unless the model is declared with marker TTLs (a proxy that fronts Claude), which sends the Anthropic-style markers. | `prompt_tokens_details.cached_tokens` and `cache_write_tokens` where the server reports them (vLLM: `--enable-prompt-tokens-details`); a LiteLLM proxy's top-level `cache_creation_input_tokens` and `cache_read_input_tokens`. | vLLM and SGLang cache prefixes on their own. |

Every Chat Completions stream asks for usage
(`stream_options.include_usage`), since the dialect sends none
otherwise, whatever the agent's `cache:`. Every target takes or ignores
it: Bedrock needs it for usage, OpenRouter treats it as a no-op, Vertex
ignores parameters it does not know, and vLLM, Ollama, and LiteLLM
support it.

**The lifetime.** A run's steps are seconds apart, and every read
renews an entry, so the shortest TTL keeps a running run's cache warm
and is the cheapest write. A run that parks for an approval, or a
thread whose user answers later, writes its prefix again on the first
step after the cache expired. A longer TTL (`ttl: :one_hour` on
Anthropic, `ttl: :twelve_hours` on GPT-5.6 and later) pays more for
every write to keep that one, and pays off only when such gaps are
common:

```elixir
use Clementine.Agent, key: "chat", turn: true, model: "claude-sonnet-5-5", cache: [ttl: :one_hour]
use Clementine.Agent, key: "classify", model: "claude-haiku-5-5", cache: false
```

`cache: false` suits an agent that makes one model call per run and
whose prompt is never sent again, where a write is never read.

An agent has one TTL, so a cost reckoned from it prices every write at
that lifetime. On a one-hour Anthropic agent, the writes the API makes
itself after a server tool's result (a tool search) are five-minute
writes priced as one-hour ones: a small overcharge.

**The key.** `prompt_cache_key` is a hash of the run's agent key and
its actor, one key per user as OpenAI's guide recommends; a run without
an actor hashes its subject instead, and one with neither its run. A
user's runs and threads with an agent share a cache, so a new
conversation reads the agent's instructions and tools that the user's
last one wrote, and two users never share one, which keeps one user
from probing for another's cached prompts. That isolation costs the
sharing across users: each user's first request writes the agent's
prefix. On models before GPT-5.6 the key routes requests to the same
cache; from GPT-5.6, OpenAI routes on its own and the key scopes cache
accounting. Only `:openai` and `:openrouter` get one. The key is an
unsalted hash, so no raw host id reaches the provider. An in-process run
whose `:context` has no `agent_key` sends none. Anthropic's cache has no
key: an entry serves every request in the workspace with the same
prefix.

**What breaks the prefix**, so the next step writes it again instead of
reading it:

- A tool added mid-run. A skill's `use_skill` adds the skill's tools to
  the tools block, which comes first in the prefix, so the call after a
  load writes everything again, once.
- Not deferred tools. Anthropic keeps tools with `defer_loading` out of
  the prefix and expands the ones a search loads inline in the
  conversation, so tool search leaves the cache alone. A deferred tool
  never carries a breakpoint, which the API refuses.
- A different `output_schema:` or reasoning setting. Both are fixed for
  a run; a thread whose agent changes them between turns writes again.
- Thinking, on older models. Claude Opus 4.5, Sonnet 4.6, Haiku 5.5, and
  later keep earlier turns' thinking blocks; on older models a new user
  message after tool use drops them, and the conversation after them is
  written again. Thinking blocks never carry a breakpoint: the
  automatic one finds the nearest block that can.
- Instructions that change per run (a date, a user's name). They come
  before the conversation, so put what varies in the input instead.

Sources, read 2026-10-30: Anthropic's
[prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching),
[tool use with prompt caching](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-use-with-prompt-caching),
and [tool search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool);
OpenAI's [prompt caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
and [Responses API reference](https://developers.openai.com/api/reference/resources/responses/methods/create);
OpenRouter's [prompt caching](https://openrouter.ai/docs/guides/best-practices/prompt-caching);
Amazon Bedrock's [prompt caching](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html);
and Vertex AI's [open models](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/maas/use-open-models).

## Prices

Clementine turns usage into money only at prices a model's sheet
carries. Its shipped sheets carry none yet: an app gives a model its
prices as an override, copied from the provider's price page with where
and when it read them. A model with `prices:` has a cost on every call;
one without has `nil`, never zero.

```elixir
# Illustrative numbers, not anyone's current prices.
config :clementine, :models, %{
  "claude-sonnet-5" => [
    prices: [
      currency: "USD",
      input: 3.00,
      output: 15.00,
      cache_read: 0.30,
      cache_write: [five_minutes: 3.75, one_hour: 6.00],
      source: "https://platform.claude.com/docs/en/about-claude/pricing",
      read: ~D[2026-11-01]
    ]
  ]
}
```

| Key | Meaning |
|---|---|
| `currency` | An ISO 4217 code, `"USD"`. Every priced model names the same one, so costs add up. |
| `input` | Uncached input. |
| `output` | Output, reasoning included. |
| `cache_read` | Input read from the provider's prompt cache. |
| `cache_write` | Input written to it: one rate, or a rate per cache TTL. |
| `source`, `read` | Where the numbers came from, and when (optional). |

- **The unit.** Every rate is in `currency` per million tokens, as price
  pages state it, to six decimal places at most; integers and floats both
  work.
- **All four rates, or none.** A missing one fails boot, naming the
  model: a call charged for only some of its tokens is an undercount
  nobody would see. Write `0` for what the provider does not charge (a
  server you host), and the input rate where it bills a cache write as
  plain input.
- **Cache writes by TTL.** Where a provider charges more to keep a cache
  entry longer, give `cache_write` a rate per TTL, as the price page
  lists them, and the TTL the agent writes with (its `cache:` choice, see
  "Prompt caching" above, or the model's shortest) picks one:

  The TTLs are the model's sheet's on its platform (`cache.ttls`):
  `:five_minutes` and `:one_hour` on Claude, `:thirty_minutes` and
  `:twelve_hours` on OpenAI's GPT-5.6 and later; a model that offers
  none takes one rate.

  A per-TTL `cache_write` without the rate for an agent's TTL, or naming
  a TTL the model does not offer, fails the build and boot. Prices are
  the model's and caching the agent's, so an agent with `cache: false`
  runs on a model priced per TTL, and writes its provider reports anyway
  are priced at the shortest TTL the prices name.

**How a call is priced.** `input_tokens` counts every input token, cached
or not, and the cache reads and writes are parts of it
(`Clementine.Usage`). A call costs its uncached input (`input_tokens`
less both cache counts) at `input`, its cache reads at `cache_read`, its
cache writes at `cache_write`, and its output at `output`, summed exactly
and rounded once, half up, to the micro-unit. A cost is a
`%Clementine.Cost{currency: "USD", micros: 1_284}`: integer millionths of
the currency, here $0.001284.

**Where costs show.**

- Each trace `:model_call` entry records the provider, model id, and
  alias it ran on (`"provider"`, `"model"`, and `"alias"`, now always `nil`)
  and its cost (`"cost"`), frozen when the call ended, at the prices the model had
  then. A price you change applies to calls from then on and never
  reprices history. On the runtime these are columns of
  `agent_run_trace` of their own (`cost_micros`, `currency`, and the
  token counts beside them), so a warehouse keeps them without the
  conversation (`Clementine.Migration`, "What a warehouse may keep").
- `Clementine.Runs.cost(run_id)` sums a run's own calls;
  `Clementine.Runs.cost(run_id, children: true)` adds every run below it
  (its delegates, a loop's turns and theirs);
  `Clementine.Runs.subject_cost(subject)` totals every run on a subject.
  Each is `nil` when any call in it ran unpriced, and when a run's
  `usage` holds a call its trace does not: the heartbeat counts a call
  as it ends, and the trace writes it at the next iteration boundary, so
  a run whose node died in between, or a live run until its boundary,
  has no cost to state rather than a short one.
- The cost lives in the trace and goes with it: after
  `Clementine.Runs.purge/1`, a run's and its subject's cost is `nil`. To
  keep spend past a purge, copy `Clementine.Runs.cost(run.id)` into your
  own table from `run_finished/2`, which sees the run's whole trace.
- `[:clementine, :llm, :usage]` carries every metered call's
  `cost_micros` when it is priced, with `currency` in its metadata,
  however the call ended (`outcome`: `stop`, `aborted`, or `error`);
  `:stop`, and `:exception` for a call a provider error ended, carry it
  too. `Clementine.Telemetry.metrics/0` sums it by agent, provider,
  model, alias (empty), outcome, and currency as
  `clementine_llm_cost_micros_total`.
- `Clementine.Cost.of(usage, model_id)` prices any usage at today's prices,
  at the model's shortest cache TTL:
  an in-process run's `result.usage`, or a trace entry's usage to reprice
  it.

**What four rates do not cover.** A price that depends on more than the
token counts is not modeled, and the cost is the plain rate: Anthropic's
US-only inference (`inference_geo`) and fast mode, a model with higher
prices above a prompt length (Claude Haiku 5.5 over 100,000 tokens),
regional pricing on Bedrock and Vertex (price the model at its region's
rates), per-use server tool fees such as web search, and OpenRouter's
routing: it serves one model id from whichever of its upstream providers
it picks, at that provider's price, and reports what it charged in the
response's `usage.cost`, which Clementine does not read. Price an
OpenRouter model at the rate you expect to pay.

## Adding a whole new provider

Only needed for a genuinely new wire dialect: check first whether the
provider is another OpenAI-compatible endpoint, which a declaration on
`:openai_compatible` already covers, with no code. Otherwise:

1. Implement `Clementine.LLM.ClientBehaviour` (`call/5`, `stream/5`) in
   `lib/clementine/llm/`, streaming through `Clementine.LLM.ProviderStream`
   with a parser that emits the shared event tuples, and resolving each
   request's choices with `Clementine.LLM.Policy.resolve!/2`.
2. Add the platform to `Clementine.Model`'s platforms and served list,
   and map it to the client in `Clementine.LLM.Router`.
3. Translate the policy to its wire in `Clementine.LLM.Reasoning`, and
   give its own options a schema in `Clementine.LLM.Policy`.
4. Normalize the provider's usage into `Clementine.Usage`'s keys
   (`Clementine.LLM.ProviderUsage`): `input_tokens` counts cache reads
   and writes, and `cache_read_tokens` and `cache_write_tokens` are
   parts of it. Send what the provider needs for caching, and say what
   it does in the "Prompt caching" table above.
5. Mirror the Bypass test pattern in `test/clementine/llm/`: request-body
   assertions, streaming, and failure paths.

A new Anthropic or OpenAI model is a sheet in
`Clementine.Models.Anthropic` or `Clementine.Models.OpenAI`, every fact
read from the vendor's page, with the page and the date. Never infer a
fact from an id: a fact in a regex has no source and no date.
