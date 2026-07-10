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
        defaults: [max_tokens: 8192],
        reasoning: [thinking: :adaptive, effort: :high]
      ],
      gpt_5: [
        provider: :openai,
        id: "gpt-5",
        defaults: [max_output_tokens: 4096],
        reasoning: [effort: :medium]
      ],
      deepseek: [
        provider: :openrouter,
        id: "deepseek/deepseek-v3.2",
        reasoning: [effort: :high, max_tokens: 2000]
      ],
      qwen_bedrock: [
        provider: :bedrock,
        id: "qwen.qwen3-235b-a22b-2507-v1:0",
        reasoning: :low
      ],
      glm_vertex: [
        provider: :vertex,
        id: "zai/glm-4.7-maas",
        api_key: {MyApp.GcpAuth, :access_token, []}
      ],
      qwen_finetune: [
        provider: :openai_compatible,
        id: "tinker://run:train:0/sampler_weights/000080",
        base_url: "https://tinker.example.com/oai/api/v1",
        api_key: {:system, "TINKER_API_KEY"}
      ]
    )

    assert :ok = ModelRegistry.validate_config!()
  end

  test "validate_config!/0 raises for endpoint keys on non chat-completions providers" do
    Application.put_env(:clementine, :models,
      broken: [provider: :anthropic, id: "claude-sonnet", base_url: "https://example.com"]
    )

    assert_raise ArgumentError, ~r/:base_url is only supported for chat completions/, fn ->
      ModelRegistry.validate_config!()
    end
  end

  test "validate_config!/0 raises for invalid api_key shapes" do
    Application.put_env(:clementine, :models,
      broken: [provider: :openrouter, id: "deepseek/deepseek-v3.2", api_key: 42]
    )

    assert_raise ArgumentError, ~r/expected a string, \{:system, "ENV_VAR"\}/, fn ->
      ModelRegistry.validate_config!()
    end
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

  test "validate_config!/0 raises for invalid Anthropic reasoning value" do
    Application.put_env(:clementine, :models,
      broken: [provider: :anthropic, id: "claude-sonnet", reasoning: [thinking: :enabled]]
    )

    assert_raise ArgumentError,
                 ~r/Anthropic reasoning thinking "enabled" requires budget_tokens/,
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

  test "resolve!/1 returns endpoint config for chat completions aliases" do
    Application.put_env(:clementine, :models,
      qwen_finetune: [
        provider: :openai_compatible,
        id: "tinker://run:train:0/sampler_weights/000080",
        base_url: "https://tinker.example.com/oai/api/v1",
        api_key: {:system, "TINKER_API_KEY"}
      ]
    )

    assert %{
             provider: :openai_compatible,
             id: "tinker://run:train:0/sampler_weights/000080",
             base_url: "https://tinker.example.com/oai/api/v1",
             api_key: {:system, "TINKER_API_KEY"},
             alias: :qwen_finetune
           } = ModelRegistry.resolve!(:qwen_finetune)
  end

  test "resolve!/1 supports direct provider tuple references" do
    assert %{provider: :openai, id: "gpt-5", defaults: [], alias: nil} =
             ModelRegistry.resolve!({:openai, "gpt-5"})

    assert %{provider: :openrouter, id: "deepseek/deepseek-v3.2", base_url: nil, api_key: nil} =
             ModelRegistry.resolve!({:openrouter, "deepseek/deepseek-v3.2"})
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
