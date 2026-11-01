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
    - `"provider"` — the provider the model resolved to (`"anthropic"`,
      `"openai"`, ...)
    - `"model"` — the provider's id for the model
    - `"alias"` — the catalog alias the agent named; `nil` for a direct
      `{provider, id}` reference
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
    - `"provider"`, `"model"` — as in `:execution`, resolved for the call
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
    - `"iteration"`, `"tool_use_id"`, `"args"` (the arguments the tool ran
      with), `"is_error"`, `"duration_ms"`
    - `"name"` — the tool's, or the name the model asked for when the
      agent offers no tool of that name
    - `"unknown"` — `true` when the agent offers no tool of that name:
      the call ran nothing, and its `"result"` is the error the model
      read. Absent for a tool the agent offers.
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

  ## How it is stored

  On the durable runtime the trace is `agent_run_trace`
  (`Clementine.Migration`, version 5), and each entry's facts have
  columns of their own, so a warehouse or a dashboard reads them without
  the content:

  - `:execution`: `provider`, `model`, `alias`, `agent_fingerprint`.
  - `:model_call`: `iteration`, `provider`, `model`, `alias`, the four
    counts of `"usage"` (`input_tokens`, `output_tokens`,
    `cache_read_tokens`, `cache_write_tokens`), `"cost"` as `cost_micros`
    and `currency`, `duration_ms`, `stop_reason`.
  - `:tool_call`: `iteration`, `tool_use_id`, `tool_name` (`"name"`),
    `is_error`, `killed`, `duration_ms`, and `"approval"`'s verdict and
    `"policy"`'s verdict and failure as `approval_verdict`,
    `policy_verdict`, and `policy_failed`. A name the agent does not offer
    is the model's text: its `tool_name` is null, and `"name"` and
    `"unknown"` stay in `payload`.
  - `:policy`: `iteration`, `tool_use_id`, `tool_name` (`"name"`),
    `policy_verdict` (`"verdict"`), `policy_failed` (`"failed"`).
  - `:skill_load`: `iteration`, `tool_use_id`, `skill_name` (`"name"`).
  - `:delegate`: `iteration`, `tool_use_id`, `delegate_key` (`"agent"`).

  A delegate's child is the run whose `parent_id` is this run and whose
  `tag_id` is the `delegate` call's `tool_use_id`, and a skill load and the
  `use_skill` call that made it share a `tool_use_id`, so a warehouse joins
  them without the content.

  The columns hold only ids, names fixed in code or chosen by the app,
  numbers, and enums, never text a person, a model, or a tool produced.
  Every other key stays in `payload`, which a fact is never copied into:
  `Clementine.Runs.trace/1` puts the columns back, so an entry reads as
  listed above.

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
  alias Clementine.LLM.ModelRegistry
  alias Clementine.Trace.Entry

  @type fidelity :: :content | :facts

  # What :facts leaves out of each kind.
  @content_keys %{
    execution: ["instructions"],
    model_call: ["content"],
    tool_call: ["result"]
  }

  # The columns of agent_run_trace that hold an entry's facts
  # (Clementine.Migration, version 5), in table order.
  @columns [
    :iteration,
    :tool_use_id,
    :provider,
    :model,
    :alias,
    :agent_fingerprint,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :cost_micros,
    :currency,
    :duration_ms,
    :stop_reason,
    :tool_name,
    :is_error,
    :killed,
    :approval_verdict,
    :policy_verdict,
    :policy_failed,
    :skill_name,
    :delegate_key
  ]

  @usage_columns [:input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens]

  # The facts each kind keeps at the top of its payload, by column. The
  # nested ones (a model call's usage and cost, a tool call's verdicts)
  # and a tool call's name are split_nested/2's.
  @fact_keys %{
    execution: [
      provider: "provider",
      model: "model",
      alias: "alias",
      agent_fingerprint: "agent_fingerprint"
    ],
    model_call: [
      iteration: "iteration",
      provider: "provider",
      model: "model",
      alias: "alias",
      duration_ms: "duration_ms",
      stop_reason: "stop_reason"
    ],
    tool_call: [
      iteration: "iteration",
      tool_use_id: "tool_use_id",
      is_error: "is_error",
      killed: "killed",
      duration_ms: "duration_ms"
    ],
    policy: [
      iteration: "iteration",
      tool_use_id: "tool_use_id",
      tool_name: "name",
      policy_verdict: "verdict",
      policy_failed: "failed"
    ],
    skill_load: [iteration: "iteration", tool_use_id: "tool_use_id", skill_name: "name"],
    delegate: [iteration: "iteration", tool_use_id: "tool_use_id", delegate_key: "agent"]
  }

  @typedoc """
  The model an execution or a call runs on, resolved once
  (`resolve_model/1`): the catalog's resolution, or a reference the
  catalog does not hold, as written.
  """
  @type model :: %{
          required(:provider) => ModelRegistry.provider() | nil,
          required(:id) => String.t() | nil,
          required(:alias) => atom() | nil,
          required(:pricing) => Clementine.LLM.Pricing.t() | nil,
          optional(atom()) => term()
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
  # The model `ref` names, resolved once for an execution or a call, so
  # its trace entry, its cost, and its telemetry name the same provider,
  # id, alias, and prices: the catalog's resolution
  # (`ModelRegistry.resolve!/1`), or, for a reference the catalog does not
  # hold (a test's on a mock client, or an alias since removed), the
  # reference as written, with no provider and no prices, rather than
  # failing the run over its record. An alias is not a provider's id, so
  # such an alias leaves the id nil; `alias` names it.
  @spec resolve_model(ModelRegistry.model_ref()) :: model()
  def resolve_model(ref) do
    ModelRegistry.resolve!(ref)
  rescue
    ArgumentError ->
      %{provider: nil, id: written_id(ref), alias: if(is_atom(ref), do: ref), pricing: nil}
  end

  defp written_id({_provider, id}) when is_binary(id), do: id
  defp written_id(_ref), do: nil

  @doc false
  # The `:execution` payload for an execution offering `model` (resolved,
  # `resolve_model/1`), `instructions`, and `tools`, the agent's own.
  # `offer` is what else it offers the model (see `fingerprint/4`), and
  # `offered:`, every tool the execution begins with when that is more
  # than `tools` (the tools of skills restored from a checkpoint, and
  # engine tools), which only the entry's `"tools"` reads.
  @spec execution(model(), String.t() | nil, [module()], boolean(), keyword()) :: map()
  def execution(model, instructions, tools, resumed?, offer \\ []) do
    {offered, offer} = Keyword.pop(offer, :offered, tools)

    %{
      "provider" => model.provider,
      "model" => model.id,
      "alias" => model.alias,
      "agent_fingerprint" => fingerprint_of(model, instructions, tools, offer),
      "instructions" => instructions,
      "tools" => Enum.map(offered, &Clementine.Tool.to_schema(&1).name),
      "deferred" => Enum.map(Keyword.get(offer, :deferred, []), & &1.__name__()),
      "skills" => Enum.map(Keyword.get(offer, :skills, []), & &1.name),
      "delegates" => Enum.map(Keyword.get(offer, :delegates, []), &delegate_key/1),
      "resumed" => resumed?
    }
  end

  @doc false
  # The `:model_call` payload of a call to `model` (resolved for the call,
  # `resolve_model/1`) that burned `usage` and cost `cost` at the model's
  # prices then. `content` is the response's blocks, or nil for a call
  # that produced none.
  @spec model_call(
          model(),
          pos_integer(),
          non_neg_integer(),
          String.t() | nil,
          Clementine.Usage.t(),
          Clementine.Cost.t() | nil,
          list() | nil
        ) ::
          map()
  def model_call(model, iteration, duration_ms, stop_reason, usage, cost, content) do
    %{
      "iteration" => iteration,
      "duration_ms" => duration_ms,
      "stop_reason" => stop_reason,
      "usage" => Clementine.Usage.to_map(usage),
      "provider" => model.provider,
      "model" => model.id,
      "alias" => model.alias,
      "cost" => Clementine.Cost.to_map(cost),
      "content" => content && Enum.map(content, &content_map/1)
    }
  end

  @doc false
  # The `:tool_call` payload. `approval` is nil or `{verdict, meta}`, and
  # `policy` nil or the tool policy's verdict: `:allow`,
  # `:require_approval`, `{:deny, reason}`, or `{:failed, reason}` for a
  # call denied because the policy failed. `unknown: true` marks a name
  # the agent does not offer.
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
    |> put_present("unknown", if(call[:unknown], do: true))
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
  # The columns of `agent_run_trace` that hold an entry's facts.
  @spec columns() :: [atom()]
  def columns, do: @columns

  @doc false
  # How an entry of `kind` with `payload` (as `payload/3` gives it) is
  # stored: its facts as a value for every column in `columns/0` (nil
  # where the kind has none), and the rest of its payload. A fact goes in
  # its column only, so `from_row/3` is the way back. A kind this version
  # does not record has no columns.
  @spec to_row(Entry.kind() | String.t(), map()) :: {map(), map()}
  def to_row(kind, payload) do
    keys = Map.get(@fact_keys, kind, [])
    {facts, rest} = Map.split(payload, Keyword.values(keys))
    {nested, rest} = split_nested(kind, rest)

    {row(Enum.map(keys, fn {column, key} -> {column, facts[key]} end) ++ nested), rest}
  end

  defp split_nested(:model_call, payload) do
    {usage, rest} = Map.pop(payload, "usage")
    {cost, rest} = Map.pop(rest, "cost")
    usage = usage || %{}
    cost = cost || %{}

    {[cost_micros: cost["micros"], currency: cost["currency"]] ++
       for(column <- @usage_columns, do: {column, usage[Atom.to_string(column)]}), rest}
  end

  # A name the agent does not offer is the model's text: it stays in the
  # payload, beside "unknown". An approval's `by` and a policy's reason
  # stay too; only the verdicts and the failure are facts.
  defp split_nested(:tool_call, payload) do
    {name, rest} = if payload["unknown"], do: {nil, payload}, else: Map.pop(payload, "name")
    {approval, rest} = Map.pop(rest, "approval")
    {policy, rest} = Map.pop(rest, "policy")

    rest =
      rest
      |> put_present("approval", approval && Map.delete(approval, "verdict"))
      |> put_present("policy", policy && Map.drop(policy, ["verdict", "failed"]))

    {[
       tool_name: name,
       approval_verdict: approval && approval["verdict"],
       policy_verdict: policy && policy["verdict"],
       policy_failed: policy && policy["failed"]
     ], rest}
  end

  defp split_nested(_kind, payload), do: {[], payload}

  @doc false
  # The payload of an entry of `kind` stored as `columns` (a map with a
  # key for each of `columns/0`) and `payload`: the inverse of `to_row/2`.
  # A key the stored payload holds itself wins over its column.
  @spec from_row(Entry.kind() | String.t(), map(), map()) :: map()
  def from_row(kind, columns, payload) do
    {nested, payload} = join_nested(kind, columns, payload)

    @fact_keys
    |> Map.get(kind, [])
    |> Map.new(fn {column, key} -> {key, Map.fetch!(columns, column)} end)
    |> Map.merge(nested)
    |> Map.merge(payload)
  end

  defp join_nested(:model_call, columns, payload) do
    cost =
      if columns.cost_micros,
        do: %{"currency" => columns.currency, "micros" => columns.cost_micros}

    usage = Map.new(@usage_columns, &{Atom.to_string(&1), Map.fetch!(columns, &1)})
    {%{"usage" => usage, "cost" => cost}, payload}
  end

  defp join_nested(:tool_call, columns, payload) do
    {approval, payload} = Map.pop(payload, "approval")
    {policy, payload} = Map.pop(payload, "policy")

    {%{
       "name" => columns.tool_name,
       "approval" => with_facts(approval, %{"verdict" => columns.approval_verdict}),
       "policy" =>
         with_facts(policy, %{
           "verdict" => columns.policy_verdict,
           "failed" => columns.policy_failed
         })
     }, payload}
  end

  defp join_nested(_kind, _columns, payload), do: {%{}, payload}

  defp row(facts), do: Map.merge(Map.new(@columns, &{&1, nil}), Map.new(facts))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # A nested map's facts go back into what the payload kept of it; an
  # entry stored with none (no approval, no policy, or a row from before
  # version 5) reads as stored.
  defp with_facts(rest, %{"verdict" => nil}), do: rest
  defp with_facts(rest, facts), do: Map.merge(rest || %{}, facts)

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
    model |> resolve_model() |> fingerprint_of(instructions, tools, offer)
  end

  defp fingerprint_of(model, instructions, tools, offer) do
    %{
      "model" => fingerprint_model(model),
      "instructions" => instructions,
      "tools" => Enum.map(tools, & &1.__schema__())
    }
    |> Map.merge(offered(offer))
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # The model enters as the provider's id, or, for an alias the catalog
  # does not hold, as the alias's name, so such an agent fingerprints as
  # it always did, and two such aliases apart.
  defp fingerprint_model(%{id: nil, alias: model_alias})
       when is_atom(model_alias) and not is_nil(model_alias),
       do: Atom.to_string(model_alias)

  defp fingerprint_model(%{id: id}), do: id

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
