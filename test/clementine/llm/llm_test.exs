defmodule Clementine.LLMTest do
  use ExUnit.Case, async: false

  import Mox

  alias Clementine.LLM

  setup :verify_on_exit!

  setup do
    previous = %{
      client: Application.get_env(:clementine, :llm_client),
      models: Application.get_env(:clementine, :models)
    }

    on_exit(fn ->
      restore_env(:llm_client, previous.client)
      restore_env(:models, previous.models)
    end)

    :ok
  end

  describe "call/5" do
    test "normalizes model resolution exceptions" do
      Application.delete_env(:clementine, :llm_client)
      Application.put_env(:clementine, :models, [])

      assert {:error, {:llm_exception, %{kind: :error, message: message}}} =
               LLM.call(:missing_alias, "", [], [])

      assert message =~ "Unknown model alias"
    end
  end

  describe "stream/5" do
    test "normalizes immediate client exceptions" do
      Application.put_env(:clementine, :llm_client, Clementine.LLM.MockClient)

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        raise "stream setup failed"
      end)

      assert [{:error, {:llm_exception, %{kind: :error, message: "stream setup failed"}}}] =
               LLM.stream(:claude_sonnet, "", [], []) |> Enum.to_list()
    end

    test "normalizes lazy stream exceptions during enumeration" do
      Application.put_env(:clementine, :llm_client, Clementine.LLM.MockClient)

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        Stream.concat(
          [{:text_delta, "partial"}],
          Stream.map([:boom], fn _ -> raise "stream blew up" end)
        )
      end)

      assert [
               {:text_delta, "partial"},
               {:error, {:llm_exception, %{kind: :error, message: "stream blew up"}}}
             ] = LLM.stream(:claude_sonnet, "", [], []) |> Enum.to_list()
    end

    test "returns an error event for invalid stream client results" do
      Application.put_env(:clementine, :llm_client, Clementine.LLM.MockClient)

      Clementine.LLM.MockClient
      |> expect(:stream, fn _model, _system, _messages, _tools, _opts ->
        :not_an_enumerable
      end)

      assert [{:error, {:invalid_llm_client_stream, :not_an_enumerable}}] =
               LLM.stream(:claude_sonnet, "", [], []) |> Enum.to_list()
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:clementine, key)
  defp restore_env(key, value), do: Application.put_env(:clementine, key, value)
end
