# Models: The Catalog and How To Add Anything To It

This is the reference for `config :clementine, :models` — what a catalog
entry may say, what each provider atom needs, and the recipe for adding any
model Clementine can reach: first-party Anthropic/OpenAI, open models
(DeepSeek, Qwen, GLM, ...) on OpenRouter/Bedrock/Vertex, and fine-tunes on
Tinker or any self-hosted OpenAI-compatible server.

The implementation lives in `Clementine.LLM.ModelRegistry` (catalog),
`Clementine.LLM.Router` (provider dispatch), `Clementine.LLM.Reasoning`
(reasoning translation), and the three clients: `Clementine.LLM.Anthropic`,
`Clementine.LLM.OpenAI`, `Clementine.LLM.ChatCompletions`.

## The catalog in one look

```elixir
config :clementine, :models,
  # First-party Anthropic (Messages API)
  claude_sonnet: [
    provider: :anthropic,
    id: "claude-sonnet-5",
    defaults: [max_tokens: 8192],
    reasoning: [thinking: :adaptive, effort: :high]
  ],

  # First-party OpenAI (Responses API)
  gpt_5: [
    provider: :openai,
    id: "gpt-5",
    defaults: [max_output_tokens: 4096],
    reasoning: [effort: :medium]
  ],

  # OpenRouter (DeepSeek, Qwen, GLM, and hundreds more behind one key)
  deepseek: [
    provider: :openrouter,
    id: "deepseek/deepseek-v3.2",
    reasoning: [effort: :high]
  ],

  # Amazon Bedrock's Chat Completions endpoint (bearer API key, no SigV4)
  qwen_bedrock: [
    provider: :bedrock,
    id: "qwen.qwen3-235b-a22b-2507-v1:0"
  ],

  # Google Vertex AI MaaS (OpenAI-compatible endpoint)
  glm_vertex: [
    provider: :vertex,
    id: "zai/glm-4.7-maas"
  ],

  # Any other OpenAI-compatible server — here, a Tinker fine-tune checkpoint
  qwen_finetune: [
    provider: :openai_compatible,
    base_url: "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1",
    api_key: {:system, "TINKER_API_KEY"},
    id: "tinker://my-run:train:0/sampler_weights/000080"
  ]
```

An agent picks a model by alias (`Clementine.Agent.new(model: :deepseek)`),
and `config :clementine, default_model: :claude_sonnet` names the fallback
for `Clementine.AgentServer` processes that don't specify one. You can also
bypass the catalog with a direct tuple — `model: {:openrouter,
"qwen/qwen3-coder"}` — but tuple references carry no defaults, reasoning,
or endpoint config, so anything beyond the id must come from app config or
per-request opts.

The catalog is validated at application boot (`ModelRegistry.
validate_config!/0`): a typo'd provider, malformed reasoning config, or an
endpoint key on the wrong provider fails startup with an error naming the
alias, not mid-run.

## Entry keys

| Key | Required | Providers | Meaning |
|---|---|---|---|
| `provider` | yes | all | One of `:anthropic`, `:openai`, `:openrouter`, `:bedrock`, `:vertex`, `:openai_compatible`. Picks the client and wire dialect. |
| `id` | yes | all | The provider's model identifier, verbatim — whatever the provider's docs say to put in the request's model field. |
| `defaults` | no | all | Keyword list of per-model defaults. Output cap: `max_tokens:` for Anthropic and chat-completions providers, `max_output_tokens:` for OpenAI (the OpenAI and chat-completions clients each also accept the other's key; Anthropic reads only `max_tokens:`). Per-request opts override; the default cap is 8192. |
| `reasoning` | no | all | Provider-neutral reasoning config; see the table below. Validated at boot for the entry's provider. |
| `base_url` | no | chat-completions providers only | Endpoint override, OpenAI-SDK style: the client appends `/chat/completions`. Required (per-model or app-wide) for `:openai_compatible`. Rejected on `:anthropic`/`:openai` entries. |
| `api_key` | no | chat-completions providers only | Per-model credential override. A literal string, `{:system, "ENV_VAR"}`, or `{module, function, args}` resolved per request (for short-lived tokens). Rejected on `:anthropic`/`:openai` entries. |
| `structured_output` | no | chat-completions providers only | `:native` (default) sends an agent's `output_schema:` as `response_format`; `:instructions` sends none, for a server whose grammar would keep the model from calling tools (see "Structured output" below). `:instructions` is rejected on `:anthropic`/`:openai` entries. |
| `pricing` | no | all | The alias's prices, which every call on it is charged at (see "Pricing" below). Without it a call's cost is `nil`, never zero. |

"Chat-completions providers" means `:openrouter`, `:bedrock`, `:vertex`,
and `:openai_compatible` — the four served by the shared
`Clementine.LLM.ChatCompletions` client.

## Provider recipes

### `:anthropic` — first-party Claude

```elixir
config :clementine, anthropic_api_key: {:system, "ANTHROPIC_API_KEY"}

claude_opus: [
  provider: :anthropic,
  id: "claude-opus-4-8",
  defaults: [max_tokens: 8192],
  reasoning: [thinking: :adaptive, effort: :high]
]
```

- `id` is the Anthropic model id (`claude-sonnet-5`, `claude-opus-4-8`, ...).
- Endpoint override: `config :clementine, anthropic_base_url: ...`.
- An agent's `deferred:` tools go out with `defer_loading: true` beside
  the Messages API's tool search tool (`tool_search_tool_regex_20251119`).
  Models older than Claude Opus 4.5, Sonnet 4.5, and Haiku 4.5 have no
  tool search and get them as ordinary tools, as every other provider
  does.

### `:openai` — first-party OpenAI (Responses API)

```elixir
config :clementine, openai_api_key: {:system, "OPENAI_API_KEY"}

gpt_5_high: [
  provider: :openai,
  id: "gpt-5",
  defaults: [max_output_tokens: 4096],
  reasoning: [effort: :high, summary: :auto]
]
```

- Endpoint override: `config :clementine, openai_base_url: ...`.

### `:openrouter` — DeepSeek, Qwen, GLM, and the long tail

```elixir
config :clementine, openrouter_api_key: {:system, "OPENROUTER_API_KEY"}

glm: [provider: :openrouter, id: "z-ai/glm-4.7", reasoning: :high]
```

- `id` is OpenRouter's `vendor/model` slug, exactly as their model page
  shows it.
- Endpoint override: `config :clementine, openrouter_base_url: ...`
  (default `https://openrouter.ai/api/v1`).

### `:bedrock` — Amazon Bedrock Chat Completions

```elixir
config :clementine,
  bedrock_api_key: {:system, "AWS_BEARER_TOKEN_BEDROCK"},
  bedrock_region: "us-west-2"

qwen: [provider: :bedrock, id: "qwen.qwen3-235b-a22b-2507-v1:0"]
```

- Authenticates with an Amazon Bedrock API key as a bearer token — no
  SigV4 signing, no AWS SDK dependency.
- The endpoint is built from `bedrock_region`
  (`https://bedrock-mantle.{region}.api.aws/v1`, AWS's recommended
  endpoint); set `bedrock_base_url` to use `bedrock-runtime` or a private
  endpoint instead.
- `id` is the Bedrock model id shown in the model catalog
  (`qwen.qwen3-...`, `deepseek.v3-...`, regional `us.` prefixes where
  applicable).
- Only models Bedrock serves over Chat Completions work here (DeepSeek
  V3.x, Qwen3 family, gpt-oss, ...). Models that are Invoke/Converse-only
  on Bedrock (e.g. DeepSeek-R1) aren't reachable this way — use OpenRouter
  for those.

### `:vertex` — Google Vertex AI MaaS

```elixir
config :clementine,
  vertex_project: "my-gcp-project",
  vertex_region: "us-central1",
  vertex_access_token: {MyApp.GcpAuth, :access_token, []}

deepseek_vertex: [provider: :vertex, id: "deepseek-ai/deepseek-v3.2-maas"]
```

- The endpoint is built from project + region
  (`https://{region}-aiplatform.googleapis.com/v1/projects/{project}/locations/{region}/endpoints/openapi`);
  set `vertex_base_url` to override.
- Vertex OAuth access tokens expire hourly, so `vertex_access_token` is
  usually an MFA tuple resolved per request — wire it to goth or your
  token source. A literal or `{:system, ...}` works for scripts.
- `id` is `publisher/model` as Vertex's MaaS docs list it
  (`deepseek-ai/...`, `qwen/...`, `zai/glm-4.7-maas`).

### `:openai_compatible` — Tinker fine-tunes, Together, Fireworks, self-hosted vLLM/SGLang

```elixir
qwen_finetune: [
  provider: :openai_compatible,
  base_url: "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1",
  api_key: {:system, "TINKER_API_KEY"},
  id: "tinker://my-run:train:0/sampler_weights/000080"
],
local: [
  provider: :openai_compatible,
  base_url: "http://localhost:8000/v1",
  id: "my-merged-qwen"  # whatever the server registered
]
```

- This is the catch-all for anything that speaks the OpenAI Chat
  Completions dialect. If a serving platform hands you a base URL, an
  optional key, and a model name, it goes here.
- `base_url` per model (or `config :clementine,
  openai_compatible_base_url: ...` app-wide when there's only one server).
- `api_key` is optional — keyless local servers get no authorization
  header. `openai_compatible_api_key` app config is the fallback when the
  entry doesn't set one.
- Tinker specifics: the base URL above is their OpenAI-compatible
  inference endpoint, and `id` is a `tinker://` sampler checkpoint path.
  It's rated for evals and internal tools, not high-throughput production
  serving — for production, export the weights to a serving provider and
  point another `:openai_compatible` (or provider-specific) entry at it.

## Reasoning config

`reasoning:` is provider-neutral at the catalog level; the provider adapter
owns the wire translation (`Clementine.LLM.Reasoning`). A bare atom or
string is always effort shorthand — `reasoning: :high` is portable across
every provider. Keyword/map forms unlock provider-specific controls:

| Provider | Wire fields | Accepted keys | Values |
|---|---|---|---|
| `:anthropic` | `thinking`, `output_config` | `effort` | `low medium high xhigh max` |
| | | `thinking` | `adaptive enabled disabled` |
| | | `budget_tokens` | positive integer (implies `thinking: :enabled`) |
| | | `display` | `summarized omitted` |
| `:openai` | `reasoning` | `effort` | `none minimal low medium high xhigh` |
| | | `summary`, `generate_summary` | `auto concise detailed` |
| `:openrouter` | `reasoning` | `effort` | `none minimal low medium high xhigh max` |
| | | `max_tokens` | positive integer |
| | | `exclude`, `enabled` | booleans |
| `:bedrock`, `:vertex`, `:openai_compatible` | `reasoning_effort` | `effort` | `none minimal low medium high xhigh` |

Key names, values, and contradictory combinations (enabled thinking
without a budget, a budget with adaptive thinking, display without
thinking) are rejected at boot. Whether a *specific model* accepts a
specific value (`budget_tokens` on adaptive-only Claude models, `effort`
on models that predate it, `reasoning_effort` on a model without a
reasoning mode) is the provider API's call — Clementine keeps no per-model
capability matrix, so expect a 4xx from the provider rather than a boot
error when a model doesn't support what you configured.

Two useful idioms:

```elixir
# Same model, several reasoning levels: aliases are cheap.
gpt_5_low:  [provider: :openai, id: "gpt-5", reasoning: :low],
gpt_5_high: [provider: :openai, id: "gpt-5", reasoning: :high],

# One-off override without touching the catalog (LLM layer only):
Clementine.LLM.call(:gpt_5_low, system, messages, tools, reasoning: :high)
```

## Structured output

An agent's `output_schema:` goes to the provider as its own structured
output, which constrains the model's text answer to the schema (tool
calls are unaffected):

| Provider | Request field |
|---|---|
| `:anthropic` | `output_config.format`: `{"type": "json_schema", "schema": ...}`, beside any reasoning `effort` |
| `:openai` | `text.format`: `{"type": "json_schema", "name": "output", "schema": ..., "strict": true}` |
| Chat Completions (`:openrouter`, `:bedrock`, `:vertex`, `:openai_compatible`) | `response_format`: `{"type": "json_schema", "json_schema": {"name": "output", "schema": ..., "strict": true}}` |

A model or server without structured outputs refuses the request, or,
on some OpenAI-compatible servers, ignores the field; the engine checks
the answer either way (`Clementine.OutputSchema`), so describe the
answer's shape in the instructions too when an agent runs there.

**A grammar can take an agent's tools away.** Anthropic and OpenAI
constrain only the text answer, and the model still calls tools. A
Chat Completions server may instead enforce `response_format` with a
grammar over the whole completion (vLLM, SGLang, Ollama, and llama.cpp
can), and then the model has no way to emit a tool call: the agent
answers at once, without its tools, and nothing fails. For such a
model, set `structured_output: :instructions` on its entry:

```elixir
qwen_local: [
  provider: :openai_compatible,
  id: "qwen3-32b",
  base_url: "http://localhost:8000/v1",
  structured_output: :instructions
]
```

No `response_format` goes out; the agent's instructions must describe
the answer, and the engine checks it as always (one markdown fence
around the JSON is tolerated). Try an agent with tools and an
`output_schema:` against a new server before relying on `:native`.

A refusal and a cut-off answer explain themselves on every provider:
the refusal text is the turn's text with stop reason `"refusal"` (an
OpenAI refusal content part or `response.refusal.delta`, a Chat
Completions `refusal`), and an answer that ran out of output tokens
stops with `"max_tokens"` (OpenAI's `response.incomplete` with
`max_output_tokens`, Chat Completions' `length`). A schema agent's
`:invalid_output` error says which.

## Pricing

Clementine turns usage into money only at prices you configure. It
ships no price table, so it never ships a stale one: copy your rates from
each provider's price page. Give an alias `pricing:` and every call on it
has a cost; leave it out and the cost is `nil`, never zero.

```elixir
# Illustrative numbers, not anyone's current prices.
claude_sonnet: [
  provider: :anthropic,
  id: "claude-sonnet-5",
  pricing: [
    currency: "USD",
    input: 3.00,
    output: 15.00,
    cache_read: 0.30,
    cache_write: [five_minutes: 3.75, one_hour: 6.00]
  ]
],
deepseek: [
  provider: :openrouter,
  id: "deepseek/deepseek-v3.2",
  pricing: [currency: "USD", input: 0.28, output: 0.42, cache_read: 0.028, cache_write: 0.28]
]
```

| Key | Meaning |
|---|---|
| `currency` | An ISO 4217 code, `"USD"`. Every priced alias names the same one, so costs across the catalog add up. |
| `input` | Uncached input. |
| `output` | Output, reasoning included. |
| `cache_read` | Input read from the provider's prompt cache. |
| `cache_write` | Input written to it: one rate, or a rate per cache TTL. |

- **The unit.** Every rate is in `currency` per million tokens, as price
  pages state it, to six decimal places at most; integers and floats both
  work.
- **All four rates, or none.** A missing one fails boot, naming the
  alias: a call charged for only some of its tokens is an undercount
  nobody would see. Write `0` for what the provider does not charge (a
  server you host), and the input rate where it bills a cache write as
  plain input.
- **Cache writes by TTL.** Where a provider charges more to keep a cache
  entry longer, give `cache_write` a rate per TTL, as the price page
  lists them, and the TTL the alias writes with (its `cache:` key, or the
  provider's default) picks one:

  | Provider | TTLs |
  |---|---|
  | `:anthropic` | `:five_minutes` (the default), `:one_hour` |
  | `:openai`, GPT-5.6 and later | `:thirty_minutes` (the default), `:twelve_hours`. OpenAI's caching guide offers twelve hours; its API reference says thirty minutes is currently the only value. |
  | `:openrouter`, `:openai_compatible`, when cache markers go out | `:five_minutes` (the default), `:one_hour` |
  | Every other alias: `:bedrock`, `:vertex`, older OpenAI ids, the rest of OpenRouter, caching off | none: give one rate |

  A per-TTL `cache_write` without the rate for the alias's TTL, or on an
  alias whose writes carry no TTL, fails boot.

**How a call is priced.** `input_tokens` counts every input token, cached
or not, and the cache reads and writes are parts of it
(`Clementine.Usage`). A call costs its uncached input (`input_tokens`
less both cache counts) at `input`, its cache reads at `cache_read`, its
cache writes at `cache_write`, and its output at `output`, summed exactly
and rounded once, half up, to the micro-unit. A cost is a
`%Clementine.Cost{currency: "USD", micros: 1_284}`: integer millionths of
the currency, here $0.001284.

**Where costs show.**

- Each trace `:model_call` entry records the alias it ran on (`"alias"`)
  and its cost (`"cost"`), frozen when the call ended, at the prices the
  alias had then. A price you change applies to calls from then on and
  never reprices history.
- `Clementine.Runs.cost(run_id)` sums a run's own calls;
  `Clementine.Runs.cost(run_id, children: true)` adds every run below it
  (its delegates, a loop's turns and theirs);
  `Clementine.Runs.subject_cost(subject)` totals every run on a subject.
  Each is `nil` when any call in it ran unpriced.
- `[:clementine, :llm, :stop]` carries a priced call's `cost_micros`,
  with `currency` in its metadata, and `Clementine.Telemetry.metrics/0`
  sums it.
- `Clementine.Cost.of(usage, alias)` prices any usage at today's prices:
  an in-process run's `result.usage`, or a trace entry's usage to reprice
  it.

**What four rates do not cover.** A price that depends on more than the
token counts is not modeled, and the cost is the plain rate: Anthropic's
US-only inference (`inference_geo`) and fast mode, a model with higher
prices above a prompt length (Claude Haiku 5.5 over 100,000 tokens),
regional pricing on Bedrock and Vertex (price the alias at its region's
rates), and per-use server tool fees such as web search.

## Adding a model, start to finish

1. Find the lane. First-party Anthropic/OpenAI → `:anthropic`/`:openai`.
   Listed on OpenRouter → `:openrouter`. Hosted in your AWS/GCP account →
   `:bedrock`/`:vertex`. Anything else with an OpenAI-compatible URL
   (fine-tune platforms, self-hosted) → `:openai_compatible`.
2. Make sure the lane's app config exists (API key; region/project for
   Bedrock/Vertex) — see the recipes above.
3. Add the catalog entry: `provider`, the provider's exact `id`, and
   optionally `defaults`/`reasoning`/`base_url`/`api_key`/`pricing`.
4. Boot the app (or run `mix test`) — an invalid entry fails at startup,
   naming the alias.
5. Smoke it: `Clementine.run(Clementine.Agent.new(model: :my_alias), "Hi")`.

## Adding a whole new provider

Only needed for a genuinely new wire dialect — check first whether the
provider is just another OpenAI-compatible endpoint (`:openai_compatible`
already covers it, no code required). Otherwise:

1. Implement `Clementine.LLM.ClientBehaviour` (`call/5`, `stream/5`) in
   `lib/clementine/llm/`, streaming through `Clementine.LLM.ProviderStream`
   with a parser that emits the shared event tuples.
2. Add the provider atom to `ModelRegistry`'s `@providers` (and to
   `@chat_completions_providers` if entries should carry
   `base_url`/`api_key`).
3. Map the atom to the client in `Clementine.LLM.Router`'s defaults.
4. Add a reasoning translation in `Clementine.LLM.Reasoning` (or extend the
   supported-provider guard) so `validate_model_config/2` accepts it.
5. Mirror the Bypass test pattern in `test/clementine/llm/` — request-body
   assertions, streaming, and failure paths.
