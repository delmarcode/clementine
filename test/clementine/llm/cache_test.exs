defmodule Clementine.LLM.CacheTest do
  use ExUnit.Case, async: false

  import Mox

  alias Clementine.{Model, Models}
  alias Clementine.LLM.{Cache, Policy, ProviderUsage}

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

  @markers [ttls: [:five_minutes, :one_hour]]

  # Models Clementine ships no sheet for, as an app declares them.
  @declared %{
    # Claude on OpenRouter, its TTLs on the model.
    "anthropic/claude-sonnet-5" => [
      vendor: :anthropic,
      context: 1_000_000,
      max_output: 128_000,
      cache: @markers,
      platforms: [openrouter: []]
    ],
    # The same TTLs as a fact of the platform entry.
    "~anthropic/claude-sonnet-latest" => [
      vendor: :anthropic,
      context: 1_000_000,
      max_output: 128_000,
      platforms: [openrouter: [cache: @markers]]
    ],
    # An id that names Anthropic no longer implies markers: the facts do.
    "anthropic/claude-haiku-5-5" => [
      vendor: :anthropic,
      context: 200_000,
      max_output: 64_000,
      platforms: [openrouter: []]
    ],
    "deepseek/deepseek-v3.2" => [
      vendor: :deepseek,
      context: 163_840,
      max_output: 65_536,
      platforms: [openrouter: []]
    ],
    # GPT-5.6 on OpenRouter and Bedrock: their writes are billed for 30
    # minutes, and Clementine sends them no TTL.
    "openai/gpt-5.6-sol" => [
      vendor: :openai,
      context: 1_050_000,
      max_output: 128_000,
      cache: [ttls: [:thirty_minutes]],
      platforms: [openrouter: []]
    ],
    "global.openai.gpt-5.6-sol" => [
      vendor: :openai,
      context: 1_050_000,
      max_output: 128_000,
      cache: [ttls: [:thirty_minutes]],
      platforms: [bedrock: []]
    ],
    "openai.gpt-oss-120b-1:0" => [
      vendor: :openai,
      context: 128_000,
      max_output: 32_768,
      platforms: [bedrock: []]
    ],
    "deepseek-ai/deepseek-v3.2-maas" => [
      vendor: :deepseek,
      context: 163_840,
      max_output: 32_768,
      platforms: [vertex: []]
    ],
    "zai/glm-4.7-maas" => [
      vendor: :zai,
      context: 200_000,
      max_output: 128_000,
      platforms: [vertex: []]
    ],
    "google/gemini-3-pro" => [
      vendor: :google,
      context: 1_048_576,
      max_output: 65_536,
      cache: [ttls: [:five_minutes]],
      platforms: [openrouter: []]
    ],
    "qwen3" => [
      vendor: :qwen,
      context: 32_768,
      max_output: 8_192,
      platforms: [openai_compatible: [base_url: "http://localhost:8000/v1"]]
    ],
    # Claude behind a proxy, under the id the proxy takes.
    "proxy/claude-sonnet-5" => [
      vendor: :anthropic,
      context: 1_000_000,
      max_output: 128_000,
      cache: @markers,
      platforms: [openai_compatible: [id: "claude-sonnet-5", base_url: "http://proxy/v1"]]
    ]
  }

  @five_minutes %{enabled: true, ttl: :five_minutes, markers: true}
  @thirty_minutes %{enabled: true, ttl: :thirty_minutes, markers: false}
  @on_its_own %{enabled: true, ttl: nil, markers: false}

  describe "a model's cache facts" do
    test "decide the default: cache_control markers, a billed TTL, or caching on its own" do
      put_models(@declared)
      assert :ok = Models.validate_config!()

      # Shipped sheets.
      assert cache("claude-sonnet-5") == @five_minutes
      assert cache("claude-haiku-4-5") == @five_minutes
      assert cache("gpt-5") == @on_its_own
      assert cache("gpt-5.5") == @on_its_own
      assert cache("gpt-5.6-sol") == @thirty_minutes
      assert cache("gpt-6.1-sol") == @thirty_minutes

      # Declarations.
      assert cache("anthropic/claude-sonnet-5") == @five_minutes
      assert cache("~anthropic/claude-sonnet-latest") == @five_minutes
      assert cache("anthropic/claude-haiku-5-5") == @on_its_own
      assert cache("deepseek/deepseek-v3.2") == @on_its_own
      assert cache("openai/gpt-5.6-sol") == @thirty_minutes
      assert cache("global.openai.gpt-5.6-sol") == @thirty_minutes
      assert cache("openai.gpt-oss-120b-1:0") == @on_its_own
      assert cache("deepseek-ai/deepseek-v3.2-maas") == @on_its_own
      assert cache("qwen3") == @on_its_own
      assert cache("proxy/claude-sonnet-5") == @five_minutes
    end

    test "false turns caching off, and each model takes the TTLs it offers" do
      put_models(@declared)

      off = %{enabled: false, ttl: nil, markers: false}
      assert cache("claude-sonnet-5", false) == off
      assert cache("gpt-6.1-sol", false) == off
      assert cache("deepseek/deepseek-v3.2", false) == off

      assert cache("claude-sonnet-5", true) == @five_minutes
      assert cache("claude-sonnet-5", ttl: :one_hour) == %{@five_minutes | ttl: :one_hour}
      assert cache("gpt-6.1-sol", ttl: :twelve_hours) == %{@thirty_minutes | ttl: :twelve_hours}
      assert cache("google/gemini-3-pro", []) == @five_minutes
      assert cache("proxy/claude-sonnet-5", ttl: :one_hour) == %{@five_minutes | ttl: :one_hour}
    end

    test "the shipped OpenAI sheets offer prompt_cache_options from GPT-5.6 on" do
      for id <- ["gpt-5.6-sol", "gpt-6-astra", "gpt-6-luna", "gpt-6.1-sol", "gpt-6.1-terra"] do
        assert Models.get!(id).cache.ttls == [:thirty_minutes, :twelve_hours], id
        assert Model.cache_mechanism(Models.get!(id).cache.ttls) == :options, id
      end

      for id <- ["gpt-5", "gpt-5.5", "gpt-5.5-pro", "gpt-5.4-mini", "gpt-4.1"] do
        assert Model.cache_mechanism(Models.get!(id).cache.ttls) == :none, id
      end

      for %Model{lifecycle: %{status: status}} = model <- Models.list(vendor: :anthropic),
          status != :retired do
        assert Model.cache_mechanism(model.cache.ttls) == :markers, model.id
      end
    end

    test "a TTL the model does not offer on its platform is refused" do
      put_models(Map.put(@declared, "claude-haiku-4-5", cache: [ttls: [:five_minutes]]))

      for {id, setting, message} <- [
            {"claude-sonnet-5", [ttl: :twelve_hours],
             "cache: [ttl: :twelve_hours] is not offered; on :anthropic it offers " <>
               "[:five_minutes, :one_hour]"},
            {"gpt-6.1-sol", [ttl: :one_hour],
             "on :openai it offers [:thirty_minutes, :twelve_hours]"},
            # Before GPT-5.6, OpenAI keeps its own retention.
            {"gpt-5.5", [ttl: :thirty_minutes],
             "on :openai it caches on its own, if at all, and takes no TTL"},
            # An override narrows a shipped sheet.
            {"claude-haiku-4-5", [ttl: :one_hour], "on :anthropic it offers [:five_minutes]"},
            {"zai/glm-4.7-maas", [ttl: :five_minutes], "on :vertex it caches on its own"},
            {"deepseek/deepseek-v3.2", [ttl: :one_hour], "on :openrouter it caches on its own"},
            {"anthropic/claude-haiku-5-5", [ttl: :five_minutes],
             "on :openrouter it caches on its own"},
            # OpenRouter and Bedrock bill GPT-5.6's writes for 30 minutes.
            {"global.openai.gpt-5.6-sol", [ttl: :twelve_hours],
             "on :bedrock it offers [:thirty_minutes]"},
            {"claude-sonnet-5", [ttl: "1h"], ~s(cache: [ttl: "1h"] is not offered)},
            {"claude-sonnet-5", [retention: :long],
             "cache: takes true, false, or [ttl: ...], got: [retention: :long]"},
            {"claude-sonnet-5", :on, "cache: takes true, false, or [ttl: ...], got: :on"}
          ] do
        assert {:error, error} = Policy.resolve(id, cache: setting)
        assert error =~ inspect(id), error
        assert error =~ message, error
      end
    end

    test "boot refuses a malformed cache fact, naming the model" do
      base = @declared["deepseek/deepseek-v3.2"]

      for {facts, message} <- [
            {Keyword.put(base, :cache, ttls: [:five_minutes, :thirty_minutes]),
             "mixes cache_control TTLs"},
            {Keyword.put(base, :cache, ttls: [:one_day]), ":one_day"},
            {Keyword.put(base, :cache, retention: :long), "retention"},
            {Keyword.put(base, :platforms, openrouter: [cache: [ttls: :one_hour]]), "ttls"}
          ] do
        put_models(%{"deepseek/deepseek-v3.2" => facts})

        error = assert_raise ArgumentError, fn -> Models.validate_config!() end
        assert error.message =~ ~s(Invalid :clementine, :models entry "deepseek/deepseek-v3.2")
        assert error.message =~ message
      end
    end
  end

  describe "key/1" do
    test "keys a run by its agent and actor: one user's runs and threads share one" do
      turn = %{
        agent_key: "chat",
        actor_type: "user",
        actor_id: 42,
        subject_type: "conversation",
        subject_id: 7,
        run_id: "r1"
      }

      assert "clementine-" <> hash = Cache.key(turn)
      assert hash =~ ~r/\A[0-9a-f]{32}\z/
      assert Cache.key(%{turn | run_id: "r2"}) == Cache.key(turn)
      assert Cache.key(%{turn | subject_id: 8, run_id: "r3"}) == Cache.key(turn)
    end

    test "users and agents never share a key, and no raw host id reaches the provider" do
      turn = %{agent_key: "chat", actor_type: "user", actor_id: "u-42"}

      refute Cache.key(%{turn | actor_id: "u-43"}) == Cache.key(turn)
      refute Cache.key(%{turn | agent_key: "triage"}) == Cache.key(turn)
      refute Cache.key(turn) =~ "u-42"
      refute Cache.key(turn) =~ "chat"
    end

    test "a run without an actor is keyed by its subject, then by its run" do
      task = %{agent_key: "screen", actor_type: nil, actor_id: nil, subject_type: "lead"}

      assert Cache.key(Map.put(task, :subject_id, 1)) == Cache.key(Map.put(task, :subject_id, 1))
      refute Cache.key(Map.put(task, :subject_id, 1)) == Cache.key(Map.put(task, :subject_id, 2))

      assert "clementine-" <> _ = Cache.key(%{agent_key: "sweep", subject_id: nil, run_id: "r1"})

      refute Cache.key(%{agent_key: "sweep", run_id: "r1"}) ==
               Cache.key(%{agent_key: "sweep", run_id: "r2"})

      assert Cache.key(%{}) == nil
      assert Cache.key(%{working_dir: "/tmp"}) == nil
    end
  end

  test "the engine sends the run's key with every model call" do
    key = Cache.key(%{agent_key: "chat", subject_type: "conversation", subject_id: 7})

    expect(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, opts ->
      assert opts[:cache_key] == key

      [
        {:text_delta, "ok"},
        {:message_delta, %{"stop_reason" => "end_turn"},
         %{"input_tokens" => 3, "output_tokens" => 1}}
      ]
    end)

    agent = Clementine.Agent.new(model: "claude-sonnet-5", instructions: "Be brief.")

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

    test "a LiteLLM proxy's top-level Anthropic cache counts are the same parts" do
      assert ProviderUsage.chat_completions(%{
               "prompt_tokens" => 2_006,
               "completion_tokens" => 300,
               "prompt_tokens_details" => %{"cached_tokens" => 1_920},
               "cache_creation_input_tokens" => 80
             }) == %{
               "input_tokens" => 2_006,
               "cache_read_tokens" => 1_920,
               "cache_write_tokens" => 80,
               "output_tokens" => 300
             }

      assert %{"cache_read_tokens" => 500, "cache_write_tokens" => 0} =
               ProviderUsage.chat_completions(%{
                 "prompt_tokens" => 600,
                 "cache_read_input_tokens" => 500,
                 "cache_creation_input_tokens" => 0
               })
    end

    test "parts never exceed their total, and a clamp says so in telemetry" do
      ref = make_ref()
      test = self()

      :telemetry.attach(
        "usage-clamped-#{inspect(ref)}",
        [:clementine, :llm, :usage_clamped],
        fn _event, measurements, metadata, _config ->
          send(test, {:clamped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("usage-clamped-#{inspect(ref)}") end)

      assert %{"input_tokens" => 1_000, "cache_read_tokens" => 1_000} =
               ProviderUsage.chat_completions(
                 %{"prompt_tokens" => 24, "prompt_tokens_details" => %{"cached_tokens" => 1_000}},
                 %{provider: :openai_compatible, model: "qwen3"}
               )

      assert_received {:clamped,
                       %{input_tokens: 24, cache_read_tokens: 1_000, cache_write_tokens: 0},
                       %{provider: :openai_compatible, model: "qwen3"}}

      ProviderUsage.openai(%{
        "input_tokens" => 900,
        "input_tokens_details" => %{"cached_tokens" => 600, "cache_write_tokens" => 100}
      })

      refute_received {:clamped, _, _}
    end
  end

  defp put_models(models), do: Application.put_env(:clementine, :models, models)

  defp cache(id), do: Policy.resolve!(id).cache
  defp cache(id, setting), do: Policy.resolve!(id, cache: setting).cache
end
