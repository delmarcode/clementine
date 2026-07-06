defmodule Clementine.ResultTest do
  use ExUnit.Case, async: true

  alias Clementine.{Error, InterruptReason, Result, Usage}
  alias Clementine.LLM.Message.UserMessage
  alias Clementine.Result.{Cancelled, Completed, Failed, Interrupted}

  test "every variant carries usage" do
    usage = %Usage{input_tokens: 5, output_tokens: 5}

    results = [
      Result.completed(usage: usage),
      Result.failed(%Error{code: :auth}, usage),
      Result.cancelled(:user_request, usage),
      Result.interrupted(:lease_expired, usage)
    ]

    for result <- results do
      assert Result.usage(result) == usage
    end
  end

  test "status/1 maps each variant to its terminal lifecycle status" do
    assert Result.status(%Completed{}) == :completed
    assert Result.status(Result.failed(:max_iterations_reached)) == :failed
    assert Result.status(%Cancelled{}) == :cancelled
    assert Result.status(Result.interrupted(:drain)) == :interrupted
  end

  test "completed separates input_message from generated messages" do
    input = UserMessage.new("prompt")

    result =
      Result.completed(
        input_message: input,
        messages: [:generated_placeholder],
        output: "answer"
      )

    history = [:prior] ++ [result.input_message] ++ result.messages
    assert history == [:prior, input, :generated_placeholder]
  end

  test "failed/2 normalizes raw reasons into Error" do
    assert %Failed{error: %Error{code: :rate_limited, retryable?: true}} =
             Result.failed({:api_error, 429, %{}})
  end

  test "interrupted/2 accepts bare codes and full reasons" do
    assert %Interrupted{reason: %InterruptReason{code: :drain}} = Result.interrupted(:drain)

    reason = InterruptReason.new(:lease_expired, "heartbeat expired")
    assert %Interrupted{reason: ^reason} = Result.interrupted(reason)
  end

  test "interrupted/2 refuses codes outside the closed set" do
    assert_raise FunctionClauseError, fn -> Result.interrupted(:not_a_real_code) end
  end
end
