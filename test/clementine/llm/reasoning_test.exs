defmodule Clementine.LLM.ReasoningTest do
  @moduledoc """
  Each wire's thinking fields for a resolved policy (`Clementine.LLM.Policy`)
  on a real model sheet: what goes, and what is left to the model's own
  default.
  """

  # Declared models live in application config.
  use ExUnit.Case, async: false

  alias Clementine.LLM.{Policy, Reasoning}

  setup do
    previous = Application.get_env(:clementine, :models)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:clementine, :models, previous),
        else: Application.delete_env(:clementine, :models)
    end)
  end

  defp anthropic(id, opts \\ []), do: Reasoning.anthropic(Policy.resolve!(id, opts))
  defp openai(id, opts \\ []), do: Reasoning.openai(Policy.resolve!(id, opts))
  defp chat(id, opts \\ []), do: Reasoning.chat_completions(Policy.resolve!(id, opts))

  defp declare(models), do: Application.put_env(:clementine, :models, models)

  describe "anthropic/1: effort" do
    test "the model's default effort always goes, so a recalibrated default never moves an agent" do
      assert anthropic("claude-sonnet-5-5") == %{"output_config" => %{"effort" => "high"}}
      assert anthropic("claude-opus-5-5") == %{"output_config" => %{"effort" => "medium"}}
      assert anthropic("claude-haiku-5-5") == %{"output_config" => %{"effort" => "medium"}}
    end

    test "the agent's effort replaces the default" do
      assert anthropic("claude-sonnet-5-5", effort: :low) ==
               %{"output_config" => %{"effort" => "low"}}

      assert anthropic("claude-opus-5-5", effort: :max) ==
               %{"output_config" => %{"effort" => "max"}}
    end

    test "a model with no effort levels sends none" do
      assert anthropic("claude-haiku-4-5") == %{}
      assert anthropic("claude-sonnet-4-5-20250929") == %{}
    end
  end

  describe "anthropic/1: thinking :off" do
    test "is disabled only on a model that thinks adaptively by default" do
      assert anthropic("claude-sonnet-5", thinking: :off) == %{
               "thinking" => %{"type" => "disabled"},
               "output_config" => %{"effort" => "high"}
             }

      assert anthropic("claude-haiku-5-5", thinking: :off) == %{
               "thinking" => %{"type" => "disabled"},
               "output_config" => %{"effort" => "medium"}
             }
    end

    test "sends no thinking field on a model that does not think by default" do
      assert anthropic("claude-opus-4-8", thinking: :off) ==
               %{"output_config" => %{"effort" => "high"}}

      assert anthropic("claude-opus-4-6", thinking: :off) ==
               %{"output_config" => %{"effort" => "high"}}

      assert anthropic("claude-haiku-4-5", thinking: :off) == %{}
    end
  end

  describe "anthropic/1: thinking :adaptive" do
    test "sends nothing where the model thinks adaptively by default" do
      assert anthropic("claude-sonnet-5", thinking: :adaptive) ==
               %{"output_config" => %{"effort" => "high"}}

      assert anthropic("claude-sonnet-5-5", thinking: :adaptive, display: :omitted) ==
               %{"output_config" => %{"effort" => "high"}}
    end

    test "is the default, and goes explicitly, on a model that does not think by default" do
      assert anthropic("claude-opus-4-8") == %{
               "thinking" => %{"type" => "adaptive"},
               "output_config" => %{"effort" => "high"}
             }

      # Claude Opus 4.6 summarizes by default, and an agent keeps the
      # model's own display unless it asks for another.
      assert anthropic("claude-opus-4-6") == %{
               "thinking" => %{"type" => "adaptive"},
               "output_config" => %{"effort" => "high"}
             }

      assert anthropic("claude-opus-4-6", display: :omitted) == %{
               "thinking" => %{"type" => "adaptive", "display" => "omitted"},
               "output_config" => %{"effort" => "high"}
             }

      assert anthropic("claude-opus-4-6", display: :summarized) == %{
               "thinking" => %{"type" => "adaptive"},
               "output_config" => %{"effort" => "high"}
             }
    end

    test "carries a display other than the model's own" do
      assert anthropic("claude-sonnet-5-5", display: :updates) == %{
               "thinking" => %{"type" => "adaptive", "display" => "updates"},
               "output_config" => %{"effort" => "high"}
             }

      assert anthropic("claude-sonnet-5-5", display: :summarized) == %{
               "thinking" => %{"type" => "adaptive", "display" => "summarized"},
               "output_config" => %{"effort" => "high"}
             }
    end

    test "carries the binding controls when the agent asks for them" do
      assert anthropic("claude-sonnet-5-5", provider_options: [prefix_mismatch: :drop_block]) ==
               %{
                 "thinking" => %{
                   "type" => "adaptive",
                   "block_binding" => %{"prefix_mismatch_behavior" => "drop_block"}
                 },
                 "output_config" => %{"effort" => "high"}
               }

      assert anthropic("claude-opus-5-5",
               display: :updates,
               provider_options: [prefix_mismatch: :error]
             ) == %{
               "thinking" => %{
                 "type" => "adaptive",
                 "display" => "updates",
                 "block_binding" => %{"prefix_mismatch_behavior" => "error"}
               },
               "output_config" => %{"effort" => "medium"}
             }
    end
  end

  describe "anthropic/1: thinking :between_tools" do
    test "takes no other thinking field, and its effort goes" do
      assert anthropic("claude-sonnet-5-5", thinking: :between_tools) == %{
               "thinking" => %{"type" => "between_tools"},
               "output_config" => %{"effort" => "high"}
             }

      assert anthropic("claude-sonnet-5-5", thinking: :between_tools, effort: :low) == %{
               "thinking" => %{"type" => "between_tools"},
               "output_config" => %{"effort" => "low"}
             }
    end
  end

  describe "anthropic/1: thinking :enabled" do
    test "carries its budget, which alone implies it" do
      assert anthropic("claude-opus-4-6", provider_options: [budget_tokens: 2048]) == %{
               "thinking" => %{
                 "type" => "enabled",
                 "budget_tokens" => 2048
               },
               "output_config" => %{"effort" => "high"}
             }

      assert anthropic("claude-haiku-4-5",
               thinking: :enabled,
               provider_options: [budget_tokens: 4096]
             ) == %{
               "thinking" => %{
                 "type" => "enabled",
                 "budget_tokens" => 4096
               }
             }
    end

    test "leaves out the display where it is the model's own" do
      assert anthropic("claude-haiku-4-5",
               display: :summarized,
               provider_options: [budget_tokens: 4096]
             ) == %{"thinking" => %{"type" => "enabled", "budget_tokens" => 4096}}
    end
  end

  describe "openai/1" do
    test "sends the model's default effort, or none where it has none" do
      assert openai("gpt-6.1-sol") == %{"reasoning" => %{"effort" => "medium"}}
      assert openai("gpt-5.4-mini") == %{"reasoning" => %{"effort" => "none"}}
      assert openai("gpt-6-astra") == %{}
      assert openai("gpt-4.1") == %{}
    end

    test "sends the agent's effort and its summary options" do
      assert openai("gpt-6.1-terra", effort: :none) == %{"reasoning" => %{"effort" => "none"}}

      assert openai("gpt-6.1-sol", effort: :high, provider_options: [summary: :auto]) == %{
               "reasoning" => %{"effort" => "high", "summary" => "auto"}
             }

      assert openai("gpt-6-astra", provider_options: [summary: :concise]) ==
               %{"reasoning" => %{"summary" => "concise"}}
    end
  end

  describe "chat_completions/1 on OpenRouter" do
    setup do
      declare(%{
        "deepseek/deepseek-v3.2" => [
          vendor: :deepseek,
          context: 163_840,
          max_output: 16_000,
          thinking: [
            default: :adaptive,
            types: [:adaptive],
            efforts: [:low, :medium, :high],
            default_effort: :medium
          ],
          platforms: [openrouter: []]
        ],
        "moonshotai/kimi-k3" => [
          vendor: :moonshot,
          context: 256_000,
          max_output: 32_000,
          thinking: [default: :adaptive, types: [:adaptive]],
          platforms: [openrouter: []]
        ],
        "mistralai/mistral-medium-4" => [
          vendor: :mistral,
          context: 128_000,
          max_output: 32_000,
          platforms: [openrouter: []]
        ]
      })
    end

    test "sends the effort in the reasoning object" do
      assert chat("deepseek/deepseek-v3.2") == %{"reasoning" => %{"effort" => "medium"}}

      assert chat("deepseek/deepseek-v3.2", effort: :high) ==
               %{"reasoning" => %{"effort" => "high"}}
    end

    test "carries OpenRouter's own reasoning options" do
      assert chat("deepseek/deepseek-v3.2",
               effort: :low,
               provider_options: [exclude: false, enabled: true]
             ) == %{"reasoning" => %{"effort" => "low", "exclude" => false, "enabled" => true}}

      assert chat("moonshotai/kimi-k3", provider_options: [max_tokens: 2000, exclude: true]) ==
               %{"reasoning" => %{"max_tokens" => 2000, "exclude" => true}}
    end

    test "sends no reasoning object for a model with no effort and no options" do
      assert chat("moonshotai/kimi-k3") == %{}
      assert chat("mistralai/mistral-medium-4") == %{}
    end
  end

  describe "chat_completions/1 on other platforms" do
    for platform <- [:bedrock, :vertex, :openai_compatible] do
      test "#{platform} sends the effort as reasoning_effort" do
        platform = unquote(platform)

        declare(%{
          "reasoner" => [
            vendor: :acme,
            context: 128_000,
            max_output: 16_000,
            thinking: [
              default: :adaptive,
              types: [:adaptive],
              efforts: [:minimal, :low, :medium, :high],
              default_effort: :low
            ],
            platforms: [{platform, []}]
          ],
          "plain" => [
            vendor: :acme,
            context: 128_000,
            max_output: 16_000,
            platforms: [{platform, []}]
          ]
        })

        assert %Policy{platform: ^platform} = Policy.resolve!("reasoner")
        assert chat("reasoner") == %{"reasoning_effort" => "low"}
        assert chat("reasoner", effort: :minimal) == %{"reasoning_effort" => "minimal"}
        assert chat("plain") == %{}
      end
    end
  end
end
