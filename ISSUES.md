# Issues

Prioritized list of correctness, reliability, and maintainability issues observed in the codebase. Each item includes context, impact, and pointers for where to work.

## P0 - Critical / Security

### 1) Unbounded atom creation from tool inputs (DoS risk)
- **Problem:** `Clementine.ToolRunner.atomize_keys/1` falls back to `String.to_atom/1` for unknown keys, which can create unlimited atoms from LLM/tool input and crash the VM. This bypasses schema expectations and is a classic DoS vector.
- **Impact:** Remote crash or memory exhaustion via crafted tool inputs.
- **Where:** `lib/clementine/tool_runner.ex:142-160`
- **Notes / Direction:** Stop creating atoms from untrusted input. Prefer validating/casting keys via schema and keep unknown keys as strings. `nimble_options` is available and could be used to validate and type‑cast input without atomizing dynamic keys.

## P1 - High

### 2) Async tasks can crash agents (linked Task)
- **Problem:** `run_async/2` uses `Task.async/1`, which links the task to the GenServer. If `Loop.run/2` raises (e.g., missing API key or unknown model), the agent process crashes.
- **Impact:** One failed async run can take down the agent process.
- **Where:** `lib/clementine/agent.ex:170-176`
- **Notes / Direction:** Use `Task.Supervisor.async_nolink` with a supervisor (similar to tool execution). Handle `:DOWN` to mark task failure without crashing the agent.

### 3) Async API is incomplete (documented await missing + results discarded)
- **Problem:** Docs mention `await/3` but there is no implementation. Completed async results are not stored or retrievable; `status/2` only returns running/completed.
- **Impact:** Users can’t get results from `run_async/2` reliably; docs are misleading.
- **Where:** `lib/clementine.ex:108-118`, `lib/clementine/agent.ex:216-230`
- **Notes / Direction:** Implement `await/3` (with timeout), store results by task_id (success/error), and clear after retrieval or TTL.

### 4) Streaming errors are swallowed and loop continues with empty result
- **Problem:** Streaming errors are emitted to callback but `call_llm_streaming/2` still returns `{:ok, result}` even after `{:error, reason}` events.
- **Impact:** Loop can report success with incomplete/empty output; errors are silently ignored.
- **Where:** `lib/clementine/loop.ex:310-329`
- **Notes / Direction:** If stream emits an error (after internal retries), abort the iteration and return `{:error, reason}`. See item 7 for retry strategy.

## P2 - Medium

### 5) `fork/3` does not copy history despite contract
- **Problem:** `fork/3` reads history but never applies it to the new agent. The doc claims full history is preserved.
- **Impact:** Forked agents lose conversation context (including tool results).
- **Where:** `lib/clementine/agent.ex:310-327`
- **Notes / Direction:** Pass history into the new agent or provide a setter. Per current discussion, preserve full history (user/assistant/tool results).

### 6) Tool result semantics inconsistent for non‑zero exits
- **Problem:** `bash` tool currently returns `{:ok, ...}` even when exit code != 0 but does not set an explicit error flag; elsewhere, tool errors are `{:error, ...}`. This is ambiguous and complicates retry logic.
- **Impact:** Model may misinterpret failures; verifier logic cannot distinguish invocation failure vs command failure.
- **Where:** `lib/clementine/tools/bash.ex:55-61`, `lib/clementine/tool_runner.ex:112-121`
- **Notes / Direction:** Adopt a consistent contract: `{:error, ...}` only for invocation failure (timeout/crash/invalid args). For non‑zero exit, return `{:ok, ...}` plus `is_error: true` in tool_result content so the model sees failure without breaking the loop.

### 7) ~~Streaming retry / error policy undefined~~ ✅ Resolved
- **Resolution:** `do_stream_request` now retries on 429/529 and network errors with exponential backoff (matching the sync `do_call_with_retry` behaviour). A `:retry_reset` message clears the stream parser between attempts so no stale data leaks. `base_url/0` extracted for testability; Bypass-based tests cover both streaming and sync retry paths.

## P3 - Low

### 8) ~~`ToolRunner` docs mention `:max_concurrency` but it is not implemented~~ ✅ Resolved
- **Resolution:** `execute/4` now uses `Task.Supervisor.async_stream_nolink` which natively supports `:max_concurrency`. Defaults to `length(tool_calls)` (preserving unlimited-parallelism behaviour for existing callers). Tests use a peak-concurrency tracker to deterministically verify serialisation (`peak == 1` with `max_concurrency: 1`) and parallel execution (`peak > 1` with the default).

### 9) ~~Stream parser docs/types don't match emitted events~~ ✅ Resolved
- **Resolution:** Wired up `current_tool_id` in parser `State` so `parse/2` enriches raw events into self-describing `{:input_json_delta, id, json}` 3-tuples via `enrich_events/2`. Made `parse_event/1` private (`defp`) since its raw 2-tuple output is an internal detail that shouldn't leak to consumers. Updated `@type event`, `@moduledoc`, `Accumulator`, `Loop`, and all docs (`anthropic.ex`, `llm.ex`, `README.md`, design doc) to the 3-tuple contract. Added focused enrichment tests covering tool ID tracking, reset after `content_block_stop`, multiple sequential tool blocks, and cross-chunk-boundary enrichment.

### 10) ReadFile line slicing lacks range validation
- **Problem:** Negative or inverted ranges can produce surprising outputs (e.g., start > end, negative indices).
- **Impact:** Unclear UX; can return empty or unintended lines.
- **Where:** `lib/clementine/tools/read_file.ex:64-71`
- **Notes / Direction:** Clamp to valid ranges or return a friendly error when invalid.

### 11) ~~Streaming request process may leak if consumer halts early~~ ✅ Resolved
- **Resolution:** Fixed in PR #8 (fix/streaming-retry-policy). The streaming implementation now properly terminates spawned processes when the stream consumer halts.

## Opportunities / Major Unlocks (Lower Priority)

### 12) Unify internal message model
- **Problem:** Mixed map formats are used across `Loop`, `LLM`, and tools, while `Clementine.LLM.Message` provides a richer internal model.
- **Impact:** Harder to add new providers and reason about content types.
- **Where:** `lib/clementine/llm/message.ex`, `lib/clementine/llm/llm.ex`, `lib/clementine/loop.ex`
- **Notes / Direction:** Use `Clementine.LLM.Message` as the internal canonical representation and convert at provider boundaries.

### 13) ~~Schema‑driven input validation for tools~~ ✅ Resolved
- **Resolution:** `validate_args/2` now validates types, enums, array items, and nested object properties — not just required-field presence. Custom recursive validator produces LLM-friendly error messages (e.g. `"expected count to be an integer, got: string"`, `"tags[1]"` for array items, `"config.port"` for nested objects). No type coercion; JSON values arrive correctly typed from `Jason.decode!`.

### 14) `:object` parameters without `:properties` silently lose data
- **Problem:** An `:object` parameter with no `:properties` schema passes validation (correctly — we can't validate what we don't know about), but `cast_keys/2` in `ToolRunner` drops all nested keys because none are in the (empty) allowed-keys set. The tool's `run/2` receives `%{config: %{}}` instead of the actual data. This makes it impossible to build tools that accept arbitrary/dynamic JSON payloads (form submissions, user-defined schemas, forwarded webhook bodies, etc.) without resorting to encoding the payload as a JSON string inside a `:string` parameter.
- **Impact:** Silent data loss. A tool author who writes `config: [type: :object, required: true]` expecting a passthrough gets an empty map with no error. The only workaround (JSON-as-string) wastes LLM tokens on double-encoding and invites malformed output.
- **Where:** `lib/clementine/tool_runner.ex:197-201` (`cast_value` for `:object`), `lib/clementine/tool_runner.ex:170-193` (`cast_keys`)
- **Constraints:** Any fix must not reintroduce the atom-creation DoS vector from issue #1. Arbitrary keys from LLM input must stay as strings.
- **Notes / Direction:** Add a passthrough mode for `:object` parameters. When an `:object` has no `:properties` (or an explicit opt-in flag like `passthrough: true`), `cast_value` should preserve the nested map with string keys intact instead of running it through `cast_keys`. The tool receives `%{config: %{"any_key" => "value"}}` — string keys, no atom creation, data preserved. Validation already handles this correctly (no `:properties` = no nested validation). Changes needed:
  1. `cast_value/2` in `tool_runner.ex`: when type is `:object` and properties is `nil` or `[]`, return the map as-is instead of calling `cast_keys(value, [])`.
  2. `param_to_json_schema/1` in `tool.ex`: when `:object` has no `:properties`, emit `{"type": "object"}` without a `"properties"` key (currently emits empty `"properties": {}` and `"required": []` which over-constrains the JSON Schema — some LLM providers interpret empty properties as "no additional properties allowed").
  3. Consider whether `validate_object_properties` should warn or error when an `:object` with `:properties` receives string keys (indicating `cast_keys` didn't recurse, likely because the parent wasn't typed as `:object`). This would surface the "forgot `type: :object`" footgun from the review findings.
  4. Update `docs/TOOL_AUTHORING.md` with a passthrough example and a note that passthrough objects arrive with string keys.
