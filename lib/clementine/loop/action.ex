defmodule Clementine.Loop.Action do
  @moduledoc false
  # The pure loop core, hidden from the docs: apps reach loops through
  # Clementine.Loop and Clementine.Runs. The text below is kept for the
  # library's own readers.
  #
  #   What a step emits (LOOP_RFC §Vocabulary), normalized from the tuple
  #   forms `init/1` and `handle/2` return:
  #
  #       {:run, tag, child}           start a child run under a two-part tag
  #       {:cancel, tag}               cancel the live child under the tag
  #       {:timer, tag, at_or_ms}      schedule a durable timer
  #       {:cancel_timer, tag}         retire a pending timer
  #       {:send, loop_id, payload}    append to another loop's inbox
  #
  #   Actions are durable cargo, so they carry data, never structs with module
  #   references: `child` must be a plain JSON map (the runtime builds the
  #   child's agent at its claim, from the `"agent"` key it names), payloads
  #   must be codec-encodable terms, and timers fire at an absolute `DateTime`
  #   or after a relative millisecond delay — the relative form stays symbolic
  #   (`{:now_plus, ms}`) so the host resolves it against the storage clock,
  #   never this node's. A child's tag is `{kind, id}` (`Clementine.Loop.Codec.split_tag/1`),
  #   because the child's row stores the two halves.
  #
  #   A malformed action is an app-contract violation and raises: the step
  #   fails deterministically and the causing input walks the poison path,
  #   informed and observable, instead of half-committed cargo.

  alias Clementine.Loop.Codec

  @enforce_keys [:kind]
  defstruct kind: nil,
            tag: nil,
            tag_key: nil,
            child_args: nil,
            fire: nil,
            target: nil,
            payload: nil

  @type fire :: {:at, DateTime.t()} | {:now_plus, non_neg_integer()}

  @type t :: %__MODULE__{
          kind: :run | :cancel | :timer | :cancel_timer | :send,
          tag: term(),
          tag_key: String.t() | nil,
          child_args: map() | nil,
          fire: fire() | nil,
          target: term(),
          payload: term()
        }

  @doc """
  Normalizes one returned action tuple. `opts` are codec options
  (`:vocabulary`). Raises `ArgumentError` outside the closed action set.
  """
  @spec normalize(term(), keyword()) :: t()
  def normalize({:run, tag, child_args}, opts) do
    # A child's row stores the tag's two halves; refuse any other shape
    # here, before the step commits anything.
    _ = Codec.split_tag(tag)

    %__MODULE__{
      kind: :run,
      tag: tag,
      tag_key: Codec.key(tag, opts),
      child_args: Codec.validate_json_map!(child_args, "child for #{inspect(tag)}")
    }
  end

  def normalize({:cancel, tag}, opts) do
    _ = Codec.split_tag(tag)
    %__MODULE__{kind: :cancel, tag: tag, tag_key: Codec.key(tag, opts)}
  end

  def normalize({:timer, tag, %DateTime{} = at}, opts) do
    %__MODULE__{kind: :timer, tag: tag, tag_key: Codec.key(tag, opts), fire: {:at, at}}
  end

  def normalize({:timer, tag, ms}, opts) when is_integer(ms) and ms >= 0 do
    %__MODULE__{kind: :timer, tag: tag, tag_key: Codec.key(tag, opts), fire: {:now_plus, ms}}
  end

  def normalize({:cancel_timer, tag}, opts) do
    %__MODULE__{kind: :cancel_timer, tag: tag, tag_key: Codec.key(tag, opts)}
  end

  def normalize({:send, target, payload}, opts) do
    # Encode-validate now: a payload that cannot cross the storage boundary
    # must fail in this step, not in the host's append.
    Codec.encode(payload, opts)
    %__MODULE__{kind: :send, target: target, payload: payload}
  end

  def normalize(other, _opts) do
    raise ArgumentError,
          "action outside the closed set {:run, tag, child} | {:cancel, tag} | " <>
            "{:timer, tag, at_or_ms} | {:cancel_timer, tag} | {:send, loop_id, payload}: " <>
            inspect(other)
  end
end
