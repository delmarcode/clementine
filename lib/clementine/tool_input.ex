defmodule Clementine.ToolInput do
  @moduledoc """
  Repairs tool input a model garbled by writing later parameters as markup
  inside an earlier string parameter.

  Models occasionally end a string parameter with the wrong closing tag and
  carry on writing the remaining parameters in their own call syntax, so the
  provider delivers them as text inside the first parameter:

      %{"rationale" => "Anticoagulated.</rationale>\\n<parameter name=\\"recommended_action\\">Same-day CT"}

  Left alone, the tool sees `recommended_action` missing (the call is
  rejected when it is required, silently incomplete when it is optional)
  and a rationale with markup in it. Asking the model to resubmit tends to
  make things worse: under repeated rejections it degrades the arguments
  rather than fixing the syntax. So `repair/2` recovers the embedded values
  instead. `Clementine.Rollout` applies it to the model's calls before
  gating and execution. The garbled parameter keeps the text before the stray closing
  tag, and each embedded parameter the tool declares and the input lacks
  gets its value, decoded to the declared type. Only the call syntax's own
  tags are removed; markup that is part of a value (an email's `</p>`) is
  kept.

  A boundary is `<parameter name="x">`, or `<x>` (also seen as `<x">`)
  directly after a stray closing tag naming a declared parameter (or a
  `parameter` tag), where `x`
  is another parameter the tool declares: a signature ordinary text does not
  produce. Only top-level string parameters are repaired, and a value the
  provider delivered as a real field is never overwritten.

  A value can also end in the call syntax with no parameter after it:

      %{"tier" => "emergency</tier>\n</submit_assessment>"}

  Its own closing tag (or a `parameter` tag) followed by at least one of the
  call's closers (`</invoke>`, `</function_calls>`, a `parameter` tag, or the
  tool's own name when `:tool` is given) is cut off. A lone closing tag is
  kept: an HTML email body may well end in `</body>`.
  """

  @doc """
  Repairs `input` (string or atom keys, as delivered) against the tool's
  `parameters`. Returns the input and the parameters the repair touched:
  empty when nothing was garbled.

  Options: `:tool`, the tool's name, whose closing tag is then call syntax
  too.
  """
  @spec repair(map(), keyword(), keyword()) :: {map(), [atom()]}
  def repair(input, parameters, opts \\ [])

  def repair(input, parameters, opts) when is_map(input) and is_list(parameters) do
    names = Keyword.keys(parameters)
    tool = Keyword.get(opts, :tool)

    Enum.reduce(parameters, {input, []}, fn {name, param}, {input, repaired} ->
      with :string <- Keyword.get(param, :type),
           {key, value} when is_binary(value) <- fetch(input, name),
           {head, recovered} <- split(value, name, names -- [name], parameters, input, tool) do
        input =
          input
          |> put_head(key, head)
          |> put_recovered(recovered, key)

        {input, repaired ++ [name | Enum.map(recovered, &elem(&1, 0))]}
      else
        _ -> {input, repaired}
      end
    end)
  end

  def repair(input, _parameters, _opts), do: {input, []}

  # A garbled value as the text to keep and the embedded parameters to
  # recover, or :intact.
  defp split(value, name, others, parameters, input, tool) do
    case others != [] and boundaries(value, name, others) do
      [{first_start, _, _} | _] = found ->
        {binary_part(value, 0, first_start), recover(value, found, parameters, input, tool)}

      _ ->
        case trailing_call_syntax(value, name, tool) do
          nil -> :intact
          start -> {binary_part(value, 0, start), []}
        end
    end
  end

  # Every boundary in the value, in order: {start, end, name}, where the
  # span covers the stray closing tag and the opening markup. A stray tag
  # closes a declared parameter or is a `...parameter` tag, so ordinary
  # HTML (`</p>`, `</b> <summary>`) is neither consumed nor a boundary.
  defp boundaries(value, own, others) do
    embedded = alternatives(others)
    stray = "</(?:[^<>\\s]*parameter|#{alternatives([own | others])})>"

    regex =
      Regex.compile!(
        "(?:#{stray}\\s*)?<parameter name=\"(#{embedded})\">" <>
          "|#{stray}\\s*<(#{embedded})\"?>"
      )

    regex
    |> Regex.scan(value, return: :index)
    |> Enum.map(fn [{start, length} | groups] ->
      {start, start + length, group_name(value, groups)}
    end)
  end

  defp alternatives(names), do: Enum.map_join(names, "|", &Regex.escape(Atom.to_string(&1)))

  defp group_name(value, groups) do
    {start, length} = Enum.find(groups, fn {start, _length} -> start >= 0 end)
    value |> binary_part(start, length) |> String.to_existing_atom()
  end

  # The embedded values, as {name, decoded} for declared parameters the
  # input does not already carry; each runs to the next boundary.
  defp recover(value, boundaries, parameters, input, tool) do
    ends = Enum.map(tl(boundaries), &elem(&1, 0)) ++ [byte_size(value)]

    boundaries
    |> Enum.zip(ends)
    |> Enum.flat_map(fn {{_start, value_start, name}, value_end} ->
      raw =
        value
        |> binary_part(value_start, value_end - value_start)
        |> strip_call_syntax(name, tool)

      with false <- present?(input, name),
           {:ok, decoded} <- decode(raw, Keyword.get(parameters[name], :type)) do
        [{name, decoded}]
      else
        _ -> []
      end
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  # A recovered value may end with the call syntax's own closers: its
  # element tag, a `...parameter` tag, or the call wrappers after the last
  # parameter, separated by whitespace. They go; everything before the
  # first of them is the value, byte for byte (indentation and trailing
  # newlines included), and other markup such as an email's `</p>` stays.
  defp strip_call_syntax(text, name, tool) do
    closer = closer(name, tool)
    String.replace(text, Regex.compile!("#{closer}(?:\\s*#{closer})*\\s*\\z"), "")
  end

  # Where a value's trailing call syntax starts, if it has any: the
  # parameter's own closing tag (or a `...parameter` tag) followed by at
  # least one more closer, then only whitespace.
  defp trailing_call_syntax(value, name, tool) do
    own = "</(?:[^<>\\s]*parameter|#{Regex.escape(Atom.to_string(name))})>"
    regex = Regex.compile!("#{own}(?:\\s*#{closer(name, tool)})+\\s*\\z")

    case Regex.run(regex, value, return: :index) do
      [{start, _length}] -> start
      nil -> nil
    end
  end

  # One of the call syntax's closing tags: a `...parameter` tag, the call
  # wrappers, the parameter's element tag, or the tool's name.
  defp closer(name, tool) do
    names = Enum.map_join([name | List.wrap(tool)], "|", &Regex.escape(to_string(&1)))
    "</(?:[^<>\\s]*parameter|[^<>\\s]*invoke|[^<>\\s]*function_calls|#{names})>"
  end

  defp decode(text, type) do
    if String.trim(text) == "", do: :error, else: decode_typed(text, type)
  end

  defp decode_typed(text, :string), do: {:ok, text}

  defp decode_typed(text, type) do
    case Jason.decode(text) do
      {:ok, value} -> if typed?(value, type), do: {:ok, value}, else: :error
      {:error, _} -> :error
    end
  end

  defp typed?(value, :array), do: is_list(value)
  defp typed?(value, :object), do: is_map(value)
  defp typed?(value, :integer), do: is_integer(value)
  defp typed?(value, :number), do: is_number(value)
  defp typed?(value, :boolean), do: is_boolean(value)
  defp typed?(_value, _type), do: false

  defp fetch(input, name) do
    string_key = Atom.to_string(name)

    cond do
      Map.has_key?(input, string_key) -> {string_key, Map.get(input, string_key)}
      Map.has_key?(input, name) -> {name, Map.get(input, name)}
      true -> :error
    end
  end

  # A key the provider delivered is a real field, whatever its value.
  defp present?(input, name), do: fetch(input, name) != :error

  # Nothing but whitespace before the stray tag means nothing to keep: the
  # parameter is then missing, and validation reports it.
  defp put_head(input, key, head) do
    if String.trim(head) == "", do: Map.delete(input, key), else: Map.put(input, key, head)
  end

  defp put_recovered(input, recovered, key) when is_binary(key),
    do:
      Enum.reduce(recovered, input, fn {name, value}, acc ->
        Map.put(acc, Atom.to_string(name), value)
      end)

  defp put_recovered(input, recovered, _key),
    do: Enum.reduce(recovered, input, fn {name, value}, acc -> Map.put(acc, name, value) end)
end
