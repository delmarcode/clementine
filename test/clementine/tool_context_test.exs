defmodule Clementine.ToolContextTest do
  use ExUnit.Case, async: true

  alias Clementine.ToolContext

  @root Path.join(System.tmp_dir!(), "clementine_tool_context_test")

  setup_all do
    File.mkdir_p!(@root)

    on_exit(fn -> File.rm_rf!(@root) end)

    :ok
  end

  describe "require_capability/2" do
    test "accepts explicitly enabled capabilities" do
      assert :ok = ToolContext.require_capability(%{capabilities: %{read: true}}, :read)
    end

    test "rejects missing capabilities" do
      assert {:error, "Tool capability denied: write"} =
               ToolContext.require_capability(%{capabilities: %{read: true}}, :write)
    end
  end

  describe "resolve_path/2" do
    test "resolves relative paths under the workspace root" do
      assert {:ok, path} = ToolContext.resolve_path("lib/file.ex", %{workspace_root: @root})
      assert path == Path.join(@root, "lib/file.ex")
    end

    test "rejects parent traversal outside the workspace root" do
      assert {:error, msg} = ToolContext.resolve_path("../outside.ex", %{workspace_root: @root})
      assert msg =~ "escapes workspace root"
    end

    test "rejects absolute paths outside the workspace root" do
      assert {:error, msg} = ToolContext.resolve_path("/etc/passwd", %{workspace_root: @root})
      assert msg =~ "escapes workspace root"
    end

    test "allows absolute paths inside the workspace root" do
      nested = Path.join(@root, "nested/file.ex")

      assert {:ok, ^nested} = ToolContext.resolve_path(nested, %{workspace_root: @root})
    end
  end
end
