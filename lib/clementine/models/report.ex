defmodule Clementine.Models.Report do
  @moduledoc false
  # What `mix clementine.models` reports, as plain data the task renders
  # as a table or as JSON: for each agent the app runs and each model it
  # offers, the model, the platform its requests go to, its lifecycle,
  # the newest active model in its line, and the facts that differ
  # between the two; the clock's warnings (Clementine.Models.Warnings);
  # and when the shipped sheets were read. It reads no network.

  alias Clementine.{Agent, Model, Models}
  alias Clementine.LLM.Policy
  alias Clementine.Models.Warnings

  @micro 1_000_000

  @type row :: %{
          agent: String.t() | nil,
          module: String.t() | nil,
          source: :agent | :offer | :cli,
          model: String.t() | nil,
          vendor: atom() | nil,
          line: atom() | nil,
          platform: atom() | nil,
          lifecycle: map() | nil,
          newest: String.t() | nil,
          differs: [%{fact: atom(), from: term(), to: term()}],
          warnings: [map()],
          error: String.t() | nil
        }

  @doc """
  The report on `today` for `agents` (agent modules) and `models`
  (`{source, id, choices}`, where `source` is `:offer` for an entry of
  the app's offer, with its choices, and `:cli` for an id named on the
  command line).
  """
  @spec build([module()], [{:offer | :cli, String.t(), keyword()}], Date.t()) :: map()
  def build(agents, models, %Date{} = today) do
    agent_rows = agents |> Enum.map(&agent_row(&1, today)) |> Enum.sort_by(& &1.agent)

    model_rows =
      Enum.map(models, fn {source, id, choices} -> model_row(source, id, choices, today) end)

    stale = Warnings.registry(today)

    warnings =
      for(
        row <- agent_rows ++ model_rows,
        warning <- row.warnings,
        do: Map.put(warning, :subject, subject(row))
      ) ++ Enum.map(stale, &(&1 |> warning() |> Map.put(:subject, nil)))

    %{
      today: today,
      registry: %{
        reads: Warnings.registry_reads(),
        stale_after_days: Warnings.stale_after_days(),
        stale: Enum.map(stale, & &1.vendor)
      },
      agents: agent_rows,
      models: model_rows,
      warnings: warnings
    }
  end

  @doc """
  One agent module's row: its declared model, resolved and checked as
  boot resolves and checks it.
  """
  @spec agent_row(module(), Date.t()) :: row()
  def agent_row(module, today) do
    base = %{empty() | agent: module.key(), module: inspect(module), source: :agent}

    case Agent.resolve_declared(module) do
      {:ok, nil} -> base
      resolved -> row(base, module.__model__(), resolved, today)
    end
  end

  @doc """
  An offered or named id's row, resolved with `choices` (the offer's
  for it, or none) and checked as boot checks an offered id.
  """
  @spec model_row(:offer | :cli, String.t(), keyword(), Date.t()) :: row()
  def model_row(source, id, choices, today) do
    row(%{empty() | source: source}, id, Policy.resolve(id, choices), today)
  end

  # Boot's checks, in its order: the model and choices against the sheet,
  # then the credential of the platform they resolve to.
  defp row(base, id, resolved, today) do
    with {:ok, %Policy{model: model, platform: platform} = policy} <- resolved,
         :ok <- Clementine.LLM.Router.check_credential(policy) do
      facts(base, model, platform, today)
    else
      {:error, message} -> failed(base, id, resolved, message, today)
    end
  end

  @doc """
  The facts that differ from `current` to `newest`, both on the platform
  the requests go to: binding, thinking types, the cache read
  multiplier, the minimum cached prefix, the context window, the input
  and output prices, and the price tier.
  """
  @spec differs(Model.t(), Model.t()) :: [%{fact: atom(), from: term(), to: term()}]
  def differs(%Model{} = current, %Model{} = newest) do
    [
      binding: & &1.thinking.binding,
      thinking: &Enum.sort(&1.thinking.types),
      cache_read: &cache_read(&1.prices),
      min_prefix: & &1.cache.min_prefix,
      context: & &1.context,
      price: &price(&1.prices),
      tier: &tier(&1.prices)
    ]
    |> Enum.map(fn {fact, read} -> %{fact: fact, from: read.(current), to: read.(newest)} end)
    |> Enum.reject(&(&1.from == &1.to))
  end

  defp empty do
    %{
      agent: nil,
      module: nil,
      source: nil,
      model: nil,
      vendor: nil,
      line: nil,
      platform: nil,
      lifecycle: nil,
      newest: nil,
      differs: [],
      warnings: [],
      error: nil
    }
  end

  defp facts(row, %Model{} = model, platform, today) do
    newest = newest(model, platform)

    %{
      row
      | model: model.id,
        vendor: model.vendor,
        line: model.line,
        platform: platform,
        lifecycle: model.lifecycle,
        newest: newest && newest.id,
        differs: if(newest, do: differs(model, newest), else: []),
        warnings: model |> Warnings.for_model(today) |> Enum.map(&warning/1)
    }
  end

  # A model boot would refuse: the reason, and what is known of the
  # model if it has a sheet (a retired one, one whose choices the sheet
  # refuses, one whose platform has no credential). A retired model is
  # not compared with its line: its replacement is in its lifecycle.
  defp failed(row, id, resolved, message, today) do
    row =
      case {resolved, is_binary(id) && Models.fetch(id)} do
        {{:ok, %Policy{model: model, platform: platform}}, _sheet} ->
          facts(row, model, platform, today)

        {_refused, {:ok, %Model{lifecycle: %{status: :retired}} = model}} ->
          %{facts(row, model, Models.default_platform(model), today) | newest: nil, differs: []}

        {_refused, {:ok, model}} ->
          facts(row, model, Models.default_platform(model), today)

        _unknown ->
          %{row | model: id}
      end

    %{row | error: message}
  end

  # The newest active model in the model's line that its platform
  # serves, with that platform's facts; nil when the model is the
  # newest there, or has no line. A model on no platform Clementine can
  # send to (a row boot refuses) is compared across the line.
  defp newest(%Model{line: nil}, _platform), do: nil

  defp newest(%Model{line: line, id: id}, platform) do
    opts = if platform, do: [platform: platform], else: []

    case Models.newest(line, opts) do
      nil ->
        nil

      %Model{id: ^id} ->
        nil

      newest when is_nil(platform) ->
        newest

      newest ->
        {:ok, on_platform} = Models.for_platform(newest, platform)
        on_platform
    end
  end

  defp cache_read(%{input: input, cache_read: read}) when input > 0,
    do: Float.round(read / input, 4)

  defp cache_read(_prices), do: nil

  defp price(nil), do: nil
  defp price(prices), do: %{input: prices.input / @micro, output: prices.output / @micro}

  defp tier(%{over: %{prompt_tokens: tokens}}), do: tokens
  defp tier(_prices), do: nil

  defp warning(%Warnings{} = warning) do
    Map.take(warning, [:kind, :model, :vendor, :date, :replacement, :message])
  end

  defp subject(%{source: :agent, agent: key}), do: "agent #{inspect(key)}"
  defp subject(%{source: :offer}), do: "offered"
  defp subject(%{source: :cli}), do: "--model"
end
