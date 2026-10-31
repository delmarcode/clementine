defmodule Clementine.LLM.CacheTest do
  use ExUnit.Case, async: false

  import Mox

  alias Clementine.LLM.{Cache, ModelRegistry, ProviderUsage}

  setup :verify_on_exit!

  setup do
    prev_models = Application.get_env(:clementine, :models)

    on_exit(fn ->
      if prev_models,
        do: Application.put_env(:clementine, :models, prev_models),
        else: Application.delete_env(:clementine, :models)
    end)

    :ok
  end

  describe "the catalog's cache: key" do
    test "defaults per provider when an alias sets none" do
      put_models(
        claude: [provider: :anthropic, id: "claude-sonnet-5"],
        gpt_5: [provider: :openai, id: "gpt-5"],
        gpt_5_6: [provider: :openai, id: "gpt-5.6-sol"],
        or_claude: [provider: :openrouter, id: "anthropic/claude-sonnet-5"],
        or_deepseek: [provider: :openrouter, id: "deepseek/deepseek-v3.2"],
        bedrock: [provider: :bedrock, id: "openai.gpt-oss-120b-1:0"],
        vertex: [provider: :vertex, id: "deepseek-ai/deepseek-v3.2-maas"],
        vllm: [provider: :openai_compatible, base_url: "http://localhost:8000/v1", id: "qwen3"]
      )

      assert :ok = ModelRegistry.validate_config!()

      assert cache(:claude) == %{enabled: true, ttl: :five_minutes, markers: true}
      assert cache(:gpt_5) == %{enabled: true, ttl: nil, markers: false}
      assert cache(:gpt_5_6) == %{enabled: true, ttl: :thirty_minutes, markers: false}
      assert cache(:or_claude) == %{enabled: true, ttl: :five_minutes, markers: true}
      assert cache(:or_deepseek) == %{enabled: true, ttl: nil, markers: false}
      assert cache(:bedrock) == %{enabled: true, ttl: nil, markers: false}
      assert cache(:vertex) == %{enabled: true, ttl: nil, markers: false}
      assert cache(:vllm) == %{enabled: true, ttl: nil, markers: false}
    end

    test "a direct tuple reference takes its provider's default" do
      assert ModelRegistry.resolve!({:anthropic, "claude-sonnet-5"}).cache ==
               %{enabled: true, ttl: :five_minutes, markers: true}
    end

    test "false turns caching off, and each provider takes its own TTLs" do
      put_models(
        off: [provider: :anthropic, id: "claude-sonnet-5", cache: false],
        claude_hour: [provider: :anthropic, id: "claude-sonnet-5", cache: [ttl: :one_hour]],
        gpt_long: [provider: :openai, id: "gpt-6.1-sol", cache: [ttl: :twelve_hours]],
        or_gemini: [provider: :openrouter, id: "google/gemini-3-pro", cache: [markers: true]],
        proxy: [
          provider: :openai_compatible,
          base_url: "http://proxy/v1",
          id: "claude-sonnet-5",
          cache: [markers: true, ttl: :one_hour]
        ]
      )

      assert :ok = ModelRegistry.validate_config!()
      assert cache(:off) == %{enabled: false, ttl: nil, markers: false}
      assert cache(:claude_hour) == %{enabled: true, ttl: :one_hour, markers: true}
      assert cache(:gpt_long) == %{enabled: true, ttl: :twelve_hours, markers: false}
      assert cache(:or_gemini) == %{enabled: true, ttl: :five_minutes, markers: true}
      assert cache(:proxy) == %{enabled: true, ttl: :one_hour, markers: true}
    end

    test "boot refuses what a provider cannot honour" do
      for {config, message} <- [
            {[provider: :anthropic, id: "claude-sonnet-5", cache: [ttl: :twelve_hours]],
             "expected :ttl with cache_control markers"},
            {[provider: :openai, id: "gpt-5.6-sol", cache: [ttl: :one_hour]],
             "expected :ttl on :openai"},
            {[provider: :openai, id: "gpt-5.5", cache: [ttl: :thirty_minutes]],
             ":ttl needs GPT-5.6 or later"},
            {[provider: :anthropic, id: "claude-sonnet-5", cache: [markers: false]],
             ":markers is only for :openrouter and :openai_compatible"},
            {[provider: :bedrock, id: "openai.gpt-oss-120b-1:0", cache: [markers: true]],
             ":markers is only for"},
            {[provider: :vertex, id: "zai/glm-4.7-maas", cache: [ttl: :five_minutes]],
             ":ttl needs cache_control markers"},
            {[provider: :openrouter, id: "deepseek/deepseek-v3.2", cache: [ttl: :one_hour]],
             ":ttl needs cache_control markers"},
            {[provider: :anthropic, id: "claude-sonnet-5", cache: [ttl: "1h"]],
             "expected :ttl to be one of"},
            {[provider: :anthropic, id: "claude-sonnet-5", cache: [retention: :long]],
             "unknown key :retention"},
            {[provider: :anthropic, id: "claude-sonnet-5", cache: :on],
             "expected true, false, or a keyword list"}
          ] do
        put_models(bad: config)

        error = assert_raise ArgumentError, fn -> ModelRegistry.validate_config!() end
        assert error.message =~ "Invalid model config for :bad"
        assert error.message =~ message
      end
    end
  end

  test "prompt_cache_options is documented for GPT-5.6 and later" do
    for id <- ["gpt-5.6-sol", "gpt-5.6", "gpt-5.10-mini", "gpt-6-astra", "gpt-6.1-terra"],
        do: assert(Cache.prompt_cache_options?(id), id)

    for id <- ["gpt-5", "gpt-5.5-pro", "gpt-4.1", "o3", "o4-mini", "chatgpt-4o-latest"],
        do: refute(Cache.prompt_cache_options?(id), id)
  end

  describe "key/1" do
    test "keys a run by its agent and subject, so a thread's turns share one" do
      turn = %{agent_key: "chat", subject_type: "conversation", subject_id: 42, run_id: "r1"}
      next_turn = %{turn | run_id: "r2"}

      assert "clementine-" <> hash = Cache.key(turn)
      assert hash =~ ~r/\A[0-9a-f]{32}\z/
      assert Cache.key(next_turn) == Cache.key(turn)
    end

    test "tenants and agents never share a key, and no host id reaches the provider" do
      turn = %{agent_key: "chat", subject_type: "conversation", subject_id: "c-42"}

      refute Cache.key(%{turn | subject_id: "c-43"}) == Cache.key(turn)
      refute Cache.key(%{turn | agent_key: "triage"}) == Cache.key(turn)
      refute Cache.key(turn) =~ "c-42"
      refute Cache.key(turn) =~ "chat"
    end

    test "a run without a subject is keyed by its run; one with neither gets none" do
      assert "clementine-" <> _ = Cache.key(%{agent_key: "sweep", subject_id: nil, run_id: "r1"})

      refute Cache.key(%{agent_key: "sweep", run_id: "r1"}) ==
               Cache.key(%{agent_key: "sweep", run_id: "r2"})

      assert Cache.key(%{}) == nil
      assert Cache.key(%{working_dir: "/tmp"}) == nil
    end
  end

  test "the engine sends the lane's key with every model call" do
    key = Cache.key(%{agent_key: "chat", subject_type: "conversation", subject_id: 7})

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, opts ->
      assert opts[:cache_key] == key

      [
        {:text_delta, "ok"},
        {:message_delta, %{"stop_reason" => "end_turn"},
         %{"input_tokens" => 3, "output_tokens" => 1}}
      ]
    end)

    agent = Clementine.Agent.new(model: :claude_sonnet, instructions: "Be brief.")

    assert {:ok, %Clementine.Result.Completed{}} =
             Clementine.run(agent, "Hi",
               context: %{agent_key: "chat", subject_type: "conversation", subject_id: 7}
             )
  end

  describe "ProviderUsage" do
    test "Anthropic's input_tokens gains the cache reads and writes it leaves out" do
      assert ProviderUsage.anthropic(%{
               "input_tokens" => 50,
               "cache_creation_input_tokens" => 200,
               "cache_read_input_tokens" => 1_000,
               "cache_creation" => %{"ephemeral_5m_input_tokens" => 200},
               "output_tokens" => 9
             }) == %{
               "input_tokens" => 1_250,
               "cache_read_tokens" => 1_000,
               "cache_write_tokens" => 200,
               "output_tokens" => 9
             }
    end

    test "a count the provider did not report is left out, so later usage merges over it" do
      assert ProviderUsage.anthropic(%{"output_tokens" => 30}) == %{"output_tokens" => 30}
      assert ProviderUsage.openai(%{"output_tokens" => 30}) == %{"output_tokens" => 30}
      assert ProviderUsage.chat_completions(%{"total_tokens" => 7}) == %{}
      assert ProviderUsage.anthropic(nil) == %{}
    end

    test "OpenAI and Chat Completions totals already hold their cache parts" do
      assert ProviderUsage.openai(%{
               "input_tokens" => 900,
               "input_tokens_details" => %{"cached_tokens" => 600, "cache_write_tokens" => 100},
               "output_tokens" => 4
             }) == %{
               "input_tokens" => 900,
               "cache_read_tokens" => 600,
               "cache_write_tokens" => 100,
               "output_tokens" => 4
             }

      assert ProviderUsage.chat_completions(%{
               "prompt_tokens" => 900,
               "prompt_tokens_details" => nil,
               "completion_tokens" => 4
             }) == %{
               "input_tokens" => 900,
               "cache_read_tokens" => 0,
               "cache_write_tokens" => 0,
               "output_tokens" => 4
             }
    end

    test "parts never exceed their total" do
      assert %{"input_tokens" => 1_000, "cache_read_tokens" => 1_000} =
               ProviderUsage.chat_completions(%{
                 "prompt_tokens" => 24,
                 "prompt_tokens_details" => %{"cached_tokens" => 1_000}
               })
    end
  end

  defp put_models(models), do: Application.put_env(:clementine, :models, models)
  defp cache(alias_name), do: ModelRegistry.resolve!(alias_name).cache
end
