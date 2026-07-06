defmodule Clementine.ErrorTest do
  use ExUnit.Case, async: true

  alias Clementine.Error

  describe "normalize/2 for api errors" do
    test "classifies retryable statuses" do
      for {status, code} <- [{429, :rate_limited}, {529, :overloaded}, {408, :timeout}] do
        error = Error.normalize({:api_error, status, %{}}, :anthropic)

        assert error.kind == :provider
        assert error.code == code
        assert error.provider == :anthropic
        assert error.retryable?
      end
    end

    test "5xx is retryable provider_unavailable" do
      error = Error.normalize({:api_error, 503, "unavailable"})
      assert error.code == :provider_unavailable
      assert error.retryable?
    end

    test "classifies non-retryable statuses" do
      for {status, code} <- [
            {401, :auth},
            {403, :auth},
            {404, :not_found},
            {400, :invalid_request},
            {413, :invalid_request}
          ] do
        error = Error.normalize({:api_error, status, %{}})

        assert error.code == code
        refute error.retryable?
      end
    end

    test "extracts the provider error message when present" do
      body = %{"error" => %{"type" => "rate_limit_error", "message" => "Slow down"}}
      error = Error.normalize({:api_error, 429, body}, :anthropic)

      assert error.message == "Slow down"
      assert error.raw == {:api_error, 429, body}
    end

    test "falls back to a truncated body string" do
      error = Error.normalize({:api_error, 500, String.duplicate("x", 500)})

      assert String.starts_with?(error.message, "HTTP 500: ")
      assert String.length(error.message) <= 220
    end
  end

  test "normalize/2 for request failures is retryable network" do
    error = Error.normalize({:request_failed, :timeout}, :openai)

    assert error.kind == :provider
    assert error.code == :network
    assert error.provider == :openai
    assert error.retryable?
  end

  test "normalize/2 for llm exceptions carries the message" do
    error = Error.normalize({:llm_exception, %{kind: :error, message: "boom"}})

    assert error.code == :exception
    assert error.message == "boom"
    refute error.retryable?
  end

  test "normalize/2 maps :max_iterations_reached to a rollout error" do
    error = Error.normalize(:max_iterations_reached)

    assert error.kind == :rollout
    assert error.code == :max_iterations
    refute error.retryable?
  end

  test "normalize/2 passes an existing Error through unchanged" do
    original = %Error{kind: :tool, code: :custom, message: "as-is"}
    assert Error.normalize(original, :anthropic) == original
  end

  test "normalize/2 never crashes on unknown shapes" do
    error = Error.normalize({:weird, :tuple})

    assert error.kind == :runtime
    assert error.code == :unknown
    refute error.retryable?
  end

  describe "from_exception/3" do
    test "rescued exceptions keep their message" do
      error =
        try do
          raise ArgumentError, "bad arg"
        rescue
          e -> Error.from_exception(:error, e, __STACKTRACE__)
        end

      assert error.kind == :runtime
      assert error.code == :exception
      assert error.message == "bad arg"
      assert {:error, %ArgumentError{}, [_ | _]} = error.raw
    end

    test "caught throws and exits are normalized" do
      error = Error.from_exception(:throw, :ball, [])

      assert error.code == :exception
      assert error.message =~ "throw"
    end
  end

  test "invalid_return/1 names the contract violation" do
    error = Error.invalid_return(:oops)

    assert error.code == :invalid_rollout_return
    assert error.message =~ ":oops"
    refute error.retryable?
  end
end
