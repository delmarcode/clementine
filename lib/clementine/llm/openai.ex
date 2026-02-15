defmodule Clementine.LLM.OpenAI do
  @moduledoc """
  OpenAI Responses API client.

  Supports synchronous and streaming requests, including tool calls.
  """

  @behaviour Clementine.LLM.ClientBehaviour

  alias Clementine.LLM.Message.{AssistantMessage, Content, ToolResultMessage, UserMessage}
  alias Clementine.LLM.OpenAIStreamParser
  alias Clementine.LLM.Response
  alias Clementine.Tool

  @default_max_output_tokens 8192
  @retriable_statuses [429, 500, 502, 503, 504]

  @doc """
  Makes a synchronous call to the OpenAI Responses API.
  """
  @impl true
  def call(model, system, messages, tools, opts \\ []) do
    body = build_body(model, system, messages, tools, opts)
    headers = build_headers()

    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)

    do_call_with_retry(body, headers, max_attempts, 1)
  end

  defp do_call_with_retry(body, headers, max_attempts, attempt) do
    case Req.post(base_url(), json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, parse_response(resp_body)}

      {:ok, %{status: status}} when status in @retriable_statuses and attempt < max_attempts ->
        Process.sleep(calculate_backoff(attempt))
        do_call_with_retry(body, headers, max_attempts, attempt + 1)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, _reason} when attempt < max_attempts ->
        Process.sleep(calculate_backoff(attempt))
        do_call_with_retry(body, headers, max_attempts, attempt + 1)

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Makes a streaming call to the OpenAI Responses API.
  """
  @impl true
  def stream(model, system, messages, tools, opts \\ []) do
    body = build_body(model, system, messages, tools, opts) |> Map.put("stream", true)
    headers = build_headers()
    parent = self()
    ref = make_ref()
    pid = spawn_link(fn -> do_stream_request(body, headers, parent, ref) end)

    Stream.resource(
      fn -> {ref, pid, OpenAIStreamParser.new()} end,
      &receive_chunk/1,
      fn
        {_ref, pid, _parser} ->
          Process.unlink(pid)
          Process.exit(pid, :shutdown)

        {:halting, pid} ->
          Process.unlink(pid)
          Process.exit(pid, :shutdown)

        _ ->
          :ok
      end
    )
  end

  defp do_stream_request(body, headers, parent, ref) do
    retry_opts = Application.get_env(:clementine, :retry, [])
    max_attempts = Keyword.get(retry_opts, :max_attempts, 3)
    do_stream_request(body, headers, parent, ref, max_attempts, 1)
  end

  defp do_stream_request(body, headers, parent, ref, max_attempts, attempt) do
    data_sent = :atomics.new(1, signed: false)

    callback = fn {:data, data}, acc ->
      :atomics.put(data_sent, 1, 1)
      send(parent, {ref, {:data, data}})
      {:cont, acc}
    end

    result =
      Req.post(base_url(), json: body, headers: headers, into: callback, receive_timeout: 300_000)

    case result do
      {:ok, %{status: 200}} ->
        send(parent, {ref, :done})

      {:ok, %{status: status}} when status in @retriable_statuses and attempt < max_attempts ->
        send(parent, {ref, :retry_reset})
        Process.sleep(calculate_backoff(attempt))
        do_stream_request(body, headers, parent, ref, max_attempts, attempt + 1)

      {:ok, %{status: status, body: resp_body}} ->
        send(parent, {ref, {:error, {:api_error, status, resp_body}}})

      {:error, reason} when attempt < max_attempts ->
        if :atomics.get(data_sent, 1) == 0 do
          send(parent, {ref, :retry_reset})
          Process.sleep(calculate_backoff(attempt))
          do_stream_request(body, headers, parent, ref, max_attempts, attempt + 1)
        else
          send(parent, {ref, {:error, {:request_failed, reason}}})
        end

      {:error, reason} ->
        send(parent, {ref, {:error, {:request_failed, reason}}})
    end
  end

  defp receive_chunk({ref, pid, parser}) do
    receive do
      {^ref, {:data, data}} ->
        {events, new_parser} = OpenAIStreamParser.parse(parser, data)
        {events, {ref, pid, new_parser}}

      {^ref, :retry_reset} ->
        {[], {ref, pid, OpenAIStreamParser.new()}}

      {^ref, :done} ->
        {:halt, :done}

      {^ref, {:error, reason}} ->
        {[{:error, reason}], {:halting, pid}}
    after
      300_000 ->
        {[{:error, :timeout}], {:halting, pid}}
    end
  end

  defp receive_chunk({:halting, pid}) do
    {:halt, {:halting, pid}}
  end

  defp base_url do
    Application.get_env(:clementine, :openai_base_url, "https://api.openai.com/v1/responses")
  end

  defp calculate_backoff(attempt) do
    retry_opts = Application.get_env(:clementine, :retry, [])
    base_delay = Keyword.get(retry_opts, :base_delay, 1000)
    max_delay = Keyword.get(retry_opts, :max_delay, 30_000)

    delay = (base_delay * :math.pow(2, attempt - 1)) |> round()
    min(delay, max_delay)
  end

  defp build_body(model, system, messages, tools, opts) do
    model_config = get_model_config(model)
    model_id = Keyword.fetch!(model_config, :model)

    max_output_tokens =
      Keyword.get(
        opts,
        :max_output_tokens,
        Keyword.get(
          opts,
          :max_tokens,
          Keyword.get(
            model_config,
            :max_output_tokens,
            Keyword.get(model_config, :max_tokens, @default_max_output_tokens)
          )
        )
      )

    body = %{
      "model" => model_id,
      "input" => format_messages(messages),
      "max_output_tokens" => max_output_tokens
    }

    body =
      if is_binary(system) and system != "" do
        Map.put(body, "instructions", system)
      else
        body
      end

    if is_list(tools) and tools != [] do
      body
      |> Map.put("tools", format_tools(tools))
      |> Map.put("tool_choice", "auto")
    else
      body
    end
  end

  defp build_headers do
    [
      {"authorization", "Bearer #{get_api_key()}"},
      {"content-type", "application/json"}
    ]
  end

  defp get_api_key do
    key = resolve_api_key(Application.get_env(:clementine, :openai_api_key))

    case key do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        raise "Missing :openai_api_key configuration for :clementine"
    end
  end

  defp resolve_api_key({:system, env_var}) when is_binary(env_var), do: System.get_env(env_var)
  defp resolve_api_key(key) when is_binary(key), do: key
  defp resolve_api_key(_), do: nil

  defp get_model_config(model) when is_atom(model) do
    models = Application.get_env(:clementine, :models, [])

    case Keyword.get(models, model) do
      nil ->
        raise "Unknown model: #{inspect(model)}. Configure it in :clementine, :models"

      config ->
        case Keyword.get(config, :provider) do
          :openai ->
            config

          other ->
            raise "Model #{inspect(model)} is configured for provider #{inspect(other)}, not :openai"
        end
    end
  end

  defp format_messages(messages) do
    messages
    |> Enum.flat_map(&format_message/1)
  end

  defp format_message(%UserMessage{content: content}) when is_binary(content) do
    [%{"type" => "message", "role" => "user", "content" => content}]
  end

  defp format_message(%UserMessage{content: content}) when is_list(content) do
    format_content_blocks("user", content)
  end

  defp format_message(%AssistantMessage{content: content}) when is_list(content) do
    format_content_blocks("assistant", content)
  end

  defp format_message(%ToolResultMessage{content: content}) do
    Enum.map(content, &tool_result_to_openai/1)
  end

  defp format_content_blocks(role, blocks) do
    {items, text_buffer} =
      Enum.reduce(blocks, {[], []}, fn
        %Content{type: :text, text: text}, {items, text_buffer} ->
          {items, [text | text_buffer]}

        %Content{type: :tool_use} = block, {items, text_buffer} ->
          items = flush_text_message(role, text_buffer, items)
          {[tool_use_to_openai(block) | items], []}

        %Content{type: :tool_result} = block, {items, text_buffer} ->
          items = flush_text_message(role, text_buffer, items)
          {[tool_result_to_openai(block) | items], []}
      end)

    items
    |> then(&flush_text_message(role, text_buffer, &1))
    |> Enum.reverse()
  end

  defp flush_text_message(_role, [], items), do: items

  defp flush_text_message(role, text_buffer, items) do
    text = text_buffer |> Enum.reverse() |> Enum.join("")
    [%{"type" => "message", "role" => role, "content" => text} | items]
  end

  defp tool_use_to_openai(%Content{type: :tool_use, id: id, name: name, input: input}) do
    %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => Jason.encode!(input)
    }
  end

  defp tool_result_to_openai(%Content{type: :tool_result, tool_use_id: id, content: content}) do
    %{
      "type" => "function_call_output",
      "call_id" => id,
      "output" => content
    }
  end

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      schema = Tool.to_anthropic_format(tool)

      %{
        "type" => "function",
        "name" => schema.name,
        "description" => schema.description,
        "parameters" => schema.input_schema
      }
    end)
  end

  defp parse_response(%{"output" => output} = body) when is_list(output) do
    content =
      output
      |> Enum.flat_map(&parse_output_item/1)

    stop_reason =
      if Enum.any?(content, &(&1.type == :tool_use)) do
        "tool_use"
      else
        "end_turn"
      end

    %Response{
      content: content,
      stop_reason: stop_reason,
      usage: Map.get(body, "usage", %{}) || %{}
    }
  end

  defp parse_response(body) when is_map(body) do
    %Response{
      content: [],
      stop_reason: nil,
      usage: Map.get(body, "usage", %{}) || %{}
    }
  end

  defp parse_output_item(%{"type" => "message", "content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> [Content.text(text)]
      _ -> []
    end)
  end

  defp parse_output_item(%{"type" => "function_call"} = item) do
    call_id = Map.get(item, "call_id") || Map.get(item, "id") || "tool_call"
    name = Map.get(item, "name", "unknown")
    arguments = Map.get(item, "arguments", "{}")

    input =
      case Jason.decode(arguments) do
        {:ok, parsed} when is_map(parsed) -> parsed
        _ -> %{}
      end

    [Content.tool_use(call_id, name, input)]
  end

  defp parse_output_item(_item), do: []
end
