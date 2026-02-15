defmodule Clementine.VerifierTest do
  use ExUnit.Case, async: true

  alias Clementine.Verifier

  # Test verifiers
  defmodule PassingVerifier do
    use Clementine.Verifier

    @impl true
    def verify(_result, _context), do: :ok
  end

  defmodule FailingVerifier do
    use Clementine.Verifier

    @impl true
    def verify(_result, _context), do: {:retry, "Verification failed"}
  end

  defmodule ConditionalVerifier do
    use Clementine.Verifier

    @impl true
    def should_run?(_result, context) do
      Map.get(context, :run_verifier, true)
    end

    @impl true
    def verify(_result, _context), do: {:retry, "Should not see this"}
  end

  defmodule CrashingVerifier do
    use Clementine.Verifier

    @impl true
    def verify(_result, _context) do
      raise "Verifier crashed!"
    end
  end

  defmodule CountingVerifier do
    use Clementine.Verifier

    @impl true
    def verify(_result, context) do
      count = context[:count] || 0

      if count >= 3 do
        :ok
      else
        {:retry, "Count is #{count}, need at least 3"}
      end
    end
  end

  describe "verify/2 callback" do
    test "passing verifier returns :ok" do
      assert :ok = PassingVerifier.verify("result", %{})
    end

    test "failing verifier returns retry tuple" do
      assert {:retry, "Verification failed"} = FailingVerifier.verify("result", %{})
    end
  end

  describe "safe_verify/3" do
    test "returns :ok for passing verifier" do
      assert :ok = Verifier.safe_verify(PassingVerifier, "result", %{})
    end

    test "returns retry for failing verifier" do
      assert {:retry, "Verification failed"} =
               Verifier.safe_verify(FailingVerifier, "result", %{})
    end

    test "catches crashes and returns retry" do
      result = Verifier.safe_verify(CrashingVerifier, "result", %{})
      assert {:retry, message} = result
      assert message =~ "crashed"
    end
  end

  describe "run_all/3" do
    test "returns :ok when no verifiers" do
      assert :ok = Verifier.run_all([], "result", %{})
    end

    test "returns :ok when all verifiers pass" do
      verifiers = [PassingVerifier, PassingVerifier]
      assert :ok = Verifier.run_all(verifiers, "result", %{})
    end

    test "returns retry at first failure" do
      verifiers = [PassingVerifier, FailingVerifier, PassingVerifier]

      result = Verifier.run_all(verifiers, "result", %{})

      assert {:retry, "Verification failed"} = result
    end

    test "stops at first failure" do
      # If we had a way to track calls, we could verify the third verifier wasn't called
      verifiers = [PassingVerifier, FailingVerifier, CrashingVerifier]

      # Should return the failing verifier's result, not crash
      result = Verifier.run_all(verifiers, "result", %{})

      assert {:retry, "Verification failed"} = result
    end

    test "skips verifier when should_run? returns false" do
      verifiers = [ConditionalVerifier]

      # With run_verifier: false, the verifier should be skipped
      result = Verifier.run_all(verifiers, "result", %{run_verifier: false})

      assert :ok = result
    end

    test "runs verifier when should_run? returns true" do
      verifiers = [ConditionalVerifier]

      result = Verifier.run_all(verifiers, "result", %{run_verifier: true})

      assert {:retry, _} = result
    end
  end

  describe "conditional verification" do
    test "verifier can use context to determine outcome" do
      # CountingVerifier passes when count >= 3
      assert {:retry, _} = Verifier.safe_verify(CountingVerifier, "result", %{count: 0})
      assert {:retry, _} = Verifier.safe_verify(CountingVerifier, "result", %{count: 2})
      assert :ok = Verifier.safe_verify(CountingVerifier, "result", %{count: 3})
      assert :ok = Verifier.safe_verify(CountingVerifier, "result", %{count: 5})
    end
  end
end
