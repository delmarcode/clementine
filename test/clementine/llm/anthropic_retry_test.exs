defmodule Clementine.LLM.AnthropicRetryTest do
  use ExUnit.Case, async: false

  alias Clementine.LLM.Anthropic
  alias Clementine.LLM.Message.Content
  alias Clementine.LLM.Message.UserMessage
  alias Clementine.LLM.Response

  setup do
    bypass = Bypass.open()

    prev_url = Application.get_env(:clementine, :anthropic_base_url)
    prev_retry = Application.get_env(:clementine, :retry)

    Application.put_env(
      :clementine,
      :anthropic_base_url,
      "http://localhost:#{bypass.port}/v1/messages"
    )

    Application.put_env(:clementine, :retry, max_attempts: 3, base_delay: 0, max_delay: 0)

    on_exit(fn ->
      if prev_url,
        do: Application.put_env(:clementine, :anthropic_base_url, prev_url),
        else: Application.delete_env(:clementine, :anthropic_base_url)

      if prev_retry,
        do: Application.put_env(:clementine, :retry, prev_retry),
        else: Application.delete_env(:clementine, :retry)
    end)

    %{bypass: bypass}
  end

  describe "streaming retry" do
    test "retries on 429 and succeeds", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        call_num = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if call_num == 1 do
          Plug.Conn.resp(
            conn,
            429,
            ~s({"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}})
          )
        else
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, sse_success_body("Hello from retry!"))
        end
      end)

      events =
        Anthropic.stream(:claude_sonnet, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()

      assert Enum.any?(events, &match?({:text_delta, "Hello from retry!"}, &1))
      assert Enum.any?(events, &match?({:message_stop}, &1))
      assert Agent.get(counter, & &1) == 2

      Agent.stop(counter)
    end

    test "retries on 529 and succeeds", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        call_num = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if call_num == 1 do
          Plug.Conn.resp(
            conn,
            529,
            ~s({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}})
          )
        else
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, sse_success_body("Hello after overload!"))
        end
      end)

      events =
        Anthropic.stream(:claude_sonnet, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()

      assert Enum.any?(events, &match?({:text_delta, "Hello after overload!"}, &1))
      assert Agent.get(counter, & &1) == 2

      Agent.stop(counter)
    end

    test "returns error carrying the provider body after exhausting retries", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      error_body =
        ~s({"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}})

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        Agent.update(counter, fn n -> n + 1 end)
        Plug.Conn.resp(conn, 429, error_body)
      end)

      events =
        Anthropic.stream(:claude_sonnet, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()

      assert {:error, {:api_error, 429, error_body}} in events

      # max_attempts is 3
      assert Agent.get(counter, & &1) == 3

      Agent.stop(counter)
    end

    # The receive_timeout budget contract, in two deterministic halves.
    # Both observe the durations the retry loop *requests* through the
    # sleep seam — the decision under test — rather than bounding
    # wall-clock elapsed time, which flaked under CI load (connect time,
    # scheduler oversleep, and Bypass latency all stretch; the decision
    # does not).

    test "backoff sleeps are capped to the remaining budget, never the configured delay",
         %{bypass: bypass} do
      # Backoff (60s) strictly larger than the whole budget (59s), so an
      # uncapped sleep is unambiguous in the recording. The recorder
      # returns instantly: the budget is never spent, every retry is
      # granted, and attempts exhaust — which forces exactly two recorded
      # backoffs, so a seam that stops being exercised fails loudly
      # rather than passing vacuously.
      Application.put_env(:clementine, :retry,
        max_attempts: 3,
        base_delay: 60_000,
        max_delay: 60_000
      )

      {:ok, sleeps} = Agent.start_link(fn -> [] end)

      Application.put_env(:clementine, :retry_sleep, fn ms ->
        Agent.update(sleeps, &[ms | &1])
      end)

      on_exit(fn -> Application.delete_env(:clementine, :retry_sleep) end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        Agent.update(counter, fn n -> n + 1 end)

        Plug.Conn.resp(
          conn,
          429,
          ~s({"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}})
        )
      end)

      budget = 59_000

      events =
        Anthropic.stream(:claude_sonnet, "system", [UserMessage.new("Hi")], [],
          receive_timeout: budget
        )
        |> Enum.to_list()

      assert Enum.any?(events, &match?({:error, {:api_error, 429, _}}, &1))
      assert Agent.get(counter, & &1) == 3

      # Two retries were granted, and each slept min(backoff, remaining):
      # strictly under the budget, never the configured 60s.
      assert [_, _] = requested = Agent.get(sleeps, & &1)
      assert Enum.all?(requested, &(&1 <= budget))

      Agent.stop(counter)
      Agent.stop(sleeps)
    end

    # A regression that stops honoring the spent budget makes this test
    # sleep a real 60s backoff; the tag bounds how long that failure
    # runs, far above the healthy path (~1s: the one granted,
    # budget-capped sleep).
    @tag timeout: 30_000
    test "a spent receive_timeout budget stops the retry loop", %{bypass: bypass} do
      Application.put_env(:clementine, :retry,
        max_attempts: 3,
        base_delay: 60_000,
        max_delay: 60_000
      )

      {:ok, sleeps} = Agent.start_link(fn -> [] end)

      Application.put_env(:clementine, :retry_sleep, fn ms ->
        Agent.update(sleeps, &[ms | &1])
        Process.sleep(ms)
      end)

      on_exit(fn -> Application.delete_env(:clementine, :retry_sleep) end)

      # No server at all: every attempt fails in microseconds (connection
      # refused), far inside the budget, so the first backoff is
      # deterministically granted — and, capped to the remaining budget,
      # sleeping it spends the whole window. The retry after it must find
      # the budget spent and refuse.
      Bypass.down(bypass)

      budget = 1_000

      events =
        Anthropic.stream(:claude_sonnet, "system", [UserMessage.new("Hi")], [],
          receive_timeout: budget
        )
        |> Enum.to_list()

      # The failure surfaced to the consumer — and with three attempts
      # configured and every attempt failing, a loop that ignored the
      # spent budget would have granted a second backoff: exactly one was
      # granted, capped to the budget, and the retry after it was refused.
      assert Enum.any?(events, &match?({:error, {:request_failed, _}}, &1))
      assert [granted] = Agent.get(sleeps, & &1)
      assert granted <= budget

      Agent.stop(sleeps)
    end

    test "retries on network error and succeeds", %{bypass: bypass} do
      # Use a small backoff so Bypass has time to come back up between attempts
      Application.put_env(:clementine, :retry, max_attempts: 3, base_delay: 100, max_delay: 100)

      # Register the success handler before taking Bypass down
      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, sse_success_body("Hello after network error!"))
      end)

      Bypass.down(bypass)

      # Bring Bypass back up after the first attempt fails
      spawn(fn ->
        Process.sleep(50)
        Bypass.up(bypass)
      end)

      events =
        Anthropic.stream(:claude_sonnet, "system", [UserMessage.new("Hi")], []) |> Enum.to_list()

      assert Enum.any?(events, &match?({:text_delta, "Hello after network error!"}, &1))
    end

    test "sync retries on network error and succeeds", %{bypass: bypass} do
      Application.put_env(:clementine, :retry, max_attempts: 3, base_delay: 100, max_delay: 100)

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(sync_success_body("Hello sync after error!")))
      end)

      Bypass.down(bypass)

      spawn(fn ->
        Process.sleep(50)
        Bypass.up(bypass)
      end)

      assert {:ok, %Response{} = response} =
               Anthropic.call(:claude_sonnet, "system", [UserMessage.new("Hi")], [])

      assert [%Content.Text{text: "Hello sync after error!"}] = response.content
    end
  end

  describe "sync retry" do
    test "retries on 429 and succeeds", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        call_num = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if call_num == 1 do
          Plug.Conn.resp(
            conn,
            429,
            ~s({"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}})
          )
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(sync_success_body("Hello sync!")))
        end
      end)

      assert {:ok, %Response{} = response} =
               Anthropic.call(:claude_sonnet, "system", [UserMessage.new("Hi")], [])

      assert [%Content.Text{text: "Hello sync!"}] = response.content
      assert Agent.get(counter, & &1) == 2

      Agent.stop(counter)
    end

    test "returns error after exhausting retries", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        Agent.update(counter, fn n -> n + 1 end)

        Plug.Conn.resp(
          conn,
          429,
          ~s({"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}})
        )
      end)

      assert {:error, {:api_error, 429, _}} =
               Anthropic.call(:claude_sonnet, "system", [UserMessage.new("Hi")], [])

      assert Agent.get(counter, & &1) == 3

      Agent.stop(counter)
    end
  end

  # Minimal SSE body that produces a text_delta and message_stop
  defp sse_success_body(text) do
    Enum.join(
      [
        "event: message_start\ndata: #{Jason.encode!(%{"type" => "message_start", "message" => %{"id" => "msg_test", "type" => "message", "role" => "assistant", "content" => [], "model" => "claude-sonnet-4-20250514", "stop_reason" => nil, "stop_sequence" => nil, "usage" => %{"input_tokens" => 10, "output_tokens" => 1}}})}\n",
        "event: content_block_start\ndata: #{Jason.encode!(%{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}})}\n",
        "event: content_block_delta\ndata: #{Jason.encode!(%{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => text}})}\n",
        "event: content_block_stop\ndata: #{Jason.encode!(%{"type" => "content_block_stop", "index" => 0})}\n",
        "event: message_delta\ndata: #{Jason.encode!(%{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil}, "usage" => %{"output_tokens" => 5}})}\n",
        "event: message_stop\ndata: #{Jason.encode!(%{"type" => "message_stop"})}\n"
      ],
      "\n"
    ) <> "\n"
  end

  defp sync_success_body(text) do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
  end
end
