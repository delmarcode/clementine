defmodule Clementine.Loop.Ecto.Codec do
  @moduledoc """
  The value-level mapping between `Clementine.Loop.Input` and the inbox
  recipe's `kind`/`payload` columns — public so hand-written hosts reuse
  the codecs instead of re-deriving them, exactly like
  `Clementine.Lifecycle.Ecto.Codec`.

  Tags and message payloads cross through the canonical loop codec
  (`Clementine.Loop.Codec`) under the loop module's declared vocabulary;
  tags are stored in their `tag_key` string form (the same bytes the
  child dedup index and envelope maps hold), so the child-terminal
  projection glue — which has the child row's `tag_key`, never the term —
  writes the identical representation. Open struct positions (a
  completion's `Clementine.Result`, poison evidence's ref) ride the
  lifecycle codec's tagged json/ETF convention for trusted storage.

  Encoding raises `ArgumentError` on values outside the durable
  vocabulary — an appender's contract violation surfaces at the append,
  loud and immediate. Decoding never raises: `decode_input/3` returns
  `{:error, %Clementine.Error{}}` for a payload the current code cannot
  read (a shrunk vocabulary, a foreign sender's atoms, version drift), and
  the seam surfaces it as `StoredInput.decode_error` — poison for that
  row, walked through the head-blame path, never a failed fetch (matrix
  row L7).
  """

  alias Clementine.{Error, Result}
  alias Clementine.Lifecycle.Ecto.Codec, as: LifecycleCodec
  alias Clementine.Loop.{Codec, Input, StepCommit}

  @kinds Map.new(Input.kinds(), fn kind -> {Atom.to_string(kind), kind} end)
  @dead_reasons Map.new(StepCommit.dead_reasons(), fn r -> {Atom.to_string(r), r} end)

  @doc "Encodes one input into its `{kind, payload}` column pair."
  @spec encode_input(Input.t(), keyword()) :: {String.t(), map()}
  def encode_input(%Input{kind: :message, payload: payload}, opts) do
    {"message", %{"payload" => Codec.encode(payload, opts)}}
  end

  def encode_input(%Input{kind: :completed, tag: tag, result: result}, opts) do
    {"completed", completion_payload(Codec.key(tag, opts), result)}
  end

  def encode_input(%Input{kind: :elapsed, tag: tag}, opts) do
    {"elapsed", %{"tag_key" => Codec.key(tag, opts)}}
  end

  def encode_input(%Input{kind: :input_failed, input_ref: ref, error: %Error{} = error}, _opts) do
    {"input_failed",
     %{
       "input_ref" => LifecycleCodec.encode_term(ref),
       "error" => LifecycleCodec.encode_error(error)
     }}
  end

  @doc """
  The completion payload from its stored halves — the child-terminal
  projection glue's door, where only the child row's `tag_key` exists.
  """
  @spec completion_payload(String.t(), Result.t()) :: map()
  def completion_payload(tag_key, result) when is_binary(tag_key) do
    %{"tag_key" => tag_key, "result" => LifecycleCodec.encode_term(result)}
  end

  @doc """
  The replay-stable dedup key for a child's completion append:
  `"completed:" <> tag_key <> ":" <> child_ref` (LOOP_RFC §Children) —
  identical whether the child's own terminal projection writes it or the
  reaper's `:reconcile_children` verdict synthesizes it.
  """
  @spec completion_dedup_key(String.t(), term()) :: String.t()
  def completion_dedup_key(tag_key, child_ref) when is_binary(tag_key) do
    "completed:#{tag_key}:#{ref_string(child_ref)}"
  end

  @doc """
  The elapsed payload from its stored half — the timer fire door, where
  only the schedule's durable `tag_key` exists.
  """
  @spec elapsed_payload(String.t()) :: map()
  def elapsed_payload(tag_key) when is_binary(tag_key) do
    %{"tag_key" => tag_key}
  end

  @doc """
  The dedup key for a timer fire's elapsed append:
  `"elapsed:" <> tag_key <> ":" <> schedule_id` (LOOP_RFC §Timers).

  Per schedule, not per tag: a fire's redelivery (the scheduler retrying
  its append) collapses to `:duplicate`, while a re-armed tag's next fire
  carries a fresh schedule id and lands — dead letters are retained rows
  that keep their keys, so a tag-only key would block every fire after
  the first stale one.
  """
  @spec elapsed_dedup_key(String.t(), term()) :: String.t()
  def elapsed_dedup_key(tag_key, schedule_id) when is_binary(tag_key) do
    "elapsed:#{tag_key}:#{ref_string(schedule_id)}"
  end

  @doc "Rebuilds the input from its `{kind, payload}` column pair."
  @spec decode_input(String.t(), map(), keyword()) :: {:ok, Input.t()} | {:error, Error.t()}
  def decode_input(kind, payload, opts) do
    case Map.fetch(@kinds, kind) do
      {:ok, decoded_kind} ->
        try do
          {:ok, do_decode(decoded_kind, payload, opts)}
        rescue
          e -> {:error, decode_error(kind, Exception.message(e))}
        end

      :error ->
        {:error, decode_error(kind, "unknown input kind")}
    end
  end

  defp do_decode(:message, %{"payload" => payload}, opts) do
    Input.message(Codec.decode(payload, opts))
  end

  defp do_decode(:completed, %{"tag_key" => tag_key, "result" => result}, opts) do
    Input.completed(decode_tag(tag_key, opts), LifecycleCodec.decode_term(result))
  end

  defp do_decode(:elapsed, %{"tag_key" => tag_key}, opts) do
    Input.elapsed(decode_tag(tag_key, opts))
  end

  defp do_decode(:input_failed, %{"input_ref" => ref, "error" => error}, _opts) do
    Input.input_failed(LifecycleCodec.decode_term(ref), LifecycleCodec.decode_error(error))
  end

  @doc """
  Recovers the tag term from its canonical `tag_key` string — total
  because `Clementine.Loop.Codec.key/2` is the JSON serialization of the
  codec's own key-term encoding.
  """
  @spec decode_tag(String.t(), keyword()) :: term()
  def decode_tag(tag_key, opts) when is_binary(tag_key) do
    Codec.decode(Jason.decode!(tag_key), opts)
  end

  @spec encode_dead_reason(StepCommit.dead_reason()) :: String.t()
  def encode_dead_reason(reason) when is_atom(reason) do
    text = Atom.to_string(reason)

    if is_map_key(@dead_reasons, text) do
      text
    else
      raise ArgumentError, "unknown dead-letter reason: #{inspect(reason)}"
    end
  end

  @spec decode_dead_reason(String.t()) :: StepCommit.dead_reason()
  def decode_dead_reason(text), do: Map.fetch!(@dead_reasons, text)

  @doc "One human-stable string form for refs inside machinery dedup keys."
  @spec ref_string(term()) :: String.t()
  def ref_string(ref) when is_binary(ref), do: ref
  def ref_string(ref) when is_integer(ref), do: Integer.to_string(ref)
  def ref_string(ref), do: inspect(ref)

  defp decode_error(kind, message) do
    %Error{
      kind: :runtime,
      code: :undecodable_input,
      message: "cannot decode stored #{kind} input: #{message}",
      retryable?: false,
      raw: nil
    }
  end
end
