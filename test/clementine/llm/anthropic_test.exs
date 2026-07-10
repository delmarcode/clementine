defmodule Clementine.LLM.AnthropicTest do
  use ExUnit.Case, async: false

  alias Clementine.LLM.Anthropic
  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Message.UserMessage
  alias Clementine.LLM.Response

  setup do
    bypass = Bypass.open()

    prev_url = Application.get_env(:clementine, :anthropic_base_url)
    prev_key = Application.get_env(:clementine, :anthropic_api_key)
    prev_models = Application.get_env(:clementine, :models)

    Application.put_env(
      :clementine,
      :anthropic_base_url,
      "http://localhost:#{bypass.port}/v1/messages"
    )

    Application.put_env(:clementine, :anthropic_api_key, "test-anthropic-key")

    Application.put_env(:clementine, :models,
      claude_test: [provider: :anthropic, id: "claude-sonnet-5", defaults: [max_tokens: 1024]],
      claude_reasoning: [
        provider: :anthropic,
        id: "claude-sonnet-5",
        reasoning: [thinking: :adaptive, effort: :high]
      ]
    )

    on_exit(fn ->
      restore_env(:anthropic_base_url, prev_url)
      restore_env(:anthropic_api_key, prev_key)
      restore_env(:models, prev_models)
    end)

    %{bypass: bypass}
  end

  describe "module structure" do
    test "exports call functions" do
      Code.ensure_loaded!(Clementine.LLM.Anthropic)
      funcs = Clementine.LLM.Anthropic.__info__(:functions)
      assert {:call, 4} in funcs
      assert {:call, 5} in funcs
    end

    test "exports stream functions" do
      Code.ensure_loaded!(Clementine.LLM.Anthropic)
      funcs = Clementine.LLM.Anthropic.__info__(:functions)
      assert {:stream, 4} in funcs
      assert {:stream, 5} in funcs
    end
  end

  describe "reasoning request fields" do
    test "call/5 omits reasoning fields when unconfigured", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["model"] == "claude-sonnet-5"
        refute Map.has_key?(request, "thinking")
        refute Map.has_key?(request, "output_config")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("No reasoning"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "No reasoning"}]}} =
               Anthropic.call(:claude_test, "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 includes configured reasoning", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["thinking"] == %{"type" => "adaptive"}
        assert request["output_config"] == %{"effort" => "high"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Configured reasoning"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Configured reasoning"}]}} =
               Anthropic.call(:claude_reasoning, "system", [UserMessage.new("Hi")], [])
    end

    test "call/5 lets request opts override configured reasoning", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        assert request["thinking"] == %{"type" => "enabled", "budget_tokens" => 2048}
        refute Map.has_key?(request, "output_config")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, text_response("Overridden reasoning"))
      end)

      assert {:ok, %Response{content: [%Content.Text{text: "Overridden reasoning"}]}} =
               Anthropic.call(:claude_reasoning, "system", [UserMessage.new("Hi")], [],
                 reasoning: [budget_tokens: 2048]
               )
    end

    test "call/5 rejects invalid Anthropic reasoning opts" do
      assert_raise ArgumentError, ~r/unsupported Anthropic reasoning effort/, fn ->
        Anthropic.call(:claude_test, "system", [UserMessage.new("Hi")], [], reasoning: :ultra)
      end
    end
  end

  defp text_response(text) do
    Jason.encode!(%{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 12, "output_tokens" => 4}
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:clementine, key)
  defp restore_env(key, value), do: Application.put_env(:clementine, key, value)
end
