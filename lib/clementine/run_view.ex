defmodule Clementine.RunView do
  @moduledoc """
  The canonical fold of a run's execution events into a live view.
  Clementine owns the event taxonomy, therefore Clementine owns this
  reduction; hosts store and transport RunViews, they do not reimplement
  the fold.

  The fold is pure and total: `apply/2` never raises on taxonomy events,
  whatever their payloads hold — the view is advisory, and a malformed
  payload must never take an observer down. Payload keys read as atoms or
  strings interchangeably: the stamper mints atom keys, but a host's
  durable-log tier may round-trip events through JSON, and a replayed
  stream must fold to the same view. Ordering discipline:

  - Events (and terminal facts) for another run are ignored: the view
    owns one run's identity, and a shared topic must not be able to wedge
    it — a stray higher-epoch event from a neighbor would otherwise
    supersede every real event that follows.
  - Events at or below the cursor (`{epoch, seq}`) are dropped — that one
    rule covers duplicates, reconnect overlap, and within-epoch reordering
    (live transport is ordered per emitter; anything behind the cursor is
    a replay or a loss already tolerated).
  - Events from an epoch below the highest seen are dropped: a superseded
    executor's stragglers vanish without a database check.
  - An event from a *higher* epoch resets the execution-scoped state
    (text, tools in flight, iteration, observed usage): a new execution
    owns the run, and the old epoch's unfinished work was either abandoned
    (requeue re-executes from scratch) or already made durable (a
    suspension's checkpoint) — the durable side is truth, the view is the
    live overlay of the current execution only.
  - Within-epoch seq gaps are applied, not rejected: gaps mean transport
    loss, which the fold tolerates.

  `close/2` pins terminal facts. A closed view rejects every further
  event — in particular everything at or below its final epoch, which is
  what finally silences a post-reap zombie's ghost stream: a reaped run
  never mints a successor epoch, so epoch comparison alone could never
  drop those events; closure does. Until the terminal notification
  arrives, a partitioned-but-alive zombie's deltas do land in the view —
  they touch nothing durable, and closure ends them.

  Reconnect is uniform: snapshot the stored view, subscribe to events and
  transition notifications, `apply/2` and `close/2` as they arrive, and
  let the fold discard duplicates, stale epochs, and post-closure ghosts.

  Two honest boundaries of the v1 view: `usage` is the sum of
  `usage_delta` events observed in the current epoch (authoritative
  numbers live in the facts and the terminal result), and the view keeps
  no clock — events carry no timestamp in their identity envelope, so
  staleness detection belongs to the host's transport, not the fold.
  """

  alias Clementine.{Event, Usage}
  alias Clementine.Lifecycle.Facts

  @enforce_keys [:run_ref]
  defstruct run_ref: nil,
            epoch: 0,
            seq: 0,
            iteration: 0,
            text: "",
            tools: %{},
            usage: %Usage{},
            status: nil,
            final: nil,
            closed?: false

  @typedoc """
  A tool call in flight: started, streaming input, possibly parked on
  approval. Completed calls leave the map — their results become durable
  message content, which is not the view's business.
  """
  @type tool_in_flight :: %{
          name: String.t() | nil,
          input: String.t(),
          approval_requested?: boolean()
        }

  @type t :: %__MODULE__{
          run_ref: term(),
          epoch: non_neg_integer(),
          seq: non_neg_integer(),
          iteration: non_neg_integer(),
          text: String.t(),
          tools: %{optional(term()) => tool_in_flight()},
          usage: Usage.t(),
          status: Facts.status() | nil,
          final: Facts.t() | nil,
          closed?: boolean()
        }

  @spec new(term()) :: t()
  def new(run_ref), do: %__MODULE__{run_ref: run_ref}

  @doc """
  Folds one execution event into the view. Pure; returns the view
  unchanged for anything the ordering discipline rejects (another run's
  event, stale epoch, at-or-below-cursor seq, any event after closure).
  """
  @spec apply(t(), Event.t()) :: t()
  def apply(%__MODULE__{closed?: true} = view, %Event{}), do: view

  def apply(%__MODULE__{run_ref: ref} = view, %Event{run_ref: event_ref})
      when ref != event_ref,
      do: view

  def apply(%__MODULE__{} = view, %Event{} = event) do
    cond do
      event.epoch < view.epoch ->
        view

      event.epoch == view.epoch and event.seq <= view.seq ->
        view

      event.epoch > view.epoch ->
        view
        |> reset_execution_state(event.epoch)
        |> advance(event)

      true ->
        advance(view, event)
    end
  end

  @doc """
  Pins terminal facts — the transition notification arrived; the fold is
  over. Closing is idempotent (terminal facts are unique per run: exactly
  one terminal writer, dead-end statuses), another run's facts are
  ignored like another run's events, and non-terminal facts for *this*
  run are a contract violation, not a close.

  The cursor keeps its last live position; `status` and `final` carry the
  lifecycle truth.
  """
  @spec close(t(), Facts.t()) :: t()
  def close(%__MODULE__{closed?: true} = view, %Facts{}), do: view

  def close(%__MODULE__{run_ref: ref} = view, %Facts{ref: facts_ref})
      when ref != facts_ref,
      do: view

  def close(%__MODULE__{} = view, %Facts{} = facts) do
    if not Facts.terminal?(facts) do
      raise ArgumentError,
            "close/2 takes terminal facts; got status #{inspect(facts.status)} — " <>
              "non-terminal notifications update host state, not the fold"
    end

    %{view | closed?: true, final: facts, status: facts.status}
  end

  @doc "The reconnect cursor: an observer resumes from here and `apply/2` discards anything at or below it."
  @spec cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def cursor(%__MODULE__{epoch: epoch, seq: seq}), do: {epoch, seq}

  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{closed?: closed?}), do: closed?

  defp advance(%__MODULE__{} = view, %Event{} = event) do
    fold(%{view | seq: event.seq}, event)
  end

  defp reset_execution_state(%__MODULE__{} = view, epoch) do
    %{view | epoch: epoch, seq: 0, iteration: 0, text: "", tools: %{}, usage: %Usage{}}
  end

  defp fold(view, %Event{type: :iteration_start, payload: payload}) do
    case payload_value(payload, :n) do
      n when is_integer(n) and n >= 0 -> %{view | iteration: n}
      _ -> view
    end
  end

  defp fold(view, %Event{type: :text_delta, payload: payload}) do
    case payload_value(payload, :content) do
      content when is_binary(content) -> %{view | text: view.text <> content}
      _ -> view
    end
  end

  defp fold(view, %Event{type: :tool_use_start, payload: payload}) do
    with_tool_use_id(view, payload, fn view, id ->
      tool = %{name: payload_value(payload, :name), input: "", approval_requested?: false}
      %{view | tools: Map.put(view.tools, id, tool)}
    end)
  end

  defp fold(view, %Event{type: :tool_input_delta, payload: payload}) do
    with_tool_use_id(view, payload, fn view, id ->
      content =
        case payload_value(payload, :content) do
          content when is_binary(content) -> content
          _ -> ""
        end

      tool = Map.get(view.tools, id, unknown_tool())
      %{view | tools: Map.put(view.tools, id, %{tool | input: tool.input <> content})}
    end)
  end

  defp fold(view, %Event{type: :tool_result, payload: payload}) do
    with_tool_use_id(view, payload, fn view, id ->
      %{view | tools: Map.delete(view.tools, id)}
    end)
  end

  defp fold(view, %Event{type: :approval_requested, payload: payload}) do
    with_tool_use_id(view, payload, fn view, id ->
      tool = Map.get(view.tools, id, %{unknown_tool() | name: payload_value(payload, :name)})
      %{view | tools: Map.put(view.tools, id, %{tool | approval_requested?: true})}
    end)
  end

  defp fold(view, %Event{type: :usage_delta, payload: payload}) do
    %{view | usage: Usage.add(view.usage, payload)}
  end

  # :error events (and any type this fold predates) advance the cursor
  # only; their payloads are for live observers, and the terminal facts
  # carry the authoritative error.
  defp fold(view, %Event{}), do: view

  # A tool event whose start was lost to transport still folds — gaps are
  # tolerated, so entries materialize on first sighting.
  defp with_tool_use_id(view, payload, fun) do
    case payload_value(payload, :tool_use_id) do
      nil -> view
      id -> fun.(view, id)
    end
  end

  defp unknown_tool, do: %{name: nil, input: "", approval_requested?: false}

  # The stamper mints atom keys; a durable-log round trip through JSON
  # strings them. A replayed stream must fold to the same view.
  defp payload_value(payload, key) do
    case payload do
      %{^key => value} -> value
      _ -> Map.get(payload, Atom.to_string(key))
    end
  end
end
