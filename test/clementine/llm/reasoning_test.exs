defmodule Clementine.LLM.ReasoningTest do
  use ExUnit.Case, async: true

  alias Clementine.LLM.Reasoning

  describe "validate_config/1" do
    test "accepts nil, atoms, strings, keyword lists, and maps" do
      assert {:ok, nil} = Reasoning.validate_config(nil)
      assert {:ok, :high} = Reasoning.validate_config(:high)
      assert {:ok, "high"} = Reasoning.validate_config("high")
      assert {:ok, [effort: :high]} = Reasoning.validate_config(effort: :high)
      assert {:ok, %{effort: :high}} = Reasoning.validate_config(%{effort: :high})
    end

    test "rejects other shapes" do
      assert {:error, "expected atom, string, keyword list, or map"} =
               Reasoning.validate_config(12)

      assert {:error, "expected atom, string, keyword list, or map"} =
               Reasoning.validate_config([1, 2])
    end
  end

  describe "to_provider_config/2 for :openai" do
    test "translates nothing for nil and empty configs" do
      assert {:ok, %{}} = Reasoning.to_provider_config(:openai, nil)
      assert {:ok, %{}} = Reasoning.to_provider_config(:openai, [])
      assert {:ok, %{}} = Reasoning.to_provider_config(:openai, %{})
    end

    test "treats a bare value as effort shorthand" do
      assert {:ok, %{"reasoning" => %{"effort" => "low"}}} =
               Reasoning.to_provider_config(:openai, :low)

      assert {:ok, %{"reasoning" => %{"effort" => "xhigh"}}} =
               Reasoning.to_provider_config(:openai, "xhigh")
    end

    test "translates keyword and map configs into the reasoning field" do
      assert {:ok, %{"reasoning" => %{"effort" => "high", "summary" => "auto"}}} =
               Reasoning.to_provider_config(:openai, effort: :high, summary: :auto)

      assert {:ok, %{"reasoning" => %{"generate_summary" => "detailed"}}} =
               Reasoning.to_provider_config(:openai, %{"generate_summary" => "detailed"})
    end

    test "rejects unsupported keys and values" do
      assert {:error, "unsupported OpenAI reasoning key" <> _} =
               Reasoning.to_provider_config(:openai, budget_tokens: 2048)

      assert {:error, "unsupported OpenAI reasoning effort" <> _} =
               Reasoning.to_provider_config(:openai, :max)

      assert {:error, "unsupported OpenAI reasoning summary" <> _} =
               Reasoning.to_provider_config(:openai, summary: :verbose)
    end

    test "rejects non-keyword lists and other shapes" do
      message = "OpenAI reasoning config must be an atom, string, keyword list, or map"

      assert {:error, ^message} = Reasoning.to_provider_config(:openai, [1, 2])
      assert {:error, ^message} = Reasoning.to_provider_config(:openai, 42)
    end
  end

  describe "to_provider_config/2 for :anthropic" do
    test "translates nothing for nil and empty configs" do
      assert {:ok, %{}} = Reasoning.to_provider_config(:anthropic, nil)
      assert {:ok, %{}} = Reasoning.to_provider_config(:anthropic, [])
      assert {:ok, %{}} = Reasoning.to_provider_config(:anthropic, %{})
    end

    test "treats a bare value as effort shorthand" do
      assert {:ok, %{"output_config" => %{"effort" => "high"}}} =
               Reasoning.to_provider_config(:anthropic, :high)

      assert {:ok, %{"output_config" => %{"effort" => "max"}}} =
               Reasoning.to_provider_config(:anthropic, "max")
    end

    test "translates effort into output_config" do
      assert {:ok, %{"output_config" => %{"effort" => "medium"}} = fields} =
               Reasoning.to_provider_config(:anthropic, effort: :medium)

      refute Map.has_key?(fields, "thinking")
    end

    test "translates adaptive thinking, with optional display" do
      assert {:ok, %{"thinking" => %{"type" => "adaptive"}} = fields} =
               Reasoning.to_provider_config(:anthropic, thinking: :adaptive)

      refute Map.has_key?(fields, "output_config")

      assert {:ok, %{"thinking" => %{"type" => "adaptive", "display" => "summarized"}}} =
               Reasoning.to_provider_config(:anthropic,
                 thinking: :adaptive,
                 display: :summarized
               )
    end

    test "translates thinking and effort together" do
      assert {:ok,
              %{
                "thinking" => %{"type" => "adaptive"},
                "output_config" => %{"effort" => "xhigh"}
              }} =
               Reasoning.to_provider_config(:anthropic, thinking: :adaptive, effort: :xhigh)
    end

    test "translates enabled thinking with a token budget" do
      assert {:ok, %{"thinking" => %{"type" => "enabled", "budget_tokens" => 2048}}} =
               Reasoning.to_provider_config(:anthropic, thinking: :enabled, budget_tokens: 2048)
    end

    test "budget_tokens alone implies enabled thinking" do
      assert {:ok, %{"thinking" => %{"type" => "enabled", "budget_tokens" => 4096}}} =
               Reasoning.to_provider_config(:anthropic, budget_tokens: 4096)

      assert {:ok,
              %{
                "thinking" => %{
                  "type" => "enabled",
                  "budget_tokens" => 4096,
                  "display" => "omitted"
                }
              }} =
               Reasoning.to_provider_config(:anthropic, budget_tokens: 4096, display: :omitted)
    end

    test "translates disabled thinking" do
      assert {:ok, %{"thinking" => %{"type" => "disabled"}}} =
               Reasoning.to_provider_config(:anthropic, thinking: :disabled)
    end

    test "accepts string keys and values" do
      assert {:ok,
              %{
                "thinking" => %{"type" => "adaptive"},
                "output_config" => %{"effort" => "high"}
              }} =
               Reasoning.to_provider_config(:anthropic, %{
                 "thinking" => "adaptive",
                 "effort" => "high"
               })
    end

    test "rejects enabled thinking without a budget" do
      assert {:error, ~s(Anthropic reasoning thinking "enabled" requires budget_tokens)} =
               Reasoning.to_provider_config(:anthropic, thinking: :enabled)
    end

    test "rejects a budget with adaptive or disabled thinking" do
      message = ~s(Anthropic reasoning budget_tokens is only supported with thinking "enabled")

      assert {:error, ^message} =
               Reasoning.to_provider_config(:anthropic, thinking: :adaptive, budget_tokens: 1024)

      assert {:error, ^message} =
               Reasoning.to_provider_config(:anthropic, thinking: :disabled, budget_tokens: 1024)
    end

    test "rejects display without thinking" do
      message = ~s(Anthropic reasoning display requires thinking "adaptive" or "enabled")

      assert {:error, ^message} =
               Reasoning.to_provider_config(:anthropic, display: :summarized)

      assert {:error, ^message} =
               Reasoning.to_provider_config(:anthropic, effort: :high, display: :summarized)

      assert {:error, ^message} =
               Reasoning.to_provider_config(:anthropic, thinking: :disabled, display: :summarized)
    end

    test "rejects unsupported keys and values" do
      assert {:error, "unsupported Anthropic reasoning key" <> _} =
               Reasoning.to_provider_config(:anthropic, summary: :auto)

      assert {:error, "unsupported Anthropic reasoning effort" <> _} =
               Reasoning.to_provider_config(:anthropic, :minimal)

      assert {:error, "unsupported Anthropic reasoning thinking" <> _} =
               Reasoning.to_provider_config(:anthropic, thinking: :sometimes)

      assert {:error, "unsupported Anthropic reasoning display" <> _} =
               Reasoning.to_provider_config(:anthropic, thinking: :adaptive, display: :full)

      assert {:error, "unsupported Anthropic reasoning budget_tokens" <> _} =
               Reasoning.to_provider_config(:anthropic, budget_tokens: 0)

      assert {:error, "unsupported Anthropic reasoning budget_tokens" <> _} =
               Reasoning.to_provider_config(:anthropic, budget_tokens: :lots)
    end

    test "rejects non-keyword lists and other shapes" do
      message = "Anthropic reasoning config must be an atom, string, keyword list, or map"

      assert {:error, ^message} = Reasoning.to_provider_config(:anthropic, [1, 2])
      assert {:error, ^message} = Reasoning.to_provider_config(:anthropic, 42)
    end
  end

  describe "to_provider_config/2 for :openrouter" do
    test "translates nothing for nil and empty configs" do
      assert {:ok, %{}} = Reasoning.to_provider_config(:openrouter, nil)
      assert {:ok, %{}} = Reasoning.to_provider_config(:openrouter, [])
      assert {:ok, %{}} = Reasoning.to_provider_config(:openrouter, %{})
    end

    test "treats a bare value as effort shorthand" do
      assert {:ok, %{"reasoning" => %{"effort" => "max"}}} =
               Reasoning.to_provider_config(:openrouter, :max)
    end

    test "translates the unified reasoning object" do
      assert {:ok,
              %{
                "reasoning" => %{
                  "effort" => "high",
                  "max_tokens" => 2000,
                  "exclude" => false,
                  "enabled" => true
                }
              }} =
               Reasoning.to_provider_config(:openrouter,
                 effort: :high,
                 max_tokens: 2000,
                 exclude: false,
                 enabled: true
               )
    end

    test "rejects unsupported keys and values" do
      assert {:error, "unsupported OpenRouter reasoning key" <> _} =
               Reasoning.to_provider_config(:openrouter, thinking: :adaptive)

      assert {:error, "unsupported OpenRouter reasoning effort" <> _} =
               Reasoning.to_provider_config(:openrouter, effort: :ultra)

      assert {:error, "unsupported OpenRouter reasoning max_tokens" <> _} =
               Reasoning.to_provider_config(:openrouter, max_tokens: 0)

      assert {:error, "unsupported OpenRouter reasoning exclude" <> _} =
               Reasoning.to_provider_config(:openrouter, exclude: "yes")
    end

    test "rejects non-keyword lists and other shapes" do
      message = "OpenRouter reasoning config must be an atom, string, keyword list, or map"

      assert {:error, ^message} = Reasoning.to_provider_config(:openrouter, [1, 2])
      assert {:error, ^message} = Reasoning.to_provider_config(:openrouter, 42)
    end
  end

  describe "to_provider_config/2 for chat completions effort providers" do
    for {provider, label} <- [
          bedrock: "Bedrock",
          vertex: "Vertex",
          openai_compatible: "OpenAI-compatible"
        ] do
      test "#{provider} translates effort into reasoning_effort" do
        provider = unquote(provider)

        assert {:ok, %{}} = Reasoning.to_provider_config(provider, nil)
        assert {:ok, %{}} = Reasoning.to_provider_config(provider, [])

        assert {:ok, %{"reasoning_effort" => "high"}} =
                 Reasoning.to_provider_config(provider, :high)

        assert {:ok, %{"reasoning_effort" => "minimal"}} =
                 Reasoning.to_provider_config(provider, effort: "minimal")
      end

      test "#{provider} rejects unsupported keys, values, and shapes" do
        provider = unquote(provider)
        label = unquote(label)

        assert {:error, effort_message} = Reasoning.to_provider_config(provider, :max)
        assert effort_message =~ "unsupported #{label} reasoning effort"

        assert {:error, key_message} =
                 Reasoning.to_provider_config(provider, budget_tokens: 1024)

        assert key_message =~ "unsupported #{label} reasoning key"

        assert {:error, "#{label} reasoning config must be an atom, string, keyword list, or map"} ==
                 Reasoning.to_provider_config(provider, 42)
      end
    end
  end

  describe "to_provider_config!/2" do
    test "returns the fields on success" do
      assert %{"output_config" => %{"effort" => "high"}} =
               Reasoning.to_provider_config!(:anthropic, :high)
    end

    test "raises ArgumentError on invalid config" do
      assert_raise ArgumentError, ~r/unsupported Anthropic reasoning effort/, fn ->
        Reasoning.to_provider_config!(:anthropic, :ultra)
      end
    end
  end

  describe "validate_model_config/2" do
    test "accepts nil for any provider" do
      assert {:ok, nil} = Reasoning.validate_model_config(:anthropic, nil)
      assert {:ok, nil} = Reasoning.validate_model_config(:some_future_provider, nil)
    end

    test "returns the config as given for supported providers" do
      assert {:ok, [effort: :high]} = Reasoning.validate_model_config(:openai, effort: :high)

      assert {:ok, [thinking: :adaptive]} =
               Reasoning.validate_model_config(:anthropic, thinking: :adaptive)

      assert {:ok, [effort: :high, max_tokens: 2000]} =
               Reasoning.validate_model_config(:openrouter, effort: :high, max_tokens: 2000)

      assert {:ok, :low} = Reasoning.validate_model_config(:bedrock, :low)
      assert {:ok, :low} = Reasoning.validate_model_config(:vertex, :low)
      assert {:ok, :low} = Reasoning.validate_model_config(:openai_compatible, :low)
    end

    test "propagates translation errors" do
      assert {:error, "unsupported OpenAI reasoning effort" <> _} =
               Reasoning.validate_model_config(:openai, effort: :max)

      assert {:error, "unsupported Anthropic reasoning effort" <> _} =
               Reasoning.validate_model_config(:anthropic, effort: :minimal)
    end

    test "rejects providers without a reasoning translation" do
      assert {:error, "is not supported by Clementine's :some_future_provider adapter yet"} =
               Reasoning.validate_model_config(:some_future_provider, :high)
    end
  end
end
