defmodule Clementine.LLM.RouterTest do
  use ExUnit.Case, async: false

  import Mox

  alias Clementine.LLM.Message.UserMessage
  alias Clementine.LLM.{Policy, Response, Router}

  setup :verify_on_exit!

  @env_keys [:models, :llm_provider_clients, :platforms]

  setup do
    previous = Enum.map(@env_keys, &{&1, Application.get_env(:clementine, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:clementine, key)
        {key, value} -> Application.put_env(:clementine, key, value)
      end)
    end)

    :ok
  end

  defp declare(id, vendor, platforms) do
    Application.put_env(:clementine, :models, %{
      id => [vendor: vendor, context: 163_840, max_output: 65_536, platforms: platforms]
    })
  end

  test "routes call/5 to the client for the platform the model is served on" do
    Application.put_env(:clementine, :llm_provider_clients, openai: Clementine.LLM.MockClient)

    Clementine.LLM.MockClient
    |> expect(:call, fn "gpt-5", "sys", [%UserMessage{}], [], [] ->
      {:ok, %Response{}}
    end)

    assert {:ok, %Response{}} = Router.call("gpt-5", "sys", [UserMessage.new("hi")], [])
  end

  test "routes stream/5 to the client for the platform the model is served on" do
    Application.put_env(:clementine, :llm_provider_clients, anthropic: Clementine.LLM.MockClient)

    Clementine.LLM.MockClient
    |> expect(:stream, fn "claude-sonnet-5", "sys", [%UserMessage{}], [], [] ->
      [{:text_delta, "ok"}]
    end)

    events =
      "claude-sonnet-5" |> Router.stream("sys", [UserMessage.new("hi")], []) |> Enum.to_list()

    assert events == [{:text_delta, "ok"}]
  end

  test "routes chat completions platforms to the ChatCompletions client by default" do
    declare("deepseek/deepseek-v3.2", :deepseek, openrouter: [])
    Application.delete_env(:clementine, :llm_provider_clients)
    Application.put_env(:clementine, :platforms, [])

    # Reaching the ChatCompletions client's credential check proves the
    # default platform mapping dispatched there.
    assert_raise ArgumentError, ~r/:platforms, openrouter: \[api_key: ...\] is not set/, fn ->
      Router.call("deepseek/deepseek-v3.2", "sys", [UserMessage.new("hi")], [])
    end
  end

  test "a declared model goes to the platform it lists, not to its vendor's own" do
    declare("openai/gpt-5.6-sol", :openai, openrouter: [])

    # No :openai client: routing by vendor would raise.
    Application.put_env(:clementine, :llm_provider_clients, openrouter: Clementine.LLM.MockClient)

    Clementine.LLM.MockClient
    |> expect(:call, fn "openai/gpt-5.6-sol", "sys", [%UserMessage{}], [], [] ->
      {:ok, %Response{}}
    end)

    assert {:ok, %Response{}} =
             Router.call("openai/gpt-5.6-sol", "sys", [UserMessage.new("hi")], [])
  end

  test "an unknown id or an old model reference raises before any client is called" do
    Application.put_env(:clementine, :llm_provider_clients,
      anthropic: Clementine.LLM.MockClient,
      openai: Clementine.LLM.MockClient
    )

    assert_raise ArgumentError, ~r/unknown model "claude-sonnet-9".*Nearest known/s, fn ->
      Router.call("claude-sonnet-9", "sys", [UserMessage.new("hi")], [])
    end

    assert_raise ArgumentError, ~r/a model is named by its id/, fn ->
      Router.stream(:claude_sonnet, "sys", [UserMessage.new("hi")], [])
    end

    assert_raise ArgumentError, ~r/a model is named by its id/, fn ->
      Router.call({:openai, "gpt-5"}, "sys", [UserMessage.new("hi")], [])
    end
  end

  test "routes to the platform the request names, over the wire its model takes there" do
    Application.put_env(:clementine, :llm_provider_clients, bedrock: Clementine.LLM.MockClient)

    Clementine.LLM.MockClient
    |> expect(:call, fn "claude-sonnet-5-5", "sys", [%UserMessage{}], [], [platform: :bedrock] ->
      {:ok, %Response{}}
    end)

    assert {:ok, %Response{}} =
             Router.call("claude-sonnet-5-5", "sys", [UserMessage.new("hi")], [],
               platform: :bedrock
             )
  end

  test "Claude on Bedrock and Foundry goes to the Messages client, an open model to Chat Completions" do
    Application.put_env(:clementine, :platforms, [])
    declare("qwen.qwen3-235b-a22b-2507-v1:0", :qwen, bedrock: [])

    # Each client's own platform check proves where the request went.
    for platform <- [:bedrock, :foundry] do
      assert_raise ArgumentError, ~r/#{platform}: needs/, fn ->
        Router.call("claude-sonnet-5-5", "sys", [UserMessage.new("hi")], [], platform: platform)
      end
    end

    assert_raise ArgumentError, ~r/bedrock: needs region:/, fn ->
      Router.call("qwen.qwen3-235b-a22b-2507-v1:0", "sys", [UserMessage.new("hi")], [])
    end
  end

  test "a platform no request can reach yet raises, naming the issue that builds it" do
    assert_raise ArgumentError, ~r/does not send Claude to :vertex yet \(OPS-199\)/, fn ->
      Router.call("claude-sonnet-5-5", "sys", [UserMessage.new("hi")], [], platform: :vertex)
    end

    assert_raise ArgumentError, ~r/does not send to :claude_on_aws yet/, fn ->
      Router.call("claude-sonnet-5-5", "sys", [UserMessage.new("hi")], [],
        platform: :claude_on_aws
      )
    end
  end

  describe "credential/1" do
    test "passes where the platform's config holds its key, even one not yet resolved" do
      Application.put_env(:clementine, :platforms,
        anthropic: [api_key: "test-anthropic-key"],
        openrouter: [api_key: {:system, "CLEMENTINE_ROUTER_TEST_UNSET_KEY"}],
        bedrock: [region: "us-east-1", api_key: {__MODULE__, :token, []}],
        foundry: [resource: "example", access_token: {__MODULE__, :token, []}]
      )

      assert :ok = Router.credential(Policy.resolve!("claude-sonnet-5"))
      assert :ok = Router.credential(Policy.resolve!("claude-sonnet-5-5", platform: :bedrock))
      assert :ok = Router.credential(Policy.resolve!("claude-sonnet-5-5", platform: :foundry))

      declare("deepseek/deepseek-v3.2", :deepseek, openrouter: [])
      assert :ok = Router.credential(Policy.resolve!("deepseek/deepseek-v3.2"))
    end

    test "names the config key the model's platform lacks" do
      Application.put_env(:clementine, :platforms, bedrock: [region: "us-east-1"])

      assert {:error, message} = Router.credential(Policy.resolve!("claude-sonnet-5"))

      assert message ==
               ~s("claude-sonnet-5" goes to :anthropic, and config :clementine, :platforms, ) <>
                 "anthropic: [api_key: ...] is not set"

      assert {:error, message} =
               Router.credential(Policy.resolve!("claude-sonnet-5-5", platform: :bedrock))

      assert message =~ "goes to :bedrock"
      assert message =~ "bedrock: [api_key: ...] is not set"

      Application.put_env(:clementine, :platforms, foundry: [resource: "example"])

      assert {:error, message} =
               Router.credential(Policy.resolve!("claude-sonnet-5-5", platform: :foundry))

      assert message =~ "foundry: sets none of [:api_key, :access_token]"
    end

    test "names what a platform's entry lacks to know where to send" do
      Application.put_env(:clementine, :platforms, bedrock: [api_key: "k"])

      assert {:error, "bedrock: needs region:" <> _} =
               Router.credential(Policy.resolve!("claude-sonnet-5-5", platform: :bedrock))
    end

    test "an OpenAI-compatible server may take no key, but needs its base_url" do
      declare("qwen3", :qwen, openai_compatible: [])
      Application.put_env(:clementine, :platforms, [])

      assert {:error, "openai_compatible: needs base_url:" <> _} =
               Router.credential(Policy.resolve!("qwen3"))

      Application.put_env(:clementine, :platforms,
        openai_compatible: [base_url: "http://localhost:8000/v1"]
      )

      assert :ok = Router.credential(Policy.resolve!("qwen3"))
    end
  end

  def token, do: "a-short-lived-token"
end
