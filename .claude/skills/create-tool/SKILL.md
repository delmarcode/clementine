---
name: create-tool
description: Scaffold a new built-in Clementine tool module and its test file
argument-hint: <tool_name>
---

# Create a new Clementine tool

You are adding a built-in tool (`Clementine.Tools.*`) to the Clementine library.

## Reference

Read `docs/TOOL_AUTHORING.md` for the full contract: results, the parameter schema, execution metadata (`retry:`, `approval:`), the context, and testing.

## Inputs

The tool name is: **$ARGUMENTS**

If no name was provided, ask the user for one before proceeding.

## Steps

1. **Gather requirements** — Ask the user:
   - What does this tool do? (one sentence)
   - What parameters does it need? (name, type, required?, description for each)
   - Which failures should the model see and react to (`{:ok, content, is_error: true}`), and which mean the call could not run (`{:error, reason}`)?
   - Is it free of external effects, so running it twice is as good as once? Only then declare `retry: :safe`; leave it unset when unsure.
   - Should each call wait for a person's approval (`approval: :required`) or ask the host's tool policy (`approval: {:policy, term}`)? The default is `:never`.
   - Which capability does it need: `:read`, `:write`, or `:shell`? Built-in tools refuse without one.

2. **Scaffold the tool module** — Create `lib/clementine/tools/$ARGUMENTS.ex`:
   - Module name: `Clementine.Tools.<PascalCaseName>`, with a `@moduledoc`
   - `use Clementine.Tool` with `name`, `description`, `parameters`, and the `retry:` or `approval:` from step 1
   - Implement `run/2`, starting with `Clementine.ToolContext.require_capability(context, capability)`
   - Resolve every path with `Clementine.ToolContext.resolve_path(path, context)`: it keeps the path inside the context's root (`workspace_root`, else `working_dir`), and on the durable runtime refuses when the agent's `tool_context:` set neither
   - Return strings: `{:ok, content}`, `{:ok, content, is_error: true}`, or `{:error, reason}`
   - Follow the existing tools (`lib/clementine/tools/read_file.ex`, `lib/clementine/tools/bash.ex`)

3. **Scaffold the test file** — Create `test/clementine/tools/$ARGUMENTS_test.exs`:
   - Module name: `Clementine.Tools.<PascalCaseName>Test`
   - `use ExUnit.Case, async: true`
   - Test the happy path (`{:ok, content}`), the error cases (`{:error, reason}`), and the 3-tuple form (`{:ok, content, is_error: true}`) if it has one
   - Test the refusal without the capability
   - Call `execute/2` as well as `run/2`, so argument validation is covered

4. **List it** in the README's built-in tools and in the capability list in `docs/TOOL_AUTHORING.md`.

5. **Run the gates**: `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix test`.

6. **Tell the user** to add the tool to an agent's `tools:` (or `deferred:`) list and to grant its capability in the context: `Clementine.run/3`'s `context:` in process, the agent's `tool_context:` on the durable runtime.
