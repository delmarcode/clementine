# Tool Authoring Guide

This guide covers how to build custom tools for Clementine agents.

## Quick Start

A tool is a module that uses `Clementine.Tool` and implements a `run/2` callback:

```elixir
defmodule MyApp.Tools.Ping do
  use Clementine.Tool,
    name: "ping",
    description: "Check if a host is reachable",
    parameters: [
      host: [type: :string, required: true, description: "Hostname or IP to ping"]
    ]

  @impl true
  def run(%{host: host}, _context) do
    case System.cmd("ping", ["-c", "1", "-W", "2", host], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:ok, String.trim(output), is_error: true}
    end
  end
end
```

Register it with an agent:

```elixir
defmodule MyApp.Agent do
  use Clementine.Agent,
    name: "my_agent",
    model: :claude_sonnet,
    tools: [MyApp.Tools.Ping],
    system: "You can check network connectivity."
end
```

## Result Contract

Tool `run/2` must return one of three shapes:

| Return value | Meaning | `is_error` sent to LLM |
|---|---|---|
| `{:ok, content}` | Success | `false` |
| `{:ok, content, opts}` | Success with metadata | value of `opts[:is_error]` (default `false`) |
| `{:error, reason}` | Invocation failure | `true` |

Both `content` and `reason` must be strings.

### When to use each form

**`{:ok, content}`** — the tool ran and produced a normal result.

```elixir
{:ok, "file contents here"}
```

**`{:ok, content, is_error: true}`** — the tool ran, but the outcome represents a failure the model should know about. The content is still delivered (not wrapped in `"Error: ..."`), so the model sees the full output. Use this for command-level failures like non-zero exit codes, HTTP 4xx/5xx responses, or failed validations where the output itself is useful context.

```elixir
{:ok, "Exit code: 1\n\nundefined function foo/0", is_error: true}
```

**`{:error, reason}`** — the tool could not run at all. Invocation failures: missing files, bad arguments, timeouts, crashes. The reason is wrapped as `"Error: #{reason}"` in the tool result.

```elixir
{:error, "File not found: /nonexistent"}
```

### How results flow to the LLM

`ToolRunner.format_results/1` converts result tuples into tool_result maps:

```elixir
%{type: :tool_result, tool_use_id: id, content: content, is_error: true | false}
```

`ToolRunner.has_errors?/1` and `get_errors/1` treat both `{:error, _}` and `{:ok, _, is_error: true}` as errors. This means downstream code that checks for failures (retry logic, verifiers, event callbacks) will see command-level failures.

## Parameter Schema

Parameters are defined as a keyword list. Each parameter has these options:

| Option | Type | Required | Description |
|---|---|---|---|
| `:type` | atom | yes | One of `:string`, `:integer`, `:number`, `:boolean`, `:array`, `:object` |
| `:required` | boolean | no | Whether the LLM must provide this parameter (default: `false`) |
| `:description` | string | no | Describes the parameter to the LLM |
| `:enum` | list | no | For `:string` type, restricts to allowed values |
| `:items` | keyword | no | For `:array` type, the schema of each item |
| `:properties` | keyword | no | For `:object` type, nested parameter definitions |

### Examples

**Basic types:**

```elixir
parameters: [
  name: [type: :string, required: true, description: "User name"],
  count: [type: :integer, required: false, description: "How many"],
  verbose: [type: :boolean, required: false, description: "Show details"]
]
```

**Enum (restricted string values):**

```elixir
parameters: [
  format: [type: :string, required: true, description: "Output format", enum: ["json", "csv", "text"]]
]
```

**Array:**

```elixir
parameters: [
  tags: [type: :array, required: false, description: "Tags to apply",
    items: [type: :string]]
]
```

**Nested object:**

```elixir
parameters: [
  config: [type: :object, required: true, description: "Configuration",
    properties: [
      host: [type: :string, required: true, description: "Hostname"],
      port: [type: :integer, required: false, description: "Port number"]
    ]]
]
```

**No parameters:**

```elixir
parameters: []
```

Parameters are validated at compile time. Invalid types or missing `:type` fields will raise `ArgumentError`.

At runtime, `validate_args/2` checks types and enums in addition to required-field presence. This means tool `run/2` implementations can trust that arguments match their declared schema — no defensive type-checking needed. Validation covers:

- **Types:** `:string` → `is_binary`, `:integer` → `is_integer`, `:number` → `is_number` (int or float), `:boolean` → `is_boolean`, `:array` → `is_list`, `:object` → `is_map`
- **Enums:** value must be in the declared `:enum` list
- **Array items:** each element validated against the `:items` schema
- **Nested objects:** each property validated against its `:properties` schema (including required checks)

## Context

The second argument to `run/2` is a context map. Available keys:

| Key | Type | Description |
|---|---|---|
| `:working_dir` | string | Working directory for the agent (resolve relative paths against this) |
| `:agent_pid` | pid | PID of the agent GenServer |

You can pass additional context keys when starting the agent or calling `ToolRunner.execute/4` directly.

### Resolving paths

Follow the pattern used by the built-in tools:

```elixir
defp resolve_path(path, context) do
  if Path.type(path) == :absolute do
    path
  else
    working_dir = Map.get(context, :working_dir, File.cwd!())
    Path.join(working_dir, path)
  end
end
```

## Error Handling

The `Clementine.Tool` macro wraps `run/2` in argument validation and crash protection automatically (via `execute/2`). If your tool raises, the caller gets `{:error, "Tool crashed: <message>"}`. You don't need to rescue inside `run/2` unless you want to return a more specific message.

### Input Validation

Arguments are validated against the parameter schema before `run/2` is called. If validation fails, the tool returns an error like:

```
Invalid arguments: expected count to be an integer, got: string
Invalid arguments: format must be one of ["json", "csv"], got: "xml"
Invalid arguments: missing required parameter: config.host
Invalid arguments: expected tags[1] to be a string, got: integer
```

Multiple errors are joined with `"; "`. These errors are sent to the LLM as `is_error: true` tool results automatically — no special handling needed in your tool.

### Error Messages

Focus on returning clear error strings. The LLM reads these to decide what to do next:

```elixir
# Good - specific and actionable
{:error, "Permission denied: #{path}"}
{:error, "Invalid regex pattern: #{reason}"}

# Bad - vague
{:error, "something went wrong"}
{:error, inspect(error)}
```

## Testing Tools

### Unit testing `run/2` directly

Tools are plain modules. Call `run/2` with an args map and context:

```elixir
defmodule MyApp.Tools.PingTest do
  use ExUnit.Case, async: true

  alias MyApp.Tools.Ping

  test "reachable host returns {:ok, output}" do
    assert {:ok, output} = Ping.run(%{host: "localhost"}, %{})
    assert output =~ "bytes from"
  end

  test "unreachable host returns {:ok, output, is_error: true}" do
    assert {:ok, output, opts} = Ping.run(%{host: "192.0.2.1"}, %{})
    assert output =~ "100% packet loss"
    assert opts[:is_error] == true
  end
end
```

### Testing via ToolRunner

For integration-level tests that exercise argument validation, crash isolation, and parallel execution:

```elixir
test "ping tool via ToolRunner" do
  tools = [MyApp.Tools.Ping]
  calls = [%{id: "call_1", name: "ping", input: %{"host" => "localhost"}}]

  results = Clementine.ToolRunner.execute(tools, calls, %{})
  assert [{"call_1", {:ok, _}}] = results
end
```

Note that `ToolRunner.execute/4` expects string keys in the `input` map (as the LLM provides). It converts them to atoms using the tool's parameter schema, so only declared parameters are atomized.

### Testing format_results with the 3-tuple

```elixir
test "format_results propagates is_error from 3-tuple" do
  results = [{"id", {:ok, "Exit code: 1\n\nfailed", is_error: true}}]
  formatted = Clementine.ToolRunner.format_results(results)

  assert [%{is_error: true, content: "Exit code: 1\n\nfailed"}] = formatted
end
```

## Complete Example

Here's a tool that makes an HTTP HEAD request to check if a URL is accessible:

```elixir
defmodule MyApp.Tools.CheckUrl do
  @moduledoc "Check if a URL is accessible by making an HTTP HEAD request."

  use Clementine.Tool,
    name: "check_url",
    description: "Check if a URL is accessible. Returns the HTTP status code.",
    parameters: [
      url: [type: :string, required: true, description: "The URL to check"],
      timeout_ms: [type: :integer, required: false, description: "Request timeout in ms (default: 5000)"]
    ]

  @default_timeout 5_000

  @impl true
  def run(%{url: url} = args, _context) do
    timeout = Map.get(args, :timeout_ms, @default_timeout)

    case Req.head(url, receive_timeout: timeout) do
      {:ok, %{status: status}} when status < 400 ->
        {:ok, "HTTP #{status} - URL is accessible"}

      {:ok, %{status: status}} ->
        {:ok, "HTTP #{status}", is_error: true}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, "Request timed out after #{timeout}ms"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end
end
```

And its test:

```elixir
defmodule MyApp.Tools.CheckUrlTest do
  use ExUnit.Case, async: true

  alias MyApp.Tools.CheckUrl

  # These tests hit the network; tag them for exclusion in CI if needed.
  @moduletag :external

  test "accessible URL returns success" do
    assert {:ok, content} = CheckUrl.run(%{url: "https://httpbin.org/status/200"}, %{})
    assert content =~ "200"
  end

  test "404 URL returns is_error: true" do
    assert {:ok, content, opts} = CheckUrl.run(%{url: "https://httpbin.org/status/404"}, %{})
    assert content =~ "404"
    assert opts[:is_error] == true
  end

  test "unreachable URL returns {:error, ...}" do
    assert {:error, _} = CheckUrl.run(%{url: "https://httpbin.org/delay/10", timeout_ms: 100}, %{})
  end
end
```

## Checklist

When creating a new tool:

1. Create `lib/clementine/tools/<name>.ex` (or `lib/your_app/tools/<name>.ex`)
2. `use Clementine.Tool` with `name`, `description`, and `parameters`
3. Implement `run/2` returning `{:ok, string}`, `{:ok, string, opts}`, or `{:error, string}`
4. Create `test/clementine/tools/<name>_test.exs`
5. Add the tool module to your agent's `tools:` list
