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
      gpt_5: [
        provider: :openai,
        id: "gpt-5",
        defaults: [max_output_tokens: 4096],
        reasoning: [effort: :medium]
      ]
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

  test "validate_config!/0 raises for invalid reasoning shape" do
    Application.put_env(:clementine, :models,
      broken: [provider: :openai, id: "gpt-5", reasoning: 12]
    )

    assert_raise ArgumentError, ~r/expected atom, string, keyword list, or map/, fn ->
      ModelRegistry.validate_config!()
    end
  end

  test "validate_config!/0 raises for invalid OpenAI reasoning value" do
    Application.put_env(:clementine, :models,
      broken: [provider: :openai, id: "gpt-5", reasoning: [effort: :max]]
    )

    assert_raise ArgumentError, ~r/unsupported OpenAI reasoning effort/, fn ->
      ModelRegistry.validate_config!()
    end
  end

  test "validate_config!/0 raises when reasoning is configured for unsupported adapters" do
    Application.put_env(:clementine, :models,
      broken: [provider: :anthropic, id: "claude-sonnet", reasoning: [effort: :medium]]
    )

    assert_raise ArgumentError,
                 ~r/:reasoning is not supported by Clementine's :anthropic adapter yet/,
                 fn ->
                   ModelRegistry.validate_config!()
                 end
  end

  test "resolve!/1 returns canonical model info for alias" do
    Application.put_env(:clementine, :models,
      gpt_5: [
        provider: :openai,
        id: "gpt-5",
        defaults: [max_output_tokens: 4096],
        reasoning: [effort: :high, summary: :auto]
      ]
    )

    assert %{
             provider: :openai,
             id: "gpt-5",
             defaults: [max_output_tokens: 4096],
             reasoning: [effort: :high, summary: :auto],
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
