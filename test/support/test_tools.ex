defmodule Clementine.Test.Tools do
  @moduledoc """
  Test tool implementations for Clementine tests.
  """

  defmodule Echo do
    @moduledoc "A simple tool that echoes its input"
    use Clementine.Tool,
      name: "echo",
      description: "Echoes the input message back",
      parameters: [
        message: [type: :string, required: true, description: "The message to echo"]
      ]

    @impl true
    def run(%{message: message}, _context) do
      {:ok, "Echo: #{message}"}
    end
  end

  defmodule Add do
    @moduledoc "A tool that adds two numbers"
    use Clementine.Tool,
      name: "add",
      description: "Adds two numbers together",
      parameters: [
        a: [type: :integer, required: true, description: "First number"],
        b: [type: :integer, required: true, description: "Second number"]
      ]

    @impl true
    def run(%{a: a, b: b}, _context) do
      {:ok, "#{a + b}"}
    end
  end

  defmodule Crash do
    @moduledoc "A tool that always crashes (for testing error handling)"
    use Clementine.Tool,
      name: "crash",
      description: "A tool that crashes",
      parameters: []

    @impl true
    def run(_args, _context) do
      raise "Intentional crash for testing!"
    end
  end

  defmodule Slow do
    @moduledoc "A tool that takes a configurable amount of time"
    use Clementine.Tool,
      name: "slow",
      description: "A slow tool for testing timeouts",
      parameters: [
        delay_ms: [type: :integer, required: true, description: "Delay in milliseconds"]
      ]

    @impl true
    def run(%{delay_ms: delay_ms}, _context) do
      Process.sleep(delay_ms)
      {:ok, "Completed after #{delay_ms}ms"}
    end
  end

  defmodule Fail do
    @moduledoc "A tool that returns an error"
    use Clementine.Tool,
      name: "fail",
      description: "A tool that always fails",
      parameters: [
        reason: [type: :string, required: false, description: "Failure reason"]
      ]

    @impl true
    def run(%{reason: reason}, _context) when is_binary(reason) do
      {:error, reason}
    end

    def run(_args, _context) do
      {:error, "Generic failure"}
    end
  end

  defmodule Counter do
    @moduledoc "A stateful tool that counts invocations (uses process dictionary)"
    use Clementine.Tool,
      name: "counter",
      description: "Increments and returns a counter",
      parameters: []

    @impl true
    def run(_args, context) do
      key = {:counter, context[:counter_key] || :default}
      count = (Process.get(key) || 0) + 1
      Process.put(key, count)
      {:ok, "Count: #{count}"}
    end
  end
end
