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

  `skills` names the skills the rollout had loaded (`Clementine.Skill`),
  in load order, so a resume offers the model the same tools: the agent's
  own, and each loaded skill's.

  `version` names the envelope format, including the embedded canonical
  message encoding. Resuming across a deploy that changed the format fails
  cleanly as `:incompatible_checkpoint` — never a crash — and the host
  chooses between accepting the failed terminal and restarting the rollout
  fresh from its original spec.

  Version 2 adds `skills`. `encode/1` writes the lowest version that
  holds the checkpoint: version 1, exactly as code before version 2 wrote
  it, unless a skill is loaded. So code that reads only version 1 still
  resumes every run parked without one, through a rolling deploy or a
  rollback; a run parked with a skill loaded fails there as
  incompatible, since that code cannot offer its tools. A version-1
  envelope decodes with no skills loaded. `pending` names its shape
  inside the envelope, so a later shape joins version 2 without a new
  version (and makes `encode/1` write version 2): a shape this code does
  not know fails the decode as incompatible, as an unknown version does.

  Checkpoint-on-suspend (this epic) and checkpoint-every-iteration (the
  future tool-call ledger) are the same mechanism at different cadences;
  nothing here assumes suspension.
  """

  alias Clementine.LLM.Message
  alias Clementine.{Error, Pending, Usage}

  @version 2
  @versions [1, 2]

  @enforce_keys [:rollout_id]
  defstruct version: 1,
            rollout_id: nil,
            iteration: 0,
            messages: [],
            pending: nil,
            skills: [],
            usage: %Usage{},
            cursor: nil

  @type cursor :: {epoch :: non_neg_integer(), seq :: non_neg_integer()} | nil
  @type t :: %__MODULE__{
          version: pos_integer(),
          rollout_id: String.t(),
          iteration: non_neg_integer(),
          messages: [Message.message()],
          pending: Pending.t() | nil,
          skills: [String.t()],
          usage: Usage.t(),
          cursor: cursor()
        }

  @doc """
  The newest version this code writes. `encode/1` writes the lowest one
  that holds a given checkpoint (`version_for/1`).
  """
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  The version `encode/1` writes for `checkpoint`: the lowest that holds
  what it carries, and never lower than its own `version`, which is the
  version it was read as (a fresh checkpoint's is 1).
  """
  @spec version_for(t()) :: pos_integer()
  def version_for(%__MODULE__{} = checkpoint), do: max(checkpoint.version, needs(checkpoint))

  # The version the content needs: loaded skills arrived with version 2.
  defp needs(%__MODULE__{skills: [_ | _]}), do: 2
  defp needs(%__MODULE__{}), do: 1

  @doc "The versions this code reads: the current one, and those before it."
  @spec versions() :: [pos_integer()]
  def versions, do: @versions

  @doc """
  Encodes to a JSON-safe map, canonical message encoding inside, at
  `version_for/1`: a version-1 envelope has exactly the keys version 1
  wrote.
  """
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = checkpoint) do
    version = version_for(checkpoint)

    %{
      "version" => version,
      "rollout_id" => checkpoint.rollout_id,
      "iteration" => checkpoint.iteration,
      "messages" => Enum.map(checkpoint.messages, &Message.to_map/1),
      "pending" => checkpoint.pending && Pending.to_map(checkpoint.pending),
      "usage" => Usage.to_map(checkpoint.usage),
      "cursor" => encode_cursor(checkpoint.cursor)
    }
    |> put_skills(version, checkpoint.skills)
  end

  defp put_skills(envelope, 1, _skills), do: envelope
  defp put_skills(envelope, _version, skills), do: Map.put(envelope, "skills", skills)

  @doc """
  Decodes `encode/1` output (possibly after a JSON round trip).

  A version-1 envelope decodes with no skills loaded. Unknown versions and
  malformed payloads return
  `{:error, %Clementine.Error{code: :incompatible_checkpoint}}`.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, Error.t()}
  def decode(%{"version" => version} = data) when version in @versions do
    checkpoint = %__MODULE__{
      version: version,
      rollout_id: fetch_binary!(data, "rollout_id"),
      iteration: Map.get(data, "iteration", 0),
      messages: data |> Map.get("messages", []) |> Enum.map(&Message.from_map/1),
      pending: decode_pending(Map.get(data, "pending")),
      skills: decode_skills(version, data),
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
     incompatible(
       "unknown checkpoint version #{inspect(other)} (this code reads #{inspect(@versions)})",
       data
     )}
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

  # Version 1 predates skills.
  defp decode_skills(1, _data), do: []

  defp decode_skills(_version, data) do
    case Map.get(data, "skills", []) do
      skills when is_list(skills) ->
        if Enum.all?(skills, &is_binary/1),
          do: skills,
          else: raise(ArgumentError, "malformed skills: #{inspect(skills)}")

      other ->
        raise ArgumentError, "malformed skills: #{inspect(other)}"
    end
  end

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
