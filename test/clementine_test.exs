defmodule ClementineTest do
  use ExUnit.Case

  describe "module structure" do
    test "exposes expected public API" do
      Code.ensure_loaded!(Clementine)
      funcs = Clementine.__info__(:functions)

      # Core operations
      assert {:run, 2} in funcs
      assert {:run_async, 2} in funcs
      assert {:stream, 2} in funcs

      # Async result retrieval
      assert {:await, 2} in funcs
      assert {:await, 3} in funcs

      # Status
      assert {:status, 2} in funcs

      # Conversation management
      assert {:get_history, 1} in funcs
      assert {:clear_history, 1} in funcs
      assert {:fork, 2} in funcs
      assert {:fork, 3} in funcs

      # Tool execution
      assert {:tool_run, 2} in funcs
      assert {:tool_run, 3} in funcs
    end
  end
end
