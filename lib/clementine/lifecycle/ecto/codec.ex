defmodule Clementine.Lifecycle.Ecto.Codec do
  @moduledoc """
  The value-level mapping between `Clementine.Lifecycle.Facts` and the
  column recipe: statuses as text, timestamps as columns, structured fields
  as jsonb — encoded so that `fetch` round-trips `Facts` exactly.

  Used by the Ecto adapter's generated `fetch`/`apply`, and public so
  hand-written lifecycles (the documented escape hatch) can reuse the
  per-field codecs instead of re-deriving them.

  Open `term()` positions (cancel reasons, external tags, resume payload
  metas, error `raw`) use a tagged encoding: values that survive a JSON
  round trip unchanged are stored as plain JSON (inspectable in the
  database); anything else is stored as Base64-encoded ETF. Decoding does
  *not* use the `:safe` option: `:safe` refuses to intern new atoms, and an
  atom this codec durably wrote may legitimately not be interned yet in a
  freshly restarted VM — `fetch` must stay total on the codec's own writes
  across restarts and deploys. The atom-creation surface is bounded by what
  the host application itself stored: these columns are trusted storage,
  not user input, and must never carry attacker-controlled bytes.

  A stored suspension whose embedded checkpoint no longer decodes (a deploy
  changed the checkpoint version between suspend and resume) keeps the raw
  envelope map in `Suspension.checkpoint` instead of a `Checkpoint` struct:
  `fetch` must stay total — a run with an unreadable checkpoint is still
  cancellable and inspectable — and the rollout's resume path is where
  `:incompatible_checkpoint` surfaces, per the RFC's snapshot doctrine.
  Distinct from that escape: an `{:external, _}` park may carry no
  checkpoint at all (LOOP_RFC amendment A4) — `nil` round-trips as `nil`,
  and any other reason without a checkpoint is refused at encode.
  """

  alias Clementine.Lifecycle.Facts

  alias Clementine.{
    ApprovalRequest,
    Checkpoint,
    Error,
    InterruptReason,
    ResumeToken,
    Suspension,
    Usage
  }

  # Facts key -> recipe column name. `ref` defaults to the schema's primary
  # key and is resolved by the adapter, not listed here.
  @field_defaults [
    kind: :kind,
    status: :status,
    epoch: :lease_epoch,
    executor_id: :executor_id,
    heartbeat_at: :heartbeat_at,
    deadline: :deadline,
    cancel: :cancel,
    suspension: :suspension,
    resume: :resume,
    effects?: :effects,
    usage: :usage,
    error: :error,
    interrupt: :interrupt,
    queued_at: :queued_at,
    finished_at: :finished_at
  ]

  @statuses Map.new(Facts.statuses(), fn status -> {Atom.to_string(status), status} end)
  @kinds Map.new(Facts.kinds(), fn kind -> {Atom.to_string(kind), kind} end)
  @interrupt_codes Map.new(InterruptReason.codes(), fn code -> {Atom.to_string(code), code} end)
  @error_kinds Map.new([:provider, :tool, :rollout, :runtime], &{Atom.to_string(&1), &1})
  @providers Map.new([:anthropic, :openai], &{Atom.to_string(&1), &1})
  @reason_types Map.new([:approval, :external, :until], &{Atom.to_string(&1), &1})

  @type fields :: keyword(atom())

  @spec field_defaults() :: fields()
  def field_defaults, do: @field_defaults

  @doc """
  Merges column-name overrides into the recipe defaults. `ref:` names the
  primary-key column. Unknown keys raise — a typo here would silently strand
  a column.
  """
  @spec resolve_fields(atom(), keyword()) :: fields()
  def resolve_fields(ref_column, overrides) do
    known = [:ref | Keyword.keys(@field_defaults)]

    case Keyword.keys(overrides) -- known do
      [] -> Keyword.merge([ref: ref_column] ++ @field_defaults, overrides)
      unknown -> raise ArgumentError, "unknown lifecycle fields: #{inspect(unknown)}"
    end
  end

  @doc "Builds `Facts` from a fetched row (schema struct or plain map)."
  @spec to_facts(map(), fields()) :: Facts.t()
  def to_facts(row, fields) do
    read = fn key -> Map.fetch!(row, Keyword.fetch!(fields, key)) end

    %Facts{
      ref: read.(:ref),
      kind: decode_kind(read.(:kind)),
      status: decode_status(read.(:status)),
      epoch: read.(:epoch),
      executor_id: read.(:executor_id),
      heartbeat_at: read.(:heartbeat_at),
      deadline: read.(:deadline),
      cancel: decode_cancel(read.(:cancel)),
      suspension: decode_suspension(read.(:suspension)),
      resume: decode_resume(read.(:resume)),
      effects?: read.(:effects?),
      usage: decode_usage(read.(:usage)),
      error: decode_error(read.(:error)),
      interrupt: decode_interrupt(read.(:interrupt)),
      queued_at: read.(:queued_at),
      finished_at: read.(:finished_at)
    }
  end

  @doc """
  Encodes one `Transition.set` value into its column representation.
  Symbolic timestamps are not handled here — the adapter resolves them
  against the storage clock before (or instead of) encoding.
  """
  @spec encode_value(atom(), term()) :: term()
  def encode_value(:kind, kind), do: encode_kind(kind)
  def encode_value(:status, status), do: encode_status(status)
  def encode_value(:cancel, cancel), do: encode_cancel(cancel)
  def encode_value(:suspension, suspension), do: encode_suspension(suspension)
  def encode_value(:resume, resume), do: encode_resume(resume)
  def encode_value(:usage, usage), do: encode_usage(usage)
  def encode_value(:error, error), do: encode_error(error)
  def encode_value(:interrupt, interrupt), do: encode_interrupt(interrupt)
  def encode_value(_key, value), do: value

  ## Status

  @spec encode_status(Facts.status()) :: String.t()
  def encode_status(status) when is_atom(status) do
    text = Atom.to_string(status)

    if is_map_key(@statuses, text) do
      text
    else
      raise ArgumentError, "unknown lifecycle status: #{inspect(status)}"
    end
  end

  @spec decode_status(String.t()) :: Facts.status()
  def decode_status(text), do: Map.fetch!(@statuses, text)

  ## Kind

  @spec encode_kind(Facts.kind()) :: String.t()
  def encode_kind(kind) when is_atom(kind) do
    text = Atom.to_string(kind)

    if is_map_key(@kinds, text) do
      text
    else
      raise ArgumentError, "unknown run kind: #{inspect(kind)}"
    end
  end

  @spec decode_kind(String.t()) :: Facts.kind()
  def decode_kind(text), do: Map.fetch!(@kinds, text)

  ## Cancel

  def encode_cancel(nil), do: nil

  def encode_cancel(%{reason: reason, requested_at: requested_at}) do
    %{"reason" => encode_term(reason), "requested_at" => encode_datetime(requested_at)}
  end

  def decode_cancel(nil), do: nil

  def decode_cancel(%{"reason" => reason, "requested_at" => requested_at}) do
    %{reason: decode_term(reason), requested_at: decode_datetime(requested_at)}
  end

  ## Suspension

  def encode_suspension(nil), do: nil

  def encode_suspension(%Suspension{} = suspension) do
    %{
      "reason" => encode_reason(suspension.reason),
      "checkpoint" => encode_checkpoint(suspension),
      "token" => encode_token(suspension.token)
    }
  end

  def decode_suspension(nil), do: nil

  def decode_suspension(%{"reason" => reason, "checkpoint" => checkpoint, "token" => token}) do
    %Suspension{
      reason: decode_reason(reason),
      checkpoint: decode_checkpoint(checkpoint),
      token: decode_token(token)
    }
  end

  defp encode_checkpoint(%Suspension{checkpoint: %Checkpoint{} = checkpoint}) do
    Checkpoint.encode(checkpoint)
  end

  # LOOP_RFC amendment A4: only an {:external, _} park may store no
  # checkpoint — its durable state is the loop envelope, in its own recipe
  # column. An approval or until park without one is a mid-rollout park
  # with no way to continue, so the write door refuses.
  defp encode_checkpoint(%Suspension{reason: {:external, _}, checkpoint: nil}), do: nil

  defp encode_checkpoint(%Suspension{reason: reason, checkpoint: nil}) do
    raise ArgumentError,
          "a #{Suspension.reason_type(reason)} suspension requires a checkpoint; " <>
            "only {:external, _} parks may store none (LOOP_RFC amendment A4)"
  end

  defp decode_checkpoint(nil), do: nil

  defp decode_checkpoint(data) do
    case Checkpoint.decode(data) do
      {:ok, checkpoint} -> checkpoint
      # Keep the raw envelope: fetch stays total, resume surfaces
      # :incompatible_checkpoint (see moduledoc).
      {:error, %Error{}} -> data
    end
  end

  defp encode_reason({:approval, %ApprovalRequest{} = request}) do
    %{
      "type" => "approval",
      "request" => %{
        "tool_use_id" => request.tool_use_id,
        "tool_name" => request.tool_name,
        "args" => request.args
      }
    }
  end

  defp encode_reason({:external, tag}), do: %{"type" => "external", "tag" => encode_term(tag)}

  defp encode_reason({:until, %DateTime{} = at}) do
    %{"type" => "until", "at" => encode_datetime(at)}
  end

  defp decode_reason(%{"type" => "approval", "request" => request}) do
    {:approval,
     %ApprovalRequest{
       tool_use_id: Map.fetch!(request, "tool_use_id"),
       tool_name: Map.fetch!(request, "tool_name"),
       args: Map.get(request, "args", %{})
     }}
  end

  defp decode_reason(%{"type" => "external", "tag" => tag}), do: {:external, decode_term(tag)}

  defp decode_reason(%{"type" => "until", "at" => at}), do: {:until, decode_datetime(at)}

  defp encode_token(%ResumeToken{} = token) do
    %{
      "run_ref" => encode_term(token.run_ref),
      "epoch" => token.epoch,
      "reason_type" => Atom.to_string(token.reason_type)
    }
  end

  defp decode_token(%{"run_ref" => run_ref, "epoch" => epoch, "reason_type" => reason_type}) do
    %ResumeToken{
      run_ref: decode_term(run_ref),
      epoch: epoch,
      reason_type: Map.fetch!(@reason_types, reason_type)
    }
  end

  ## Resume

  def encode_resume(nil), do: nil

  def encode_resume(%{payload: payload, resumed_at: resumed_at}) do
    %{"payload" => encode_payload(payload), "resumed_at" => encode_datetime(resumed_at)}
  end

  def decode_resume(nil), do: nil

  def decode_resume(%{"payload" => payload, "resumed_at" => resumed_at}) do
    %{payload: decode_payload(payload), resumed_at: decode_datetime(resumed_at)}
  end

  # Normative approval payloads get first-class shapes; everything else is
  # an opaque term.
  defp encode_payload({:approved, meta}), do: %{"kind" => "approved", "meta" => encode_term(meta)}
  defp encode_payload({:denied, meta}), do: %{"kind" => "denied", "meta" => encode_term(meta)}
  defp encode_payload(:elapsed), do: %{"kind" => "elapsed"}
  defp encode_payload(other), do: %{"kind" => "term", "value" => encode_term(other)}

  defp decode_payload(%{"kind" => "approved", "meta" => meta}), do: {:approved, decode_term(meta)}
  defp decode_payload(%{"kind" => "denied", "meta" => meta}), do: {:denied, decode_term(meta)}
  defp decode_payload(%{"kind" => "elapsed"}), do: :elapsed
  defp decode_payload(%{"kind" => "term", "value" => value}), do: decode_term(value)

  ## Usage

  def encode_usage(nil), do: nil
  def encode_usage(%Usage{} = usage), do: Usage.to_map(usage)

  def decode_usage(nil), do: nil
  def decode_usage(map), do: Usage.from_map(map)

  ## Error

  def encode_error(nil), do: nil

  def encode_error(%Error{} = error) do
    %{
      "kind" => Atom.to_string(error.kind),
      "code" => Atom.to_string(error.code),
      "provider" => error.provider && Atom.to_string(error.provider),
      "message" => error.message,
      "retryable" => error.retryable?,
      "raw" => encode_term(error.raw)
    }
  end

  def decode_error(nil), do: nil

  def decode_error(%{} = map) do
    %Error{
      kind: Map.fetch!(@error_kinds, Map.fetch!(map, "kind")),
      # Codes are an open atom set written by this application; recreating
      # them from trusted storage is bounded by what it wrote.
      code: String.to_atom(Map.fetch!(map, "code")),
      provider: with(p when is_binary(p) <- map["provider"], do: Map.fetch!(@providers, p)),
      message: Map.fetch!(map, "message"),
      retryable?: Map.fetch!(map, "retryable"),
      raw: decode_term(Map.fetch!(map, "raw"))
    }
  end

  ## Interrupt

  def encode_interrupt(nil), do: nil

  def encode_interrupt(%InterruptReason{code: {:app, term}, detail: detail}) do
    %{"code" => %{"app" => encode_term(term)}, "detail" => detail}
  end

  def encode_interrupt(%InterruptReason{code: code, detail: detail}) do
    %{"code" => Atom.to_string(code), "detail" => detail}
  end

  def decode_interrupt(nil), do: nil

  def decode_interrupt(%{"code" => %{"app" => term}} = map) do
    %InterruptReason{code: {:app, decode_term(term)}, detail: map["detail"]}
  end

  def decode_interrupt(%{"code" => code} = map) do
    %InterruptReason{code: Map.fetch!(@interrupt_codes, code), detail: map["detail"]}
  end

  ## Terms and timestamps

  @doc """
  Tagged encoding for open `term()` positions: JSON-exact values stay
  inspectable JSON; everything else round-trips through ETF.
  """
  @spec encode_term(term()) :: map()
  def encode_term(term) do
    if json_exact?(term) do
      %{"t" => "json", "v" => term}
    else
      %{"t" => "etf", "v" => Base.encode64(:erlang.term_to_binary(term))}
    end
  end

  @spec decode_term(map()) :: term()
  def decode_term(%{"t" => "json", "v" => value}), do: value

  def decode_term(%{"t" => "etf", "v" => encoded}) do
    # No :safe — it would make fetch partial across VM restarts (see
    # moduledoc). Trusted storage only.
    :erlang.binary_to_term(Base.decode64!(encoded))
  end

  # True only when a JSON round trip returns the value unchanged.
  defp json_exact?(value)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: true

  defp json_exact?(value) when is_binary(value), do: String.valid?(value)
  defp json_exact?(value) when is_list(value), do: Enum.all?(value, &json_exact?/1)

  defp json_exact?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {k, v} -> is_binary(k) and String.valid?(k) and json_exact?(v) end)
  end

  defp json_exact?(_value), do: false

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp decode_datetime(nil), do: nil

  defp decode_datetime(text) when is_binary(text) do
    {:ok, dt, 0} = DateTime.from_iso8601(text)
    dt
  end
end
