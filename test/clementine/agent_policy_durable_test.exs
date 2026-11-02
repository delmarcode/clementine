defmodule Clementine.AgentPolicyDurableTest do
  @moduledoc """
  An agent's choices reach the request body the client builds, through
  the durable runtime's claim: `cache: false` on `use`, and on the
  `Agent.new/1` an `agent/1` returns, sends no `cache_control`.
  `Clementine.AgentPolicyTest` has the same in process.
  """
  use Clementine.RunsCase

  alias Clementine.LLM.Anthropic

  defmodule UseCacheOff do
    @moduledoc false
    use Clementine.Agent,
      key: "test_policy_use_cache_off",
      model: "claude-sonnet-5-5",
      instructions: "Be brief.",
      cache: false
  end

  defmodule NewCacheOff do
    @moduledoc false
    use Clementine.Agent, key: "test_policy_new_cache_off", model: "claude-sonnet-5-5"

    @impl true
    def agent(_run), do: Clementine.Agent.new(instructions: "Be brief.", cache: false)
  end

  # agent/1 picks another model for the run (an eval's): use's effort
  # and TTL are Sonnet 5.5's, and Haiku 4.5 takes neither, so they do not
  # apply.
  defmodule PerRunModel do
    @moduledoc false
    use Clementine.Agent,
      key: "test_policy_per_run_model",
      model: "claude-sonnet-5-5",
      effort: :xhigh,
      cache: [ttl: :one_hour]

    @impl true
    def agent(run) do
      Clementine.Agent.new(model: run.metadata["model"] || __model__(), instructions: "Hi.")
    end
  end

  @moduletag runtime: false

  setup do
    start_supervised!(
      {Clementine,
       repo: TestRepo,
       agents: [UseCacheOff, NewCacheOff, PerRunModel],
       host: Clementine.RunsCase.Host}
    )

    :ok
  end

  # The body the Anthropic client would send for the request the engine
  # made.
  defp expect_body do
    test = self()

    expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
      {body, _binding, _dropped} = Anthropic.request(model, system, messages, tools, opts)
      send(test, {:body, body})
      text_events("Done.")
    end)
  end

  for agent <- [UseCacheOff, NewCacheOff] do
    test "cache: false from #{inspect(agent)} reaches the request body" do
      {:ok, run} = Runs.start(unquote(agent), "Hi")
      expect_body()

      assert :ok = perform_job(Worker, %{"run_id" => run.id})
      assert %AgentRun{status: "completed"} = Runs.get(run.id)

      assert_received {:body, body}
      refute Map.has_key?(body, "cache_control")
      assert body["system"] == "Be brief."
    end
  end

  test "a per-run model runs on its own defaults, not use's choices for another model" do
    {:ok, run} = Runs.start(PerRunModel, "Hi", metadata: %{"model" => "claude-haiku-4-5"})
    expect_body()

    assert :ok = perform_job(Worker, %{"run_id" => run.id})
    assert %AgentRun{status: "completed"} = Runs.get(run.id)

    assert_received {:body, body}
    assert body["model"] == "claude-haiku-4-5"
    refute Map.has_key?(body, "output_config")
    assert body["cache_control"] == %{"type" => "ephemeral"}
  end
end
