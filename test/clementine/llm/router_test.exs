defmodule Clementine.LLM.RouterTest do
  use ExUnit.Case, async: false

  import Mox

  alias Clementine.LLM.Message.UserMessage
  alias Clementine.LLM.Response
  alias Clementine.LLM.Router

  setup :verify_on_exit!

  setup do
    prev_models = Application.get_env(:clementine, :models)
    prev_clients = Application.get_env(:clementine, :llm_provider_clients)

    on_exit(fn ->
      if prev_models do
        Application.put_env(:clementine, :models, prev_models)
      else
        Application.delete_env(:clementine, :models)
      end

      if prev_clients do
        Application.put_env(:clementine, :llm_provider_clients, prev_clients)
      else
        Application.delete_env(:clementine, :llm_provider_clients)
      end
    end)

    :ok
  end

  test "routes call/5 to the configured provider client" do
    Application.put_env(:clementine, :models, gpt_test: [provider: :openai, model: "gpt-5"])
    Application.put_env(:clementine, :llm_provider_clients, openai: Clementine.LLM.MockClient)

    Clementine.LLM.MockClient
    |> expect(:call, fn :gpt_test, "sys", [%UserMessage{}], [], [] ->
      {:ok, %Response{}}
    end)

    assert {:ok, %Response{}} = Router.call(:gpt_test, "sys", [UserMessage.new("hi")], [])
  end

  test "routes stream/5 to the configured provider client" do
    Application.put_env(:clementine, :models,
      claude_test: [provider: :anthropic, model: "claude-test"]
    )

    Application.put_env(:clementine, :llm_provider_clients, anthropic: Clementine.LLM.MockClient)

    Clementine.LLM.MockClient
    |> expect(:stream, fn :claude_test, "sys", [%UserMessage{}], [], [] ->
      [{:text_delta, "ok"}]
    end)

    events = Router.stream(:claude_test, "sys", [UserMessage.new("hi")], []) |> Enum.to_list()
    assert events == [{:text_delta, "ok"}]
  end
end
