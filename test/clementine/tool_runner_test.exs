defmodule Clementine.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.Message.Content
  alias Clementine.ToolRunner

  # Import test tools
  alias Clementine.Test.Tools.{Echo, Add, Crash, Slow, Fail, TrackedSlow, InspectObject, InspectDeclaredObject}

  @tools [Echo, Add, Crash, Slow, Fail, TrackedSlow, InspectObject, InspectDeclaredObject]

  setup do
    # The TaskSupervisor is started by the application
    :ok
  end

  describe "execute_single/3" do
    test "executes a successful tool" do
      call = %{name: "echo", input: %{"message" => "hello"}}

      result = ToolRunner.execute_single(@tools, call, %{})

      assert {:ok, "Echo: hello"} = result
    end

    test "executes a tool with numeric args" do
      call = %{name: "add", input: %{"a" => 5, "b" => 3}}

      result = ToolRunner.execute_single(@tools, call, %{})

      assert {:ok, "8"} = result
    end

    test "returns error for unknown tool" do
      call = %{name: "unknown_tool", input: %{}}

      result = ToolRunner.execute_single(@tools, call, %{})

      assert {:error, "Unknown tool: unknown_tool"} = result
    end

    test "handles tool that returns error" do
      call = %{name: "fail", input: %{"reason" => "something broke"}}

      result = ToolRunner.execute_single(@tools, call, %{})

      assert {:error, "something broke"} = result
    end

    test "handles tool crash" do
      call = %{name: "crash", input: %{}}

      result = ToolRunner.execute_single(@tools, call, %{})

      assert {:error, message} = result
      assert message =~ "crashed" or message =~ "failed"
    end

    test "drops unknown keys from input instead of creating atoms" do
      # Keys not in the tool's parameter schema should be silently dropped,
      # not converted to atoms (which would be a DoS vector).
      random_key = "unknown_key_#{System.unique_integer([:positive])}"
      call = %{name: "echo", input: %{"message" => "hello", random_key => "injected"}}

      # The tool should still execute successfully with the known key
      assert {:ok, "Echo: hello"} = ToolRunner.execute_single(@tools, call, %{})

      # Verify the random key was NOT turned into an atom
      refute String.to_existing_atom(random_key)
    rescue
      ArgumentError ->
        # Expected: the atom does not exist, confirming it was never created
        :ok
    end
  end

  describe "execute_single/3 input validation" do
    test "wrong type argument returns validation error" do
      call = %{name: "echo", input: %{"message" => 123}}

      assert {:error, message} = ToolRunner.execute_single(@tools, call, %{})
      assert message =~ "Invalid arguments"
      assert message =~ "expected message to be a string, got: integer"
    end

    test "validation error formatted as is_error tool result" do
      results = [{"call_1", {:error, "Invalid arguments: expected message to be a string, got: integer"}}]

      formatted = ToolRunner.format_results(results)

      assert [
               %Content{
                 type: :tool_result,
                 tool_use_id: "call_1",
                 content: "Error: Invalid arguments: expected message to be a string, got: integer",
                 is_error: true
               }
             ] = formatted
    end
  end

  describe "execute_single/3 object passthrough" do
    test "object without properties preserves string-keyed data" do
      call = %{name: "inspect_object", input: %{"data" => %{"foo" => "bar"}}}

      assert {:ok, "string_keys"} = ToolRunner.execute_single(@tools, call, %{})
    end

    test "object with empty properties preserves string-keyed data" do
      defmodule EmptyPropsObject do
        use Clementine.Tool,
          name: "empty_props_object",
          description: "Object with properties: []",
          parameters: [
            data: [type: :object, required: true, properties: []]
          ]

        @impl true
        def run(%{data: data}, _context) when is_map(data) do
          cond do
            data == %{} -> {:ok, "empty"}
            Enum.all?(data, fn {k, _} -> is_binary(k) end) -> {:ok, "string_keys"}
            Enum.all?(data, fn {k, _} -> is_atom(k) end) -> {:ok, "atom_keys"}
            true -> {:ok, "mixed_keys"}
          end
        end
      end

      call = %{name: "empty_props_object", input: %{"data" => %{"foo" => "bar"}}}

      assert {:ok, "string_keys"} = ToolRunner.execute_single([EmptyPropsObject], call, %{})
    end

    test "object with declared properties atomizes keys" do
      call = %{name: "inspect_declared_object", input: %{"data" => %{"host" => "localhost"}}}

      assert {:ok, "atom_keys"} = ToolRunner.execute_single(@tools, call, %{})
    end
  end

  describe "execute/4" do
    test "executes multiple tools in parallel" do
      calls = [
        %{id: "call_1", name: "echo", input: %{"message" => "first"}},
        %{id: "call_2", name: "echo", input: %{"message" => "second"}}
      ]

      results = ToolRunner.execute(@tools, calls, %{})

      assert length(results) == 2

      result_map = Map.new(results)
      assert {:ok, "Echo: first"} = result_map["call_1"]
      assert {:ok, "Echo: second"} = result_map["call_2"]
    end

    test "handles timeout" do
      calls = [
        %{id: "call_1", name: "slow", input: %{"delay_ms" => 5000}}
      ]

      results = ToolRunner.execute(@tools, calls, %{}, timeout: 100)

      assert [{"call_1", {:error, message}}] = results
      assert message =~ "timed out"
    end

    test "isolates tool crashes" do
      calls = [
        %{id: "call_1", name: "crash", input: %{}},
        %{id: "call_2", name: "echo", input: %{"message" => "hello"}}
      ]

      results = ToolRunner.execute(@tools, calls, %{})

      result_map = Map.new(results)

      # Crash tool should return error
      assert {:error, _} = result_map["call_1"]

      # Echo tool should succeed despite the crash
      assert {:ok, "Echo: hello"} = result_map["call_2"]
    end

    test "preserves order of results" do
      calls = [
        %{id: "call_1", name: "echo", input: %{"message" => "1"}},
        %{id: "call_2", name: "echo", input: %{"message" => "2"}},
        %{id: "call_3", name: "echo", input: %{"message" => "3"}}
      ]

      results = ToolRunner.execute(@tools, calls, %{})
      ids = Enum.map(results, fn {id, _} -> id end)

      assert ids == ["call_1", "call_2", "call_3"]
    end

    test "max_concurrency: 1 serialises execution" do
      tracker = start_supervised!({Agent, fn -> {0, 0} end})
      context = %{concurrency_tracker: tracker}

      calls = [
        %{id: "call_1", name: "tracked_slow", input: %{"delay_ms" => 50}},
        %{id: "call_2", name: "tracked_slow", input: %{"delay_ms" => 50}},
        %{id: "call_3", name: "tracked_slow", input: %{"delay_ms" => 50}}
      ]

      results = ToolRunner.execute(@tools, calls, context, max_concurrency: 1)

      assert length(results) == 3
      assert Enum.all?(results, fn {_, result} -> match?({:ok, _}, result) end)

      {_, peak} = Agent.get(tracker, & &1)
      assert peak == 1
    end

    test "default (unlimited) concurrency runs in parallel" do
      tracker = start_supervised!({Agent, fn -> {0, 0} end})
      context = %{concurrency_tracker: tracker}

      calls = [
        %{id: "call_1", name: "tracked_slow", input: %{"delay_ms" => 50}},
        %{id: "call_2", name: "tracked_slow", input: %{"delay_ms" => 50}},
        %{id: "call_3", name: "tracked_slow", input: %{"delay_ms" => 50}}
      ]

      results = ToolRunner.execute(@tools, calls, context)

      assert length(results) == 3
      assert Enum.all?(results, fn {_, result} -> match?({:ok, _}, result) end)

      {_, peak} = Agent.get(tracker, & &1)
      assert peak > 1
    end

    test "all results returned with max_concurrency limit" do
      calls = [
        %{id: "call_1", name: "echo", input: %{"message" => "a"}},
        %{id: "call_2", name: "echo", input: %{"message" => "b"}},
        %{id: "call_3", name: "echo", input: %{"message" => "c"}},
        %{id: "call_4", name: "echo", input: %{"message" => "d"}}
      ]

      results = ToolRunner.execute(@tools, calls, %{}, max_concurrency: 2)

      assert length(results) == 4
      result_map = Map.new(results)
      assert {:ok, "Echo: a"} = result_map["call_1"]
      assert {:ok, "Echo: b"} = result_map["call_2"]
      assert {:ok, "Echo: c"} = result_map["call_3"]
      assert {:ok, "Echo: d"} = result_map["call_4"]
    end
  end

  describe "format_results/1" do
    test "formats successful results" do
      results = [
        {"call_1", {:ok, "success"}},
        {"call_2", {:ok, "also success"}}
      ]

      formatted = ToolRunner.format_results(results)

      assert [
               %Content{type: :tool_result, tool_use_id: "call_1", content: "success", is_error: false},
               %Content{type: :tool_result, tool_use_id: "call_2", content: "also success", is_error: false}
             ] = formatted
    end

    test "formats error results" do
      results = [
        {"call_1", {:error, "something went wrong"}}
      ]

      formatted = ToolRunner.format_results(results)

      assert [
               %Content{type: :tool_result, tool_use_id: "call_1", content: "Error: something went wrong", is_error: true}
             ] = formatted
    end

    test "formats mixed results" do
      results = [
        {"call_1", {:ok, "success"}},
        {"call_2", {:error, "failure"}}
      ]

      formatted = ToolRunner.format_results(results)

      assert length(formatted) == 2
      assert Enum.at(formatted, 0).is_error == false
      assert Enum.at(formatted, 1).is_error == true
    end

    test "formats 3-tuple with is_error: true" do
      results = [
        {"call_1", {:ok, "Exit code: 1\n\nfailed", is_error: true}}
      ]

      formatted = ToolRunner.format_results(results)

      assert [
               %Content{type: :tool_result, tool_use_id: "call_1", content: "Exit code: 1\n\nfailed", is_error: true}
             ] = formatted
    end

    test "formats 3-tuple with is_error: false" do
      results = [
        {"call_1", {:ok, "some output", is_error: false}}
      ]

      formatted = ToolRunner.format_results(results)

      assert [
               %Content{type: :tool_result, tool_use_id: "call_1", content: "some output", is_error: false}
             ] = formatted
    end

    test "formats 3-tuple without is_error defaults to false" do
      results = [
        {"call_1", {:ok, "some output", []}}
      ]

      formatted = ToolRunner.format_results(results)

      assert [
               %Content{type: :tool_result, tool_use_id: "call_1", content: "some output", is_error: false}
             ] = formatted
    end
  end

  describe "has_errors?/1" do
    test "returns false when no errors" do
      results = [
        {"call_1", {:ok, "success"}},
        {"call_2", {:ok, "also success"}}
      ]

      refute ToolRunner.has_errors?(results)
    end

    test "returns true when any error" do
      results = [
        {"call_1", {:ok, "success"}},
        {"call_2", {:error, "failure"}}
      ]

      assert ToolRunner.has_errors?(results)
    end

    test "returns true when 3-tuple has is_error: true" do
      results = [
        {"call_1", {:ok, "success"}},
        {"call_2", {:ok, "Exit code: 1\n\nfailed", is_error: true}}
      ]

      assert ToolRunner.has_errors?(results)
    end

    test "returns false when 3-tuple has is_error: false" do
      results = [
        {"call_1", {:ok, "success"}},
        {"call_2", {:ok, "output", is_error: false}}
      ]

      refute ToolRunner.has_errors?(results)
    end
  end

  describe "get_errors/1" do
    test "returns empty list when no errors" do
      results = [
        {"call_1", {:ok, "success"}}
      ]

      assert [] = ToolRunner.get_errors(results)
    end

    test "returns only errors" do
      results = [
        {"call_1", {:ok, "success"}},
        {"call_2", {:error, "error 1"}},
        {"call_3", {:error, "error 2"}}
      ]

      errors = ToolRunner.get_errors(results)

      assert length(errors) == 2
      assert {"call_2", "error 1"} in errors
      assert {"call_3", "error 2"} in errors
    end

    test "returns 3-tuple errors with is_error: true" do
      results = [
        {"call_1", {:ok, "success"}},
        {"call_2", {:ok, "Exit code: 1\n\nfailed", is_error: true}},
        {"call_3", {:error, "crash"}}
      ]

      errors = ToolRunner.get_errors(results)

      assert length(errors) == 2
      assert {"call_2", "Exit code: 1\n\nfailed"} in errors
      assert {"call_3", "crash"} in errors
    end
  end
end
