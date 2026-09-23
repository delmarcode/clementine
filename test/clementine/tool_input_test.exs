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

    test "recovers an element tag written with a stray quote" do
      # As delivered by the provider in a live triage screen.
      input = %{
        "tier" => "monitor",
        "summary" =>
          "Uncomplicated cystitis; needs a prescription.</summary>\n<red_flags\">[\"none\"]"
      }

      assert {%{
                "summary" => "Uncomplicated cystitis; needs a prescription.",
                "red_flags" => ["none"]
              }, [:summary, :red_flags]} = ToolInput.repair(input, @verdict)
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

    test "keeps markup that belongs to a value, removing only the call syntax" do
      email = [
        body: [type: :string, required: true],
        subject: [type: :string]
      ]

      assert {%{"body" => "<p>Hi there.</p>", "subject" => "Re: <b>your order</b>"},
              [:body, :subject]} =
               ToolInput.repair(
                 %{
                   "body" =>
                     "<p>Hi there.</p></body>\n" <>
                       "<parameter name=\"subject\">Re: <b>your order</b></parameter>\n</invoke>"
                 },
                 email
               )

      # No stray tag at all: the paragraph's own closing tag stays put.
      assert {%{"body" => "<p>Hi.</p>", "subject" => "Re: order"}, [:body, :subject]} =
               ToolInput.repair(
                 %{"body" => "<p>Hi.</p><parameter name=\"subject\">Re: order"},
                 email
               )
    end

    test "recovered values keep their whitespace exactly" do
      file = [path: [type: :string, required: true], content: [type: :string, required: true]]

      input = %{
        "path" =>
          "  notes.txt\n</path>\n<parameter name=\"content\">  indented\nline\n</parameter>\n</invoke>"
      }

      assert {%{"path" => "  notes.txt\n", "content" => "  indented\nline\n"}, [:path, :content]} =
               ToolInput.repair(input, file)

      # Whitespace-only is still nothing: missing, not a value.
      assert {repaired, [:path, :content]} =
               ToolInput.repair(%{"path" => " \n</path><parameter name=\"content\">x"}, file)

      refute Map.has_key?(repaired, "path")
      assert {_, []} = ToolInput.repair(%{"path" => "a", "content" => "b"}, file)

      assert {%{"path" => "p"} = only_path, [:path]} =
               ToolInput.repair(%{"path" => "p</path><parameter name=\"content\">  \n"}, file)

      refute Map.has_key?(only_path, "content")
    end

    test "an explicitly delivered empty or nil field counts as present" do
      for delivered <- ["", nil] do
        input = %{
          "tier" => "urgent",
          "summary" => "S",
          "recommended_action" => delivered,
          "rationale" => "R.</rationale>\n<parameter name=\"recommended_action\">Leaked"
        }

        assert {%{"recommended_action" => ^delivered, "rationale" => "R."}, [:rationale]} =
                 ToolInput.repair(input, @verdict)
      end
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

  describe "ToolRunner" do
    defmodule RecordVerdict do
      use Clementine.Tool,
        name: "record_verdict",
        description: "Records a verdict",
        parameters: [
          tier: [type: :string, required: true, enum: ["monitor", "urgent"]],
          summary: [type: :string, required: true]
        ]

      @impl true
      def run(_args, _context), do: {:ok, "recorded"}
    end

    test "passes arguments through unchanged; the rollout repairs before gating" do
      call = %{
        name: "record_verdict",
        input: %{"summary" => "Chest pain.</summary>\n<parameter name=\"tier\">urgent"}
      }

      assert {:error, "Invalid arguments: missing required parameter: tier"} =
               ToolRunner.execute_single([RecordVerdict], call, %{})
    end
  end
end
