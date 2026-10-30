defmodule Clementine.OutputSchema do
  @moduledoc """
  An agent's `output_schema:`: the JSON schema its final answer follows.

  With one, a run's final answer is a JSON object rather than prose, and
  `Clementine.Result.Completed`'s `output` is that object decoded: a map
  with string keys, the same map `run.result["output"]` stores and a
  loop's `{:completed, tag, result}` carries. The run uses its tools
  freely on the way; only the answer that ends it is constrained.

  The schema goes to the provider as its native structured output
  (Anthropic's `output_config.format`, OpenAI's `text.format`, the Chat
  Completions dialect's `response_format`), which constrains the model's
  decoding to it. The engine then decodes the answer, the text the final
  turn wrote last (after any tool search or thinking, and across a
  paused turn's continuation), and checks it here as well, because a provider's constraint gives way when the model
  refuses or runs out of tokens, and an OpenAI-compatible server may not
  constrain at all. An answer that is not JSON, or does not match, fails
  the run with a `Clementine.Error` of code `:invalid_output`.

  The check covers the schema's structure: `type`, `properties`,
  `required`, `additionalProperties`, `items`, `enum`, `const`, `anyOf`,
  `allOf`, and `$ref` into the schema itself. Other keywords (`format`,
  `pattern`, `minimum`, ...) are the provider's to enforce or refuse.
  """

  alias Clementine.LLM.Message.Content

  @typedoc "A JSON schema with string keys, its root an object."
  @type t :: %{required(String.t()) => term()}

  @doc """
  The schema as the agent keeps it: string keys throughout (atom keys
  and atom values such as `type: :object` become strings), and an
  object at the root, since the answer decodes to a map. Raises
  `ArgumentError` on anything else, so a bad schema on
  `use Clementine.Agent` fails the build.
  """
  @spec normalize!(term()) :: t()
  def normalize!(schema) when is_map(schema) and not is_struct(schema) do
    normalized =
      case Jason.encode(schema) do
        {:ok, json} ->
          Jason.decode!(json)

        {:error, error} ->
          raise ArgumentError,
                "output_schema: must be a JSON schema, and this one does not encode " <>
                  "as JSON: #{Exception.message(error)}"
      end

    case normalized do
      %{"type" => "object"} ->
        normalized

      _other ->
        raise ArgumentError,
              "output_schema: describes the final answer as a JSON object, so its root " <>
                "needs \"type\": \"object\"; got: #{inspect(schema)}"
    end
  end

  def normalize!(other) do
    raise ArgumentError, "output_schema: must be a JSON schema map, got: #{inspect(other)}"
  end

  @doc """
  Decodes a final answer against `schema`: `{:ok, map}`, or
  `{:error, %Clementine.Error{code: :invalid_output}}` when the answer is
  not JSON or does not match. `stop_reason` is the provider's, which
  explains an answer cut off (`"max_tokens"`) or refused (`"refusal"`).

  The answer is text, or the final turn's content blocks. From blocks,
  the answer is the text after the last block that is not text: a turn
  may say something before a tool search or a thinking block, and the
  JSON is what it writes last. Adjacent text blocks run together, so an
  answer the provider split across a paused turn and its continuation
  decodes whole. The error's `raw["output"]` keeps all of the turn's
  text.
  """
  @spec decode(t(), String.t() | [Content.t()], String.t() | nil) ::
          {:ok, map()} | {:error, Clementine.Error.t()}
  def decode(schema, answer, stop_reason \\ nil)

  def decode(schema, blocks, stop_reason) when is_map(schema) and is_list(blocks),
    do: decode_answer(schema, final_text(blocks), Content.join_text(blocks), stop_reason)

  def decode(schema, text, stop_reason) when is_map(schema) and is_binary(text),
    do: decode_answer(schema, text, text, stop_reason)

  defp decode_answer(schema, answer, text, stop_reason) do
    with {:ok, value} <- parse(answer),
         :ok <- validate(schema, value) do
      {:ok, value}
    else
      {:error, problems} -> {:error, invalid_output(problems, text, stop_reason)}
    end
  end

  defp final_text(blocks) do
    blocks
    |> Enum.reverse()
    |> Enum.take_while(&match?(%Content.Text{}, &1))
    |> Enum.reverse()
    |> Enum.map_join("", & &1.text)
  end

  defp parse(text) do
    case String.trim(text) do
      "" ->
        {:error, ["the answer is empty, not JSON"]}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, value} -> {:ok, value}
          {:error, error} -> {:error, ["the answer is not JSON: #{Exception.message(error)}"]}
        end
    end
  end

  defp invalid_output(problems, text, stop_reason) do
    %Clementine.Error{
      kind: :rollout,
      code: :invalid_output,
      message:
        "The final answer does not match the agent's output_schema: " <>
          Enum.join(problems, "; ") <> stop_note(stop_reason),
      retryable?: false,
      raw: %{"output" => text, "problems" => problems, "stop_reason" => stop_reason}
    }
  end

  defp stop_note("max_tokens"), do: " (the model hit max_tokens, so the answer is cut off)"
  defp stop_note("refusal"), do: " (the model refused)"
  defp stop_note(_stop_reason), do: ""

  @doc """
  Checks a decoded value against `schema`: `:ok`, or `{:error, problems}`
  with one line per mismatch, each naming where it is as a JSON pointer
  (`/items/0/name`; `/` is the whole answer).
  """
  @spec validate(t() | boolean(), term()) :: :ok | {:error, [String.t()]}
  def validate(schema, value) do
    case check(schema, value, "", {schema, MapSet.new()}) do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  # `ctx` is `{root, refs}`: the whole schema, which a $ref resolves
  # against, and the $refs followed at this place in the value, so a $ref
  # that leads back to itself without descending is reported rather than
  # followed forever. Descending into a property or an item clears it.
  defp check(true, _value, _path, _ctx), do: []
  defp check(false, _value, path, _ctx), do: [problem(path, "no value is allowed here")]

  defp check(%{"$ref" => ref} = schema, value, path, {root, refs} = ctx) do
    with false <- MapSet.member?(refs, ref),
         {:ok, target} <- resolve(ref, root) do
      check(target, value, path, {root, MapSet.put(refs, ref)}) ++
        check(Map.delete(schema, "$ref"), value, path, ctx)
    else
      true -> [problem(path, "the schema's $ref #{inspect(ref)} refers to itself")]
      :error -> [problem(path, "the schema's $ref #{inspect(ref)} does not resolve")]
    end
  end

  defp check(%{} = schema, value, path, ctx) do
    case check_type(schema, value, path) do
      [] ->
        check_enum(schema, value, path) ++
          check_const(schema, value, path) ++
          check_object(schema, value, path, ctx) ++
          check_items(schema, value, path, ctx) ++
          check_any_of(schema, value, path, ctx) ++
          check_all_of(schema, value, path, ctx)

      mismatch ->
        mismatch
    end
  end

  defp check(_unknown, _value, _path, _ctx), do: []

  defp descend({root, _refs}), do: {root, MapSet.new()}

  defp check_type(%{"type" => type}, value, path) do
    types = List.wrap(type)

    if Enum.any?(types, &type?(&1, value)),
      do: [],
      else: [problem(path, "expected #{Enum.join(types, " or ")}, got #{type_name(value)}")]
  end

  defp check_type(_schema, _value, _path), do: []

  defp type?("object", value), do: is_map(value)
  defp type?("array", value), do: is_list(value)
  defp type?("string", value), do: is_binary(value)

  defp type?("integer", value),
    do: is_integer(value) or (is_float(value) and value == trunc(value))

  defp type?("number", value), do: is_number(value)
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("null", value), do: is_nil(value)
  defp type?(_unknown, _value), do: true

  defp type_name(value) when is_map(value), do: "an object"
  defp type_name(value) when is_list(value), do: "an array"
  defp type_name(value) when is_binary(value), do: "a string"
  defp type_name(value) when is_integer(value), do: "an integer"
  defp type_name(value) when is_float(value), do: "a number"
  defp type_name(value) when is_boolean(value), do: "a boolean"
  defp type_name(nil), do: "null"

  defp check_enum(%{"enum" => allowed}, value, path) when is_list(allowed) do
    if Enum.any?(allowed, &(&1 == value)),
      do: [],
      else: [problem(path, "expected one of #{Jason.encode!(allowed)}")]
  end

  defp check_enum(_schema, _value, _path), do: []

  defp check_const(%{"const" => const}, value, path) do
    if const == value, do: [], else: [problem(path, "expected #{Jason.encode!(const)}")]
  end

  defp check_const(_schema, _value, _path), do: []

  defp check_object(schema, value, path, ctx) when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    missing =
      for name <- Map.get(schema, "required", []), not Map.has_key?(value, name) do
        problem(path, "missing required property #{inspect(name)}")
      end

    present =
      Enum.flat_map(value, fn {name, item} ->
        case Map.fetch(properties, name) do
          {:ok, subschema} -> check(subschema, item, child(path, name), descend(ctx))
          :error -> check_additional(schema, name, item, path, ctx)
        end
      end)

    missing ++ present
  end

  defp check_object(_schema, _value, _path, _ctx), do: []

  defp check_additional(%{"additionalProperties" => false}, name, _item, path, _ctx),
    do: [problem(path, "unexpected property #{inspect(name)}")]

  defp check_additional(%{"additionalProperties" => %{} = subschema}, name, item, path, ctx),
    do: check(subschema, item, child(path, name), descend(ctx))

  defp check_additional(_schema, _name, _item, _path, _ctx), do: []

  defp check_items(%{"items" => items}, value, path, ctx) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> check(items, item, child(path, index), descend(ctx)) end)
  end

  defp check_items(_schema, _value, _path, _ctx), do: []

  defp check_any_of(%{"anyOf" => [_ | _] = schemas}, value, path, ctx) do
    if Enum.any?(schemas, &(check(&1, value, path, ctx) == [])),
      do: [],
      else: [problem(path, "matches none of the #{length(schemas)} schemas in anyOf")]
  end

  defp check_any_of(_schema, _value, _path, _ctx), do: []

  defp check_all_of(%{"allOf" => schemas}, value, path, ctx) when is_list(schemas),
    do: Enum.flat_map(schemas, &check(&1, value, path, ctx))

  defp check_all_of(_schema, _value, _path, _ctx), do: []

  # A $ref names a place in this schema by JSON pointer (`#/$defs/item`,
  # `#/definitions/item`, `#` for the root); nothing outside it resolves.
  defp resolve("#", root), do: {:ok, root}

  defp resolve("#/" <> pointer, root) do
    pointer
    |> String.split("/")
    |> Enum.reduce_while({:ok, root}, fn segment, {:ok, node} ->
      case step(node, unescape(segment)) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp resolve(_ref, _root), do: :error

  defp step(node, segment) when is_map(node), do: Map.fetch(node, segment)

  defp step(node, segment) when is_list(node) do
    case Integer.parse(segment) do
      {index, ""} when index >= 0 and index < length(node) -> {:ok, Enum.at(node, index)}
      _ -> :error
    end
  end

  defp step(_node, _segment), do: :error

  defp unescape(segment), do: segment |> String.replace("~1", "/") |> String.replace("~0", "~")

  defp child(path, key) when is_integer(key), do: "#{path}/#{key}"

  defp child(path, key),
    do: path <> "/" <> (key |> String.replace("~", "~0") |> String.replace("/", "~1"))

  defp problem("", message), do: "/: " <> message
  defp problem(path, message), do: path <> ": " <> message
end
