defmodule Clementine.Loop.Report do
  @moduledoc """
  The doctor's finding for one loop (LOOP_RFC §Operations), built by
  `Clementine.Loop.inspect/3`: lifecycle facts, the persisted spec with
  its version compatibility, the decoded envelope, live children with
  statuses, the timer schedule, pending inputs with ages, retained dead
  letters, and the diagnosed **strands** — so frozen-loop diagnosis is
  one call, not jsonb spelunking. `render/1` turns the struct into an
  operator-readable block.

  ## Strand classes

  Each strand is `%{class: atom, detail: map}`, one entry per anomaly the
  self-healing machinery exists to cover — a strand is evidence, and on a
  transactional substrate every class should be transient at worst (the
  reaper's verdicts heal them; a persistent strand is the glue bug the
  firing-rate telemetry pages on):

  - `:incompatible_spec` — the persisted `loop_module` does not resolve
    to a loop on this release (matrix row L2); deploy compatible code or
    cancel the loop.
  - `:incompatible_state` — the stored envelope (or its `state_version`)
    is unreadable by the running code (row L2); same remedy.
  - `:parked_with_pending` — the loop is `waiting` while consumable
    inputs sit unconsumed (row L4): the park re-check or append wake was
    lost; `:wake_pending` is the healing verdict. Mid-cascade, only
    pending *completions* count — non-completion backlog legitimately
    waits for the terminal sweep — judged from the host's `:completions`
    window (the cascade's own read), so a completion parked behind a
    backlog longer than `:limit` still strands.
  - `:parked_with_cancel` — the loop is `waiting` with the cancel flag
    set but no cascade underway (row L8's lost-wake interleaving); the
    next wake enters the cascade.
  - `:stranded_completion` — the envelope lists a live child whose run
    is terminal and whose completion input exists nowhere (row L13): the
    exactly-once-at-source append was lost; `:reconcile_children` is the
    healing verdict. Presence reads the `:completions` window plus the
    dead letters, each bounded by `:limit` — completions only, so a
    non-completion backlog of any length cannot hide a delivered one —
    and matches the canonical completion dedup key first, which is
    vocabulary-free: a delivered completion whose payload no longer
    decodes after a vocabulary-shrinking deploy still counts as present.
    Detected only when a `:lifecycle` is given.
  - `:stale_queued` — the loop has sat `queued` past `:stale_after`
    (row L15): its step job is likely lost; `:reenqueue` is the healing
    verdict.

  Ages compare row stamps (storage clock) against this node's clock at
  gather time (the report's `now`) — diagnostic precision, not protocol
  precision.
  """

  alias Clementine.Lifecycle.Facts
  alias Clementine.Loop
  alias Clementine.Loop.{Codec, Envelope, StoredInput}
  alias Clementine.Loop.Ecto.Codec, as: InboxCodec

  defstruct facts: nil,
            module: nil,
            args: %{},
            policy: %{},
            state_version: %{stored: nil, declared: nil},
            envelope: nil,
            children: [],
            timers: [],
            pending: [],
            dead_letters: [],
            strands: [],
            now: nil

  @typedoc """
  One live child from the envelope, joined to its run status: a
  `t:Clementine.Lifecycle.Facts.status/0` when the `:lifecycle` option
  resolved it, `:unknown` when none was given (or the ref is unfilled),
  `:missing` when the run row is gone. `tag` is `{:ok, term}` or
  `:undecodable` (a vocabulary the current spec no longer declares).
  """
  @type child :: %{
          tag_key: String.t(),
          tag: {:ok, term()} | :undecodable,
          ref: term(),
          status: Facts.status() | :unknown | :missing
        }

  @type timer :: %{tag_key: String.t(), tag: {:ok, term()} | :undecodable, meta: map()}

  @type strand :: %{class: atom(), detail: map()}

  @type t :: %__MODULE__{
          facts: Facts.t(),
          module: {:ok, module()} | {:error, {:incompatible_spec, map()}},
          args: map(),
          policy: map(),
          state_version: %{stored: pos_integer() | nil, declared: pos_integer() | nil},
          envelope: Envelope.t() | nil | {:error, {:incompatible_state, map()}},
          children: [child()],
          timers: [timer()],
          pending: [StoredInput.t()],
          dead_letters: [StoredInput.t()] | :unsupported,
          strands: [strand()],
          now: DateTime.t()
        }

  @doc false
  @spec gather(module(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def gather(host, loop_ref, opts) do
    ctx = Keyword.get(opts, :ctx)
    limit = Keyword.get(opts, :limit, 50)
    lifecycle = Keyword.get(opts, :lifecycle)
    stale_after = Keyword.get(opts, :stale_after, :timer.minutes(5))

    with {:ok, loaded} <- host.load(loop_ref, ctx) do
      module = Loop.resolve(loaded.module)

      vocab =
        case module do
          {:ok, mod} -> mod.__loop__(:vocabulary)
          {:error, _incompatible} -> []
        end

      envelope = decode_envelope(loaded.envelope)

      report = %__MODULE__{
        facts: loaded.facts,
        module: module,
        args: loaded.args,
        policy: loaded.policy,
        state_version: %{stored: stored_version(envelope), declared: declared_version(module)},
        envelope: envelope,
        children: children(envelope, vocab, lifecycle, ctx),
        timers: timers(envelope, vocab),
        pending: host.pending(loop_ref, limit, :any, ctx),
        dead_letters: dead_letters(host, loop_ref, limit, ctx),
        now: DateTime.utc_now()
      }

      # The diagnosis window for completions is the runner's own cascade
      # read: a completion parked behind a FIFO backlog longer than the
      # limit never surfaces in the :any window, and judging from that
      # window alone would miss a stranded cascade — or call a delivered
      # completion stranded.
      completions = host.pending(loop_ref, limit, :completions, ctx)

      {:ok, %{report | strands: strands(report, completions, vocab, stale_after)}}
    end
  end

  defp decode_envelope(nil), do: nil

  defp decode_envelope(data) do
    case Envelope.decode(data) do
      {:ok, %Envelope{} = envelope} -> envelope
      {:error, detail} -> {:error, detail}
    end
  end

  defp stored_version(%Envelope{state_version: version}), do: version
  defp stored_version(_none_or_error), do: nil

  defp declared_version({:ok, module}), do: module.__loop__(:state_version)
  defp declared_version(_error), do: nil

  defp children(%Envelope{children: children}, vocab, lifecycle, ctx) do
    children
    |> Enum.sort_by(fn {tag_key, _ref} -> tag_key end)
    |> Enum.map(fn {tag_key, ref} ->
      %{
        tag_key: tag_key,
        tag: decode_tag(tag_key, vocab),
        ref: ref,
        status: child_status(lifecycle, ref, ctx)
      }
    end)
  end

  defp children(_none_or_error, _vocab, _lifecycle, _ctx), do: []

  defp timers(%Envelope{timers: timers}, vocab) do
    timers
    |> Enum.sort_by(fn {tag_key, _meta} -> tag_key end)
    |> Enum.map(fn {tag_key, meta} ->
      %{tag_key: tag_key, tag: decode_tag(tag_key, vocab), meta: meta}
    end)
  end

  defp timers(_none_or_error, _vocab), do: []

  defp child_status(nil, _ref, _ctx), do: :unknown
  defp child_status(_lifecycle, nil, _ctx), do: :unknown

  defp child_status(lifecycle, ref, ctx) do
    case lifecycle.fetch(ref, ctx) do
      {:ok, %Facts{status: status}} -> status
      {:error, _reason} -> :missing
    end
  end

  defp dead_letters(host, loop_ref, limit, ctx) do
    if function_exported?(host, :dead_letters, 3) do
      host.dead_letters(loop_ref, limit, ctx)
    else
      :unsupported
    end
  end

  defp decode_tag(tag_key, vocab) do
    {:ok, Codec.decode(Jason.decode!(tag_key), vocabulary: vocab)}
  rescue
    _undeclared_or_malformed -> :undecodable
  end

  ## Strand diagnosis

  defp strands(%__MODULE__{} = report, completions, vocab, stale_after) do
    [
      spec_strand(report),
      state_strand(report),
      parked_with_pending(report, completions),
      parked_with_cancel(report),
      stale_queued(report, stale_after)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.concat(stranded_completions(report, completions, vocab))
  end

  defp spec_strand(%{module: {:error, {:incompatible_spec, detail}}}),
    do: %{class: :incompatible_spec, detail: detail}

  defp spec_strand(_report), do: nil

  defp state_strand(%{envelope: {:error, {:incompatible_state, detail}}}),
    do: %{class: :incompatible_state, detail: detail}

  defp state_strand(%{state_version: %{stored: stored, declared: declared}})
       when is_integer(stored) and is_integer(declared) and stored != declared,
       do: %{class: :incompatible_state, detail: %{state_version: stored, declared: declared}}

  defp state_strand(_report), do: nil

  # Mid-cascade only completions are consumable, so only they strand a
  # park — judged from the :completions window, which sees past any
  # non-completion backlog. Everywhere else any pending input against a
  # waiting row means a lost wake (the append's atomic unit makes the
  # state unreachable).
  defp parked_with_pending(%{facts: %Facts{status: :waiting}} = report, completions) do
    consumable = if cascading?(report), do: completions, else: report.pending

    case consumable do
      [] ->
        nil

      [oldest | _rest] ->
        %{
          class: :parked_with_pending,
          detail: %{pending: length(consumable), oldest_age_ms: age_ms(report.now, oldest)}
        }
    end
  end

  defp parked_with_pending(_report, _completions), do: nil

  defp parked_with_cancel(%{facts: %Facts{status: :waiting, cancel: cancel}} = report)
       when cancel != nil do
    if cascading?(report),
      do: nil,
      else: %{class: :parked_with_cancel, detail: %{reason: Map.get(cancel, :reason)}}
  end

  defp parked_with_cancel(_report), do: nil

  defp stale_queued(
         %{facts: %Facts{status: :queued, queued_at: %DateTime{} = queued_at}} = report,
         stale_after
       ) do
    waited = DateTime.diff(report.now, queued_at, :millisecond)
    if waited > stale_after, do: %{class: :stale_queued, detail: %{queued_for_ms: waited}}
  end

  defp stale_queued(_report, _stale_after), do: nil

  # LoopEvidence's grain: a live child whose run is terminal strands only
  # when its completion exists nowhere — pending or dead-lettered rows
  # both count as present (a poison completion that dead-lettered must
  # not be re-synthesized). Presence reads the :completions window, never
  # the :any one: a delivered completion parked behind a backlog longer
  # than the limit must not read as stranded.
  defp stranded_completions(%{children: children} = report, completions, vocab) do
    children
    |> Enum.filter(fn child ->
      child.status not in [:unknown, :missing] and Facts.terminal?(child.status) and
        not completion_present?(report, completions, child, vocab)
    end)
    |> Enum.map(fn child ->
      %{
        class: :stranded_completion,
        detail: %{tag_key: child.tag_key, child_ref: child.ref, child_status: child.status}
      }
    end)
  end

  # The canonical dedup key is the primary match — the same
  # vocabulary-free grain the reconcile glue queries by — so a delivered
  # completion still counts when its payload no longer decodes under the
  # current vocabulary (a shrinking deploy sets decode_error; delivery
  # already happened). The decoded-tag match covers host-appended
  # completions that never carried the machinery key.
  defp completion_present?(report, completions, child, vocab) do
    rows = completions ++ if(is_list(report.dead_letters), do: report.dead_letters, else: [])
    canonical = InboxCodec.completion_dedup_key(child.tag_key, child.ref)

    Enum.any?(rows, fn %StoredInput{} = stored ->
      stored.dedup_key == canonical or
        (stored.decode_error == nil and stored.input.kind == :completed and
           safe_key(stored.input.tag, vocab) == child.tag_key)
    end)
  end

  defp safe_key(tag, vocab) do
    Codec.key(tag, vocabulary: vocab)
  rescue
    _undeclared -> nil
  end

  defp cascading?(%{envelope: %Envelope{} = envelope}), do: Envelope.cascading?(envelope)
  defp cascading?(_report), do: false

  defp age_ms(%DateTime{} = now, %StoredInput{inserted_at: %DateTime{} = at}),
    do: max(DateTime.diff(now, at, :millisecond), 0)

  defp age_ms(_now, _stored), do: nil

  ## Rendering

  @doc """
  The report as an operator-readable block — `IO.puts/1` it:

      {:ok, report} = Clementine.Loop.inspect(MyApp.LoopHost, loop_ref, lifecycle: MyApp.Lifecycle)
      report |> Clementine.Loop.Report.render() |> IO.puts()
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{facts: %Facts{} = facts} = report) do
    [
      "loop #{inspect(facts.ref)} — #{facts.status}, epoch #{facts.epoch}#{cancel_note(facts)}",
      "  spec: #{module_line(report)}",
      cascade_line(report),
      children_lines(report),
      timers_lines(report),
      pending_lines(report),
      dead_letter_lines(report),
      strand_lines(report)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp cancel_note(%Facts{cancel: nil}), do: ""
  defp cancel_note(%Facts{cancel: cancel}), do: ", cancel #{inspect(Map.get(cancel, :reason))}"

  defp module_line(%{module: {:ok, module}} = report) do
    %{stored: stored, declared: declared} = report.state_version
    "#{inspect(module)} state_version #{inspect(stored)} (declared #{inspect(declared)})"
  end

  defp module_line(%{module: {:error, {:incompatible_spec, detail}}}),
    do: "INCOMPATIBLE #{inspect(detail)}"

  defp cascade_line(%{envelope: %Envelope{pending_halt: %{result: result}}}),
    do: "  cascading toward #{inspect(result.__struct__)}"

  defp cascade_line(_report), do: nil

  defp children_lines(%{children: []}), do: "  children: none"

  defp children_lines(%{children: children}) do
    [
      "  children (#{length(children)} live):"
      | Enum.map(children, fn child ->
          "    #{tag_label(child)} -> run #{inspect(child.ref)} [#{child.status}]"
        end)
    ]
  end

  defp timers_lines(%{timers: []}), do: "  timers: none"

  defp timers_lines(%{timers: timers}) do
    [
      "  timers (#{length(timers)}):"
      | Enum.map(timers, fn timer -> "    #{tag_label(timer)} #{inspect(timer.meta)}" end)
    ]
  end

  defp pending_lines(%{pending: []}), do: "  pending: none"

  defp pending_lines(%{pending: pending} = report) do
    [
      "  pending (#{length(pending)}):"
      | Enum.map(pending, fn stored ->
          "    ##{inspect(stored.ref)} #{stored.input.kind} age=#{format_age(report.now, stored)}" <>
            "#{attempts_note(stored)}#{decode_note(stored)}"
        end)
    ]
  end

  defp dead_letter_lines(%{dead_letters: :unsupported}), do: "  dead letters: unsupported by host"
  defp dead_letter_lines(%{dead_letters: []}), do: "  dead letters: none"

  defp dead_letter_lines(%{dead_letters: dead}) do
    [
      "  dead letters (#{length(dead)}):"
      | Enum.map(dead, fn stored ->
          "    ##{inspect(stored.ref)} #{stored.input.kind} #{inspect(stored.dead_reason)}"
        end)
    ]
  end

  defp strand_lines(%{strands: []}), do: "  strands: none"

  defp strand_lines(%{strands: strands}) do
    [
      "  strands (#{length(strands)}):"
      | Enum.map(strands, fn strand ->
          "    ! #{strand.class} #{inspect(strand.detail)}"
        end)
    ]
  end

  defp tag_label(%{tag: {:ok, tag}}), do: inspect(tag)
  defp tag_label(%{tag: :undecodable, tag_key: tag_key}), do: "#{tag_key} (undecodable)"

  defp format_age(now, stored) do
    case age_ms(now, stored) do
      nil -> "unknown"
      ms when ms < 1000 -> "#{ms}ms"
      ms -> "#{div(ms, 1000)}s"
    end
  end

  defp attempts_note(%StoredInput{attempts: 0}), do: ""
  defp attempts_note(%StoredInput{attempts: n}), do: " attempts=#{n}"

  defp decode_note(%StoredInput{decode_error: nil}), do: ""
  defp decode_note(%StoredInput{}), do: " UNDECODABLE"
end
