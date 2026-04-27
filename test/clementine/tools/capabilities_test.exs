defmodule Clementine.Tools.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Clementine.Tools.{ListDir, Search, WriteFile}

  @root Path.join(System.tmp_dir!(), "clementine_tools_capabilities_test")

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(@root)
    File.write!(Path.join(@root, "needle.txt"), "find me\n")

    on_exit(fn -> File.rm_rf!(@root) end)

    :ok
  end

  test "write_file requires write capability" do
    assert {:error, msg} =
             WriteFile.run(%{path: "out.txt", content: "hello"}, %{
               working_dir: @root,
               capabilities: %{read: true}
             })

    assert msg =~ "Tool capability denied: write"
  end

  test "write_file writes only within the workspace root" do
    context = %{working_dir: @root, capabilities: %{write: true}}

    assert {:ok, _} = WriteFile.run(%{path: "out.txt", content: "hello"}, context)
    assert File.read!(Path.join(@root, "out.txt")) == "hello"

    assert {:error, msg} = WriteFile.run(%{path: "../outside.txt", content: "no"}, context)
    assert msg =~ "escapes workspace root"
  end

  test "list_dir requires read capability" do
    assert {:error, msg} =
             ListDir.run(%{path: "."}, %{working_dir: @root, capabilities: %{write: true}})

    assert msg =~ "Tool capability denied: read"
  end

  test "search requires read capability and stays inside the workspace root" do
    context = %{working_dir: @root, capabilities: %{read: true}}

    assert {:ok, result} = Search.run(%{pattern: "find", path: "."}, context)
    assert result =~ "needle.txt"

    assert {:error, msg} = Search.run(%{pattern: "find", path: "../"}, context)
    assert msg =~ "escapes workspace root"
  end
end
