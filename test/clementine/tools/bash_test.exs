defmodule Clementine.Tools.BashTest do
  use ExUnit.Case, async: true

  alias Clementine.Tools.Bash

  describe "run/2" do
    test "successful command returns {:ok, output}" do
      result = Bash.run(%{command: "echo hello"}, %{})

      assert {:ok, "hello"} = result
    end

    test "failed command returns 3-tuple with is_error: true" do
      result = Bash.run(%{command: "exit 1"}, %{})

      assert {:ok, content, opts} = result
      assert content =~ "Exit code: 1"
      assert Keyword.get(opts, :is_error) == true
    end

    test "failed command includes output in content" do
      result = Bash.run(%{command: "echo 'some error' && exit 2"}, %{})

      assert {:ok, content, opts} = result
      assert content =~ "Exit code: 2"
      assert content =~ "some error"
      assert Keyword.get(opts, :is_error) == true
    end

    test "timed-out command returns {:error, ...}" do
      result = Bash.run(%{command: "sleep 10", timeout_ms: 100}, %{})

      assert {:error, message} = result
      assert message =~ "timed out"
    end

    test "respects working directory from context" do
      result = Bash.run(%{command: "pwd"}, %{working_dir: "/tmp"})

      assert {:ok, path} = result
      # On macOS, /tmp is a symlink to /private/tmp
      assert path in ["/tmp", "/private/tmp"]
    end
  end
end
