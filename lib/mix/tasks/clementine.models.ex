defmodule Mix.Tasks.Clementine.Models do
  @shortdoc "Shows each agent's model, the newest in its line, and what differs"

  @moduledoc """
  The adoption report: for each agent the app runs, its model, the
  platform its requests go to, the model's lifecycle, the newest active
  model in its line that platform serves, and the facts that differ
  between the two.

      $ mix clementine.models
      agent    model              platform   lifecycle                              newest in line     differs on the newest
      chat     claude-sonnet-5    anthropic  active, retires not before 2027-06-30  claude-sonnet-5-5  binding none->prefix; thinking +between_tools -off; cache read 0.1x->0.05x; min prefix 1024->512
      weather  claude-sonnet-5-5  anthropic  active, retires not before 2027-09-28  -                  -

  The facts it compares are the ones that change what an agent gets or
  pays: whether the model binds its thinking, the thinking types it
  takes, the cache read multiplier, the minimum cached prefix, the
  context window, the input and output prices, and the price tier. Below
  the table come the warnings boot also logs (a deprecated model, a
  not-sooner-than date passed, a shutdown date reached, sheets read more
  than 120 days ago), which compare dates with today and never fail
  anything.

  ## Which agents

  Every module that implements `Clementine.Agent`, in this project and
  in each dependency that depends on Clementine: a superset of the
  `agents:` in the child spec, read from the compiled code, so the task
  needs no database and starts nothing. Each agent's model is its
  `use Clementine.Agent`'s (`__model__/0`), with its choices, resolved as
  boot resolves them.

  An app that builds agents from data, picking each one's model in
  `agent/1` from a stored row, declares no model on `use`; its row says
  so. Point the task (and boot's checks and warnings) at the models such
  agents may run with the app's offer, a list of ids or a function that
  returns one:

      config :clementine, :offer, {MyApp.Models, :offered, []}

  Each offered id gets a row of its own. `--model ID` adds a row for any
  other id, once.

  ## Options

    * `--check` - also read Anthropic's and OpenAI's Models APIs, with
      the configured `anthropic_api_key` and `openai_api_key`, and report
      where the shipped sheets differ: ids the sheets lack, lifecycle and
      retirement or shutdown date changes, and capability and ceiling
      mismatches. Prices have no API and are not checked. A vendor
      without a configured key is skipped.
    * `--json` - print the report as JSON, for CI.
    * `--model ID` - add a row for a model id; repeatable.

  The task exits 1 when an agent's or an offered model would fail boot,
  or when `--check` finds a difference or cannot read an API; warnings
  never change the exit status.
  """

  use Mix.Task

  alias Clementine.Models
  alias Clementine.Models.{Check, Report}

  @switches [check: :boolean, json: :boolean, model: :keep]

  @impl Mix.Task
  def run(argv) do
    opts = parse!(argv)
    Mix.Task.run("app.config")
    if opts[:check], do: {:ok, _started} = Application.ensure_all_started(:req)

    report = report(opts)
    Mix.shell().info(if opts[:json], do: json(report), else: text(report))

    case status(report) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end

  defp parse!(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} ->
        opts

      {_opts, args, invalid} ->
        Mix.raise(
          "mix clementine.models takes --check, --json, and --model ID; got: " <>
            Enum.map_join(args ++ Enum.map(invalid, &elem(&1, 0)), " ", &inspect/1)
        )
    end
  end

  @doc false
  # The report as data: `agents:` and `today:` stand in for discovery
  # and the clock in tests.
  @spec report(keyword()) :: map()
  def report(opts) do
    agents = Keyword.get_lazy(opts, :agents, &agents/0)
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    offered = Enum.map(Models.offered(), &{:offer, &1})

    named =
      for id <- Keyword.get_values(opts, :model), {:offer, id} not in offered, do: {:cli, id}

    agents
    |> Report.build(Enum.uniq(offered ++ named), today)
    |> Map.put(:check, if(opts[:check], do: Check.run()))
  end

  @doc false
  # 1 when anything would fail boot, or the check found or hit
  # something; else 0.
  @spec status(map()) :: 0 | 1
  def status(report) do
    failing? = Enum.any?(report.agents ++ report.models, & &1.error)

    drifted? =
      Enum.any?(report.check || [], &(&1.status == :failed or &1.findings != []))

    if failing? or drifted?, do: 1, else: 0
  end

  @doc false
  # Every module implementing Clementine.Agent in this project's apps
  # and in the dependencies that depend on Clementine.
  @spec agents() :: [module()]
  def agents do
    project =
      if Mix.Project.umbrella?(),
        do: Map.keys(Mix.Project.apps_paths()),
        else: [Mix.Project.config()[:app]]

    (project ++ Enum.filter(Mix.Project.deps_apps(), &uses_clementine?/1))
    |> Enum.uniq()
    |> Enum.flat_map(&modules/1)
    |> Enum.filter(&agent?/1)
  end

  defp uses_clementine?(app),
    do: loaded?(app) and :clementine in (Application.spec(app, :applications) || [])

  defp modules(app), do: if(loaded?(app), do: Application.spec(app, :modules) || [], else: [])

  defp loaded?(app) do
    case Application.load(app) do
      :ok -> true
      {:error, {:already_loaded, ^app}} -> true
      {:error, _not_an_app} -> false
    end
  end

  defp agent?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :key, 0) and
      Clementine.Agent in behaviours(module)
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

  ## JSON

  @doc false
  @spec json(map()) :: String.t()
  def json(report), do: Jason.encode!(report, pretty: true)

  ## Text

  @headers ["agent", "model", "platform", "lifecycle", "newest in line", "differs on the newest"]

  @doc false
  @spec text(map()) :: String.t()
  def text(report) do
    rows = report.agents ++ report.models

    [
      table(rows, report.today),
      notes(rows),
      warnings(report.warnings, report.today),
      footer(report),
      check(report.check)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp table([], _today) do
    "No agents found, and config :clementine, :offer names no models. An agent is a module " <>
      "that uses Clementine.Agent; mix clementine.gen.agent writes one."
  end

  defp table(rows, today) do
    lines = [@headers | Enum.map(rows, &cells(&1, today))]

    widths =
      lines
      |> Enum.zip_with(& &1)
      |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map_join(lines, "\n", fn cells ->
      cells
      |> Enum.zip(widths)
      |> Enum.with_index()
      |> Enum.map_join("  ", fn
        {{cell, _width}, index} when index == length(@headers) - 1 -> cell
        {{cell, width}, _index} -> String.pad_trailing(cell, width)
      end)
      |> String.trim_trailing()
    end)
  end

  defp cells(row, today) do
    [
      label(row),
      row.model || "(agent/1)",
      (row.platform && Atom.to_string(row.platform)) || "-",
      lifecycle(row, today),
      row.newest || "-",
      differs(row)
    ]
  end

  defp label(%{source: :agent, agent: key}), do: key
  defp label(%{source: :offer}), do: "(offered)"
  defp label(%{source: :cli}), do: "(--model)"

  defp lifecycle(%{error: error, lifecycle: nil}, _today) when is_binary(error), do: "error"
  defp lifecycle(%{lifecycle: nil}, _today), do: "-"

  defp lifecycle(%{lifecycle: lifecycle, vendor: vendor, error: error}, today) do
    parts =
      [Atom.to_string(lifecycle.status)] ++
        ending(lifecycle, vendor, today) ++
        if(lifecycle.status != :active and lifecycle.replacement,
          do: ["replaced by #{lifecycle.replacement}"],
          else: []
        ) ++
        if(error, do: ["boot refuses it"], else: [])

    Enum.join(parts, ", ")
  end

  defp ending(%{status: :retired, retires_on: date}, vendor, _today) when not is_nil(date),
    do: ["#{if vendor == :openai, do: "shut down", else: "retired"} #{date}"]

  defp ending(%{retires_on: %Date{} = date}, vendor, today) do
    if Date.compare(date, today) == :gt,
      do: ["#{if vendor == :openai, do: "shuts down", else: "retires"} #{date}"],
      else: ["#{if vendor == :openai, do: "shutdown", else: "retirement"} date reached #{date}"]
  end

  defp ending(%{retires_not_before: %Date{} = date}, _vendor, today) do
    if Date.compare(date, today) == :lt,
      do: ["date passed #{date}"],
      else: ["retires not before #{date}"]
  end

  defp ending(_lifecycle, _vendor, _today), do: []

  defp differs(%{newest: nil}), do: "-"
  defp differs(%{differs: []}), do: "nothing"
  defp differs(%{differs: differs}), do: Enum.map_join(differs, "; ", &differ/1)

  defp differ(%{fact: :binding, from: from, to: to}), do: "binding #{from}->#{to}"

  defp differ(%{fact: :thinking, from: from, to: to}) do
    "thinking " <>
      Enum.join(Enum.map(to -- from, &"+#{&1}") ++ Enum.map(from -- to, &"-#{&1}"), " ")
  end

  defp differ(%{fact: :cache_read, from: from, to: to}),
    do: "cache read #{multiplier(from)}->#{multiplier(to)}"

  defp differ(%{fact: :min_prefix, from: from, to: to}),
    do: "min prefix #{from || "none"}->#{to || "none"}"

  defp differ(%{fact: :context, from: from, to: to}), do: "context #{tokens(from)}->#{tokens(to)}"

  defp differ(%{fact: :price, from: from, to: to}),
    do: "price in/out #{price(from)}->#{price(to)}"

  defp differ(%{fact: :tier, from: from, to: to}), do: "tier #{tier(from)}->#{tier(to)}"

  defp multiplier(nil), do: "none"
  defp multiplier(value), do: :erlang.float_to_binary(value / 1, [:compact, decimals: 4]) <> "x"

  defp price(nil), do: "unpriced"
  defp price(%{input: input, output: output}), do: "#{money(input)}/#{money(output)}"

  defp tier(nil), do: "none"
  defp tier(tokens), do: "over #{tokens(tokens)}"

  defp money(amount) do
    if amount == trunc(amount) do
      Integer.to_string(trunc(amount))
    else
      case String.split(:erlang.float_to_binary(amount / 1, [:compact, decimals: 6]), ".") do
        [whole, fraction] -> whole <> "." <> String.pad_trailing(fraction, 2, "0")
        [whole] -> whole
      end
    end
  end

  defp tokens(nil), do: "none"
  defp tokens(count) when count >= 1_000_000, do: scaled(count / 1_000_000) <> "M"
  defp tokens(count) when count >= 1_000, do: scaled(count / 1_000) <> "K"
  defp tokens(count), do: Integer.to_string(count)

  defp scaled(value) do
    rounded = Float.round(value, 2)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: Float.to_string(rounded)
  end

  defp notes(rows) do
    errors =
      for %{error: error} = row <- rows, error, do: "  #{subject(row)}: #{error}"

    unset =
      for %{source: :agent, model: nil, agent: key} <- rows,
          do:
            "  agent #{inspect(key)} picks its model in agent/1. List the models it may run " <>
              "under config :clementine, :offer to report them here."

    [
      if(errors != [], do: Enum.join(["Boot refuses:" | errors], "\n")),
      if(unset != [], do: Enum.join(["Models chosen per run:" | unset], "\n"))
    ]
  end

  defp warnings([], _today), do: nil

  defp warnings(warnings, today) do
    lines =
      Enum.map(warnings, fn
        %{subject: nil, message: message} -> "  #{message}"
        %{subject: subject, message: message} -> "  #{subject}: #{message}"
      end)

    Enum.join(["Warnings (dates compared with today, #{today}; never errors):" | lines], "\n")
  end

  defp footer(%{registry: registry, check: check}) do
    hint =
      if check,
        do: "",
        else: " mix clementine.models --check compares them with the vendors' Models APIs."

    "Clementine's model sheets were read #{registry.read}.#{hint}"
  end

  defp subject(%{source: :agent, agent: key}), do: "agent #{inspect(key)}"
  defp subject(%{source: :offer, model: id}), do: "offered #{id}"
  defp subject(%{source: :cli, model: id}), do: "--model #{id}"

  ## --check

  defp check(nil), do: nil
  defp check(results), do: Enum.map(results, &vendor_check/1)

  defp vendor_check(%{status: :skipped, vendor: vendor, reason: reason}),
    do: "#{api(vendor)}: skipped; #{reason}."

  defp vendor_check(%{status: :failed, vendor: vendor, reason: reason}),
    do: "#{api(vendor)}: could not be read: #{reason}."

  defp vendor_check(%{vendor: vendor, listed: listed, findings: findings, unshipped: unshipped}) do
    head =
      "#{api(vendor)} lists #{listed} models: " <>
        case findings do
          [] -> "the sheets agree"
          [_one] -> "1 difference from the sheets (sheet -> API)"
          many -> "#{length(many)} differences from the sheets (sheet -> API)"
        end <>
        unshipped(unshipped)

    width = findings |> Enum.map(&String.length(&1.id)) |> Enum.max(fn -> 0 end)

    Enum.join(
      [
        head
        | Enum.map(findings, &("  " <> String.pad_trailing(&1.id, width) <> "  " <> finding(&1)))
      ],
      "\n"
    )
  end

  defp unshipped([]), do: "."

  defp unshipped(ids),
    do: "; #{length(ids)} older or non-vendor ids the sheets do not ship (--json lists them)."

  defp api(:anthropic), do: "Anthropic's Models API"
  defp api(:openai), do: "OpenAI's Models API"

  defp finding(%{kind: :unknown, api: api}) do
    known =
      Enum.map_join(
        for(key <- [:lifecycle, :line, :released, :created, :owned_by], api[key], do: key),
        ", ",
        &"#{&1} #{api[&1]}"
      )

    "not in the sheets (#{known}); declare it under config :clementine, :models, based_on: " <>
      "the sheet it succeeds, until a Clementine release ships it"
  end

  defp finding(%{kind: kind, sheet: sheet, api: api}),
    do: "#{kind} #{value(sheet)} -> #{value(api)}"

  defp value(nil), do: "none"
  defp value(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &to_string/1) <> "]"
  defp value(other), do: to_string(other)
end
