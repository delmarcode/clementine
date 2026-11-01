defmodule Clementine.LLM.AnthropicBindingTest do
  @moduledoc """
  A thread on a model that binds its thinking to the conversation before
  it (Claude Sonnet 5.5 here), run turn by turn in process against
  `Clementine.LLM.Anthropic.Fake`, which refuses what the API refuses:
  an unchanged thread replays its thinking; a changed system prompt, a
  changed tool list, and a window that moves cost the earlier turns'
  thinking once and are never refused; a skill load keeps the tool list
  as the first request sent it; and the text Sonnet 5.5 writes between
  tool calls reaches the events and the stored turn.
  """

  use ExUnit.Case, async: false

  import Mox

  alias Clementine.{Agent, Event, History, Result}
  alias Clementine.LLM.Anthropic
  alias Clementine.LLM.Anthropic.{Binding, Fake}
  alias Clementine.LLM.Message
  alias Clementine.LLM.Message.{AssistantMessage, Content, SystemMessage, UserMessage}
  alias Clementine.Test.Tools.{Echo, SafeEcho, SafePush}

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:clementine, :models)

    Application.put_env(:clementine, :models,
      sonnet_55: [provider: :anthropic, id: "claude-sonnet-5-5"],
      sonnet_55_updates: [
        provider: :anthropic,
        id: "claude-sonnet-5-5",
        reasoning: [thinking: :adaptive, display: :updates]
      ],
      sonnet_55_between: [
        provider: :anthropic,
        id: "claude-sonnet-5-5",
        reasoning: [thinking: :between_tools, effort: :high]
      ],
      sonnet_5: [provider: :anthropic, id: "claude-sonnet-5"]
    )

    on_exit(fn -> Application.put_env(:clementine, :models, previous) end)
  end

  defmodule Notes do
    @moduledoc false
    use Clementine.Skill, name: "notes", description: "Take notes.", tools: [SafeEcho]

    @impl true
    def body(_context), do: "Keep notes short."
  end

  defmodule Drafts do
    @moduledoc false
    use Clementine.Skill, name: "drafts", description: "Draft text.", tools: [SafePush]

    @impl true
    def body(_context), do: "Draft plainly."
  end

  defp agent(opts \\ []) do
    Agent.new(Keyword.merge([model: :sonnet_55, instructions: "Be brief.", tools: [Echo]], opts))
  end

  # One turn: each script answers one model call, through the fake. The
  # requests are sent to the test process as the mock receives them.
  defp turn(agent, history, prompt, scripts) do
    test = self()

    for script <- scripts do
      expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
        send(test, {:request, {model, system, messages, tools, opts}})
        Fake.stream(model, system, messages, tools, opts, script)
      end)
    end

    case Clementine.run(agent, prompt, messages: history) do
      {:ok, %Result.Completed{} = completed} ->
        {:ok, history ++ [completed.input_message | completed.messages]}

      {:error, result} ->
        {:error, result}
    end
  end

  defp turn!(agent, history, prompt, scripts) do
    {:ok, thread} = turn(agent, history, prompt, scripts)
    thread
  end

  defp answer(text), do: [[{:thinking, "Thinking it over."}, {:text, text}]]

  defp tool_then_answer(text) do
    [
      [{:thinking, "I should echo."}, {:tool_use, "toolu_#{text}", "echo", %{"message" => text}}],
      [{:thinking, "Done echoing."}, {:text, text}]
    ]
  end

  # The thinking blocks the last request sent, as the API saw them.
  defp sent_thinking do
    {model, system, messages, tools, opts} = last_request()
    {body, _binding} = Anthropic.request(model, system, messages, tools, opts)

    for message <- body["messages"],
        is_list(message["content"]),
        block <- message["content"],
        block["type"] == "thinking",
        do: block
  end

  defp last_request do
    {:messages, messages} = Process.info(self(), :messages)
    for({:request, request} <- messages, do: request) |> List.last()
  end

  defp flush_requests do
    receive do
      {:request, _request} -> flush_requests()
    after
      0 -> :ok
    end
  end

  describe "binds?/1" do
    test "the 5.1-and-later models bind; the ones before them do not" do
      for id <- ~w(claude-fable-5-1 claude-mythos-5-1 claude-opus-5-5 claude-sonnet-5-5
                   claude-haiku-5-5 claude-opus-6 claude-opus-5-5-20261101) do
        assert Binding.binds?(id), id
      end

      for id <- ~w(claude-sonnet-5 claude-opus-5 claude-fable-5 claude-opus-4-8
                   claude-haiku-4-5-20251001 claude-sonnet-4-20250514 claude-3-5-sonnet-20241022
                   claude-mythos-preview) do
        refute Binding.binds?(id), id
      end
    end
  end

  describe "a thread on Sonnet 5.5" do
    test "an unchanged thread replays every turn's thinking, and the fake accepts it" do
      thread = turn!(agent(), [], "Echo one.", tool_then_answer("one"))

      assert [%UserMessage{}, %AssistantMessage{binding: b1}, _, %AssistantMessage{binding: b2}] =
               thread

      assert is_binary(b1) and is_binary(b2) and b1 != b2

      flush_requests()
      thread = turn!(agent(), thread, "Again.", answer("Again."))
      assert length(sent_thinking()) == 2
      assert %AssistantMessage{binding: binding} = List.last(thread)
      assert is_binary(binding)

      # The stored form round-trips, binding included, and replays the same.
      stored = thread |> Enum.map(&Message.to_map/1) |> Jason.encode!() |> Jason.decode!()
      thread = Enum.map(stored, &Message.from_map/1)
      flush_requests()
      _thread = turn!(agent(), thread, "Once more.", answer("Once more."))
      assert length(sent_thinking()) == 3
    end

    test "a changed system prompt costs the earlier thinking once, and is never refused" do
      thread = turn!(agent(), [], "Echo one.", tool_then_answer("one"))

      flush_requests()
      changed = agent(instructions: "Be brief. The user is on mobile.")
      thread = turn!(changed, thread, "Hi.", answer("Hi."))
      assert sent_thinking() == []

      flush_requests()
      _thread = turn!(changed, thread, "Hi again.", answer("Hi again."))
      assert [_turn_two_thinking] = sent_thinking()
    end

    test "a changed tool list costs the earlier thinking once, and is never refused" do
      thread = turn!(agent(), [], "Echo one.", tool_then_answer("one"))

      flush_requests()
      deployed = agent(tools: [Echo, SafeEcho])
      thread = turn!(deployed, thread, "Hi.", answer("Hi."))
      assert sent_thinking() == []

      flush_requests()
      _thread = turn!(deployed, thread, "Hi again.", answer("Hi again."))
      assert [_turn_two_thinking] = sent_thinking()
    end

    test "a stepped window keeps the thinking after each cut until the next one" do
      thread =
        Enum.reduce(1..6, [], fn n, thread ->
          flush_requests()

          turn!(agent(), History.window(thread, max: 8), "Turn #{n}.", answer("#{n}"))
          |> then(&(thread ++ Enum.drop(&1, length(History.window(thread, max: 8)))))
        end)

      # Six turns of a prompt and an answer: the window of eight has cut
      # once, at four, and the turns since the cut keep their thinking.
      assert length(thread) == 12
      window = History.window(thread, max: 8)
      assert length(window) == 8

      flush_requests()
      _thread = turn!(agent(), window, "Turn 7.", answer("7"))
      assert length(sent_thinking()) >= 1
    end

    test "the fake refuses an edit Clementine cannot see" do
      thread = turn!(agent(), [], "Echo one.", tool_then_answer("one"))

      # The host dropped the bindings and rebuilt the system prompt: the
      # thinking goes out as stored, and the API's check refuses it.
      unbound =
        Enum.map(thread, fn
          %AssistantMessage{} = message -> %{message | binding: nil}
          message -> message
        end)

      changed = agent(instructions: "Something else.")

      assert {:error, %Result.Failed{error: error}} =
               turn(changed, unbound, "Hi.", [[{:text, "Hi."}]])

      assert inspect(error) =~ "bound to a different conversation"
    end

    test "prefix_mismatch: :drop_block lets the API drop what it refuses" do
      model = {:anthropic, "claude-sonnet-5-5"}
      thread = turn!(agent(), [], "Echo one.", tool_then_answer("one"))

      unbound =
        Enum.map(thread, fn
          %AssistantMessage{} = message -> %{message | binding: nil}
          message -> message
        end)

      opts = [reasoning: [thinking: :adaptive, prefix_mismatch: :drop_block]]
      assert :ok = Fake.check(model, "Changed.", unbound, [Echo], opts)

      {body, _binding} = Anthropic.request(model, "Changed.", unbound, [Echo], opts)
      assert body["thinking"]["block_binding"] == %{"prefix_mismatch_behavior" => "drop_block"}
      assert "thinking-binding-controls-2026-08-01" in Anthropic.betas(body)

      assert {:error, {:api_error, 400, _}} = Fake.check(model, "Changed.", unbound, [Echo], [])
    end
  end

  describe "skills on a model that binds its thinking" do
    test "a load adds its tools in a system message, and the request's tools never change" do
      agent = agent(skills: [Notes])

      thread =
        turn!(agent, [], "Take a note.", [
          [{:thinking, "Load notes."}, {:tool_use, "toolu_1", "use_skill", %{"name" => "notes"}}],
          [{:thinking, "Now note."}, {:tool_use, "toolu_2", "safe_echo", %{"message" => "x"}}],
          [{:thinking, "Noted."}, {:text, "Noted."}]
        ])

      assert [%SystemMessage{skill: "notes"} = system] =
               for(%SystemMessage{} = m <- thread, do: m)

      assert [%{"name" => "safe_echo"}] = SystemMessage.tool_definitions(system)

      {model, system_prompt, messages, tools, opts} = last_request()
      {body, _binding} = Anthropic.request(model, system_prompt, messages, tools, opts)
      assert Enum.map(body["tools"], & &1["name"]) |> Enum.sort() == ["echo", "use_skill"]
      assert Enum.any?(body["messages"], &(&1["role"] == "system"))
      assert "inline-tools-2026-09-15" in Anthropic.betas(body)
      assert length(sent_thinking()) == 2

      # The next turn reads the skill back from the thread: its tool runs.
      flush_requests()

      _thread =
        turn!(agent, thread, "Another.", [
          [{:thinking, "Note again."}, {:tool_use, "toolu_3", "safe_echo", %{"message" => "y"}}],
          [{:thinking, "Noted."}, {:text, "Noted again."}]
        ])

      # Turn one's three calls, then this turn's first: nothing dropped.
      assert length(sent_thinking()) == 4
    end

    test "two skills loaded in one batch add their tools in consecutive system messages" do
      agent = agent(skills: [Notes, Drafts])

      thread =
        turn!(agent, [], "Note and draft.", [
          [
            {:tool_use, "toolu_1", "use_skill", %{"name" => "notes"}},
            {:tool_use, "toolu_2", "use_skill", %{"name" => "drafts"}}
          ],
          [{:thinking, "Both loaded."}, {:text, "Ready."}]
        ])

      assert ["notes", "drafts"] = for(%SystemMessage{skill: skill} <- thread, do: skill)

      # A system message followed by a user message is refused.
      misplaced = thread ++ [UserMessage.new("Hi")]
      i = Enum.find_index(misplaced, &match?(%SystemMessage{}, &1))
      {before, [system | rest]} = Enum.split(misplaced, i)
      broken = before ++ [system, UserMessage.new("Interjection") | rest]

      assert {:error, {:api_error, 400, _}} =
               Fake.check(:sonnet_55, "Be brief.", broken, [Echo, SafeEcho, SafePush], [])
    end

    test "on a model that does not bind, the skill's tools go in the tool list" do
      system =
        SystemMessage.new([%Content.ToolAddition{definition: %{"name" => "safe_echo"}}],
          skill: "notes"
        )

      messages = [UserMessage.new("Hi"), system]
      {body, nil} = Anthropic.request(:sonnet_5, "Be brief.", messages, [Echo, SafeEcho], [])

      assert Enum.map(body["tools"], & &1["name"]) == ["echo", "safe_echo"]
      refute Enum.any?(body["messages"], &(&1["role"] == "system"))
      assert Anthropic.betas(body) == []
    end
  end

  describe "text between tool calls" do
    test "reaches the events and the stored turn under display: :updates" do
      test = self()

      for script <- [
            [
              {:thinking, "Plan."},
              {:update, "Looking it up."},
              {:tool_use, "toolu_1", "echo", %{"message" => "x"}}
            ],
            [{:text, "Found it."}]
          ] do
        expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
          send(test, {:request, {model, system, messages, tools, opts}})
          Fake.stream(model, system, messages, tools, opts, script)
        end)
      end

      output = Clementine.stream(agent(model: :sonnet_55_updates), "Find it.") |> Enum.to_list()

      assert ["Looking it up."] =
               for(%Event{type: :thinking_delta, payload: %{content: text}} <- output, do: text)

      assert {:result, %Result.Completed{messages: [%AssistantMessage{content: content} | _]}} =
               List.last(output)

      assert [%Content.Thinking{thinking: ""}, %Content.Thinking{thinking: "Looking it up."}, _] =
               content

      {model, system, messages, tools, opts} = last_request()
      {body, _binding} = Anthropic.request(model, system, messages, tools, opts)
      assert body["thinking"] == %{"type" => "adaptive", "display" => "updates"}
      assert "thinking-display-updates-2026-08-18" in Anthropic.betas(body)
    end

    test "comes back with its text under thinking: :between_tools, with no beta" do
      thread =
        turn!(agent(model: :sonnet_55_between), [], "Find it.", [
          [{:update, "Checking."}, {:tool_use, "toolu_1", "echo", %{"message" => "x"}}],
          [{:text, "Found it."}]
        ])

      assert [%Content.Thinking{thinking: "Checking."}, _] =
               Enum.find_value(thread, fn
                 %AssistantMessage{content: [%Content.Thinking{} | _] = content} -> content
                 _ -> nil
               end)

      {model, system, messages, tools, opts} = last_request()
      {body, _binding} = Anthropic.request(model, system, messages, tools, opts)
      assert body["thinking"] == %{"type" => "between_tools"}
      assert Anthropic.betas(body) == []
    end
  end
end
