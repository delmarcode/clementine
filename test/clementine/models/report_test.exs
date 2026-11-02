defmodule Clementine.Models.ReportTest do
  use ExUnit.Case, async: false

  alias Clementine.Models
  alias Clementine.Models.Report

  setup do
    models = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, models) end)
    :ok
  end

  defmodule Chat do
    use Clementine.Agent, key: "chat", turn: true, model: "claude-sonnet-5"

    @impl true
    def history(_run), do: []
  end

  defmodule PerRow do
    use Clementine.Agent, key: "per_row"

    @impl true
    def agent(_run), do: Clementine.Agent.new(model: "claude-sonnet-5-5")
  end

  defmodule Later do
    # Declared only in config, so its check waits for boot.
    use Clementine.Agent, key: "later", model: "claude-sonnet-later", effort: :xhigh
  end

  describe "differs/2" do
    test "Sonnet 5 to 5.5: binding, thinking types, cache read multiplier, minimum prefix" do
      assert Report.differs(Models.get!("claude-sonnet-5"), Models.get!("claude-sonnet-5-5")) == [
               %{fact: :binding, from: :none, to: :prefix},
               %{fact: :thinking, from: [:adaptive, :off], to: [:adaptive, :between_tools]},
               %{fact: :cache_read, from: 0.1, to: 0.05},
               %{fact: :min_prefix, from: 1024, to: 512}
             ]
    end

    test "Haiku 4.5 to 5.5: context, price, and a tier" do
      differs = Report.differs(Models.get!("claude-haiku-4-5"), Models.get!("claude-haiku-5-5"))

      assert %{from: 200_000, to: 1_000_000} = Enum.find(differs, &(&1.fact == :context))

      assert %{from: %{input: 1.0, output: 5.0}, to: %{input: 0.1, output: 0.5}} =
               Enum.find(differs, &(&1.fact == :price))

      assert %{from: nil, to: 100_000} = Enum.find(differs, &(&1.fact == :tier))
      refute Enum.find(differs, &(&1.fact == :cache_read))
    end

    test "an app's price override is what it compares" do
      Application.put_env(:clementine, :models, %{
        "claude-sonnet-5-5" => [
          prices: [currency: "USD", input: 1.80, output: 9, cache_read: 0.09, cache_write: 2.25]
        ]
      })

      assert [%{fact: :price, to: %{input: 1.8, output: 9.0}}] =
               Models.get!("claude-sonnet-5")
               |> Report.differs(Models.get!("claude-sonnet-5-5"))
               |> Enum.filter(&(&1.fact == :price))
    end
  end

  describe "rows" do
    test "an agent's row: its model on its platform, the newest in its line, and what differs" do
      row = Report.agent_row(Chat, ~D[2026-11-02])

      assert %{
               agent: "chat",
               module: "Clementine.Models.ReportTest.Chat",
               source: :agent,
               model: "claude-sonnet-5",
               vendor: :anthropic,
               platform: :anthropic,
               lifecycle: %{status: :active, retires_not_before: ~D[2027-06-30]},
               newest: "claude-sonnet-5-5",
               warnings: [],
               error: nil
             } = row

      assert length(row.differs) == 4
    end

    test "the newest model has no newest and nothing to differ" do
      assert %{model: "claude-sonnet-5-5", newest: nil, differs: []} =
               Report.model_row(:cli, "claude-sonnet-5-5", [], ~D[2026-11-02])
    end

    test "the newest is the newest its platform serves, or none" do
      declared = fn released_on ->
        [
          vendor: :anthropic,
          line: :sonnet,
          released_on: released_on,
          context: 200_000,
          max_output: 16_000,
          platforms: [openrouter: []]
        ]
      end

      # Sonnet 5.5 is the line's newest, but OpenRouter does not serve it.
      Application.put_env(:clementine, :models, %{
        "anthropic/claude-sonnet-x" => declared.(~D[2026-01-01])
      })

      assert %{platform: :openrouter, newest: nil, differs: []} =
               Report.model_row(:cli, "anthropic/claude-sonnet-x", [], ~D[2026-11-02])

      Application.put_env(:clementine, :models, %{
        "anthropic/claude-sonnet-x" => declared.(~D[2026-01-01]),
        "anthropic/claude-sonnet-y" => declared.(~D[2026-02-01])
      })

      assert %{platform: :openrouter, newest: "anthropic/claude-sonnet-y"} =
               Report.model_row(:cli, "anthropic/claude-sonnet-x", [], ~D[2026-11-02])
    end

    test "an offered entry is resolved with the offer's choices for it" do
      assert %{model: "claude-opus-5-5", error: nil} =
               Report.model_row(:offer, "claude-opus-5-5", [max_tokens: 64_000], ~D[2026-11-02])

      assert %{model: "claude-opus-5-5", error: error, lifecycle: %{status: :active}} =
               Report.model_row(:offer, "claude-opus-5-5", [thinking: :off], ~D[2026-11-02])

      assert error =~ "refuses thinking: :off"
    end

    test "a model whose platform has no credential is one boot refuses" do
      client = Application.get_env(:clementine, :llm_client)
      on_exit(fn -> Application.put_env(:clementine, :llm_client, client) end)

      # The real router, as the task runs in an app, with no Anthropic key.
      Application.put_env(:clementine, :llm_client, Clementine.LLM.Router)
      Clementine.TestPlatforms.put(anthropic: [])

      assert %{model: "claude-sonnet-5", platform: :anthropic, error: error} =
               Report.agent_row(Chat, ~D[2026-11-02])

      assert error =~ "config :clementine, :platforms, anthropic: [api_key: ...] is not set"
    end

    test "a model with no line names no newest" do
      Application.put_env(:clementine, :models, %{
        "acme-triage" => [
          vendor: :acme,
          context: 32_000,
          max_output: 4_000,
          platforms: [openai_compatible: []]
        ]
      })

      assert %{line: nil, newest: nil, error: nil} =
               Report.model_row(:cli, "acme-triage", [], ~D[2026-11-02])
    end

    test "an agent that picks its model per run has a row without one" do
      assert %{agent: "per_row", model: nil, platform: nil, error: nil} =
               Report.agent_row(PerRow, ~D[2026-11-02])
    end

    test "a model boot would refuse has its reason, and its facts where it has a sheet" do
      assert %{model: "claude-sonnet-later", error: error, lifecycle: nil} =
               Report.agent_row(Later, ~D[2026-11-02])

      assert error =~ ~s(unknown model "claude-sonnet-later")

      # Retired: not compared with its line, and no warning beside the error.
      assert %{
               model: "claude-sonnet-4-20250514",
               error: error,
               lifecycle: %{status: :retired},
               newest: nil,
               differs: [],
               warnings: []
             } = Report.model_row(:offer, "claude-sonnet-4-20250514", [], ~D[2026-11-02])

      assert error =~ "is retired"

      # Declared in config, the effort its use names is refused.
      Application.put_env(:clementine, :models, %{
        "claude-sonnet-later" => [based_on: "claude-haiku-4-5", line: :sonnet]
      })

      assert %{error: error, platform: :anthropic, newest: "claude-sonnet-5-5"} =
               Report.agent_row(Later, ~D[2026-11-02])

      assert error =~ "effort"
    end

    test "the warnings of each row, and the registry's age, collected with their subjects" do
      report =
        Report.build(
          [Chat],
          [{:offer, "claude-haiku-4-5", []}, {:cli, "gpt-5", []}],
          ~D[2027-04-01]
        )

      assert %{
               registry: %{
                 reads: %{anthropic: ~D[2026-11-01], openai: ~D[2026-11-01]},
                 stale_after_days: 120,
                 stale: [:anthropic, :openai]
               }
             } = report

      assert Enum.map(report.warnings, &{&1.subject, &1.kind, &1[:vendor]}) == [
               {"offered", :not_before_passed, :anthropic},
               {"--model", :deprecated, :openai},
               {"--model", :retirement_reached, :openai},
               {nil, :stale_registry, :anthropic},
               {nil, :stale_registry, :openai}
             ]
    end
  end
end
