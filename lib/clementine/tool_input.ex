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
  instead. The garbled parameter keeps the text before the stray closing
  tag, and each embedded parameter the tool declares and the input lacks
  gets its value, decoded to the declared type.

  A boundary is `<parameter name="x">`, or `<x>` directly after a stray
  closing tag naming a declared parameter (or a `parameter` tag), where `x`
  is another parameter the tool declares: a signature ordinary text does not
  produce. Only top-level string parameters are repaired, and a value the
  provider delivered as a real field is never overwritten.
  """

  @closing_tag "</[^<>\\s]{1,64}>"
  @trailing_closing_tags Regex.compile!("(\\s*#{@closing_tag})+\\s*\\z")

  @doc """
  Repairs `input` (string or atom keys, as delivered) against the tool's
  `parameters`. Returns the input and the parameters the repair touched:
  empty when nothing was garbled.
  """
  @spec repair(map(), keyword()) :: {map(), [atom()]}
  def repair(input, parameters) when is_map(input) and is_list(parameters) do
    names = Keyword.keys(parameters)

    Enum.reduce(parameters, {input, []}, fn {name, opts}, {input, repaired} ->
      with :string <- Keyword.get(opts, :type),
           {key, value} when is_binary(value) <- fetch(input, name),
           [_ | _] = others <- names -- [name],
           [{first_start, _, _} | _] = boundaries <- boundaries(value, name, others) do
        head = value |> binary_part(0, first_start) |> clean()
        recovered = recover(value, boundaries, parameters, input)

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

  def repair(input, _parameters), do: {input, []}

  # Every boundary in the value, in order: {start, end, name}, where the
  # span covers the stray closing tag and the opening markup. The element
  # form needs the stray tag to close a declared parameter (or be a
  # `...parameter` tag), so ordinary HTML such as `</b> <summary>` is not
  # a boundary.
  defp boundaries(value, own, others) do
    embedded = alternatives(others)
    stray = "</(?:[^<>\\s]*parameter|#{alternatives([own | others])})>"

    regex =
      Regex.compile!(
        "(?:#{@closing_tag}\\s*)?<parameter name=\"(#{embedded})\">" <>
          "|#{stray}\\s*<(#{embedded})>"
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
  defp recover(value, boundaries, parameters, input) do
    ends = Enum.map(tl(boundaries), &elem(&1, 0)) ++ [byte_size(value)]

    boundaries
    |> Enum.zip(ends)
    |> Enum.flat_map(fn {{_start, value_start, name}, value_end} ->
      raw = value |> binary_part(value_start, value_end - value_start) |> clean()

      with false <- present?(input, name),
           {:ok, decoded} <- decode(raw, Keyword.get(parameters[name], :type)) do
        [{name, decoded}]
      else
        _ -> []
      end
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp clean(text), do: text |> String.replace(@trailing_closing_tags, "") |> String.trim()

  defp decode("", _type), do: :error
  defp decode(text, :string), do: {:ok, text}

  defp decode(text, type) do
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

  defp present?(input, name) do
    case fetch(input, name) do
      {_key, value} -> value not in [nil, ""]
      :error -> false
    end
  end

  # Nothing before the stray tag means nothing to keep: the parameter is
  # then missing, and validation reports it.
  defp put_head(input, key, ""), do: Map.delete(input, key)
  defp put_head(input, key, head), do: Map.put(input, key, head)

  defp put_recovered(input, recovered, key) when is_binary(key),
    do:
      Enum.reduce(recovered, input, fn {name, value}, acc ->
        Map.put(acc, Atom.to_string(name), value)
      end)

  defp put_recovered(input, recovered, _key),
    do: Enum.reduce(recovered, input, fn {name, value}, acc -> Map.put(acc, name, value) end)
end
