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
    resumes after an approval or a delegation.
    - `"model"` — the model's resolved id
    - `"agent_fingerprint"` — a sha256 over the model id, the
      instructions, the agent's tool schemas, and, when the agent has
      them, which tools are deferred, the output schema, the skills it
      offers (each one's name, description, and tool schemas), and the
      agents it may ask (their keys, and descriptions where they have
      them), in lowercase hex. Executions with the
      same fingerprint ran the same agent: they offered the model the same
      thing.
    - `"instructions"` — the system prompt the execution sent
    - `"tools"` — the names of the tools offered as the execution began,
      in order: the agent's, deferred ones included, then those of the
      skills a resumed execution had loaded before it parked, then
      `use_skill` when the agent offers skills, and `delegate` when it
      offers delegates
    - `"deferred"` — the names of the tools among them the model loads
      through the provider's tool search (`deferred:` on the agent); `[]`
      when none are
    - `"skills"` — the names of the skills the agent offers; `[]` when
      none are
    - `"delegates"` — the keys of the agents it may ask; `[]` when none
      are
    - `"resumed"` — `true` for an execution that resumed from a checkpoint
  - `:model_call`, once per call to the model.
    - `"iteration"`, `"duration_ms"`
    - `"stop_reason"` — the provider's, or `nil` when the call did not
      finish (a cancel, a drain, a lost lease, or a provider error ended
      the execution in the middle of it)
    - `"usage"` — `Clementine.Usage.to_map/1`'s map (`"input_tokens"`,
      `"output_tokens"`, `"cache_read_tokens"`, `"cache_write_tokens"`),
      what the stream reported, so far as it got
    - `"alias"` — the catalog alias the call ran on, whose prices priced
      it; `nil` for a direct `{provider, id}` reference. Two aliases may
      share a provider id at different prices, so the id is not enough.
    - `"cost"` — what the call cost, frozen when it ended at the prices
      the alias had then: `Clementine.Cost.to_map/1`'s map
      (`"currency"`, `"micros"`), or `nil` for an alias without prices
      (`Clementine.Runs.cost/2` sums them)
    - `"content"` — the assistant's blocks, as
      `Clementine.LLM.Message.Content.to_map/1` maps them
  - `:tool_call`, once per tool call started, a call a cancel or a drain
    cut off included (the model never sees its result; the trace keeps it).
    - `"iteration"`, `"tool_use_id"`, `"name"`, `"args"` (the arguments
      the tool ran with), `"is_error"`, `"duration_ms"`
    - `"result"` — the text the model saw, or would have; `nil` for a
      killed call
    - `"killed"` — `true` for a call killed before it answered (a drain,
      or a cancel stopping a `retry: :safe` tool): it started, and what it
      did is unknown
    - `"approval"` — `nil`, or `%{"verdict" => "approved" | "denied",
      "by" => ...}` for a call that waited on a decision, with `by` from
      the decision's meta
    - `"policy"` — `nil`, or the tool policy's verdict the call settled
      under, for a call to a tool declared `approval: {:policy, term}`
      (`c:Clementine.Host.authorize_tool/3`): `%{"verdict" => "allow" |
      "require_approval" | "deny", "reason" => ..., "failed" => ...}`.
      `"reason"` is the text a deny gave the model, `nil` otherwise, and
      `"failed"` is `true` when the policy raised, gave an answer it may
      not, or did not answer in time, and the call was denied for it. A
      call that waited on a decision carries the `"approval"` beside it:
      the verdict the policy gave when the approval resumed the run
      (where a deny wins over the approval), or the one that parked it
      when the decision was a denial. `nil` when no policy was asked: a
      tool without `{:policy, _}`, or a run without one, where
      `{:policy, _}` gates like `:required`.

    A call the policy denied ran nothing: its entry has the deny's text
    as `"result"`, `"is_error"` `true`, and `"duration_ms"` 0.
  - `:policy`, once per answer the tool policy gave, when it gave it:
    before the call settles, so a run that parks on the call, or a
    cancel, a drain, or an expiry that ends it meanwhile, keeps the
    answer. A call the policy is asked about again (on a resume) gets an
    entry each time.
    - `"iteration"`, `"tool_use_id"`, `"name"` (the tool's)
    - `"verdict"`, `"reason"`, `"failed"` — as in the `:tool_call`
      entry's `"policy"`

    A `use_skill` call is a tool call like any other: its result is the
    skill's body, or the error the model saw. The engine settles it before
    the rest of its batch starts, so a cancel or a drain never kills one.
  - `:skill_load`, once per skill loaded, just before the `use_skill`
    call that loaded it (`Clementine.Skill`). A call that loaded nothing
    (a name not offered, a skill already loaded) records none.
    - `"iteration"`, `"tool_use_id"` (of the `use_skill` call)
    - `"name"` — the skill's
    - `"tools"` — the names of the tools it brought
    - `"body_sha256"` — a sha256 of the body the model read, in lowercase
      hex: a body may differ by run, and this says which one it was under
      either fidelity (the body itself is the `use_skill` call's result)
  - `:delegate`, once per child a `delegate` call started
    (`Clementine.Delegation`), when the run resumes with the children's
    answers, just before that call's `:tool_call` entry. A call refused
    at once, or refused when the run parked, records none.
    - `"iteration"`, `"tool_use_id"` (of the `delegate` call)
    - `"agent"` — the child's agent key
    - `"child_id"` — the child's run id: `Clementine.Runs.trace/1` of it
      is the child's own trace
    - `"status"` — how the child ended: `"completed"`, `"failed"`,
      `"cancelled"`, or `"interrupted"`

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
  # `instructions`, and `tools`, the agent's own. `offer` is what else it
  # offers the model (see `fingerprint/4`), and `offered:`, every tool the
  # execution begins with when that is more than `tools` (the tools of
  # skills restored from a checkpoint, and engine tools), which only the
  # entry's `"tools"` reads.
  @spec execution(
          Clementine.LLM.ModelRegistry.model_ref(),
          String.t() | nil,
          [module()],
          boolean(),
          keyword()
        ) ::
          map()
  def execution(model, instructions, tools, resumed?, offer \\ []) do
    {offered, offer} = Keyword.pop(offer, :offered, tools)

    %{
      "model" => model_id(model),
      "agent_fingerprint" => fingerprint(model, instructions, tools, offer),
      "instructions" => instructions,
      "tools" => Enum.map(offered, &Clementine.Tool.to_schema(&1).name),
      "deferred" => Enum.map(Keyword.get(offer, :deferred, []), & &1.__name__()),
      "skills" => Enum.map(Keyword.get(offer, :skills, []), & &1.name),
      "delegates" => Enum.map(Keyword.get(offer, :delegates, []), &delegate_key/1),
      "resumed" => resumed?
    }
  end

  @doc false
  # The `:model_call` payload of a call to `model`. `content` is the
  # response's blocks, or nil for a call that produced none.
  @spec model_call(
          Clementine.LLM.ModelRegistry.model_ref(),
          pos_integer(),
          non_neg_integer(),
          String.t() | nil,
          Clementine.Usage.t(),
          list() | nil
        ) ::
          map()
  def model_call(model, iteration, duration_ms, stop_reason, %Clementine.Usage{} = usage, content) do
    %{
      "iteration" => iteration,
      "duration_ms" => duration_ms,
      "stop_reason" => stop_reason,
      "usage" => Clementine.Usage.to_map(usage),
      "alias" => alias_name(model),
      "cost" => usage |> Clementine.Cost.of(model) |> Clementine.Cost.to_map(),
      "content" => content && Enum.map(content, &content_map/1)
    }
  end

  @doc false
  # The `:tool_call` payload. `approval` is nil or `{verdict, meta}`, and
  # `policy` nil or the tool policy's verdict: `:allow`,
  # `:require_approval`, `{:deny, reason}`, or `{:failed, reason}` for a
  # call denied because the policy failed.
  @spec tool_call(map()) :: map()
  def tool_call(%{} = call) do
    %{
      "iteration" => call.iteration,
      "tool_use_id" => call.tool_use_id,
      "name" => call.name,
      "args" => call.args,
      "result" => call.result,
      "is_error" => call.is_error,
      "killed" => Map.get(call, :killed, false),
      "duration_ms" => call.duration_ms,
      "approval" => approval(call[:approval]),
      "policy" => call[:policy] && verdict_map(call[:policy])
    }
  end

  @doc false
  # The `:policy` payload: the tool policy's `verdict` (as `tool_call/1`
  # takes it) on `call` in `iteration`.
  @spec policy(pos_integer(), %{id: String.t(), name: String.t()}, term()) :: map()
  def policy(iteration, call, verdict) do
    Map.merge(
      %{"iteration" => iteration, "tool_use_id" => call.id, "name" => call.name},
      verdict_map(verdict)
    )
  end

  @doc false
  # The `:skill_load` payload for `skill`, whose `body` the `use_skill`
  # call `tool_use_id` loaded in `iteration`. The body's hash is a fact:
  # :facts keeps it.
  @spec skill_load(pos_integer(), String.t(), Clementine.Skill.t(), String.t()) :: map()
  def skill_load(iteration, tool_use_id, %Clementine.Skill{} = skill, body)
      when is_binary(body) do
    %{
      "iteration" => iteration,
      "tool_use_id" => tool_use_id,
      "name" => skill.name,
      "tools" => Enum.map(skill.tools, & &1.__name__()),
      "body_sha256" => :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    }
  end

  @doc false
  # The `:delegate` payload for the `delegate` call `tool_use_id` in
  # `iteration`, whose child ended with `outcome`
  # (`Clementine.Delegation.outcome/2`).
  @spec delegate(pos_integer(), String.t(), Clementine.Delegation.child(), map()) :: map()
  def delegate(iteration, tool_use_id, child, outcome) do
    %{
      "iteration" => iteration,
      "tool_use_id" => tool_use_id,
      "agent" => child.agent,
      "child_id" => child.run_id,
      "status" => outcome["status"]
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

  `offer` is what else the execution offers the model: `deferred:`, the
  tools in `tools` it loads through the provider's tool search;
  `output_schema:`, the JSON schema its final answer follows (canonical
  JSON too); `skills:`, the skills it may load, each with its name, its
  description, and its tools' schemas, not its body (the body is read
  when the model loads the skill, and may differ by run); and
  `delegates:`, the agents it may ask, each by key, or as a
  `{key, description}` pair whose description enters beside the key
  when there is one. Each enters the
  fingerprint only when set, so an agent without it keeps the fingerprint
  it had; moving a tool between `tools:` and `deferred:`, changing the
  schema, changing a skill's description or tools, or changing whom it
  may ask changes it.
  """
  @spec fingerprint(
          Clementine.LLM.ModelRegistry.model_ref(),
          String.t() | nil,
          [module()],
          keyword()
        ) ::
          String.t()
  def fingerprint(model, instructions, tools, offer \\ []) do
    %{
      "model" => model_id(model),
      "instructions" => instructions,
      "tools" => Enum.map(tools, & &1.__schema__())
    }
    |> Map.merge(offered(offer))
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp offered(offer) do
    Enum.reduce(offer, %{}, fn
      {:deferred, []}, acc ->
        acc

      {:deferred, tools}, acc ->
        Map.put(acc, "deferred", Enum.map(tools, & &1.__name__()))

      {:output_schema, nil}, acc ->
        acc

      {:output_schema, schema}, acc ->
        Map.put(acc, "output_schema", schema)

      {:skills, []}, acc ->
        acc

      {:skills, skills}, acc ->
        Map.put(acc, "skills", Enum.map(skills, &skill_fingerprint/1))

      {:delegates, []}, acc ->
        acc

      {:delegates, entries}, acc ->
        Map.put(acc, "delegates", Enum.map(entries, &delegate_print/1))
    end)
  end

  # A delegate enters as its key, or `{key, description}`; a description
  # enters the fingerprint beside its key, so an agent whose delegates
  # have none keeps the fingerprint it had.
  defp delegate_key({key, _description}), do: key
  defp delegate_key(key) when is_binary(key), do: key

  defp delegate_print({key, nil}), do: key
  defp delegate_print({key, description}), do: %{"key" => key, "description" => description}
  defp delegate_print(key) when is_binary(key), do: key

  defp skill_fingerprint(%Clementine.Skill{} = skill) do
    %{
      "name" => skill.name,
      "description" => skill.description,
      "tools" => Enum.map(skill.tools, & &1.__schema__())
    }
  end

  defp alias_name(model) when is_atom(model) and not is_nil(model), do: Atom.to_string(model)
  defp alias_name(_tuple), do: nil

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

  defp verdict_map(:allow), do: %{"verdict" => "allow", "reason" => nil, "failed" => false}

  defp verdict_map(:require_approval),
    do: %{"verdict" => "require_approval", "reason" => nil, "failed" => false}

  defp verdict_map({:deny, reason}),
    do: %{"verdict" => "deny", "reason" => reason, "failed" => false}

  defp verdict_map({:failed, reason}),
    do: %{"verdict" => "deny", "reason" => reason, "failed" => true}

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
