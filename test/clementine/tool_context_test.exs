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

    test "an in-process context with no root resolves under the current directory" do
      assert {:ok, path} = ToolContext.resolve_path("lib/file.ex", %{})
      assert path == Path.expand("lib/file.ex", File.cwd!())
    end

    test "a durable run's context (it carries run_id) has no default root: refused without a working_dir" do
      assert {:error, msg} = ToolContext.resolve_path("lib/file.ex", %{run_id: "r-1"})
      assert msg =~ "No working_dir"

      assert {:ok, path} =
               ToolContext.resolve_path("lib/file.ex", %{run_id: "r-1", working_dir: @root})

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

    test "allows children when workspace root is filesystem root" do
      assert {:ok, "/etc/hosts"} = ToolContext.resolve_path("/etc/hosts", %{workspace_root: "/"})
    end

    test "rejects paths that escape through symlinks" do
      root = Path.join(@root, "symlink_escape")
      outside = Path.join(@root, "outside")
      File.rm_rf!(root)
      File.rm_rf!(outside)
      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "secret")

      link = Path.join(root, "link")
      File.ln_s!(outside, link)

      assert {:error, msg} =
               ToolContext.resolve_path("link/secret.txt", %{workspace_root: root})

      assert msg =~ "escapes workspace root"
    end
  end
end
