defmodule Clementine.Models.WarningsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
    test "warns once the shipped sheets were read more than 120 days ago" do
      read = Warnings.registry_read()
      assert read == ~D[2026-11-01]

      assert Warnings.registry(Date.add(read, 120)) == nil

      assert %Warnings{kind: :stale_registry, date: ^read, message: message} =
               Warnings.registry(Date.add(read, 121))

      assert message =~ "last read on 2026-11-01, more than 120 days ago"
      assert message =~ "mix clementine.models --check"
    end
  end

  describe "at_boot/3 and log/2" do
    test "every declared agent model and offered id, labeled; a model chosen per run gives none" do
      warnings = Warnings.at_boot([Judge, Screener, Current, PerRow], ["gpt-4.1"], ~D[2026-11-02])

      assert Enum.map(warnings, fn {label, warning} -> {label, warning.kind, warning.model} end) ==
               [
                 {~s(agent "judge"), :not_before_passed, "claude-haiku-4-5"},
                 {~s(agent "screener"), :deprecated, "gpt-5"},
                 {"offered", :deprecated, "gpt-4.1"}
               ]
    end

    test "adds the stale registry, unlabeled" do
      assert [{nil, %Warnings{kind: :stale_registry}}] =
               Warnings.at_boot([Current], [], ~D[2027-06-01])
    end

    test "a model declared in config warns from its own dates" do
      Application.put_env(:clementine, :models, %{
        "claude-sonnet-legacy" => [
          based_on: "claude-sonnet-5-5",
          lifecycle: [status: :deprecated, retires_on: ~D[2020-01-01]]
        ]
      })

      assert [{"offered", %{kind: :deprecated}}, {"offered", %{kind: :retirement_reached}}] =
               Warnings.at_boot([], ["claude-sonnet-legacy"], ~D[2026-11-02])
    end

    test "log/2 writes one line per warning and returns :ok" do
      log =
        capture_log(fn ->
          assert :ok = Warnings.log([Judge, Screener], [])
        end)

      assert log =~ ~s(agent "judge": claude-haiku-4-5's not-sooner-than date, 2026-10-15)
      assert log =~ ~s(agent "screener": gpt-5 is deprecated)
      assert log =~ "See mix clementine.models"
    end
  end

  defp kinds(warnings), do: Enum.map(warnings, & &1.kind)
end
