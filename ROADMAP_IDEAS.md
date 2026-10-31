# Roadmap Ideas

Ideas Clementine has not built. They are ideas, not commitments: Linear
tracks the work, and an idea becomes an issue there before anyone builds
it. What has shipped (streamed events, the durable runtime, approvals and
the tool policy, delegates, skills, deferred tools, structured output,
the OpenAI and Chat Completions providers, telemetry, token usage on every
result, and the run trace) is in the README and the guides.

## Context compaction

A long thread's history grows until it no longer fits the model. A turn
agent's `history/1` already decides what the model sees, so an app can
summarize or window there today; the idea is a library helper for it:
a token threshold, a strategy (`:summarize`, `:truncate`,
`:sliding_window`), and a smaller model to summarize with.

## Per-tool timeouts

Every tool call gets the same timeout (two minutes, cut to the run's
remaining time). A tool could declare its own:
`use Clementine.Tool, timeout: :timer.minutes(5)`.

## Error recovery policy

Provider calls retry rate limits, overloads, and transient server errors
with backoff (`config :clementine, :retry`). A policy per error type
(which errors, how many attempts, backoff with jitter) would sit beside
it.

## Cost

Every result carries token `usage`; nothing turns it into money. Prices
per model in the catalog would let a result or a trace report an
estimated cost.

## MCP tools

Offer an MCP server's tools to an agent as tools, likely as `deferred:`
ones so the provider's tool search chooses among them.

## Caching

Provider prompt caching (Anthropic's `cache_control` on the system prompt
and the tools), and perhaps cached tool results. Those would need a
declaration and an invalidation rule of their own: `retry: :safe` says a
second call is harmless, not that it returns the same answer.

## Replay

Run a stored run's input and history again, against another model or
other instructions, and compare the traces: a debugging and eval aid.

## Rate limiting

Requests and tokens per minute per provider, shared across a node's runs,
so a burst of runs waits its turn instead of drawing 429s.

## Long-term memory

Facts kept across threads: read into an agent at its claim (`agent/1`)
and written by a tool. Possibly app code over a vector store rather than
library machinery.

## Planning mode

A run that returns a plan (`output_schema:`) for a person or a judge to
approve before a second run carries it out. Possibly a guide pattern
rather than new API.

## Non-Goals

Things we explicitly don't want to add:

- **Orchestration graphs or chains**: keep the model–tool cycle simple.
  What happens above a run is ordinary Elixir, or a `Clementine.Loop`
  when it must outlive a process.
- **A tool or skill graph**: no dependency graph between skills, no
  satisfiability check, and no `search_*` or `inspect_*` meta-tools. A
  skill is a value `agent/1` offers at each claim (`Clementine.Skill`),
  and a body may name another skill in prose. A catalog too large for the
  prompt belongs to the provider's own tool search.
- **Plugin systems**: Just use Elixir modules
- **GUI/Dashboard**: Use existing observability tools
- **Proprietary formats**: Stick to standard Elixir patterns
- **Heavy dependencies**: Keep the dep tree minimal

## Contributing Ideas

Have an idea? Consider:

1. Does it keep the model–tool cycle simple?
2. Can it be implemented without breaking existing APIs?
3. Does it have clear use cases beyond "might be cool"?
4. Can it be optional/configurable rather than default?

File it in Linear before implementing.
