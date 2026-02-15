defmodule Clementine.LLM.ModelRegistryTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.ModelRegistry

  setup do
    prev_models = Application.get_env(:clementine, :models)

    on_exit(fn ->
      if prev_models do
        Application.put_env(:clementine, :models, prev_models)
      else
        Application.delete_env(:clementine, :models)
      end
    end)

    :ok
  end

  test "validate_config!/0 accepts canonical model schema" do
    Application.put_env(:clementine, :models,
      claude_sonnet: [
        provider: :anthropic,
        id: "claude-sonnet-4-20250514",
        defaults: [max_tokens: 8192]
      ],
      gpt_5: [provider: :openai, id: "gpt-5", defaults: [max_output_tokens: 4096]]
    )

    assert :ok = ModelRegistry.validate_config!()
  end

  test "validate_config!/0 raises for invalid model config" do
    Application.put_env(:clementine, :models, broken: [provider: :openai, model: "gpt-5"])

    assert_raise ArgumentError, ~r/Invalid model config for :broken/, fn ->
      ModelRegistry.validate_config!()
    end
  end

  test "validate_config!/0 raises for empty alias model id" do
    Application.put_env(:clementine, :models, broken: [provider: :openai, id: ""])

    assert_raise ArgumentError, ~r/:id must be a non-empty string/, fn ->
      ModelRegistry.validate_config!()
    end
  end

  test "resolve!/1 returns canonical model info for alias" do
    Application.put_env(:clementine, :models,
      gpt_5: [provider: :openai, id: "gpt-5", defaults: [max_output_tokens: 4096]]
    )

    assert %{
             provider: :openai,
             id: "gpt-5",
             defaults: [max_output_tokens: 4096],
             alias: :gpt_5
           } = ModelRegistry.resolve!(:gpt_5)
  end

  test "resolve!/1 raises for empty alias model id" do
    Application.put_env(:clementine, :models, bad_alias: [provider: :openai, id: "  "])

    assert_raise ArgumentError, ~r/:id must be a non-empty string/, fn ->
      ModelRegistry.resolve!(:bad_alias)
    end
  end

  test "resolve!/1 supports direct provider tuple references" do
    assert %{provider: :openai, id: "gpt-5", defaults: [], alias: nil} =
             ModelRegistry.resolve!({:openai, "gpt-5"})
  end

  test "resolve!/1 raises for unknown aliases" do
    Application.put_env(:clementine, :models, [])

    assert_raise ArgumentError, ~r/Unknown model alias/, fn ->
      ModelRegistry.resolve!(:missing_alias)
    end
  end

  test "resolve!/1 raises for unknown tuple providers" do
    assert_raise ArgumentError, ~r/Unknown provider :foo/, fn ->
      ModelRegistry.resolve!({:foo, "model-x"})
    end
  end

  test "resolve!/1 raises for empty tuple model id" do
    assert_raise ArgumentError, ~r/model id must be a non-empty string/, fn ->
      ModelRegistry.resolve!({:openai, "   "})
    end
  end
end
