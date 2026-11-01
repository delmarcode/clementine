defmodule Clementine.LLM.Anthropic.Fake do
  @moduledoc """
  A scripted Anthropic model for tests, which checks a replayed history
  the way the Messages API does on models that bind their thinking.

  Claude Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5, and later models
  accept a thinking block only after the exact system prompt, tools, and
  messages it was produced after, and only in the order its conversation
  produced it. Use this fake in the model mock's expectation, and a test
  fails on any edit the API would refuse: a rebuilt system prompt, a
  changed tool list, a trimmed or reordered history.

      Mox.expect(MyApp.LLMMock, :stream, fn model, system, messages, tools, opts ->
        Clementine.LLM.Anthropic.Fake.stream(model, system, messages, tools, opts, [
          {:thinking, "Checking the record."},
          {:update, "Looking up the appointment."},
          {:tool_use, "toolu_1", "lookup", %{"id" => 7}}
        ])
      end)

  It builds the request with `Clementine.LLM.Anthropic`'s own encoder,
  so it sees what the API would: Clementine's own handling of an edited
  history included (see the guide's "Models that bind their thinking").
  Each thinking block it returns carries a signature that records the
  conversation before it; a later request that replays the block after
  that conversation changed gets the API's 400 as an
  `{:error, {:api_error, 400, body}}` event, or, when the request sets
  `prefix_mismatch: :drop_block`, the block and every later one dropped.
  On a model that does not bind its thinking nothing is checked.

  A script is a list of steps, answered in order:

  - `{:thinking, text}`: a reasoning block. Its text shows only under
    `display: :summarized`, as the API's summary does.
  - `{:update, text}`: a progress update before the next tool call. Its
    text shows under `display: :updates` or `:summarized`, and under
    `thinking: :between_tools`; under the default display it is empty.
  - `{:text, text}`: answer text.
  - `{:tool_use, id, name, input}`: a tool call.

  The turn ends on `"tool_use"` when it calls a tool and `"end_turn"`
  otherwise. The fake also refuses a mid-conversation system message the
  API would: one that does not follow a user message, or that a user
  message follows.
  """

  alias Clementine.LLM.Anthropic
  alias Clementine.LLM.Anthropic.Binding

  @prefix "clementine-fake."

  @type step ::
          {:thinking, String.t()}
          | {:update, String.t()}
          | {:text, String.t()}
          | {:tool_use, String.t(), String.t(), map()}

  @doc """
  The stream events of one scripted turn, or a one-event stream carrying
  the API's 400 when the request replays thinking the API would refuse.
  Takes the arguments the mock's `stream/5` receives, then the script.
  """
  @spec stream(term(), String.t() | nil, list(), list(), keyword(), [step()]) :: list()
  def stream(model, system, messages, tools, opts, script) when is_list(script) do
    {body, binding} = Anthropic.request(model, system, messages, tools || [], opts)

    case checked(body) do
      {:ok, body} ->
        binding_events(binding) ++ turn(body, script)

      {:error, error} ->
        [{:error, error}]
    end
  end

  @doc """
  Checks the request a turn would send, as the API would: `:ok`, or the
  API's 400 as `{:error, {:api_error, 400, body}}`.
  """
  @spec check(term(), String.t() | nil, list(), list(), keyword()) ::
          :ok | {:error, {:api_error, 400, map()}}
  def check(model, system, messages, tools, opts \\ []) do
    {body, _binding} = Anthropic.request(model, system, messages, tools || [], opts)

    with {:ok, _body} <- checked(body), do: :ok
  end

  defp binding_events(nil), do: []
  defp binding_events(binding), do: [{:binding, binding}]

  ## The check

  defp checked(body) do
    with :ok <- check_system_messages(body["messages"]) do
      if Binding.binds?(body["model"]), do: check_thinking(body), else: {:ok, body}
    end
  end

  defp check_system_messages(messages) do
    last = length(messages) - 1

    messages
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn
      {%{"role" => "system"}, index} ->
        before = index > 0 and Enum.at(messages, index - 1)["role"] == "user"
        later = index == last or Enum.at(messages, index + 1)["role"] == "assistant"

        unless before and later do
          refuse(
            "messages.#{index}: a system message must follow a user message and be " <>
              "the last message or be followed by an assistant message"
          )
        end

      _message ->
        nil
    end)
  end

  # Walks the messages as the API does: each block of ours must follow
  # the conversation its signature recorded, and the thinking block the
  # conversation produced before it (or none, when a leading run of
  # thinking was left out). The first that does not fails the request,
  # or, under drop_block, goes with every thinking block after it.
  defp check_thinking(body) do
    drop? =
      get_in(body, ["thinking", "block_binding", "prefix_mismatch_behavior"]) == "drop_block"

    state = %{digest: start(body), previous: nil, failed?: false}

    body["messages"]
    |> Enum.with_index()
    |> Enum.reduce_while({[], state}, fn {message, index}, {messages, state} ->
      case check_blocks(message, index, state, drop?) do
        {:ok, message, state} ->
          {:cont, {[message | messages], %{state | digest: chain(state.digest, message)}}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      {messages, _state} -> {:ok, %{body | "messages" => Enum.reverse(messages)}}
    end
  end

  defp check_blocks(%{"content" => content} = message, index, state, drop?)
       when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], state}, fn {block, position}, {:ok, kept, state} ->
      case check_block(block, "messages.#{index}.content.#{position}", state, drop?) do
        {:keep, state} -> {:cont, {:ok, [block | kept], state}}
        {:drop, state} -> {:cont, {:ok, kept, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, kept, state} -> {:ok, Map.put(message, "content", Enum.reverse(kept)), state}
      {:error, error} -> {:error, error}
    end
  end

  defp check_blocks(message, _index, state, _drop?), do: {:ok, message, state}

  defp check_block(%{"type" => type} = block, path, state, drop?)
       when type in ["thinking", "redacted_thinking"] do
    signature = block["signature"] || block["data"]

    cond do
      state.failed? -> {:drop, state}
      valid?(signature, state) -> {:keep, %{state | previous: signature}}
      drop? -> {:drop, %{state | failed?: true}}
      true -> {:error, refusal(path)}
    end
  end

  defp check_block(_block, _path, state, _drop?), do: {:keep, state}

  defp valid?(signature, state) do
    case recorded(signature) do
      nil ->
        true

      %{"prefix" => prefix, "after" => after_id} ->
        prefix == Binding.stamp(state.digest) and
          (after_id == id(state.previous) or state.previous == nil)
    end
  end

  defp refusal(path) do
    {:api_error, 400,
     %{
       "type" => "error",
       "error" => %{
         "type" => "invalid_request_error",
         "message" =>
           "#{path}: Invalid `signature` in `thinking` block. The block is bound to a " <>
             "different conversation. Remove the block, or set " <>
             ~s(`thinking.block_binding.prefix_mismatch_behavior` to "drop_block".)
       }
     }}
  end

  defp refuse(message) do
    {:error,
     {:api_error, 400,
      %{"type" => "error", "error" => %{"type" => "invalid_request_error", "message" => message}}}}
  end

  ## The turn

  defp turn(body, script) do
    display = display(body)
    request = without_continuation(body["messages"])
    digest = Enum.reduce(request, start(body), &chain(&2, &1))
    previous = last_signature(body["messages"])

    {events, _state} =
      script
      |> Enum.with_index()
      |> Enum.flat_map_reduce(previous, fn {step, index}, previous ->
        step_events(step, index, digest, previous, display)
      end)

    stop =
      if Enum.any?(script, &match?({:tool_use, _, _, _}, &1)), do: "tool_use", else: "end_turn"

    events ++
      [{:message_delta, %{"stop_reason" => stop}, %{"input_tokens" => 10, "output_tokens" => 5}}]
  end

  defp step_events({kind, text}, index, digest, previous, display)
       when kind in [:thinking, :update] do
    signature = mint(digest, previous)

    shown =
      case {kind, display} do
        {_kind, "summarized"} -> text
        {:update, shows} when shows in ["updates", "between_tools"] -> text
        _hidden -> ""
      end

    {[
       {:content_block_start, index, :thinking},
       {:thinking_delta, shown},
       {:signature_delta, signature},
       {:content_block_stop, index}
     ], signature}
  end

  defp step_events({:text, text}, _index, _digest, previous, _display) do
    {[{:text_delta, text}], previous}
  end

  defp step_events({:tool_use, id, name, input}, index, _digest, previous, _display) do
    {[
       {:tool_use_start, id, name},
       {:input_json_delta, id, Jason.encode!(input)},
       {:content_block_stop, index}
     ], previous}
  end

  defp display(%{"thinking" => %{"type" => "between_tools"}}), do: "between_tools"
  defp display(%{"thinking" => %{"display" => display}}), do: display

  defp display(%{"model" => model}),
    do: if(Binding.binds?(model), do: "omitted", else: "summarized")

  # A request that ends with an assistant turn continues that turn (a
  # paused one): what the response adds follows the conversation before
  # it.
  defp without_continuation(messages) do
    case List.last(messages) do
      %{"role" => "assistant"} -> Enum.drop(messages, -1)
      _other -> messages
    end
  end

  defp last_signature(messages) do
    messages
    |> Enum.flat_map(fn message -> List.wrap(message["content"]) end)
    |> Enum.filter(&(is_map(&1) and &1["type"] in ["thinking", "redacted_thinking"]))
    |> Enum.map(&(&1["signature"] || &1["data"]))
    |> List.last()
  end

  ## Signatures and the API's prefix

  defp mint(digest, previous) do
    record = %{
      "prefix" => Binding.stamp(digest),
      "after" => id(previous),
      "n" => System.unique_integer([:positive])
    }

    @prefix <> Base.url_encode64(Jason.encode!(record), padding: false)
  end

  defp recorded(@prefix <> encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, record} <- Jason.decode(json),
         do: record,
         else: (_ -> nil)
  end

  defp recorded(_signature), do: nil

  defp id(nil), do: nil
  defp id(signature), do: Binding.stamp(:crypto.hash(:sha256, signature))

  # The API's prefix: the system prompt's text, the tools as a set, and
  # each earlier message without its thinking (earlier thinking is bound
  # through the chain of blocks, not the prefix) or cache breakpoints.
  defp start(body) do
    system =
      case body["system"] do
        blocks when is_list(blocks) -> Enum.map_join(blocks, "", & &1["text"])
        text -> text || ""
      end

    Binding.start(system, body["tools"])
  end

  defp chain(digest, message) do
    message =
      case message["content"] do
        content when is_list(content) ->
          content =
            content
            |> Enum.reject(&(&1["type"] in ["thinking", "redacted_thinking"]))
            |> Enum.map(&Map.delete(&1, "cache_control"))

          Map.put(message, "content", content)

        _text ->
          message
      end

    :crypto.hash(:sha256, [digest | Binding.canonical(message)])
  end
end
