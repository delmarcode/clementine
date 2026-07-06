defmodule Clementine.Checkpoint do
  @moduledoc """
  Serializable rollout progress at a boundary — the durable representation
  that makes suspension safe.

  A checkpoint is loop state, not an event history: resume is snapshot
  restoration, not replay. `messages` is the full canonical message list
  accumulated so far (bounded in practice by the model's context window);
  `pending` records which boundary execution stopped on; `cursor` is the
  last `{epoch, seq}` the execution emitted, so event ordering survives
  suspension.

  `version` names the envelope format, including the embedded canonical
  message encoding. Resuming across a deploy that changed the format fails
  cleanly as `:incompatible_checkpoint` — never a crash — and the host
  chooses between accepting the failed terminal and restarting the rollout
  fresh from its original spec.

  Checkpoint-on-suspend (this epic) and checkpoint-every-iteration (the
  future tool-call ledger) are the same mechanism at different cadences;
  nothing here assumes suspension.
  """

  alias Clementine.LLM.Message
  alias Clementine.{Error, Pending, Usage}

  @version 1

  @enforce_keys [:rollout_id]
  defstruct version: @version,
            rollout_id: nil,
            iteration: 0,
            messages: [],
            pending: nil,
            usage: %Usage{},
            cursor: nil

  @type cursor :: {epoch :: non_neg_integer(), seq :: non_neg_integer()} | nil
  @type t :: %__MODULE__{
          version: pos_integer(),
          rollout_id: String.t(),
          iteration: non_neg_integer(),
          messages: [Message.message()],
          pending: Pending.t() | nil,
          usage: Usage.t(),
          cursor: cursor()
        }

  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Encodes to a JSON-safe map, canonical message encoding inside."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = checkpoint) do
    %{
      "version" => checkpoint.version,
      "rollout_id" => checkpoint.rollout_id,
      "iteration" => checkpoint.iteration,
      "messages" => Enum.map(checkpoint.messages, &Message.to_map/1),
      "pending" => checkpoint.pending && Pending.to_map(checkpoint.pending),
      "usage" => Usage.to_map(checkpoint.usage),
      "cursor" => encode_cursor(checkpoint.cursor)
    }
  end

  @doc """
  Decodes `encode/1` output (possibly after a JSON round trip).

  Unknown versions and malformed payloads return
  `{:error, %Clementine.Error{code: :incompatible_checkpoint}}`.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(%{"version" => @version} = data) do
    checkpoint = %__MODULE__{
      version: @version,
      rollout_id: fetch_binary!(data, "rollout_id"),
      iteration: Map.get(data, "iteration", 0),
      messages: data |> Map.get("messages", []) |> Enum.map(&Message.from_map/1),
      pending: decode_pending(Map.get(data, "pending")),
      usage: Usage.from_map(Map.get(data, "usage")),
      cursor: decode_cursor(Map.get(data, "cursor"))
    }

    {:ok, checkpoint}
  rescue
    # Deserialization boundary: any raise here means a malformed envelope,
    # and decode's contract is a clean :incompatible_checkpoint, never a
    # crash — a corrupt durable checkpoint must not take down the resumer.
    e ->
      {:error, incompatible("malformed checkpoint: #{Exception.message(e)}", data)}
  end

  def decode(%{"version" => other} = data) do
    {:error,
     incompatible("unknown checkpoint version #{inspect(other)} (current: #{@version})", data)}
  end

  def decode(other) do
    {:error, incompatible("not a checkpoint envelope", other)}
  end

  defp incompatible(message, raw) do
    %Error{
      kind: :rollout,
      code: :incompatible_checkpoint,
      message: message,
      retryable?: false,
      raw: raw
    }
  end

  defp decode_pending(nil), do: nil
  defp decode_pending(data), do: Pending.from_map(data)

  defp fetch_binary!(data, key) do
    case Map.fetch!(data, key) do
      value when is_binary(value) -> value
      other -> raise ArgumentError, "#{key} must be a string, got: #{inspect(other)}"
    end
  end

  defp encode_cursor(nil), do: nil
  defp encode_cursor({epoch, seq}), do: [epoch, seq]

  defp decode_cursor(nil), do: nil

  defp decode_cursor([epoch, seq]) when is_integer(epoch) and is_integer(seq) do
    {epoch, seq}
  end

  defp decode_cursor(other) do
    raise ArgumentError, "malformed cursor: #{inspect(other)}"
  end
end
