defmodule Clementine.SkillTest do
  @moduledoc """
  `Clementine.Skill` as a value: both forms, what `skills:` on an agent
  accepts and refuses, the `use_skill` engine tool the model sees, and how
  a load settles. The engine's side is in `Clementine.SkillsExecutionTest`.
  """

  use ExUnit.Case, async: true

  alias Clementine.{EngineTool, Skill, Tool}
  alias Clementine.Test.Tools.{Echo, GatedDeploy, SafeEcho}

  defmodule Refunds do
    @moduledoc false
    use Clementine.Skill,
      name: "refunds",
      description: "Review or issue a refund. Use when the customer asks for money back.",
      tools: [SafeEcho, GatedDeploy]

    @impl true
    def body(context), do: "Refund policy for #{context[:subject] || "anyone"}."
  end

  defmodule Bare do
    @moduledoc false
    use Clementine.Skill, name: "bare", description: "No tools at all."

    @impl true
    def body(_context), do: "Just words."
  end

  defmodule NotASkill do
    @moduledoc false
  end

  defmodule OtherEcho do
    @moduledoc false
    use Clementine.Tool, name: "echo", description: "Another tool named echo", parameters: []

    @impl true
    def run(_args, _context), do: {:ok, "other"}
  end

  defmodule UseSkillTool do
    @moduledoc false
    use Clementine.Tool, name: "use_skill", description: "A tool of the app's own", parameters: []

    @impl true
    def run(_args, _context), do: {:ok, "mine"}
  end

  defp agent(opts) do
    Clementine.Agent.new(Keyword.merge([model: :claude_sonnet, instructions: "Help."], opts))
  end

  describe "the use form" do
    test "defines the skill: name, description, tools, and its body/1" do
      assert %Skill{name: "refunds", tools: [SafeEcho, GatedDeploy], body: body} =
               Refunds.__skill__()

      assert body.(%{subject: "ticket 7"}) == "Refund policy for ticket 7."
      assert %Skill{tools: []} = Bare.__skill__()
    end

    test "refuses a missing or blank name, a blank description, and tools that are not modules" do
      for opts <- [
            [description: "d"],
            [name: "", description: "d"],
            [name: "x", description: ""],
            [name: "x", description: "d", tools: "nope"],
            [name: "x", description: "d", tools: ["nope"]]
          ] do
        assert_raise_on_compile(opts)
      end
    end
  end

  defp assert_raise_on_compile(opts) do
    module = Module.concat(__MODULE__, "Bad#{System.unique_integer([:positive])}")

    assert_raise_any(fn ->
      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            use Clementine.Skill, unquote(opts)
            def body(_context), do: ""
          end
        end
      )
    end)
  end

  defp assert_raise_any(fun) do
    fun.()
    flunk("expected a raise")
  rescue
    e in [ArgumentError, KeyError] -> e
  end

  describe "new/1" do
    test "builds a skill from values, its body a string or a function of the context" do
      assert %Skill{body: "Do it."} =
               Skill.new(name: "plain", description: "Plain.", body: "Do it.", tools: [Echo])

      assert %Skill{body: body} =
               Skill.new(name: "lazy", description: "Lazy.", body: fn ctx -> ctx.who end)

      assert body.(%{who: "me"}) == "me"
    end

    test "refuses a skill without a body, or with a body that is neither text nor a function of one argument" do
      assert_raise ArgumentError, fn -> Skill.new(name: "x", description: "d") end

      assert_raise ArgumentError, ~r/needs a body/, fn ->
        Skill.new(name: "x", description: "d", body: 42)
      end

      assert_raise ArgumentError, ~r/needs a body/, fn ->
        Skill.new(name: "x", description: "d", body: fn -> "zero" end)
      end
    end
  end

  describe "skills: on an agent" do
    test "takes modules and built skills, and keeps them as skills" do
      built = Skill.new(name: "plain", description: "Plain.", body: "Do it.")

      assert %Clementine.Agent{skills: [%Skill{name: "refunds"}, ^built]} =
               agent(tools: [Echo], skills: [Refunds, built])
    end

    test "the use form of an agent offers its skills" do
      defmodule SupportAgent do
        @moduledoc false
        use Clementine.Agent,
          key: "support",
          model: :claude_sonnet,
          instructions: "Help.",
          tools: [Echo],
          skills: [Clementine.SkillTest.Refunds]
      end

      assert %Clementine.Agent{skills: [%Skill{name: "refunds"}]} = SupportAgent.agent(nil)
    end

    test "lets two skills, or a skill and the agent, bring the same tool" do
      shared =
        Skill.new(name: "shared", description: "Shares safe_echo.", body: "", tools: [SafeEcho])

      assert %Clementine.Agent{} = agent(tools: [SafeEcho], skills: [Refunds, shared])
    end

    test "refuses two skills of one name" do
      again = Skill.new(name: "refunds", description: "Again.", body: "")

      assert_raise ArgumentError, ~r/more than one skill named \["refunds"\]/, fn ->
        agent(skills: [Refunds, again])
      end
    end

    test "refuses two tools of one name among everything the agent may offer" do
      other = Skill.new(name: "other", description: "Other echo.", body: "", tools: [OtherEcho])

      assert_raise ArgumentError, ~r/share the name "echo"/, fn ->
        agent(tools: [Echo], skills: [other])
      end
    end

    test "refuses a tool named use_skill when the agent offers skills, and allows it otherwise" do
      assert_raise ArgumentError, ~r/named "use_skill"/, fn ->
        agent(tools: [UseSkillTool], skills: [Bare])
      end

      assert %Clementine.Agent{skills: []} = agent(tools: [UseSkillTool])
    end

    test "refuses what is not a skill, and a skill tool that is not a tool" do
      assert_raise ArgumentError, ~r/does not use Clementine.Skill/, fn ->
        agent(skills: [NotASkill])
      end

      assert_raise ArgumentError, ~r/is not available/, fn ->
        agent(skills: [Clementine.SkillTest.Missing])
      end

      assert_raise ArgumentError, ~r/skills: takes skill modules/, fn ->
        agent(skills: ["refunds"])
      end

      assert_raise ArgumentError, ~r/skills: takes a list/, fn -> agent(skills: Refunds) end

      assert_raise ArgumentError, ~r/needs a body/, fn ->
        agent(skills: [%Skill{name: "hand_built", description: "d", body: nil}])
      end

      not_a_tool = Skill.new(name: "x", description: "d", body: "", tools: [NotASkill])

      assert_raise ArgumentError, ~r/is not a Clementine.Tool module/, fn ->
        agent(skills: [not_a_tool])
      end
    end
  end

  describe "the use_skill tool" do
    test "takes a name from an enum of the offered skills, and lists each one in its description" do
      tool = Skill.use_skill_tool([Refunds.__skill__(), Bare.__skill__()])

      assert %EngineTool{kind: :use_skill, name: "use_skill"} = tool

      assert %{
               name: "use_skill",
               description: description,
               input_schema: %{
                 "type" => "object",
                 "required" => ["name"],
                 "properties" => %{"name" => %{"type" => "string", "enum" => ["refunds", "bare"]}}
               }
             } = Tool.to_schema(tool)

      assert description =~
               "- refunds: Review or issue a refund. Use when the customer asks for money back."

      assert description =~ "- bare: No tools at all."
    end

    test "every provider client encodes it beside tool modules" do
      tool = Skill.use_skill_tool([Bare.__skill__()])

      assert [%{"name" => "echo"}, %{"name" => "use_skill", "input_schema" => schema}] =
               Clementine.LLM.Anthropic.Tools.encode_all([Echo, tool])

      assert schema["properties"]["name"]["enum"] == ["bare"]

      assert [_, %{"type" => "function", "name" => "use_skill", "parameters" => ^schema}] =
               Clementine.LLM.OpenAI.Tools.encode_all([Echo, tool])

      assert [_, %{"type" => "function", "function" => %{"name" => "use_skill"}}] =
               Clementine.LLM.ChatCompletions.Tools.encode_all([Echo, tool])
    end
  end

  describe "load/4" do
    setup do
      {:ok, skills: [Refunds.__skill__(), Bare.__skill__()]}
    end

    test "a first load answers with the body and the tools it brings", %{skills: skills} do
      assert {:loaded, %Skill{name: "refunds"}, "Refund policy for ticket 7.", content} =
               Skill.load(skills, [], %{"name" => "refunds"}, %{subject: "ticket 7"})

      assert content ==
               "Refund policy for ticket 7.\n\nIts tools are available: safe_echo, gated_deploy."

      assert {:loaded, _bare, "Just words.", "Just words.\n\nThis skill brings no tools."} =
               Skill.load(skills, [], %{"name" => "bare"}, %{})
    end

    test "a second load answers that the skill is loaded already", %{skills: skills} do
      assert {:unchanged, content} = Skill.load(skills, ["refunds"], %{"name" => "refunds"}, %{})
      assert content =~ ~s(The skill "refunds" is already loaded.)
    end

    test "a name not offered, or no name, is an error naming the skills", %{skills: skills} do
      assert {:error, ~s(There is no skill named "Elixir.File". The skills are: refunds, bare.)} =
               Skill.load(skills, [], %{"name" => "Elixir.File"}, %{})

      assert {:error, "use_skill needs the name of a skill: one of refunds, bare."} =
               Skill.load(skills, [], %{"skill" => "refunds"}, %{})

      assert {:error, _} = Skill.load(skills, [], %{"name" => 7}, %{})
    end

    test "a body that raises, exits, throws, or returns anything but text is an error, and " <>
           "nothing loads" do
      raises = Skill.new(name: "raises", description: "d", body: fn _ -> raise "no file" end)
      returns = Skill.new(name: "returns", description: "d", body: fn _ -> :nope end)

      # A call that timed out exits the caller.
      exits =
        Skill.new(
          name: "exits",
          description: "d",
          body: fn _ -> exit({:timeout, {GenServer, :call, [:somewhere, :read, 5000]}}) end
        )

      throws = Skill.new(name: "throws", description: "d", body: fn _ -> throw(:nope) end)

      assert {:error, message} = Skill.load([exits], [], %{"name" => "exits"}, %{})
      assert message =~ ~s(The skill "exits" could not be loaded: exit {:timeout, {GenServer)

      assert {:error, ~s(The skill "throws" could not be loaded: throw :nope)} =
               Skill.load([throws], [], %{"name" => "throws"}, %{})

      assert {:error, ~s(The skill "raises" could not be loaded: no file)} =
               Skill.load([raises], [], %{"name" => "raises"}, %{})

      assert {:error, message} = Skill.load([returns], [], %{"name" => "returns"}, %{})
      assert message =~ "its body is not text (:nope)"
    end
  end
end
