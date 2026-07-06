defmodule Clementine.Events.Stamper do
  @moduledoc """
  The emit handle for one execution: assigns each event a gapless,
  monotonic per-epoch `seq` (the epoch comes from the lease — one stamper
  per claim), and accumulates `usage_delta` events into a counter the
  heartbeat samples for its usage piggyback. One source, two consumers:
  the rollout emits through the stamper; the heartbeat reads `usage/1`.

  Counters live in `:atomics`, so `usage/1` is readable from the heartbeat
  process without any message round-trip, and `seq` assignment stays
  gapless even under a misbehaving concurrent emitter.

  Delivery is best-effort by construction: the `seq` is assigned before
  the sink is called, sink errors are ignored, and sink raises are rescued
  and logged — a lost event is transport loss, which live observers may
  ignore and the RunView fold tolerates. Delivery never affects execution,
  and it never affects the numbering.
  """

  require Logger

  alias Clementine.{Event, Lease, Usage}

  @seq_ix 1
  @input_tokens_ix 2
  @output_tokens_ix 3

  @enforce_keys [:sink, :lease, :counters]
  defstruct [:sink, :lease, :counters]

  @type t :: %__MODULE__{
          sink: module(),
          lease: Lease.t(),
          counters: :atomics.atomics_ref()
        }

  @spec new(module(), Lease.t()) :: t()
  def new(sink, %Lease{} = lease) when is_atom(sink) do
    %__MODULE__{sink: sink, lease: lease, counters: :atomics.new(3, signed: false)}
  end

  @doc """
  Stamps and delivers one execution event. The type must belong to the
  closed taxonomy (`Clementine.Event.types/0`) — the stream carries no
  lifecycle events, so `run_started`/`run_finished` are unmintable here.
  An `approval_requested` payload must not carry a resume token: the token
  is a control-plane reference read from stored facts by authorized code,
  never broadcast.

  Always returns `:ok` — delivery is advisory.
  """
  @spec emit(t(), Event.type(), map()) :: :ok
  def emit(%__MODULE__{} = stamper, type, payload \\ %{}) when is_map(payload) do
    validate_type!(type)
    validate_payload!(type, payload)
    accumulate_usage(stamper, type, payload)

    event = %Event{
      run_ref: stamper.lease.run_ref,
      epoch: stamper.lease.epoch,
      seq: :atomics.add_get(stamper.counters, @seq_ix, 1),
      type: type,
      payload: payload
    }

    deliver(stamper, event)
  end

  @doc """
  The usage accumulated from `usage_delta` events so far, as sampled by
  the heartbeat. Reads may tear between the two fields; the sample is an
  approximation that trails live truth by design, and the terminal result
  carries the exact numbers.
  """
  @spec usage(t()) :: Usage.t()
  def usage(%__MODULE__{counters: counters}) do
    %Usage{
      input_tokens: :atomics.get(counters, @input_tokens_ix),
      output_tokens: :atomics.get(counters, @output_tokens_ix)
    }
  end

  @doc """
  The stamper's position, `{epoch, last_seq}` — what the runner writes
  into a checkpoint's cursor at suspend. `{epoch, 0}` means this execution
  has emitted nothing.
  """
  @spec cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def cursor(%__MODULE__{} = stamper) do
    {stamper.lease.epoch, :atomics.get(stamper.counters, @seq_ix)}
  end

  defp validate_type!(type) do
    if type not in Event.types() do
      raise ArgumentError,
            "unknown execution event type #{inspect(type)}; " <>
              "the stream carries only #{inspect(Event.types())} — lifecycle " <>
              "facts travel as transition notifications, not events"
    end
  end

  defp validate_payload!(:approval_requested, payload) do
    if Map.has_key?(payload, :token) or Map.has_key?(payload, "token") do
      raise ArgumentError,
            "approval_requested carries no resume token: the token is a " <>
              "control-plane reference read from stored facts by authorized " <>
              "code, never broadcast to observers"
    end

    :ok
  end

  defp validate_payload!(_type, _payload), do: :ok

  defp accumulate_usage(%__MODULE__{counters: counters}, :usage_delta, payload) do
    %Usage{input_tokens: input, output_tokens: output} = Usage.new(payload)
    if input > 0, do: :atomics.add(counters, @input_tokens_ix, input)
    if output > 0, do: :atomics.add(counters, @output_tokens_ix, output)
    :ok
  end

  defp accumulate_usage(_stamper, _type, _payload), do: :ok

  defp deliver(%__MODULE__{sink: sink, lease: lease}, %Event{} = event) do
    sink.emit(lease, event)
  rescue
    exception ->
      Logger.warning(
        "Clementine event sink #{inspect(sink)} raised on emit: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning("Clementine event sink #{inspect(sink)} #{kind} on emit: #{inspect(reason)}")

      :ok
  else
    _any -> :ok
  end
end
