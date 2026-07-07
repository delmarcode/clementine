defmodule Clementine.Loop.Action do
  @moduledoc """
  What a step emits (LOOP_RFC §Vocabulary), normalized from the tuple
  forms `init/1` and `handle/2` return:

      {:run, tag, child_args}      spawn a child rollout-run
      {:timer, tag, at_or_ms}      schedule a durable timer
      {:cancel_timer, tag}         retire a pending timer
      {:send, loop_ref, payload}   append to another loop's inbox

  Actions are durable cargo, so they carry data, never structs with module
  references: `child_args` must be a plain JSON map (rollouts are built at
  the child boundary via `build_child/4`), payloads must be codec-encodable
  terms, and timers fire at an absolute `DateTime` or after a relative
  millisecond delay — the relative form stays symbolic (`{:now_plus, ms}`)
  so the host resolves it against the storage clock, never this node's.

  A malformed action is an app-contract violation and raises: the step
  fails deterministically and the causing input walks the poison path,
  informed and observable, instead of half-committed cargo.
  """

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
          kind: :run | :timer | :cancel_timer | :send,
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
    %__MODULE__{
      kind: :run,
      tag: tag,
      tag_key: Codec.key(tag, opts),
      child_args: Codec.validate_json_map!(child_args, "child_args for #{inspect(tag)}")
    }
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
          "action outside the closed set {:run, tag, args} | {:timer, tag, at_or_ms} | " <>
            "{:cancel_timer, tag} | {:send, loop_ref, payload}: #{inspect(other)}"
  end
end
