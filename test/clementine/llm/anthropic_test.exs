defmodule Clementine.LLM.AnthropicTest do
  use ExUnit.Case, async: true

  # These tests focus on request/response formatting
  # Actual HTTP calls are tested in integration tests

  describe "module structure" do
    test "exports call functions" do
      Code.ensure_loaded!(Clementine.LLM.Anthropic)
      funcs = Clementine.LLM.Anthropic.__info__(:functions)
      assert {:call, 4} in funcs
      assert {:call, 5} in funcs
    end

    test "exports stream functions" do
      Code.ensure_loaded!(Clementine.LLM.Anthropic)
      funcs = Clementine.LLM.Anthropic.__info__(:functions)
      assert {:stream, 4} in funcs
      assert {:stream, 5} in funcs
    end
  end

  # Note: Most Anthropic tests require mocking HTTP requests
  # which we'll do in integration tests. These tests verify
  # the module structure and public interface.
end
