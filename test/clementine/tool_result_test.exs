defmodule Clementine.ToolResultTest do
  use ExUnit.Case, async: true

  alias Clementine.ToolResult

  describe "normalize/1" do
    test "normalizes successful two-tuples to canonical success results" do
      assert {:ok, %ToolResult{content: "done", is_error: false}} =
               ToolResult.normalize({:ok, "done"})
    end

    test "normalizes successful three-tuples with is_error" do
      assert {:ok, %ToolResult{content: "failed command", is_error: true}} =
               ToolResult.normalize({:ok, "failed command", is_error: true})
    end

    test "accepts existing valid tool result structs" do
      result = %ToolResult{content: "done", is_error: false}

      assert {:ok, ^result} = ToolResult.normalize(result)
    end

    test "normalizes error tuples" do
      assert {:error, "bad args"} = ToolResult.normalize({:error, "bad args"})
    end

    test "rejects successful results with non-string content" do
      assert {:error, message} = ToolResult.normalize({:ok, %{content: "not valid"}})

      assert message =~ "Invalid tool result"
      assert message =~ "content to be a string"
    end

    test "rejects error results with non-string reasons" do
      assert {:error, message} = ToolResult.normalize({:error, :bad_args})

      assert message =~ "Invalid tool result"
      assert message =~ "error reason to be a string"
    end

    test "rejects unknown success options" do
      assert {:error, message} = ToolResult.normalize({:ok, "done", hidden: true})

      assert message =~ "Invalid tool result"
      assert message =~ "unknown successful tool option"
    end

    test "rejects non-boolean is_error options" do
      assert {:error, message} = ToolResult.normalize({:ok, "done", is_error: "yes"})

      assert message =~ "Invalid tool result"
      assert message =~ ":is_error option to be a boolean"
    end
  end

  describe "content/1 and error?/1" do
    test "successful command errors use raw content and error flag" do
      result = {:ok, %ToolResult{content: "Exit code: 1", is_error: true}}

      assert ToolResult.content(result) == "Exit code: 1"
      assert ToolResult.error?(result)
    end

    test "invocation errors are formatted with an Error prefix" do
      result = {:error, "invalid args"}

      assert ToolResult.content(result) == "Error: invalid args"
      assert ToolResult.error?(result)
    end
  end
end
