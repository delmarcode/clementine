# Models: The Catalog and How To Add Anything To It

This is the reference for `config :clementine, :models` — what a catalog
entry may say, what each provider atom needs, and the recipe for adding any
model Clementine can reach: first-party Anthropic/OpenAI, open models
(DeepSeek, Qwen, GLM, ...) on OpenRouter/Bedrock/Vertex, and fine-tunes on
Tinker or any self-hosted OpenAI-compatible server.

The implementation lives in `Clementine.LLM.ModelRegistry` (catalog),
`Clementine.LLM.Router` (provider dispatch), `Clementine.LLM.Reasoning`
(reasoning translation), `Clementine.LLM.Cache` (prompt caching), and
the three clients: `Clementine.LLM.Anthropic`,
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
| `cache` | no | all | Prompt caching, on by default. `false` sends no cache hints; `[ttl: ..., markers: ...]` changes the cache write's lifetime or, on `:openrouter`/`:openai_compatible`, whether `cache_control` markers go. Validated at boot for the entry's provider; see "Prompt caching" below. |

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
telemetry carry all four.

| Provider | What Clementine sends | What's reported | Limits |
|---|---|---|---|
| `:anthropic` | `cache_control` on the system prompt (on the last tool loaded up front when there is none), and the top-level `cache_control` the API moves to the last cacheable block. TTL: `:five_minutes` (default) or `:one_hour`. | `cache_read_input_tokens` and `cache_creation_input_tokens`, added to `input_tokens`, which excludes them. | 2 of the 4 breakpoints a request may carry. A prefix under the model's minimum (512 to 4,096 tokens) is not cached and costs nothing extra. Each breakpoint looks back 20 positions for an earlier write. Writes cost 1.25× input (5 minutes) or 2× (1 hour); reads 0.1× or less. |
| `:openai` | `prompt_cache_key`, a hash of the run's agent and subject. On GPT-5.6 and later, `prompt_cache_options.ttl` (`:thirty_minutes` default, or `:twelve_hours`); with `cache: false`, `prompt_cache_options.mode: "explicit"` and no breakpoints, which turns caching off. | `input_tokens_details.cached_tokens` and `cache_write_tokens`, parts of `input_tokens`. | Caching is automatic (from 1,024 tokens on GPT-5.6 and later). Writes cost nothing before GPT-5.6, and 1.25× (30 minutes) or 2.5× (12 hours) from it. Older models keep their own retention; `cache: false` cannot turn their caching off. |
| `:openrouter` | `anthropic/` models: a `cache_control` content part on the system prompt and the top-level `cache_control`, as on Anthropic (`:five_minutes` or `:one_hour`). Every model: `prompt_cache_key`, which OpenRouter uses for sticky provider routing. | `prompt_tokens_details.cached_tokens` and `cache_write_tokens`, parts of `prompt_tokens`. | Other models cache on their own (OpenAI, DeepSeek, Gemini 2.5 and later, Grok, Moonshot); `markers: true` sends the markers to any model. |
| `:bedrock` | Nothing. | `prompt_tokens_details.cached_tokens`, and `cache_write_tokens` where reported (GPT-5.6 and later). | Implicit caching where the model has it, from 1,024 tokens for OpenAI models. GPT-5.6 and later also take explicit `prompt_cache_breakpoint`s, which Clementine does not send: implicit mode already marks the latest message. |
| `:vertex` | Nothing. | `prompt_tokens_details.cached_tokens` where reported. | Implicit caching only, in Preview, for some MaaS open models, from 4,096 tokens; Vertex names no request field. Its docs call the count `cachedContentTokenCount` and do not say how the OpenAI-compatible endpoint reports it. |
| `:openai_compatible` | Nothing, unless `markers: true` (a proxy that fronts Claude), which sends the Anthropic-style markers. | `prompt_tokens_details.cached_tokens` and `cache_write_tokens` where the server reports them (vLLM: `--enable-prompt-tokens-details`). | vLLM and SGLang cache prefixes on their own. |

Every Chat Completions stream asks for usage
(`stream_options.include_usage`), since the dialect sends none
otherwise.

**The lifetime.** A run's steps are seconds apart, and every read
renews an entry, so the shortest TTL keeps a running run's cache warm
and is the cheapest write. A run that parks for an approval, or a
thread whose user answers later, writes its prefix again on the first
step after the cache expired. A longer TTL (`ttl: :one_hour` on
Anthropic, `ttl: :twelve_hours` on GPT-5.6 and later) pays more for
every write to keep that one, and pays off only when such gaps are
common:

```elixir
claude_chat: [provider: :anthropic, id: "claude-sonnet-5", cache: [ttl: :one_hour]],
classifier: [provider: :anthropic, id: "claude-haiku-5-5", cache: false],
proxied_claude: [
  provider: :openai_compatible,
  base_url: "https://llm-proxy.internal/v1",
  id: "claude-sonnet-5",
  cache: [markers: true]
]
```

`cache: false` suits an agent that makes one model call per run and
whose prompt is never sent again, where a write is never read.

**The key.** `prompt_cache_key` is a hash of the run's agent key and
subject (a thread's turns share their conversation's), or of the agent
and the run for a run without a subject, so one lane's requests share a
cache, and two tenants never share one. An in-process run whose
`:context` has no `agent_key` sends none.

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

## Adding a model, start to finish

1. Find the lane. First-party Anthropic/OpenAI → `:anthropic`/`:openai`.
   Listed on OpenRouter → `:openrouter`. Hosted in your AWS/GCP account →
   `:bedrock`/`:vertex`. Anything else with an OpenAI-compatible URL
   (fine-tune platforms, self-hosted) → `:openai_compatible`.
2. Make sure the lane's app config exists (API key; region/project for
   Bedrock/Vertex) — see the recipes above.
3. Add the catalog entry: `provider`, the provider's exact `id`, and
   optionally `defaults`/`reasoning`/`base_url`/`api_key`.
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
5. Normalize the provider's usage into `Clementine.Usage`'s keys
   (`Clementine.LLM.ProviderUsage`): `input_tokens` counts cache reads
   and writes, and `cache_read_tokens` and `cache_write_tokens` are
   parts of it. Send what the provider needs for caching, and say what
   it does in the "Prompt caching" table above.
6. Mirror the Bypass test pattern in `test/clementine/llm/` — request-body
   assertions, streaming, and failure paths.
