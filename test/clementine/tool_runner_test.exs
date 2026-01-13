defmodule Clementine.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias Clementine.ToolRunner

  # Import test tools
  alias Clementine.Test.Tools.{Echo, Add, Crash, Slow, Fail}

  @tools [Echo, Add, Crash, Slow, Fail]

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
  end

  describe "format_results/1" do
    test "formats successful results" do
      results = [
        {"call_1", {:ok, "success"}},
        {"call_2", {:ok, "also success"}}
      ]

      formatted = ToolRunner.format_results(results)

      assert [
               %{type: :tool_result, tool_use_id: "call_1", content: "success", is_error: false},
               %{type: :tool_result, tool_use_id: "call_2", content: "also success", is_error: false}
             ] = formatted
    end

    test "formats error results" do
      results = [
        {"call_1", {:error, "something went wrong"}}
      ]

      formatted = ToolRunner.format_results(results)

      assert [
               %{type: :tool_result, tool_use_id: "call_1", content: "Error: something went wrong", is_error: true}
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
  end
end
