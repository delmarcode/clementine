defmodule Clementine.ToolInputTest do
  use ExUnit.Case, async: true

  alias Clementine.ToolInput
  alias Clementine.ToolRunner

  @verdict [
    tier: [type: :string, required: true, enum: ["monitor", "urgent", "emergency"]],
    summary: [type: :string, required: true],
    red_flags: [type: :array, items: [type: :string]],
    rationale: [type: :string],
    recommended_action: [type: :string],
    score: [type: :integer]
  ]

  describe "repair/2" do
    test "recovers a parameter written as <parameter name=...> inside another" do
      # As delivered by the provider in a live triage screen.
      input = %{
        "tier" => "urgent",
        "summary" => "Head bump on warfarin.",
        "rationale" =>
          "Anticoagulated head injury with a supratherapeutic INR.</rationale>\n" <>
            "<parameter name=\"recommended_action\">Contact the patient today; arrange a head CT."
      }

      assert {%{
                "tier" => "urgent",
                "summary" => "Head bump on warfarin.",
                "rationale" => "Anticoagulated head injury with a supratherapeutic INR.",
                "recommended_action" => "Contact the patient today; arrange a head CT."
              }, [:rationale, :recommended_action]} = ToolInput.repair(input, @verdict)
    end

    test "recovers a run of element-form parameters, decoding them to their declared types" do
      input = %{
        "tier" => "urgent",
        "summary" =>
          "New-onset diabetes symptoms.</summary>\n" <>
            "<red_flags>[\"Polyuria for 2 months\", \"10-lb weight loss\"]</red_flags>\n" <>
            "<rationale>Classic hyperglycemia; no DKA features.</rationale>\n" <>
            "<parameter name=\"recommended_action\">Labs this week.</parameter>\n" <>
            "<parameter name=\"score\">7</parameter>"
      }

      assert {repaired, fields} = ToolInput.repair(input, @verdict)

      assert repaired == %{
               "tier" => "urgent",
               "summary" => "New-onset diabetes symptoms.",
               "red_flags" => ["Polyuria for 2 months", "10-lb weight loss"],
               "rationale" => "Classic hyperglycemia; no DKA features.",
               "recommended_action" => "Labs this week.",
               "score" => 7
             }

      assert fields == [:summary, :red_flags, :rationale, :recommended_action, :score]
    end

    test "recovers a swallowed required parameter behind a variant parameter tag" do
      input = %{
        "summary" => "Thunderclap headache.</antml：parameter>\n<parameter name=\"tier\">emergency"
      }

      assert {%{"summary" => "Thunderclap headache.", "tier" => "emergency"}, [:summary, :tier]} =
               ToolInput.repair(input, @verdict)
    end

    test "never overwrites a value delivered as a real field, but still cleans the garbled one" do
      input = %{
        "tier" => "monitor",
        "summary" => "Cold symptoms.",
        "recommended_action" => "Self-care.",
        "rationale" =>
          "Viral picture.</rationale>\n<parameter name=\"recommended_action\">Something else"
      }

      assert {%{"rationale" => "Viral picture.", "recommended_action" => "Self-care."},
              [:rationale]} = ToolInput.repair(input, @verdict)
    end

    test "skips embedded values that do not decode to the declared type" do
      input = %{
        "tier" => "urgent",
        "summary" => "Chest pain.</summary>\n<red_flags>not a list</red_flags>",
        "rationale" => "Exertional.</rationale>\n<parameter name=\"score\">high</parameter>"
      }

      assert {repaired, [:summary, :rationale]} = ToolInput.repair(input, @verdict)
      assert repaired["summary"] == "Chest pain."
      assert repaired["rationale"] == "Exertional."
      refute Map.has_key?(repaired, "red_flags")
      refute Map.has_key?(repaired, "score")
    end

    test "a garbled parameter with nothing before the stray tag is left missing" do
      input = %{"summary" => "</summary>\n<parameter name=\"tier\">monitor"}

      assert {%{"tier" => "monitor"} = repaired, [:summary, :tier]} =
               ToolInput.repair(input, @verdict)

      refute Map.has_key?(repaired, "summary")
    end

    test "leaves ordinary text alone, including markup that is not a leak" do
      for text <- [
            "Plain text with no markup.",
            "Use a <summary> element in HTML5.",
            "<p>Bold</p> <summary>not a leaked parameter</summary>",
            "Mentions tier and rationale in prose.",
            "</summary> but nothing follows"
          ] do
        input = %{"tier" => "monitor", "summary" => "S", "rationale" => text}
        assert {^input, []} = ToolInput.repair(input, @verdict)
      end
    end

    test "works on atom-keyed input and ignores non-string parameters" do
      input = %{
        tier: "urgent",
        summary: "Fall.</summary>\n<parameter name=\"rationale\">On anticoagulants.",
        score: 3
      }

      assert {%{tier: "urgent", summary: "Fall.", rationale: "On anticoagulants.", score: 3},
              [:summary, :rationale]} = ToolInput.repair(input, @verdict)
    end

    test "tolerates non-map input and tools without other parameters" do
      assert {nil, []} = ToolInput.repair(nil, @verdict)
      only = [text: [type: :string]]
      input = %{"text" => "a</text>\n<parameter name=\"text\">b"}
      assert {^input, []} = ToolInput.repair(input, only)
    end
  end

  @doc false
  def forward(_event, measurements, metadata, {pid, ref}),
    do: send(pid, {ref, measurements, metadata})

  describe "ToolRunner.execute_single/3" do
    defmodule RecordVerdict do
      use Clementine.Tool,
        name: "record_verdict",
        description: "Records a verdict",
        parameters: [
          tier: [type: :string, required: true, enum: ["monitor", "urgent"]],
          summary: [type: :string, required: true],
          rationale: [type: :string]
        ]

      @impl true
      def run(args, _context),
        do: {:ok, inspect(Map.new(args), custom_options: [sort_maps: true])}
    end

    test "runs the tool on repaired input and reports the repair" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "tool-input-repaired-#{inspect(ref)}",
        [:clementine, :tool, :input_repaired],
        &__MODULE__.forward/4,
        {test_pid, ref}
      )

      on_exit(fn -> :telemetry.detach("tool-input-repaired-#{inspect(ref)}") end)

      # Without the repair, the swallowed tier fails validation.
      call = %{
        id: "call_1",
        name: "record_verdict",
        input: %{"summary" => "Chest pain at rest.</summary>\n<parameter name=\"tier\">urgent"}
      }

      assert {:ok, %{content: content, is_error: false}} =
               ToolRunner.execute_single([RecordVerdict], call, %{})

      assert content =~ ~s(summary: "Chest pain at rest.")
      assert content =~ ~s(tier: "urgent")

      assert_receive {^ref, %{count: 2},
                      %{tool: "record_verdict", tool_call_id: "call_1", fields: [:summary, :tier]}}
    end

    test "clean input is not reported" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "tool-input-clean-#{inspect(ref)}",
        [:clementine, :tool, :input_repaired],
        &__MODULE__.forward/4,
        {test_pid, ref}
      )

      on_exit(fn -> :telemetry.detach("tool-input-clean-#{inspect(ref)}") end)

      call = %{name: "record_verdict", input: %{"tier" => "monitor", "summary" => "Fine."}}
      assert {:ok, _} = ToolRunner.execute_single([RecordVerdict], call, %{})
      refute_receive {^ref, _, _}
    end
  end
end
