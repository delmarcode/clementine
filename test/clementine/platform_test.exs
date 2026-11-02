defmodule Clementine.PlatformTest do
  use ExUnit.Case, async: false

  alias Clementine.{Models, Platform}

  setup do
    platforms = Application.get_env(:clementine, :platforms)
    models = Application.get_env(:clementine, :models)

    on_exit(fn ->
      Application.put_env(:clementine, :platforms, platforms)
      Application.put_env(:clementine, :models, models)
    end)

    Application.put_env(:clementine, :platforms, [])
    :ok
  end

  defp put(platforms), do: Application.put_env(:clementine, :platforms, platforms)

  describe "url/2: each platform's documented endpoint" do
    test "with no base_url" do
      put(
        bedrock: [region: "us-east-1", api_key: "k"],
        foundry: [resource: "example-resource", api_key: "k"],
        vertex: [project: "proj", region: "us-central1", access_token: "t"]
      )

      for {name, protocol, url} <- [
            {:anthropic, :messages, "https://api.anthropic.com/v1/messages"},
            {:openai, :responses, "https://api.openai.com/v1/responses"},
            {:openrouter, :chat_completions, "https://openrouter.ai/api/v1/chat/completions"},
            {:bedrock, :messages,
             "https://bedrock-mantle.us-east-1.api.aws/anthropic/v1/messages"},
            {:bedrock, :chat_completions,
             "https://bedrock-mantle.us-east-1.api.aws/v1/chat/completions"},
            {:foundry, :messages,
             "https://example-resource.services.ai.azure.com/anthropic/v1/messages"},
            {:vertex, :chat_completions,
             "https://us-central1-aiplatform.googleapis.com/v1/projects/proj/locations/" <>
               "us-central1/endpoints/openapi/chat/completions"}
          ] do
        assert Platform.url(Platform.fetch!(name), protocol) == url
      end
    end

    test "a base_url is the part before the wire's path" do
      put(
        anthropic: [api_key: "k", base_url: "https://proxy.example/"],
        bedrock: [api_key: "k", base_url: "https://bedrock-mantle.eu-west-1.api.aws"],
        foundry: [
          api_key: "k",
          base_url: "https://example-resource.services.ai.azure.com/anthropic"
        ],
        tinker: [protocol: :chat_completions, base_url: "https://tinker.example/oai/api/v1"]
      )

      assert Platform.url(Platform.fetch!(:anthropic), :messages) ==
               "https://proxy.example/v1/messages"

      assert Platform.url(Platform.fetch!(:bedrock), :messages) ==
               "https://bedrock-mantle.eu-west-1.api.aws/anthropic/v1/messages"

      assert Platform.url(Platform.fetch!(:foundry), :messages) ==
               "https://example-resource.services.ai.azure.com/anthropic/v1/messages"

      assert Platform.url(Platform.fetch!(:tinker), :chat_completions) ==
               "https://tinker.example/oai/api/v1/chat/completions"
    end
  end

  describe "auth_headers/2" do
    test "each platform's credential header, resolved per request" do
      System.put_env("CLEMENTINE_PLATFORM_TEST_KEY", "from-env")
      on_exit(fn -> System.delete_env("CLEMENTINE_PLATFORM_TEST_KEY") end)

      put(
        anthropic: [api_key: {:system, "CLEMENTINE_PLATFORM_TEST_KEY"}],
        bedrock: [region: "us-east-1", api_key: {__MODULE__, :token, ["bedrock"]}],
        foundry: [resource: "r", api_key: "azure-key"],
        openai_compatible: [base_url: "http://localhost:1/v1"]
      )

      assert Platform.auth_headers(Platform.fetch!(:anthropic), :messages) ==
               [{"x-api-key", "from-env"}]

      # One Bedrock API key: x-api-key on Messages, a bearer on Chat
      # Completions.
      assert Platform.auth_headers(Platform.fetch!(:bedrock), :messages) ==
               [{"x-api-key", "bedrock-token"}]

      assert Platform.auth_headers(Platform.fetch!(:bedrock), :chat_completions) ==
               [{"authorization", "Bearer bedrock-token"}]

      assert Platform.auth_headers(Platform.fetch!(:foundry), :messages) ==
               [{"api-key", "azure-key"}]

      assert Platform.auth_headers(Platform.fetch!(:openai_compatible), :chat_completions) == []

      put(foundry: [resource: "r", access_token: {__MODULE__, :token, ["entra"]}])

      assert Platform.auth_headers(Platform.fetch!(:foundry), :messages) ==
               [{"authorization", "Bearer entra-token"}]
    end

    test "a credential that resolves to nothing raises, naming the key and never a value" do
      put(anthropic: [api_key: {:system, "CLEMENTINE_PLATFORM_TEST_UNSET"}])

      assert_raise ArgumentError,
                   ~r/anthropic: \[api_key: ...\] resolved to no value: the environment variable CLEMENTINE_PLATFORM_TEST_UNSET/,
                   fn -> Platform.auth_headers(Platform.fetch!(:anthropic), :messages) end

      put([])

      assert_raise ArgumentError, ~r/anthropic: \[api_key: ...\] is not set/, fn ->
        Platform.auth_headers(Platform.fetch!(:anthropic), :messages)
      end
    end

    test "an {m, f, a} that returns no string says what it returned, never the value" do
      for {function, pattern} <- [
            {:ok_tuple, ~r/ok_tuple\/0 returned an \{:ok, value\} tuple, not a string/},
            {:number, ~r/number\/0 returned an integer, not a string/},
            {:nothing, ~r/resolved to no value: Clementine.PlatformTest.nothing\/0 returned nil/}
          ] do
        put(bedrock: [region: "us-east-1", api_key: {__MODULE__, function, []}])

        error =
          assert_raise ArgumentError, fn ->
            Platform.auth_headers(Platform.fetch!(:bedrock), :messages)
          end

        assert error.message =~ pattern
        refute error.message =~ "sk-not-a-real-key"
      end

      # An optional credential in the wrong shape raises too, rather than
      # going without.
      put(
        proxy: [protocol: :messages, base_url: "https://p", api_key: {__MODULE__, :ok_tuple, []}]
      )

      assert_raise ArgumentError, ~r/returned an \{:ok, value\} tuple/, fn ->
        Platform.auth_headers(Platform.fetch!(:proxy), :messages)
      end
    end
  end

  describe "fetch/1" do
    test "names what an entry lacks or gets wrong" do
      for {platforms, name, pattern} <- [
            {[bedrock: [api_key: "k"]], :bedrock, ~r/bedrock: needs region:/},
            {[foundry: [api_key: "k"]], :foundry, ~r/foundry: needs one of resource:/},
            {[foundry: [resource: "r", base_url: "https://x"]], :foundry, ~r/needs one of/},
            {[foundry: [resource: "r", api_key: "k", access_token: "t"]], :foundry,
             ~r/api_key: or access_token: \(Entra ID\), not both/},
            {[vertex: [project: "p"]], :vertex, ~r/vertex: needs project: and region:/},
            {[openai_compatible: []], :openai_compatible, ~r/needs base_url:/},
            {[anthropic: [region: "us"]], :anthropic, ~r/unknown options \[:region\]/},
            {[tinker: [base_url: "https://x"]], :tinker, ~r/required :protocol option/},
            {[tinker: [protocol: :responses, base_url: "https://x"]], :tinker,
             ~r/:protocol.*expected one of \[:chat_completions, :messages\]/s},
            {[claude_on_aws: [api_key: "k"]], :claude_on_aws, ~r/takes no configuration yet/},
            {[anthropic: "k"], :anthropic, ~r/anthropic: expected a keyword list/}
          ] do
        put(platforms)
        assert {:error, message} = Platform.fetch(name)
        assert message =~ pattern, message
      end
    end

    test "never prints a literal credential, in an error or inspected" do
      put(anthropic: [api_key: "sk-not-a-real-key", base_url: 42])
      assert {:error, message} = Platform.fetch(:anthropic)
      refute message =~ "sk-not-a-real-key"

      put(anthropic: [api_key: "sk-not-a-real-key"])
      refute inspect(Platform.fetch!(:anthropic)) =~ "sk-not-a-real-key"
      assert inspect(Platform.fetch!(:anthropic)) =~ "**redacted**"

      put(anthropic: [api_key: 42, other: "sk-not-a-real-key"])
      assert {:error, message} = Platform.fetch(:anthropic)
      refute message =~ "sk-not-a-real-key"
    end

    test "never prints a credential in the wrong shape, in fetch/1 or at boot" do
      key = "sk-not-a-real-key"

      for {platforms, name, shape} <- [
            # System.fetch_env/1, or a vault helper's {:ok, secret}.
            {[anthropic: [api_key: {:ok, key}]], :anthropic, "an {:ok, value} tuple"},
            {[anthropic: [api_key: {:error, key}]], :anthropic, "an {:error, reason} tuple"},
            {[anthropic: [api_key: [key]]], :anthropic, "a list"},
            {[anthropic: [api_key: %{key: key}]], :anthropic, "a map"},
            {[anthropic: [api_key: {"a", "b", key}]], :anthropic, "a 3-element tuple"},
            {[anthropic: [api_key: {:system, :not_a_string, key}]], :anthropic, "a 3-element"},
            {[foundry: [resource: "r", access_token: {:ok, key}]], :foundry, "an {:ok, value}"},
            {[vertex: [project: "p", region: "r", access_token: [{:token, key}]]], :vertex,
             "a list"},
            # The entry itself in the wrong shape.
            {[anthropic: {:ok, key}], :anthropic, "an {:ok, value} tuple"},
            {[anthropic: key], :anthropic, "a string"},
            # A list that is not a keyword list, which NimbleOptions would
            # quote: string keys from decoded JSON, a bare key, a mix.
            {[anthropic: [{"api_key", key}]], :anthropic, "a list that is not one"},
            {[anthropic: [key]], :anthropic, "a list that is not one"},
            {[anthropic: [{:api_key, key}, key]], :anthropic, "a list that is not one"},
            {[tinker: [{"protocol", "messages"}, {"api_key", key}]], :tinker,
             "a list that is not one"},
            {[tinker: [protocol: :messages, base_url: "https://p", api_key: "k", other: key]],
             :tinker, "unknown options [:other]"}
          ] do
        put(platforms)

        assert {:error, message} = Platform.fetch(name)
        assert message =~ shape, message
        refute message =~ key

        error = assert_raise ArgumentError, &Platform.validate_config!/0
        assert error.message =~ shape
        refute error.message =~ key
      end

      # The whole key in the wrong shape.
      put(%{anthropic: key})
      error = assert_raise ArgumentError, &Platform.validate_config!/0
      assert error.message =~ "got a map"
      refute error.message =~ key

      put(anthropic: [api_key: {:ok, key}])
      error = assert_raise ArgumentError, &Platform.validate_config!/0
      assert error.message =~ "unwrap it"
    end

    test "inspect shows an {m, f, a}'s module and function, never its arguments" do
      put(bedrock: [region: "us-east-1", api_key: {__MODULE__, :token, ["sk-not-a-real-key"]}])

      inspected = inspect(Platform.fetch!(:bedrock))
      refute inspected =~ "sk-not-a-real-key"
      assert inspected =~ "{Clementine.PlatformTest, :token, [\"**redacted**\"]}"

      put(anthropic: [api_key: {:system, "ANTHROPIC_API_KEY"}])
      assert inspect(Platform.fetch!(:anthropic)) =~ ~s({:system, "ANTHROPIC_API_KEY"})
    end

    test "a base_url that ends in the path Clementine appends is refused, naming the convention" do
      for {platforms, name, pattern} <- [
            {[anthropic: [api_key: "k", base_url: "https://api.anthropic.com/v1/messages"]],
             :anthropic, ~r"ends in /v1/messages.*https://api.anthropic.com\)"},
            {[anthropic: [api_key: "k", base_url: "https://api.anthropic.com/v1/"]], :anthropic,
             ~r"ends in /v1,"},
            {[openai: [api_key: "k", base_url: "https://api.openai.com/v1/responses"]], :openai,
             ~r"ends in /responses.*before /responses"},
            {[foundry: [api_key: "k", base_url: "https://r.services.ai.azure.com/anthropic/v1"]],
             :foundry, ~r"ends in /v1,.*/anthropic\)"},
            # Anthropic's Bedrock page gives SDKs .../anthropic.
            {[
               bedrock: [
                 api_key: "k",
                 base_url: "https://bedrock-mantle.us-east-1.api.aws/anthropic"
               ]
             ], :bedrock, ~r"ends in /anthropic,.*Mantle host"},
            {[
               bedrock: [
                 api_key: "k",
                 base_url: "https://bedrock-mantle.us-east-1.api.aws/openai/v1"
               ]
             ], :bedrock, ~r"ends in /openai/v1,.*app-named platform"},
            {[bedrock: [api_key: "k", base_url: "https://bedrock-mantle.us-east-1.api.aws/v1"]],
             :bedrock, ~r"ends in /v1,"},
            {[tinker: [protocol: :chat_completions, base_url: "https://t/v1/chat/completions"]],
             :tinker, ~r"ends in /chat/completions"},
            {[proxy: [protocol: :messages, base_url: "https://proxy.example/v1"]], :proxy,
             ~r"ends in /v1,"}
          ] do
        put(platforms)
        assert {:error, message} = Platform.fetch(name)
        assert message =~ pattern, message

        assert_raise ArgumentError, ~r/Invalid :clementine, :platforms: #{name}: base_url:/, fn ->
          Platform.validate_config!()
        end
      end
    end
  end

  describe "protocol/2" do
    test "the model's vendor picks the wire where a platform has two" do
      assert Platform.protocol(:bedrock, :anthropic) == {:ok, :messages}
      assert Platform.protocol(:bedrock, :qwen) == {:ok, :chat_completions}
      assert Platform.protocol(:foundry, :anthropic) == {:ok, :messages}

      assert {:error, "Clementine sends only Claude to :foundry" <> _} =
               Platform.protocol(:foundry, :openai)

      assert {:error, message} = Platform.protocol(:vertex, :anthropic)
      assert message =~ "OPS-199"
      assert Platform.protocol(:vertex, :deepseek) == {:ok, :chat_completions}
      assert {:error, _} = Platform.protocol(:claude_on_aws, :anthropic)
      assert {:error, message} = Platform.protocol(:nowhere, :qwen)
      assert message =~ "config :clementine, :platforms names none"

      put(proxy: [protocol: :messages, base_url: "https://proxy.example"])
      assert Platform.protocol(:proxy, :anthropic) == {:ok, :messages}
    end
  end

  describe "model_id/2" do
    test "Foundry's deployment names map in its config, and default to the model id" do
      put(foundry: [resource: "r", api_key: "k", deployments: %{"claude-sonnet-5-5" => "chat"}])

      {:ok, sonnet} = Models.for_platform("claude-sonnet-5-5", :foundry)
      {:ok, opus} = Models.for_platform("claude-opus-5-5", :foundry)
      {:ok, bedrock} = Models.for_platform("claude-sonnet-5-5", :bedrock)

      assert Platform.model_id(:foundry, sonnet) == "chat"
      assert Platform.model_id(:foundry, opus) == "claude-opus-5-5"
      assert Platform.model_id(:bedrock, bedrock) == "anthropic.claude-sonnet-5-5"
    end
  end

  describe "validate_config!/0" do
    test "an {m, f, a} credential names a function that exists" do
      put(bedrock: [region: "us-east-1", api_key: {__MODULE__, :no_such_token, []}])

      assert_raise ArgumentError,
                   ~r/bedrock: \[api_key: \{Clementine.PlatformTest, :no_such_token, ...\}\] names Clementine.PlatformTest.no_such_token\/0, which does not exist/,
                   &Platform.validate_config!/0

      put(foundry: [resource: "r", access_token: {NoSuch.Module, :token, ["sk-not-a-real-key"]}])
      error = assert_raise ArgumentError, &Platform.validate_config!/0
      assert error.message =~ "NoSuch.Module.token/1, which does not exist"
      refute error.message =~ "sk-not-a-real-key"

      put(bedrock: [region: "us-east-1", api_key: {__MODULE__, :token, ["bedrock"]}])
      assert :ok = Platform.validate_config!()
    end

    test "an app config key the platforms replaced fails every request too" do
      put(anthropic: [api_key: "k", base_url: "http://localhost:1"])
      Application.put_env(:clementine, :anthropic_base_url, "http://localhost:2")

      try do
        assert {:error, message} = Platform.fetch(:anthropic)
        assert message =~ "anthropic_base_url: is replaced by config :clementine, :platforms"
        assert message =~ "anthropic: [base_url: ...]"
        assert message =~ "on every request"

        assert_raise ArgumentError, ~r/anthropic_base_url: is replaced/, fn ->
          Clementine.LLM.Anthropic.call(
            "claude-sonnet-5-5",
            "Be brief.",
            [Clementine.LLM.Message.UserMessage.new("Hi")],
            []
          )
        end
      after
        Application.delete_env(:clementine, :anthropic_base_url)
      end
    end

    test "an app config key the platforms replaced fails boot, naming its new place" do
      for {old, pattern} <- [
            {:anthropic_api_key, ~r/:platforms, anthropic: \[api_key: ...\]/},
            {:bedrock_region, ~r/:platforms, bedrock: \[region: ...\]/},
            {:vertex_access_token, ~r/:platforms, vertex: \[access_token: ...\]/},
            {:openai_base_url, ~r/openai: \[base_url: ...\]; base_url: is now the part before/}
          ] do
        Application.put_env(:clementine, old, "sk-not-a-real-key")

        try do
          error = assert_raise ArgumentError, &Platform.validate_config!/0
          assert error.message =~ pattern
          refute error.message =~ "sk-not-a-real-key"
        after
          Application.delete_env(:clementine, old)
        end
      end
    end

    test "every entry builds" do
      put(
        anthropic: [api_key: "k"],
        bedrock: [region: "us-east-1", api_key: "k"],
        tinker: [protocol: :chat_completions, base_url: "https://x"]
      )

      assert :ok = Platform.validate_config!()

      put(foundry: [api_key: "k"])

      assert_raise ArgumentError, ~r/Invalid :clementine, :platforms: foundry: needs/, fn ->
        Platform.validate_config!()
      end

      put(%{anthropic: [api_key: "k"]})

      assert_raise ArgumentError, ~r/expected a keyword list from platform/, fn ->
        Platform.validate_config!()
      end
    end
  end

  def token(kind), do: "#{kind}-token"
  def ok_tuple, do: {:ok, "sk-not-a-real-key"}
  def number, do: 42
  def nothing, do: nil
end
