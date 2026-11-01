defmodule Clementine.LLM.AnthropicBindingTest do
  @moduledoc """
  A thread on a model that binds its thinking to the conversation before
  it (Claude Sonnet 5.5 here), run turn by turn in process against
  `Clementine.LLM.Anthropic.Fake`, which refuses what the API refuses
  and, strict, any turn Clementine sent without its thinking: an
  unchanged thread replays its thinking; a changed system prompt, a
  changed tool list, a reordered history, and a window that moves cost
  the earlier turns' thinking once, are never refused by the API, and
  are reported; a skill load keeps the tool list as the first request
  sent it; and the text Sonnet 5.5 writes between tool calls reaches
  the events and the stored turn.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

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
  defp turn(agent, history, prompt, scripts, fake_opts \\ []) do
    test = self()

    for script <- scripts do
      expect(Clementine.LLM.MockClient, :stream, fn model, system, messages, tools, opts ->
        send(test, {:request, {model, system, messages, tools, opts}})
        Fake.stream(model, system, messages, tools, opts, script, fake_opts)
      end)
    end

    case Clementine.run(agent, prompt, messages: history) do
      {:ok, %Result.Completed{} = completed} ->
        {:ok, history ++ [completed.input_message | completed.messages]}

      {:error, result} ->
        {:error, result}
    end
  end

  defp turn!(agent, history, prompt, scripts, fake_opts \\ []) do
    {:ok, thread} = turn(agent, history, prompt, scripts, fake_opts)
    thread
  end

  @lenient [strict: false]

  defp unbound(thread) do
    Enum.map(thread, fn
      %AssistantMessage{} = message -> %{message | binding: nil}
      message -> message
    end)
  end

  defp flush_dropped do
    receive do
      {:thinking_dropped, _measurements, _metadata} -> flush_dropped()
    after
      0 -> :ok
    end
  end

  defp attach_dropped do
    test = self()
    id = make_ref()

    :telemetry.attach(
      id,
      [:clementine, :llm, :thinking_dropped],
      fn _event, measurements, metadata, _config ->
        send(test, {:thinking_dropped, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
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
    {body, _binding, _dropped} = Anthropic.request(model, system, messages, tools, opts)

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

  describe "which models bind" do
    test "an id Clementine cannot read is checked, and its system messages fold" do
      assert Binding.model("my-sonnet-deployment") == :unknown
      assert Binding.binds?("my-sonnet-deployment")
      refute Binding.inline_system?("my-sonnet-deployment")
      assert Binding.inline_system?("claude-sonnet-5-5")

      system =
        SystemMessage.new([%Content.ToolAddition{definition: %{"name" => "safe_echo"}}],
          skill: "notes"
        )

      messages = [UserMessage.new("Hi"), system]
      model = {:anthropic, "my-sonnet-deployment"}
      {body, binding, nil} = Anthropic.request(model, "Be brief.", messages, [Echo], [])

      assert is_binary(binding)
      assert Enum.map(body["tools"], & &1["name"]) == ["echo", "safe_echo"]
      refute Enum.any?(body["messages"], &(&1["role"] == "system"))
    end

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
      attach_dropped()
      thread = turn!(agent(), [], "Echo one.", tool_then_answer("one"))

      # The strict fake fails the turn that lost the thinking.
      changed = agent(instructions: "Be brief. The user is on mobile.")
      assert {:error, %Result.Failed{error: error}} = turn(changed, thread, "Hi.", answer("Hi."))
      assert inspect(error) =~ "messages.1: Clementine sent this turn without its thinking"

      flush_requests()
      thread = turn!(changed, thread, "Hi.", answer("Hi."), @lenient)
      assert sent_thinking() == []

      # Reported once, with counts and where it starts, never content.
      assert_received {:thinking_dropped, %{turns: 2, blocks: 2},
                       %{first_index: 1, model: "claude-sonnet-5-5", provider: :anthropic}}

      flush_requests()
      flush_dropped()
      _thread = turn!(changed, thread, "Hi again.", answer("Hi again."))
      assert [_turn_two_thinking] = sent_thinking()
      refute_received {:thinking_dropped, _, _}
    end

    test "a changed tool list costs the earlier thinking once, and is never refused" do
      thread = turn!(agent(), [], "Echo one.", tool_then_answer("one"))

      flush_requests()
      deployed = agent(tools: [Echo, SafeEcho])
      thread = turn!(deployed, thread, "Hi.", answer("Hi."), @lenient)
      assert sent_thinking() == []

      flush_requests()
      _thread = turn!(deployed, thread, "Hi again.", answer("Hi again."))
      assert [_turn_two_thinking] = sent_thinking()
    end

    test "a history replayed out of order fails the strict fake, which the API would take" do
      attach_dropped()
      one = turn!(agent(), [], "One.", answer("1"))
      two = turn!(agent(), one, "Two.", answer("2"))
      [u1, a1, u2, a2] = two

      # Sorted by when rows were written, as a queued message is: the
      # prompts first, then the replies.
      reordered = [u1, u2, a1, a2]

      assert {:error, %Result.Failed{error: error}} =
               turn(agent(), reordered, "Three.", answer("3"))

      assert inspect(error) =~ "messages.2: Clementine sent this turn without its thinking"
      assert_received {:thinking_dropped, %{turns: 2, blocks: 2}, %{first_index: 2}}

      # The API takes it, as Clementine sends it, and the reasoning is gone.
      flush_requests()
      _thread = turn!(agent(), reordered, "Three.", answer("3"), @lenient)
      assert sent_thinking() == []
    end

    test "a turn without its binding is sent without its thinking" do
      thread = turn!(agent(), [], "Echo one.", tool_then_answer("one"))

      assert {:error, %Result.Failed{error: error}} =
               turn(agent(), unbound(thread), "Hi.", answer("Hi."))

      assert inspect(error) =~ "messages.1: Clementine sent this turn without its thinking"

      flush_requests()
      _thread = turn!(agent(), unbound(thread), "Hi.", answer("Hi."), @lenient)
      assert sent_thinking() == []
    end

    test "a stepped window keeps the thinking after each cut until the next one" do
      thread =
        Enum.reduce(1..6, [], fn n, thread ->
          flush_requests()

          turn!(agent(), History.window(thread, max: 8), "Turn #{n}.", answer("#{n}"), @lenient)
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

    test "the fake refuses thinking moved into another conversation, as the API does" do
      one = turn!(agent(), [], "Echo one.", tool_then_answer("one"))
      two = turn!(agent(), [], "Echo two.", tool_then_answer("two"))

      # Thread two's last turn with thread one's thinking: its binding
      # holds, so Clementine sends it, and its signature says where it
      # came from.
      %AssistantMessage{content: [thinking | _]} = List.last(one)
      %AssistantMessage{content: [_ | rest]} = last = List.last(two)
      spliced = List.replace_at(two, -1, %{last | content: [thinking | rest]})

      assert {:error, %Result.Failed{error: error}} =
               turn(agent(), spliced, "Hi.", [[{:text, "Hi."}]], @lenient)

      assert inspect(error) =~ "bound to a different conversation"

      # prefix_mismatch: :drop_block lets the API drop what it refuses.
      model = {:anthropic, "claude-sonnet-5-5"}
      opts = [reasoning: [thinking: :adaptive, prefix_mismatch: :drop_block]]
      assert :ok = Fake.check(model, "Be brief.", spliced, [Echo], opts)

      {body, _binding, nil} = Anthropic.request(model, "Be brief.", spliced, [Echo], opts)
      assert body["thinking"]["block_binding"] == %{"prefix_mismatch_behavior" => "drop_block"}
      assert "thinking-binding-controls-2026-08-01" in Anthropic.betas(body)

      assert {:error, {:api_error, 400, _}} = Fake.check(model, "Be brief.", spliced, [Echo], [])
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
      {body, _binding, _dropped} = Anthropic.request(model, system_prompt, messages, tools, opts)
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

    test "a turn of thinking only after a skill's system message stays valid once stale" do
      agent = agent(skills: [Notes])

      # The model ends its turn on thinking alone, right after the load.
      thread =
        turn!(agent, [], "Load notes.", [
          [{:thinking, "Load."}, {:tool_use, "toolu_1", "use_skill", %{"name" => "notes"}}],
          [{:thinking, "Nothing to say."}]
        ])

      assert [_, _, _, %SystemMessage{}, %AssistantMessage{content: [%Content.Thinking{}]}] =
               thread

      # New instructions void that thinking. Sent without it the turn
      # would be empty, and a system message the next prompt follows is
      # refused: it goes as "(no reply)" instead.
      changed = agent(instructions: "Be brief. The user is on mobile.", skills: [Notes])
      flush_requests()
      thread = turn!(changed, thread, "Hi.", answer("Hi."), @lenient)

      {model, system, messages, tools, opts} = last_request()
      {body, _binding, _dropped} = Anthropic.request(model, system, messages, tools, opts)

      assert [%{"role" => "system"}, %{"role" => "assistant", "content" => stand_in}, _prompt] =
               Enum.slice(body["messages"], 3, 3)

      assert stand_in == [%{"type" => "text", "text" => "(no reply)"}]

      # The stand-in is the same every time, so the turn after it keeps
      # its thinking, and the strict fake passes.
      flush_requests()
      _thread = turn!(changed, thread, "Hi again.", answer("Hi again."))
      assert [_turn_two_thinking] = sent_thinking()
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
      {body, nil, nil} = Anthropic.request(:sonnet_5, "Be brief.", messages, [Echo, SafeEcho], [])

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

      # The update's block index, so a client tells one update from the next.
      assert [{1, "Looking it up."}] =
               for(
                 %Event{type: :thinking_delta, payload: %{index: index, content: text}} <- output,
                 do: {index, text}
               )

      assert {:result, %Result.Completed{messages: [%AssistantMessage{content: content} | _]}} =
               List.last(output)

      assert [%Content.Thinking{thinking: ""}, %Content.Thinking{thinking: "Looking it up."}, _] =
               content

      {model, system, messages, tools, opts} = last_request()
      {body, _binding, _dropped} = Anthropic.request(model, system, messages, tools, opts)
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
      {body, _binding, _dropped} = Anthropic.request(model, system, messages, tools, opts)
      assert body["thinking"] == %{"type" => "between_tools"}
      assert Anthropic.betas(body) == []
    end
  end
end
