defmodule Clementine.LLM.AnthropicFakeTest do
  @moduledoc """
  What a scripted turn of `Clementine.LLM.Anthropic.Fake` can carry
  besides its blocks: the usage the turn reports, cache tokens included,
  normalized as the client's parser normalizes a real stream's; any stop
  reason; an error event mid-stream; and the HTTP errors the client meets
  before the answer, retried as the client retries them. And the fake
  refuses an empty text block or an empty message, as the API does.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Mox

  alias Clementine.{Agent, Error, Result}
  alias Clementine.LLM.{Anthropic, StreamParser}
  alias Clementine.LLM.Anthropic.Fake
  alias Clementine.LLM.Message.{AssistantMessage, Content, UserMessage}
  alias StreamParser.Accumulator

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:clementine, :models)

    Application.put_env(:clementine, :models,
      priced: [
        provider: :anthropic,
        id: "claude-sonnet-5",
        pricing: [currency: "USD", input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75]
      ]
    )

    on_exit(fn -> Application.put_env(:clementine, :models, previous) end)

    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:clementine, :llm, :usage],
      fn _event, measurements, metadata, _config ->
        send(test, {:usage, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp agent, do: Agent.new(model: :priced, instructions: "Be brief.")

  defp claude_turn(script, fake_opts \\ []) do
    expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
      Fake.stream(model, system, messages, tools, opts, script, fake_opts)
    end)
  end

  defp accumulate(events),
    do: events |> Enum.reduce(Accumulator.new(), &Accumulator.process(&2, &1))

  describe "usage:" do
    test "reaches the usage event and the cost as a real stream's would, cache tokens included" do
      usage = [
        input_tokens: 40,
        output_tokens: 7,
        cache_read_input_tokens: 900,
        cache_creation_input_tokens: 300
      ]

      claude_turn([{:text, "Hi."}], usage: usage)
      assert {:ok, %Result.Completed{usage: total}} = Clementine.run(agent(), "Hello")

      # Anthropic reports the uncached input apart; the input counts all of it.
      assert %{input_tokens: 1240, output_tokens: 7, cache_read_tokens: 900} =
               Map.from_struct(total)

      assert total.cache_write_tokens == 300

      assert_received {:usage, measurements, %{outcome: :stop, currency: "USD"}}

      assert %{
               input_tokens: 1240,
               output_tokens: 7,
               cache_read_tokens: 900,
               cache_write_tokens: 300,
               cost_micros: cost
             } = measurements

      # 40 × 3.0 + 900 × 0.3 + 300 × 3.75 + 7 × 15.0, per million tokens.
      assert cost == 40 * 3 + 270 + 1125 + 105

      # The same usage on the wire, through the client's own parser.
      sse =
        sse("message_start", %{
          "message" => %{
            "usage" => %{
              "input_tokens" => 40,
              "cache_read_input_tokens" => 900,
              "cache_creation_input_tokens" => 300,
              "output_tokens" => 1
            }
          }
        }) <>
          sse("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 7}
          })

      {wire, _state} = StreamParser.parse(StreamParser.new(), sse)

      faked =
        Fake.stream(
          {:anthropic, "claude-sonnet-5"},
          "Be brief.",
          [UserMessage.new("Hi")],
          [],
          [],
          [{:text, "Hi."}],
          usage: usage
        )

      assert accumulate(faked).usage == accumulate(wire).usage
    end

    test "takes the cache write by TTL, as the API breaks it out, and sums it" do
      claude_turn([{:text, "Hi."}],
        usage: %{
          cache_creation: %{ephemeral_5m_input_tokens: 100, ephemeral_1h_input_tokens: 200}
        }
      )

      assert {:ok, %Result.Completed{usage: usage}} = Clementine.run(agent(), "Hello")
      assert usage.cache_write_tokens == 300
      assert usage.input_tokens == 310
      assert usage.output_tokens == 5
    end

    test "defaults to 10 input and 5 output tokens, no cache" do
      claude_turn([{:text, "Hi."}])
      assert {:ok, %Result.Completed{usage: usage}} = Clementine.run(agent(), "Hello")
      assert %{input_tokens: 10, output_tokens: 5, cache_read_tokens: 0} = Map.from_struct(usage)
    end

    test "refuses a key the API does not report" do
      assert_raise ArgumentError, ~r/usage: takes/, fn ->
        Fake.stream(:priced, nil, [UserMessage.new("Hi")], [], [], [], usage: [tokens: 1])
      end
    end
  end

  describe "{:error, type}" do
    test "ends the turn mid-stream: the run fails with the provider's error, charged its input" do
      claude_turn([{:text, "Half an"}, {:error, "overloaded_error"}], usage: [input_tokens: 40])

      assert {:error, %Result.Failed{error: error, usage: usage}} =
               Clementine.run(agent(), "Hello")

      assert %Error{kind: :provider, code: :overloaded, retryable?: true} = error
      assert error.message =~ "overloaded_error"
      assert usage.input_tokens == 40
      assert_received {:usage, %{input_tokens: 40}, %{outcome: :error}}
    end

    test "no step may follow it" do
      assert_raise ArgumentError, ~r/ends the turn/, fn ->
        Fake.stream(:priced, nil, [UserMessage.new("Hi")], [], [], [
          {:error, "api_error"},
          {:text, "More."}
        ])
      end
    end
  end

  describe "api_errors:" do
    setup do
      test = self()
      previous = Application.get_env(:clementine, :retry_sleep)
      Application.put_env(:clementine, :retry_sleep, &send(test, {:slept, &1}))

      on_exit(fn ->
        if previous,
          do: Application.put_env(:clementine, :retry_sleep, previous),
          else: Application.delete_env(:clementine, :retry_sleep)
      end)
    end

    test "a 529 the client retries, after its backoff, is answered" do
      claude_turn([{:text, "Hi."}], api_errors: [529])

      assert {:ok, %Result.Completed{output: "Hi."}} = Clementine.run(agent(), "Hello")
      assert_received {:slept, 1000}
      refute_received {:slept, _ms}
    end

    test "429s that spend the client's attempts fail the run as rate limited" do
      claude_turn([{:text, "Hi."}], api_errors: [429, 429, 429])

      assert {:error, %Result.Failed{error: error}} = Clementine.run(agent(), "Hello")
      assert %Error{kind: :provider, code: :rate_limited, retryable?: true} = error
      assert error.message =~ "rate_limit_error"
      assert_received {:slept, 1000}
      assert_received {:slept, 2000}
      refute_received {:slept, _ms}
    end

    test "a status the client does not retry fails the run at once" do
      claude_turn([{:text, "Hi."}], api_errors: [400])

      assert {:error, %Result.Failed{error: %Error{code: :invalid_request}}} =
               Clementine.run(agent(), "Hello")

      refute_received {:slept, _ms}
    end

    test "gives the error as the client does: the status and the body's raw JSON" do
      assert [{:error, {:api_error, 529, body}}] =
               Fake.stream(:priced, nil, [UserMessage.new("Hi")], [], [], [{:text, "Hi."}],
                 api_errors: [529, 529, 529]
               )

      assert %{"error" => %{"type" => "overloaded_error"}} = Jason.decode!(body)
    end
  end

  describe "the API's refusals" do
    test "an empty text block anywhere the encoder sends one" do
      history = [%UserMessage{content: [Content.text("Hi"), Content.text("")]}]

      assert {:error, {:api_error, 400, body}} = Fake.check(:priced, nil, history, [])
      assert body["error"]["message"] =~ "messages.0.content.1.text"

      # A stored assistant turn's empty block never goes.
      history = [UserMessage.new("Hi"), AssistantMessage.new([Content.text("")])]
      assert :ok = Fake.check(:priced, nil, history ++ [UserMessage.new("Again?")], [])
    end

    test "an empty message anywhere but last; the encoder never sends an empty assistant one" do
      history = [UserMessage.new(""), AssistantMessage.new([Content.text("Hm?")])]

      assert {:error, {:api_error, 400, body}} = Fake.check(:priced, nil, history, [])
      assert body["error"]["message"] =~ "messages.0: all messages must have non-empty content"

      # A turn stored with no blocks is left out of the request.
      empty = AssistantMessage.new([])
      history = [UserMessage.new("Hi"), empty, UserMessage.new("Hm?")]
      assert :ok = Fake.check(:priced, nil, history, [])
    end
  end

  test "the client's retry wait is the one the fake retries with" do
    test = self()
    Application.put_env(:clementine, :retry_sleep, &send(test, {:slept, &1}))
    on_exit(fn -> Application.delete_env(:clementine, :retry_sleep) end)

    Anthropic.retry_wait(3)
    assert_received {:slept, 4000}
  end

  defp sse(type, data),
    do: "event: #{type}\ndata: #{Jason.encode!(Map.put(data, "type", type))}\n\n"
end
