defmodule Clementine.ModelsTest do
  # Config is global, and these tests change it.
  use ExUnit.Case, async: false

  alias Clementine.{Model, Models}

  setup do
    original = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, original) end)
    :ok
  end

  defp put_models(models), do: Application.put_env(:clementine, :models, models)

  describe "the shipped sheets" do
    test "cover section 2's models and the legacy ids, each with its source and read date" do
      ids = Enum.map(Models.list(), & &1.id)

      for id <- ~w(claude-fable-5-1 claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5
                   claude-sonnet-5 claude-opus-5 claude-haiku-4-5 claude-opus-4-8
                   claude-sonnet-4-20250514 claude-opus-4-1-20250805
                   gpt-6-astra gpt-6.1-sol gpt-6.1-terra gpt-6-luna gpt-5.6-sol gpt-5) do
        assert id in ids, id
      end

      for model <- Models.list() do
        assert model.source =~ ~r{^https://}, model.id
        assert model.read == ~D[2026-11-01], model.id
      end
    end

    test "carry the facts the clients read" do
      sonnet = Models.get!("claude-sonnet-5-5")
      assert sonnet.thinking.binding == :prefix
      assert sonnet.features.mid_conversation_system
      assert sonnet.thinking.max_effort == %{between_tools: :high}
      assert sonnet.cache == %{min_prefix: 512, ttls: [:five_minutes, :one_hour]}
      assert sonnet.lifecycle.retires_not_before == ~D[2027-09-28]

      older = Models.get!("claude-sonnet-5")
      assert older.thinking.binding == :none
      refute older.features.mid_conversation_system

      assert Models.get!("gpt-6.1-sol").cache.ttls == [:thirty_minutes, :twelve_hours]
      assert Models.get!("gpt-5").cache.ttls == []

      assert %{status: :deprecated, retires_on: ~D[2026-12-11], replacement: "gpt-5.6-sol"} =
               Models.get!("gpt-5").lifecycle
    end

    test "a model before the 4.6 generation goes by its alias and its dated snapshot" do
      alias_sheet = Models.get!("claude-haiku-4-5")
      dated = Models.get!("claude-haiku-4-5-20251001")

      assert %{alias_sheet | id: dated.id, platforms: dated.platforms} == dated
      assert Model.platform_id(dated, :vertex) == "claude-haiku-4-5@20251001"
      assert Model.platform_id(dated, :foundry) == "claude-haiku-4-5"
    end
  end

  describe "get/1, fetch/1, list/1, newest/1" do
    test "an unknown id names the nearest known ones" do
      assert Models.get("claude-sonnet-5-6") == nil
      assert {:error, message} = Models.fetch("claude-sonnet-5-6")
      assert message =~ ~s(unknown model "claude-sonnet-5-6")
      assert message =~ ~s("claude-sonnet-5-5")
      assert_raise ArgumentError, ~r/unknown model/, fn -> Models.get!("nope") end
      assert {:error, _alias_atoms_are_gone} = Models.fetch(:claude_sonnet)
    end

    test "list/1 filters by line, vendor, lifecycle status, and platform" do
      assert Enum.all?(Models.list(line: :sonnet), &(&1.line == :sonnet))
      assert Enum.all?(Models.list(vendor: :openai), &(&1.vendor == :openai))
      assert "gpt-5" in Enum.map(Models.list(lifecycle: :deprecated), & &1.id)
      assert "claude-sonnet-4-20250514" in Enum.map(Models.list(lifecycle: :retired), & &1.id)
      refute "gpt-6.1-sol" in Enum.map(Models.list(platform: :bedrock), & &1.id)
    end

    test "newest/1 is the active model in a line released last" do
      assert Models.newest(:sonnet).id == "claude-sonnet-5-5"
      assert Models.newest(:haiku).id == "claude-haiku-5-5"
      assert Models.newest(:sol).id == "gpt-6.1-sol"
      assert Models.newest(:no_such_line) == nil
    end
  end

  describe "for_platform/2 and default_platform/1" do
    test "merges a platform's deltas and gives its id" do
      assert {:ok, bedrock} = Models.for_platform("claude-sonnet-5-5", :bedrock)
      assert bedrock.platform == :bedrock
      assert Model.platform_id(bedrock) == "anthropic.claude-sonnet-5-5"

      assert {:error, message} = Models.for_platform("gpt-6.1-sol", :bedrock)
      assert message =~ "not served on :bedrock"
    end

    test "the vendor's own platform, else the first one Clementine can send to" do
      assert Models.default_platform(Models.get!("claude-opus-5-5")) == :anthropic
      assert Models.default_platform(Models.get!("gpt-6-astra")) == :openai

      put_models(%{
        "qwen3-ft" => [
          vendor: :qwen,
          context: 128_000,
          max_output: 16_000,
          platforms: [foundry: [], openai_compatible: [base_url: "http://localhost:8000/v1"]]
        ]
      })

      assert Models.default_platform(Models.get!("qwen3-ft")) == :openai_compatible
    end
  end

  describe "config :clementine, :models" do
    test "an override merges key by key over the shipped sheet" do
      put_models(%{
        "claude-sonnet-5" => [
          features: [tool_search: false],
          cache: [ttls: [:five_minutes]],
          platforms: [bedrock: [id: "us.anthropic.claude-sonnet-5"]]
        ]
      })

      model = Models.get!("claude-sonnet-5")
      refute model.features.tool_search
      assert model.features.structured_outputs
      assert model.cache == %{min_prefix: 1024, ttls: [:five_minutes]}
      assert Model.platform_id(model, :bedrock) == "us.anthropic.claude-sonnet-5"
      assert model.platforms[:bedrock].lifecycle == :partner
      assert model.thinking.default_effort == :high
    end

    test "a declaration is a model of the app's own, with the defaults of one that does not think" do
      put_models(%{
        "deepseek/deepseek-v3.2" => [
          vendor: :deepseek,
          context: 163_840,
          max_output: 16_000,
          platforms: [openrouter: []]
        ]
      })

      model = Models.get!("deepseek/deepseek-v3.2")
      assert %{default: :off, types: [:off], efforts: [], binding: :none} = model.thinking
      assert model.cache == %{min_prefix: nil, ttls: []}
      refute model.features.structured_outputs
      assert "deepseek/deepseek-v3.2" in Enum.map(Models.list(vendor: :deepseek), & &1.id)
      assert :ok = Models.validate_config!()
    end

    test "validate_config!/0 names the id of what is wrong" do
      for {models, pattern} <- [
            {[claude: [provider: :anthropic]], ~r/expected a map from model id/},
            {%{"claude-sonnet-5" => [thinking: [types: [:sometimes]]]}, ~r/"claude-sonnet-5"/},
            {%{"mine" => [vendor: :me, platforms: [openrouter: []]]},
             ~r/context: and max_output:/},
            {%{"mine" => [vendor: :me, context: 1, max_output: 1, platforms: [tinker: []]]},
             ~r/does not know/},
            {%{"mine" => [vendor: :me, context: 1, max_output: 1, platforms: [foundry: []]]},
             ~r/Clementine can send to/},
            {%{"claude-sonnet-5" => [id: "other"]}, ~r/no other id/},
            {%{"claude-sonnet-5" => [platforms: [anthropic: [base_url: "http://x"]]]},
             ~r/base_url: and api_key: go only on/},
            {%{
               "claude-sonnet-5" => [
                 prices: [
                   currency: "USD",
                   input: 1,
                   output: 1,
                   cache_read: 0,
                   cache_write: [twelve_hours: 1]
                 ]
               ]
             }, ~r/does not offer/}
          ] do
        put_models(models)
        assert_raise ArgumentError, pattern, fn -> Models.validate_config!() end
      end
    end
  end

  describe "the sheets added and corrected on 2026-11-01" do
    test "every active vendor model has a sheet" do
      for id <- ~w(claude-opus-4-7 claude-fable-5 claude-mythos-5 claude-mythos-preview
                   gpt-6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.4 gpt-5.4-pro gpt-5.4-nano
                   gpt-5.2 gpt-5.2-pro gpt-5.1 gpt-5-mini gpt-5-nano gpt-5-pro gpt-4.1-mini) do
        assert %Model{} = Models.get(id), id
      end

      assert %Model{lifecycle: %{status: :deprecated, replacement: "gpt-6-sol"}} =
               Models.get("gpt-5.1")

      for {old, new} <- [{"gpt-5-mini", "gpt-5.6-terra"}, {"gpt-5-nano", "gpt-5.6-luna"}] do
        assert Models.get(old).lifecycle.replacement == new
      end

      assert %Model{
               thinking: %{default: :off, types: [:adaptive, :off]},
               cache: %{min_prefix: 2048}
             } =
               Models.get("claude-opus-4-7")

      assert %Model{thinking: %{types: [:adaptive], default_effort: :high, binding: :none}} =
               Models.get("claude-fable-5")
    end

    test "a retired id names its replacement" do
      for {id, replacement} <- [
            {"claude-opus-4-20250514", "claude-opus-4-8"},
            {"claude-3-7-sonnet-20250219", "claude-sonnet-5-5"},
            {"claude-3-5-haiku-20241022", "claude-haiku-4-5-20251001"},
            {"o4-mini", "gpt-5.6-terra"},
            {"gpt-4.1-nano", "gpt-5.6-luna"}
          ] do
        assert {:error, message} = Clementine.LLM.Policy.resolve(id)
        assert message =~ ~s(is retired; its replacement is "#{replacement}"), id
      end
    end

    test "Foundry takes no mid-conversation system messages" do
      for id <- ~w(claude-sonnet-5-5 claude-opus-4-8 claude-fable-5-1 claude-mythos-5-1) do
        assert Models.get(id).features.mid_conversation_system, id
        assert {:ok, foundry} = Models.for_platform(id, :foundry)
        refute foundry.features.mid_conversation_system, id
      end
    end

    test "Bedrock entries are its Messages endpoint's, anthropic.<id>" do
      for model <- Models.list(vendor: :anthropic), entry = model.platforms[:bedrock] do
        assert entry.id == "anthropic." <> model.id, model.id
      end

      # InvokeModel only: no entry.
      for id <- ~w(claude-opus-4-6 claude-sonnet-4-6 claude-opus-4-5 claude-sonnet-4-5
                   claude-haiku-4-5-20251001 claude-opus-4-1-20250805) do
        refute Keyword.has_key?(Models.get(id).platforms, :bedrock), id
      end

      assert Models.get("claude-haiku-4-5").platforms[:bedrock].id == "anthropic.claude-haiku-4-5"

      assert Models.get("claude-mythos-5-1").platforms[:bedrock].id ==
               "anthropic.claude-mythos-5-1"
    end
  end

  describe "based_on: a new model the day it ships" do
    test "starts from the shipped sheet, under the new id" do
      put_models(%{
        "claude-sonnet-6" => [
          based_on: "claude-sonnet-5-5",
          display_name: "Claude Sonnet 6",
          thinking: [default_effort: :medium]
        ]
      })

      assert :ok = Models.validate_config!()
      base = Models.get!("claude-sonnet-5-5")
      model = Models.get!("claude-sonnet-6")

      assert model.id == "claude-sonnet-6"
      assert model.display_name == "Claude Sonnet 6"
      assert model.thinking == %{base.thinking | default_effort: :medium}
      assert model.features == base.features
      assert model.cache == base.cache
      assert model.rejects == base.rejects

      # What names the base model does not carry over.
      assert model.lifecycle == %{base.lifecycle | retires_not_before: nil}
      assert model.released_on == nil
      assert model.source == nil

      # Each platform takes the new id.
      assert Model.platform_id(model, :anthropic) == "claude-sonnet-6"
      assert Model.platform_id(model, :bedrock) == "claude-sonnet-6"

      assert {:ok, policy} = Clementine.LLM.Policy.resolve("claude-sonnet-6", effort: :xhigh)
      assert policy.thinking == :adaptive
      assert policy.model.thinking.binding == :prefix
    end

    test "names a shipped sheet" do
      put_models(%{"claude-sonnet-6" => [based_on: "claude-sonnet-9"]})

      assert_raise ArgumentError,
                   ~r/based_on: names "claude-sonnet-9", which is not a shipped sheet/,
                   fn ->
                     Models.validate_config!()
                   end
    end
  end

  describe "a declared effort level" do
    test "goes to the wire as written, and ranks where the sheet lists it" do
      put_models(%{
        "claude-sonnet-6" => [
          based_on: "claude-sonnet-5-5",
          thinking: [
            efforts: [:low, :medium, :high, :xhigh, :max, :ultra],
            max_effort: [between_tools: :max]
          ]
        ]
      })

      assert {:ok, policy} = Clementine.LLM.Policy.resolve("claude-sonnet-6", effort: :ultra)
      assert Clementine.LLM.Reasoning.anthropic(policy)["output_config"] == %{"effort" => "ultra"}

      assert {:error, message} =
               Clementine.LLM.Policy.resolve("claude-sonnet-6",
                 thinking: :between_tools,
                 effort: :ultra
               )

      assert message =~ "takes effort up to :max, got: :ultra"

      put_models(%{
        "claude-sonnet-6" => [based_on: "claude-sonnet-5-5", thinking: [efforts: ["ultra"]]]
      })

      assert {:error, message} = Models.fetch("claude-sonnet-6")
      assert message =~ "expected an effort level atom"
    end
  end

  describe "a literal API key on a declared platform" do
    test "is redacted wherever the model is inspected" do
      put_models(%{
        "qwen3" => [
          vendor: :qwen,
          context: 32_000,
          max_output: 8_000,
          platforms: [
            openai_compatible: [base_url: "http://localhost:1/v1", api_key: "sk-not-a-real-key"]
          ]
        ],
        "qwen3-env" => [
          vendor: :qwen,
          context: 32_000,
          max_output: 8_000,
          platforms: [
            openai_compatible: [base_url: "http://localhost:1/v1", api_key: {:system, "QWEN_KEY"}]
          ]
        ]
      })

      model = Models.get!("qwen3")
      assert model.platforms[:openai_compatible].api_key == "sk-not-a-real-key"
      refute inspect(model) =~ "sk-not-a-real-key"
      assert inspect(model) =~ "**redacted**"
      refute inspect(Clementine.LLM.Policy.resolve!("qwen3")) =~ "sk-not-a-real-key"
      assert inspect(Models.get!("qwen3-env")) =~ "QWEN_KEY"

      # A malformed entry's error does not print it either.
      put_models(%{"qwen3" => %{platforms: [openai_compatible: [api_key: "sk-not-a-real-key"]]}})
      assert {:error, message} = Models.fetch("qwen3")
      refute message =~ "sk-not-a-real-key"
    end
  end

  describe "a declared or overridden model" do
    test "is rebuilt when its config changes, and kept while it does not" do
      put_models(%{"claude-opus-5-5" => [display_name: "Opus A"]})
      assert Models.get!("claude-opus-5-5").display_name == "Opus A"
      assert {Clementine.Models, "claude-opus-5-5"} in Process.get_keys()

      put_models(%{"claude-opus-5-5" => [display_name: "Opus B"]})
      assert Models.get!("claude-opus-5-5").display_name == "Opus B"

      put_models(%{})
      assert Models.get!("claude-opus-5-5").display_name == "Claude Opus 5.5"
    end
  end
end
