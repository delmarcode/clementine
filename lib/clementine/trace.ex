defmodule Clementine.Trace do
  @moduledoc """
  A run's trace: what the model was offered, each call to it, and each
  tool call, recorded by the engine as the run executes and written with
  the run (`Clementine.Runs.trace/1` reads it). Audit reads it to learn
  what a run read and did, under whose authority; training reads the
  same rows for the trajectory. Only Clementine writes it.

  ## Entries

  Each entry is a `Clementine.Trace.Entry`. Its payload has string keys,
  as stored:

  - `:execution`, once per execution: when a run starts, and again when it
    resumes after an approval.
    - `"model"` — the model's resolved id
    - `"agent_fingerprint"` — a sha256 over the instructions, the tool
      schemas, and the model id, in lowercase hex. Executions with the same
      fingerprint offered the model the same thing.
    - `"instructions"` — the system prompt the execution sent
    - `"tools"` — the names of the tools offered, in order
    - `"resumed"` — `true` for an execution that resumed from a checkpoint
  - `:model_call`, once per call to the model.
    - `"iteration"`, `"duration_ms"`
    - `"stop_reason"` — the provider's, or `nil` when the call did not
      finish (a cancel, a drain, a lost lease, or a provider error ended
      the execution in the middle of it)
    - `"usage"` — `%{"input_tokens" => n, "output_tokens" => n}`, what
      the stream reported, so far as it got
    - `"content"` — the assistant's blocks, as
      `Clementine.LLM.Message.Content.to_map/1` maps them
  - `:tool_call`, once per tool call settled, a call that ran on after a
    cancel included (the model never sees its result; the trace keeps it).
    - `"iteration"`, `"tool_use_id"`, `"name"`, `"args"` (the arguments
      the tool ran with), `"is_error"`, `"duration_ms"`
    - `"result"` — the text the model saw
    - `"approval"` — `nil`, or `%{"verdict" => "approved" | "denied",
      "by" => ...}` for a call that waited on a decision, with `by` from
      the decision's meta

  ## Fidelity

  An agent declares how much its trace keeps with `trace:`
  (`Clementine.Agent`): `:content`, the default, keeps everything above;
  `:facts` leaves out `"instructions"`, `"content"`, and `"result"`,
  keeping names, arguments, ids, timing, usage, and the fingerprint. A
  turn agent whose host stores the conversation loses nothing under
  `:facts`; a task agent whose trajectory nothing else holds keeps
  `:content`. The fingerprint is the same under either.

  ## When it is written

  The engine records each entry as it happens. At every iteration
  boundary the runner writes the new ones, fenced on the run's epoch like
  the heartbeat, so an executor that has lost its run writes nothing; the
  terminal or suspend write carries the rest in its own transaction. A run
  that ended through its runner has its whole trace, committed with its
  end; a run reaped after its node died has its trace up to its last
  boundary.
  """

  alias Clementine.LLM.Message.Content
  alias Clementine.Trace.Entry

  @type fidelity :: :content | :facts

  # What :facts leaves out of each kind.
  @content_keys %{
    execution: ["instructions"],
    model_call: ["content"],
    tool_call: ["result"]
  }

  @doc "The fidelities an agent may declare."
  @spec fidelities() :: [fidelity()]
  def fidelities, do: [:content, :facts]

  @doc false
  # Raises unless `fidelity` is one an agent may declare.
  @spec validate_fidelity!(term()) :: fidelity()
  def validate_fidelity!(fidelity) when fidelity in [:content, :facts], do: fidelity

  def validate_fidelity!(other) do
    raise ArgumentError, "trace: takes :content or :facts, got: #{inspect(other)}"
  end

  @doc false
  # The `:execution` payload for an execution offering `model`,
  # `instructions`, and `tools`.
  @spec execution(
          Clementine.LLM.ModelRegistry.model_ref(),
          String.t() | nil,
          [module()],
          boolean()
        ) ::
          map()
  def execution(model, instructions, tools, resumed?) do
    %{
      "model" => model_id(model),
      "agent_fingerprint" => fingerprint(model, instructions, tools),
      "instructions" => instructions,
      "tools" => Enum.map(tools, & &1.__name__()),
      "resumed" => resumed?
    }
  end

  @doc false
  # The `:model_call` payload. `content` is the response's blocks, or nil
  # for a call that produced none.
  @spec model_call(
          pos_integer(),
          non_neg_integer(),
          String.t() | nil,
          Clementine.Usage.t(),
          list() | nil
        ) ::
          map()
  def model_call(iteration, duration_ms, stop_reason, %Clementine.Usage{} = usage, content) do
    %{
      "iteration" => iteration,
      "duration_ms" => duration_ms,
      "stop_reason" => stop_reason,
      "usage" => Clementine.Usage.to_map(usage),
      "content" => content && Enum.map(content, &content_map/1)
    }
  end

  @doc false
  # The `:tool_call` payload. `approval` is nil or `{verdict, meta}`.
  @spec tool_call(map()) :: map()
  def tool_call(%{} = call) do
    %{
      "iteration" => call.iteration,
      "tool_use_id" => call.tool_use_id,
      "name" => call.name,
      "args" => call.args,
      "result" => call.result,
      "is_error" => call.is_error,
      "duration_ms" => call.duration_ms,
      "approval" => approval(call[:approval])
    }
  end

  @doc false
  # What an entry of `kind` stores at `fidelity`: content keys dropped
  # under :facts, and every value in the form a jsonb round trip returns,
  # so what is recorded is what a read gives back, and a write never
  # fails on a value Postgres cannot store.
  @spec payload(Entry.kind(), map(), fidelity()) :: map()
  def payload(kind, payload, fidelity) do
    payload
    |> Map.drop(if fidelity == :facts, do: Map.get(@content_keys, kind, []), else: [])
    |> json()
  end

  @doc """
  The agent fingerprint of an execution offering `model`, `instructions`,
  and `tools`: a sha256 over the three, in lowercase hex. The tool schemas
  enter it as canonical JSON (keys sorted), so the fingerprint is stable
  across deploys and VM versions while the agent is unchanged.
  """
  @spec fingerprint(Clementine.LLM.ModelRegistry.model_ref(), String.t() | nil, [module()]) ::
          String.t()
  def fingerprint(model, instructions, tools) do
    %{
      "model" => model_id(model),
      "instructions" => instructions,
      "tools" => Enum.map(tools, & &1.__schema__())
    }
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # The provider's id for a model reference; a reference the catalog does
  # not hold (a test's) is recorded as written rather than failing the run.
  defp model_id(model) do
    Clementine.LLM.ModelRegistry.resolve!(model).id
  rescue
    ArgumentError -> if is_atom(model), do: Atom.to_string(model), else: inspect(model)
  end

  defp content_map(%_{} = block) do
    Content.to_map(block)
  rescue
    _ -> block |> Map.from_struct() |> json()
  end

  defp content_map(block), do: block

  defp approval(nil), do: nil

  defp approval({verdict, meta}) when verdict in [:approved, :denied] do
    %{"verdict" => Atom.to_string(verdict), "by" => by(meta)}
  end

  defp by(%{by: by}), do: by
  defp by(%{"by" => by}), do: by
  defp by(_meta), do: nil

  defp canonical(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {key(k), canonical(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: json(other)

  defp json(value) when is_binary(value) do
    cond do
      not String.valid?(value) -> inspect(value)
      # jsonb cannot hold U+0000.
      String.contains?(value, <<0>>) -> String.replace(value, <<0>>, "�")
      true -> value
    end
  end

  defp json(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value
  defp json(value) when is_atom(value), do: Atom.to_string(value)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)

  defp json(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {key(k), json(v)} end)

  defp json(other), do: inspect(other)

  defp key(key) when is_binary(key), do: json(key)
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: inspect(key)
end
