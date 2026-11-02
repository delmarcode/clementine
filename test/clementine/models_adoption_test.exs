defmodule Clementine.ModelsAdoptionTest do
  # yakky's and Meli's configs from section 3 of the model-selection
  # design, as fixtures: each agent names its model by id and carries its
  # own policy, and boot accepts them. The apps adopt in their own PRs
  # (OPS-201, OPS-202).
  use ExUnit.Case, async: false

  alias Clementine.{Agent, Models}

  setup do
    models = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, models) end)
    :ok
  end

  defmodule Yakky.Screener do
    use Clementine.Agent,
      key: "yakky_triage",
      model: "claude-sonnet-5-5",
      effort: :high,
      max_tokens: 16_000

    @impl true
    def agent(%{metadata: metadata}) do
      Clementine.Agent.new(
        # The eval's override for this run, else the declared model.
        model: metadata["model"] || __model__(),
        instructions: "Triage the conversation.",
        defaults: [max_iterations: 8],
        trace: :content
      )
    end
  end

  defmodule Yakky.PatientAssistant do
    use Clementine.Agent,
      key: "yakky_chat",
      turn: true,
      model: "claude-sonnet-5",
      effort: :high,
      max_tokens: 16_000,
      cache: [ttl: :one_hour]

    @impl true
    def agent(_run), do: Clementine.Agent.new(instructions: "Help the patient.")

    @impl true
    def history(_run), do: []
  end

  test "yakky: two agents, two choices, and boot accepts both" do
    config =
      Clementine.Runs.Config.new!(
        repo: Clementine.TestRepo,
        agents: [Yakky.Screener, Yakky.PatientAssistant]
      )

    assert map_size(config.agents) == 2
    assert Yakky.Screener.__model__() == "claude-sonnet-5-5"

    # The runtime fills what agent/1 leaves unset from the module's use.
    screener = Agent.declared!(Yakky.Screener, Yakky.Screener.agent(%{metadata: %{}}))
    assert %Agent{model: "claude-sonnet-5-5", effort: :high, max_tokens: 16_000} = screener

    assistant = Agent.declared!(Yakky.PatientAssistant, Yakky.PatientAssistant.agent(%{}))
    assert %Agent{model: "claude-sonnet-5", cache: [ttl: :one_hour]} = assistant

    # mix yakky.eval --model claude-opus-5-5: the id rides in run
    # metadata. use's choices are for its own model, so the eval's model
    # runs on its own defaults.
    opus = %{metadata: %{"model" => "claude-opus-5-5"}}

    assert %Agent{model: "claude-opus-5-5", effort: nil, max_tokens: nil} =
             Agent.declared!(Yakky.Screener, Yakky.Screener.agent(opus))
  end

  test "Meli: a tenant picks from an offer, and the registry describes it" do
    offered = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "gpt-6-astra"]

    # Meli.Agent.agent/1, once per stored row's model.
    for id <- offered do
      assert %Agent{model: ^id} =
               Clementine.Agent.new(
                 id: "workspace-agent-1",
                 model: id,
                 effort: :high,
                 max_tokens: 16_000,
                 instructions: "Answer the workspace's questions."
               )
    end

    # available_models: the offer, described by the registry.
    available =
      for id <- offered, model = Models.get!(id) do
        %{
          value: id,
          label: model.display_name,
          provider: model.vendor,
          line: model.line,
          lifecycle: model.lifecycle.status
        }
      end

    assert %{label: "Claude Opus 5.5", provider: :anthropic, line: :opus, lifecycle: :active} =
             hd(available)

    assert %{label: "GPT-6 Astra", provider: :openai, line: :astra} = List.last(available)
  end

  test "an override with a negotiated rate, and a fine-tune the app declares, boot" do
    Application.put_env(:clementine, :models, %{
      "claude-opus-5-5" => [
        prices: [
          input: 3.60,
          output: 18.00,
          cache_read: 0.18,
          cache_write: [five_minutes: 4.50, one_hour: 7.20],
          currency: "USD",
          source: "contract 2026-10",
          read: ~D[2026-10-15]
        ]
      ],
      # The design's example names an app platform (`tinker:`), which
      # arrives with Clementine.Platform (OPS-195); until then the
      # endpoint rides on the OpenAI-compatible platform entry.
      "qwen3-triage-ft" => [
        vendor: :qwen,
        line: :qwen3,
        context: 128_000,
        max_output: 16_000,
        thinking: [default: :off, types: [:off]],
        cache: [min_prefix: 0, ttls: []],
        platforms: [
          openai_compatible: [
            id: "tinker://run:train:0/sampler_weights/000080",
            base_url: "https://tinker.example/v1",
            api_key: {:system, "TINKER_API_KEY"}
          ]
        ]
      ]
    })

    assert :ok = Models.validate_config!()
    assert %{input: 3_600_000, read: ~D[2026-10-15]} = Models.get!("claude-opus-5-5").prices
    assert %Agent{} = Agent.new(model: "qwen3-triage-ft", max_tokens: 8_000)
    assert %Agent{} = Agent.new(model: "claude-opus-5-5", cache: [ttl: :one_hour])
  end
end
