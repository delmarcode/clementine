defmodule Clementine.Loop.Codec do
  @moduledoc """
  The canonical, stable encoding for loop tags and payloads
  (LOOP_RFC §Tags And Payloads).

  Tags and payloads are terms, but they persist — in inbox rows, envelope
  maps, and idempotency keys — so they cross storage through one canonical
  codec rather than anything substrate-specific:

  - JSON scalars (`nil`, booleans, numbers, valid-UTF-8 binaries) pass
    through unchanged.
  - Tuples encode as tagged arrays (`{:reply, 5}` → `["t", [..., 5]]`) —
    the worked examples keep tuple tags, and this is why that is legal.
  - Lists are tagged too (`["l", [...]]`), so a stored array is always
    machinery-tagged and decoding is total on the codec's own writes.
  - Atoms whitelist through the loop module's declared vocabulary
    (`use Clementine.Loop, vocabulary: [...]`) and encode as `["a", name]`.
    An undeclared atom is an encode-time error, not a silent ETF escape:
    keys must be canonical across substrates and deploys.
  - Maps pass through with string keys and encoded values. Atom or
    composite keys are refused — payload maps are JSON objects.

  Anything else — structs, pids, refs, functions, invalid binaries — is
  outside the durable vocabulary and raises. `Clementine.Result` and
  friends never pass through this codec; completion payloads are carried
  as live structs in `Clementine.Loop.Input` and encoded by the host seam.

  `key/2` is the canonical string form (`tag_key`) used by envelope maps,
  the `(loop_ref, tag_key)` child dedup index, and idempotency keys. Keys
  must be byte-stable across deploys and VM versions, so tags may not
  contain maps (JSON object key order is not canonical); tag terms are
  scalars, vocabulary atoms, and tuples/lists thereof.
  """

  @type json_safe ::
          nil
          | boolean()
          | number()
          | String.t()
          | [json_safe()]
          | %{optional(String.t()) => json_safe()}

  @doc """
  Encodes a term to its canonical JSON-safe form.

  Options: `:vocabulary` — the atom whitelist (default `[]`).
  Raises `ArgumentError` on terms outside the durable vocabulary.
  """
  @spec encode(term(), keyword()) :: json_safe()
  def encode(term, opts \\ []) do
    do_encode(term, Keyword.get(opts, :vocabulary, []))
  end

  @doc """
  Decodes `encode/2` output back to the original term.

  Total on the codec's own writes given the same vocabulary; a shrunk
  vocabulary makes old payloads raise, which the drain surfaces through
  the poison path rather than a silent misread.
  """
  @spec decode(json_safe(), keyword()) :: term()
  def decode(data, opts \\ []) do
    do_decode(data, Keyword.get(opts, :vocabulary, []))
  end

  @doc """
  The canonical string form of a tag (`tag_key`): the JSON serialization
  of `encode/2`. Deterministic because tag terms exclude maps.
  """
  @spec key(term(), keyword()) :: String.t()
  def key(term, opts \\ []) do
    term
    |> encode_key_term(Keyword.get(opts, :vocabulary, []))
    |> Jason.encode!()
  end

  @doc """
  Validates that a map is plain JSON data (string keys, scalar/list/map
  values, no structs, no atoms) — the shape `child_args` must have,
  because actions are durable cargo built at host boundaries. Raises
  `ArgumentError` otherwise.
  """
  @spec validate_json_map!(term(), String.t()) :: map()
  def validate_json_map!(map, what) when is_map(map) and not is_struct(map) do
    if plain_json?(map) do
      map
    else
      raise ArgumentError,
            "#{what} must be a JSON-safe map (string keys, scalar/list/map values), got: " <>
              inspect(map)
    end
  end

  def validate_json_map!(other, what) do
    raise ArgumentError, "#{what} must be a JSON-safe map, got: #{inspect(other)}"
  end

  ## Encode

  defp do_encode(term, _vocab) when is_nil(term) or is_boolean(term) or is_number(term), do: term

  defp do_encode(term, _vocab) when is_binary(term) do
    if String.valid?(term) do
      term
    else
      raise ArgumentError, "cannot encode non-UTF-8 binary: #{inspect(term)}"
    end
  end

  defp do_encode(term, vocab) when is_atom(term) do
    if term in vocab do
      ["a", Atom.to_string(term)]
    else
      raise ArgumentError,
            "atom #{inspect(term)} is not in the loop's declared vocabulary " <>
              "(use Clementine.Loop, vocabulary: [...]); got vocabulary: #{inspect(vocab)}"
    end
  end

  defp do_encode(term, vocab) when is_tuple(term) do
    ["t", term |> Tuple.to_list() |> Enum.map(&do_encode(&1, vocab))]
  end

  defp do_encode(term, vocab) when is_list(term) do
    ["l", Enum.map(term, &do_encode(&1, vocab))]
  end

  defp do_encode(term, vocab) when is_map(term) and not is_struct(term) do
    Map.new(term, fn
      {key, value} when is_binary(key) ->
        unless String.valid?(key) do
          raise ArgumentError, "cannot encode non-UTF-8 map key: #{inspect(key)}"
        end

        {key, do_encode(value, vocab)}

      {key, _value} ->
        raise ArgumentError,
              "payload map keys must be strings, got: #{inspect(key)} — " <>
                "atom-keyed maps do not survive the storage boundary"
    end)
  end

  defp do_encode(term, _vocab) do
    raise ArgumentError,
          "cannot encode #{inspect(term)} — tags and payloads are JSON scalars, " <>
            "vocabulary atoms, tuples, lists, and string-keyed maps"
  end

  # Tag terms additionally exclude maps: a map has no canonical byte form.
  defp encode_key_term(term, _vocab) when is_map(term) do
    raise ArgumentError,
          "tags may not contain maps (no canonical key form): #{inspect(term)}"
  end

  defp encode_key_term(term, vocab) when is_tuple(term) do
    ["t", term |> Tuple.to_list() |> Enum.map(&encode_key_term(&1, vocab))]
  end

  defp encode_key_term(term, vocab) when is_list(term) do
    ["l", Enum.map(term, &encode_key_term(&1, vocab))]
  end

  defp encode_key_term(term, vocab), do: do_encode(term, vocab)

  ## Decode

  defp do_decode(term, _vocab) when is_nil(term) or is_boolean(term) or is_number(term), do: term
  defp do_decode(term, _vocab) when is_binary(term), do: term

  defp do_decode(["a", name], vocab) when is_binary(name) do
    case Enum.find(vocab, fn atom -> Atom.to_string(atom) == name end) do
      nil ->
        raise ArgumentError,
              "stored atom #{inspect(name)} is not in the loop's declared vocabulary " <>
                "#{inspect(vocab)} — did the vocabulary shrink across a deploy?"

      atom ->
        atom
    end
  end

  defp do_decode(["t", elements], vocab) when is_list(elements) do
    elements |> Enum.map(&do_decode(&1, vocab)) |> List.to_tuple()
  end

  defp do_decode(["l", elements], vocab) when is_list(elements) do
    Enum.map(elements, &do_decode(&1, vocab))
  end

  defp do_decode(term, vocab) when is_map(term) and not is_struct(term) do
    Map.new(term, fn {key, value} -> {key, do_decode(value, vocab)} end)
  end

  defp do_decode(term, _vocab) do
    raise ArgumentError, "cannot decode #{inspect(term)} — not a canonical codec form"
  end

  defp plain_json?(value)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: true

  defp plain_json?(value) when is_binary(value), do: String.valid?(value)
  defp plain_json?(value) when is_list(value), do: Enum.all?(value, &plain_json?/1)

  defp plain_json?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {k, v} -> is_binary(k) and String.valid?(k) and plain_json?(v) end)
  end

  defp plain_json?(_value), do: false
end
