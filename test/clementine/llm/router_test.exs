defmodule Clementine.LLM.RouterTest do
  use ExUnit.Case, async: false

  import Mox

  alias Clementine.LLM.Message.UserMessage
  alias Clementine.LLM.{Policy, Response, Router}

  setup :verify_on_exit!

  @env_keys [:models, :llm_provider_clients, :anthropic_api_key, :openrouter_api_key]

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
    Application.delete_env(:clementine, :openrouter_api_key)

    # Reaching the ChatCompletions client's credential check proves the
    # default platform mapping dispatched there.
    assert_raise RuntimeError, ~r/Missing :openrouter_api_key/, fn ->
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

  test "raises for a platform with no client configured" do
    Application.put_env(:clementine, :llm_provider_clients, anthropic: Clementine.LLM.MockClient)

    assert_raise RuntimeError, ~r/No LLM client configured for provider :openai/, fn ->
      Router.call("gpt-5", "sys", [UserMessage.new("hi")], [])
    end
  end

  describe "credential/1" do
    test "passes where app config holds the platform's key, even one not yet resolved" do
      Application.put_env(:clementine, :anthropic_api_key, "test-anthropic-key")
      assert :ok = Router.credential(Policy.resolve!("claude-sonnet-5"))

      declare("deepseek/deepseek-v3.2", :deepseek, openrouter: [])

      Application.put_env(
        :clementine,
        :openrouter_api_key,
        {:system, "CLEMENTINE_ROUTER_TEST_UNSET_KEY"}
      )

      assert :ok = Router.credential(Policy.resolve!("deepseek/deepseek-v3.2"))
    end

    test "names the config key the model's platform lacks" do
      Application.delete_env(:clementine, :anthropic_api_key)

      assert {:error, message} = Router.credential(Policy.resolve!("claude-sonnet-5"))

      assert message ==
               ~s("claude-sonnet-5" goes to :anthropic, and config :clementine, ) <>
                 "anthropic_api_key: is not set"

      declare("deepseek/deepseek-v3.2", :deepseek, openrouter: [])
      Application.delete_env(:clementine, :openrouter_api_key)

      assert {:error, message} = Router.credential(Policy.resolve!("deepseek/deepseek-v3.2"))
      assert message =~ "goes to :openrouter"
      assert message =~ "openrouter_api_key: is not set"
    end

    test "a declared platform entry's api_key stands in for app config" do
      Application.delete_env(:clementine, :openrouter_api_key)

      declare("deepseek/deepseek-v3.2", :deepseek,
        openrouter: [api_key: {:system, "CLEMENTINE_ROUTER_TEST_UNSET_KEY"}]
      )

      assert :ok = Router.credential(Policy.resolve!("deepseek/deepseek-v3.2"))
    end

    test "an OpenAI-compatible server may take no key" do
      declare("qwen3", :qwen, openai_compatible: [base_url: "http://localhost:8000/v1"])

      assert :ok = Router.credential(Policy.resolve!("qwen3"))
    end
  end
end
