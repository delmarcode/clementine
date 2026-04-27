defmodule Clementine.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias Clementine.Tools.ReadFile

  @fixture_dir Path.join(System.tmp_dir!(), "clementine_read_file_test")
  @fixture_file Path.join(@fixture_dir, "test.txt")
  @fixture_content Enum.map_join(1..10, "\n", &"line #{&1}")

  @trailing_newline_file Path.join(@fixture_dir, "trailing.txt")
  @trailing_newline_content "line 1\nline 2\nline 3\n"

  @blank_lines_file Path.join(@fixture_dir, "blank_lines.txt")
  @blank_lines_content "a\n\n\nb\n"

  @all_newlines_file Path.join(@fixture_dir, "all_newlines.txt")
  @all_newlines_content "\n\n\n"

  @empty_file Path.join(@fixture_dir, "empty.txt")

  setup_all do
    File.mkdir_p!(@fixture_dir)
    File.write!(@fixture_file, @fixture_content)
    File.write!(@trailing_newline_file, @trailing_newline_content)
    File.write!(@blank_lines_file, @blank_lines_content)
    File.write!(@all_newlines_file, @all_newlines_content)
    File.write!(@empty_file, "")

    on_exit(fn -> File.rm_rf!(@fixture_dir) end)

    :ok
  end

  defp context do
    %{working_dir: @fixture_dir, capabilities: %{read: true}}
  end

  describe "run/2 basic" do
    test "reads entire file" do
      assert {:ok, content} = ReadFile.run(%{path: "test.txt"}, context())
      assert content == @fixture_content
    end

    test "returns error for missing file" do
      assert {:error, msg} = ReadFile.run(%{path: "missing.txt"}, context())
      assert msg =~ "File not found"
    end

    test "returns error for directory" do
      assert {:error, msg} = ReadFile.run(%{path: "."}, context())
      assert msg =~ "directory"
    end

    test "rejects reads without explicit capability" do
      assert {:error, msg} = ReadFile.run(%{path: "test.txt"}, %{working_dir: @fixture_dir})
      assert msg =~ "Tool capability denied: read"
    end

    test "rejects paths outside workspace root" do
      assert {:error, msg} = ReadFile.run(%{path: "../outside.txt"}, context())
      assert msg =~ "escapes workspace root"
    end

    test "allows absolute paths only when they remain under workspace root" do
      assert {:ok, content} = ReadFile.run(%{path: @fixture_file}, context())
      assert content == @fixture_content
    end
  end

  describe "run/2 line slicing" do
    test "slices with valid start and end" do
      assert {:ok, content} =
               ReadFile.run(%{path: "test.txt", start_line: 2, end_line: 4}, context())

      assert content == "2: line 2\n3: line 3\n4: line 4"
    end

    test "slices with only start_line" do
      assert {:ok, content} = ReadFile.run(%{path: "test.txt", start_line: 9}, context())
      assert content == "9: line 9\n10: line 10"
    end

    test "slices with only end_line" do
      assert {:ok, content} = ReadFile.run(%{path: "test.txt", end_line: 3}, context())
      assert content == "1: line 1\n2: line 2\n3: line 3"
    end

    test "end_line beyond file length clamps to last line" do
      assert {:ok, content} =
               ReadFile.run(%{path: "test.txt", start_line: 9, end_line: 999}, context())

      assert content == "9: line 9\n10: line 10"
    end

    test "trailing newline does not produce phantom line" do
      assert {:ok, content} =
               ReadFile.run(%{path: "trailing.txt", start_line: 1, end_line: 10}, context())

      assert content == "1: line 1\n2: line 2\n3: line 3"
    end

    test "preserves intentional blank lines" do
      assert {:ok, content} =
               ReadFile.run(%{path: "blank_lines.txt", start_line: 1, end_line: 4}, context())

      assert content == "1: a\n2: \n3: \n4: b"
    end

    test "all-newlines file preserves blank lines" do
      assert {:ok, content} =
               ReadFile.run(%{path: "all_newlines.txt", start_line: 1, end_line: 3}, context())

      assert content == "1: \n2: \n3: "
    end
  end

  describe "run/2 range validation" do
    test "rejects negative start_line" do
      assert {:error, msg} =
               ReadFile.run(%{path: "test.txt", start_line: -5, end_line: 2}, context())

      assert msg =~ "start_line must be >= 1"
    end

    test "rejects zero start_line" do
      assert {:error, msg} =
               ReadFile.run(%{path: "test.txt", start_line: 0, end_line: 2}, context())

      assert msg =~ "start_line must be >= 1"
    end

    test "rejects negative end_line" do
      assert {:error, msg} =
               ReadFile.run(%{path: "test.txt", start_line: 1, end_line: -1}, context())

      assert msg =~ "end_line must be >= 1"
    end

    test "rejects inverted range (start > end)" do
      assert {:error, msg} =
               ReadFile.run(%{path: "test.txt", start_line: 5, end_line: 2}, context())

      assert msg =~ "start_line (5) must be <= end_line (2)"
    end

    test "rejects start_line beyond file length" do
      assert {:error, msg} = ReadFile.run(%{path: "test.txt", start_line: 100}, context())
      assert msg =~ "start_line (100) is beyond end of file (10 lines)"
    end

    test "rejects slicing an empty file" do
      assert {:error, msg} = ReadFile.run(%{path: "empty.txt", start_line: 1}, context())
      assert msg =~ "file is empty"
    end
  end
end
