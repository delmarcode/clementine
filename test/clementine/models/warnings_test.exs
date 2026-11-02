defmodule Clementine.Models.WarningsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Clementine.Models
  alias Clementine.Models.Warnings

  setup do
    models = Application.get_env(:clementine, :models)
    on_exit(fn -> Application.put_env(:clementine, :models, models) end)
    :ok
  end

  defmodule Judge do
    use Clementine.Agent, key: "judge", model: "claude-haiku-4-5"
  end

  defmodule Screener do
    use Clementine.Agent, key: "screener", model: "gpt-5"
  end

  defmodule Current do
    use Clementine.Agent, key: "current", model: "claude-sonnet-5-5"
  end

  defmodule PerRow do
    use Clementine.Agent, key: "per_row"

    @impl true
    def agent(_run), do: Clementine.Agent.new(model: "claude-sonnet-5-5")
  end

  describe "for_model/2" do
    test "a deprecated model warns, naming the vendor's date and replacement" do
      assert [%Warnings{kind: :deprecated, model: "gpt-5", replacement: "gpt-5.6-sol"} = warning] =
               Warnings.for_model(Models.get!("gpt-5"), ~D[2026-11-02])

      assert warning.message ==
               "gpt-5 is deprecated: OpenAI shuts it down on 2026-12-11; its replacement is " <>
                 "gpt-5.6-sol"
    end

    test "a shutdown date warns from the day it is reached" do
      gpt_5 = Models.get!("gpt-5")

      assert [:deprecated] = kinds(Warnings.for_model(gpt_5, ~D[2026-12-10]))

      assert [:deprecated, :retirement_reached] =
               kinds(Warnings.for_model(gpt_5, ~D[2026-12-11]))

      [_deprecated, reached] = Warnings.for_model(gpt_5, ~D[2027-01-01])
      assert reached.date == ~D[2026-12-11]
      assert reached.message =~ "gpt-5's shutdown date, 2026-12-11, has been reached"
      assert reached.message =~ "OpenAI's own error ends the runs that reach it"
    end

    test "a not-sooner-than date warns the day after it" do
      haiku = Models.get!("claude-haiku-4-5")

      assert [] = Warnings.for_model(haiku, ~D[2026-10-15])

      assert [%Warnings{kind: :not_before_passed, date: ~D[2026-10-15], message: message}] =
               Warnings.for_model(haiku, ~D[2026-10-16])

      assert message ==
               "claude-haiku-4-5's not-sooner-than date, 2026-10-15, has passed: Anthropic " <>
                 "may now retire it, with notice"
    end

    test "an active model before its dates gives none" do
      assert [] = Warnings.for_model(Models.get!("claude-sonnet-5-5"), ~D[2026-11-02])
    end
  end

  describe "registry/1" do
    test "warns for each vendor whose shipped sheets were read more than 120 days ago" do
      assert Warnings.registry_reads() == %{anthropic: ~D[2026-11-01], openai: ~D[2026-11-01]}

      assert Warnings.registry(~D[2027-03-01]) == []

      assert [
               %Warnings{kind: :stale_registry, vendor: :anthropic, date: ~D[2026-11-01]} =
                 anthropic,
               %Warnings{kind: :stale_registry, vendor: :openai}
             ] = Warnings.registry(~D[2027-03-02])

      assert anthropic.message =~
               "Clementine's Anthropic model sheets were last read on 2026-11-01, more than " <>
                 "120 days ago"

      assert anthropic.message =~ "mix clementine.models --check"
    end
  end

  describe "for_model/2 on a retired model" do
    test "gives none: boot refuses it, and its dates are past" do
      retired = Models.get!("claude-sonnet-4-20250514")
      assert retired.lifecycle.status == :retired
      assert retired.lifecycle.retires_on

      assert [] = Warnings.for_model(retired, ~D[2026-11-02])
    end
  end

  describe "for_agents/2 and for_offer/2" do
    test "every declared agent model, labeled; a model chosen per run gives none" do
      warnings = Warnings.for_agents([Judge, Screener, Current, PerRow], ~D[2026-11-02])

      assert Enum.map(warnings, fn {label, warning} -> {label, warning.kind, warning.model} end) ==
               [
                 {~s(agent "judge"), :not_before_passed, "claude-haiku-4-5"},
                 {~s(agent "screener"), :deprecated, "gpt-5"}
               ]
    end

    test "every offered id, labeled; an unknown one gives none" do
      assert [{"offered", %Warnings{kind: :deprecated, model: "gpt-4.1"}}] =
               Warnings.for_offer(["gpt-4.1", "claude-sonet-5-5"], ~D[2026-11-02])
    end

    test "a model declared in config warns from its own dates" do
      Application.put_env(:clementine, :models, %{
        "claude-sonnet-legacy" => [
          based_on: "claude-sonnet-5-5",
          lifecycle: [status: :deprecated, retires_on: ~D[2020-01-01]]
        ]
      })

      assert [{"offered", %{kind: :deprecated}}, {"offered", %{kind: :retirement_reached}}] =
               Warnings.for_offer(["claude-sonnet-legacy"], ~D[2026-11-02])
    end
  end

  describe "logging" do
    setup :set_mox_global

    setup do
      offer = Application.get_env(:clementine, :offer)

      on_exit(fn ->
        if offer,
          do: Application.put_env(:clementine, :offer, offer),
          else: Application.delete_env(:clementine, :offer)

        Warnings.reset()
      end)
    end

    test "log_start/0 writes the offer's warnings, one line each" do
      Application.put_env(:clementine, :offer, [{"gpt-5", max_tokens: 16_000}, "gpt-5"])

      log = capture_log(fn -> assert :ok = Warnings.log_start() end)

      assert [_one] = Regex.scan(~r/offered: gpt-5 is deprecated/, log)
      assert log =~ "See mix clementine.models"
    end

    test "log_start/0 never raises: an offer it cannot read warns" do
      Application.put_env(:clementine, :offer, {__MODULE__, :raising_offer, []})

      log = capture_log(fn -> assert :ok = Warnings.log_start() end)

      assert log =~ "Clementine could not read its offer's dates: config :clementine, :offer: "
      assert log =~ "raised RuntimeError: the offer's table is not there yet"
    end

    test "log_start/0 never raises: an offer function that throws or exits warns" do
      for function <- [:throwing_offer, :exiting_offer] do
        Application.put_env(:clementine, :offer, {__MODULE__, function, []})

        log = capture_log(fn -> assert :ok = Warnings.log_start() end)

        assert log =~ "Clementine could not read its offer's dates: config :clementine, :offer: "
        assert log =~ ~r/(threw|exited)/
        refute log =~ "sk-offer-secret"
      end
    end

    test "reset/0 lets an agent's next run log its warnings again" do
      capture_log(fn -> Warnings.log_first_run(Screener) end)
      assert capture_log(fn -> Warnings.log_first_run(Screener) end) == ""

      assert :ok = Warnings.reset()
      assert capture_log(fn -> Warnings.log_first_run(Screener) end) =~ "gpt-5 is deprecated"
    end

    test "log_agents/1 writes each agent's warnings, and its runs then log nothing more" do
      log = capture_log(fn -> assert :ok = Warnings.log_agents([Judge, Screener]) end)

      assert log =~ ~s(agent "judge": claude-haiku-4-5's not-sooner-than date, 2026-10-15)
      assert log =~ ~s(agent "screener": gpt-5 is deprecated)

      assert capture_log(fn -> Warnings.log_first_run(Judge) end) == ""
    end

    test "an agent module's first Clementine.run/3 or stream/3 logs its warnings, once" do
      stub(Clementine.LLM.MockClient, :stream, fn _model, _system, _messages, _tools, _opts ->
        [
          {:text_delta, "Done."},
          {:message_delta, %{"stop_reason" => "end_turn"},
           %{"input_tokens" => 10, "output_tokens" => 5}}
        ]
      end)

      log =
        capture_log(fn ->
          assert {:ok, _completed} = Clementine.run(Judge, "Hi")
          assert {:ok, _completed} = Clementine.run(Judge, "Hi")
        end)

      assert [_once] = Regex.scan(~r/agent "judge": claude-haiku-4-5's not-sooner-than/, log)

      log = capture_log(fn -> Clementine.stream(Screener, "Hi") |> Stream.run() end)
      assert log =~ ~s(agent "screener": gpt-5 is deprecated)
    end

    test "log_first_run/1 writes an agent's warnings the first time only" do
      log = capture_log(fn -> assert :ok = Warnings.log_first_run(Screener) end)
      assert log =~ ~s(agent "screener": gpt-5 is deprecated)

      assert capture_log(fn -> assert :ok = Warnings.log_first_run(Screener) end) == ""
    end
  end

  def raising_offer, do: raise("the offer's table is not there yet")
  def throwing_offer, do: throw({:vault, "sk-offer-secret"})
  def exiting_offer, do: exit({:vault, "sk-offer-secret"})

  defp kinds(warnings), do: Enum.map(warnings, & &1.kind)
end
