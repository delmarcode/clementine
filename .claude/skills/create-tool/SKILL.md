---
name: create-tool
description: Scaffold a new Clementine tool module and its test file
argument-hint: <tool_name>
---

# Create a new Clementine tool

You are scaffolding a new tool for the Clementine agent framework.

## Reference

Read `docs/TOOL_AUTHORING.md` for the full tool authoring guide, including the result contract, parameter schema, and error handling patterns.

## Inputs

The tool name is: **$ARGUMENTS**

If no name was provided, ask the user for one before proceeding.

## Steps

1. **Gather requirements** — Ask the user:
   - What does this tool do? (one sentence)
   - What parameters does it need? (name, type, required?, description for each)
   - Should any failure cases use `{:ok, content, is_error: true}` vs `{:error, reason}`?

2. **Scaffold the tool module** — Create `lib/clementine/tools/$ARGUMENTS.ex`:
   - Module name: `Clementine.Tools.<PascalCaseName>`
   - `use Clementine.Tool` with `name`, `description`, and `parameters`
   - Implement `run/2` callback
   - Add a `@moduledoc` string
   - Follow the patterns in existing tools (`lib/clementine/tools/bash.ex`, `lib/clementine/tools/read_file.ex`)
   - If the tool works with file paths, include a `resolve_path/2` helper using `context.working_dir`

3. **Scaffold the test file** — Create `test/clementine/tools/$ARGUMENTS_test.exs`:
   - Module name: `Clementine.Tools.<PascalCaseName>Test`
   - `use ExUnit.Case, async: true`
   - Test the happy path (`{:ok, content}`)
   - Test error cases (`{:error, reason}`)
   - If applicable, test the 3-tuple form (`{:ok, content, is_error: true}`)

4. **Run `mix test`** to verify the new tests pass.

5. **Tell the user** to add the tool to their agent's `tools:` list.
