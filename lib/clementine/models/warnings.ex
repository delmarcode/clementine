defmodule Clementine.Models.Warnings do
  @moduledoc """
  What is ending: the warnings a model's lifecycle and dates give, at
  boot and in `mix clementine.models`. They are never errors.

  Boot is clock-independent. Every error at boot comes from the shipped
  sheets and the app's config (a sheet whose status is `:retired` in
  this Clementine release is one), never from today's date, so a node
  that restarts after a vendor's shutdown date still boots, its non-AI
  parts included; the vendor's own error ends the run that reaches the
  model. Each warning here compares a date with today, or reports a
  status that is not yet an end:

  - `:deprecated`: the sheet's status is `:deprecated`.
  - `:not_before_passed`: the model's `retires_not_before` date, the
    vendor's "not sooner than", is before today, so the vendor may now
    retire it with notice.
  - `:retirement_reached`: the model's `retires_on` date, a retirement
    or shutdown date the vendor has set, is today or before, so requests
    may now fail with the vendor's error.
  - `:stale_registry`: the newest `read` date of one vendor's sheets
    that Clementine ships is more than 120 days before today, so their
    facts may have moved on.

  They are logged, never raised:

  - when Clementine starts: the stale registry, and every model the app
    offers (`config :clementine, :offer`, `Clementine.Models.offer/0`);
  - when `{Clementine, ...}` starts: every agent in its `agents:` that
    declares a model;
  - on an agent module's first `Clementine.run/3` or `Clementine.stream/3`
    in the node, unless the runtime already logged it: that agent's
    model. An app that runs agents only in process (an eval, a script)
    gets each agent's warnings once, on the run that first reaches it.
    A test that asserts such a warning calls `reset/0` in its `setup`,
    since an earlier test may have run that agent.

  Nothing here reads the network: the vendors' Models APIs are read only
  by `mix clementine.models --check`.
  """

  require Logger

  alias Clementine.{Model, Models}

  @stale_after_days 120

  @enforce_keys [:kind, :message]
  defstruct [:kind, :model, :vendor, :date, :replacement, :message]

  @type kind :: :deprecated | :not_before_passed | :retirement_reached | :stale_registry

  @typedoc """
  One warning: its kind, the model it is about (`nil` for the registry),
  that model's vendor (or the vendor whose sheets are stale), the date it
  turns on, the vendor's replacement where it names one, and a message
  that names the model and the date.
  """
  @type t :: %__MODULE__{
          kind: kind(),
          model: String.t() | nil,
          vendor: atom() | nil,
          date: Date.t() | nil,
          replacement: String.t() | nil,
          message: String.t()
        }

  @doc "How many days old the shipped sheets may be before they warn."
  @spec stale_after_days() :: pos_integer()
  def stale_after_days, do: @stale_after_days

  @doc """
  The warnings `model`'s lifecycle and dates give on `today`, in the
  order the moduledoc lists them. A retired model gives none: boot
  refuses it.
  """
  @spec for_model(Model.t(), Date.t()) :: [t()]
  def for_model(%Model{lifecycle: %{status: :retired}}, %Date{}), do: []

  def for_model(%Model{lifecycle: lifecycle} = model, %Date{} = today) do
    [
      deprecated(model, lifecycle),
      not_before_passed(model, lifecycle, today),
      retirement_reached(model, lifecycle, today)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The newest `read` date of each vendor's sheets that Clementine ships:
  when this release last read that vendor's pages.
  """
  @spec registry_reads() :: %{atom() => Date.t()}
  def registry_reads, do: Map.new(Models.shipped_vendors(), &{&1, Models.shipped_read(&1)})

  @doc """
  The stale-registry warnings on `today`: one for each vendor whose
  shipped sheets were last read more than 120 days ago.
  """
  @spec registry(Date.t()) :: [t()]
  def registry(%Date{} = today) do
    for {vendor, read} <- Enum.sort(registry_reads()),
        Date.diff(today, read) > @stale_after_days do
      %__MODULE__{
        kind: :stale_registry,
        vendor: vendor,
        date: read,
        message:
          "Clementine's #{vendor(vendor)} model sheets were last read on #{read}, more than " <>
            "#{@stale_after_days} days ago: their lifecycles, ceilings, and prices may have " <>
            "changed since. Upgrade Clementine, or run mix clementine.models --check to compare " <>
            "them with the vendors' Models APIs"
      }
    end
  end

  @doc """
  The warnings for agent modules on `today`, each labeled `agent "key"`:
  their declared models' (`__model__/0`). An agent that picks its model
  in `agent/1` gives none, nor does an id that names no model, since
  boot refuses it.
  """
  @spec for_agents([module()], Date.t()) :: [{String.t(), t()}]
  def for_agents(agents, %Date{} = today) do
    for module <- agents,
        id = declared_model(module),
        warning <- for_id(id, today),
        do: {"agent #{inspect(module.key())}", warning}
  end

  @doc """
  The warnings for offered ids on `today`, each labeled `offered`.
  """
  @spec for_offer([String.t()], Date.t()) :: [{String.t(), t()}]
  def for_offer(ids, %Date{} = today) do
    for id <- ids, warning <- for_id(id, today), do: {"offered", warning}
  end

  @doc false
  # Clementine.Application's start: the registry's age and the offer.
  # Never raises: an offer that cannot be read warns here, and boot's
  # check of it (`{Clementine, ...}`) or the task says why.
  @spec log_start() :: :ok
  def log_start do
    today = Date.utc_today()

    offer =
      try do
        Models.offer() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> for_offer(today)
      rescue
        exception ->
          Logger.warning(
            "Clementine could not read its offer's dates: #{Exception.message(exception)}"
          )

          []
      catch
        kind, _reason ->
          did = if kind == :throw, do: "threw", else: "exited"
          Logger.warning("Clementine could not read its offer's dates: its function #{did}")
          []
      end

    log(offer ++ Enum.map(registry(today), &{nil, &1}))
  end

  @doc false
  # `{Clementine, ...}`'s start: its agents. A module logged here logs
  # nothing more on its runs.
  @spec log_agents([module()]) :: :ok
  def log_agents(agents) do
    Enum.each(agents, &:persistent_term.put({__MODULE__, :logged, &1}, true))
    agents |> for_agents(Date.utc_today()) |> log()
  end

  @doc false
  # `Clementine.run/3` and `stream/3` with an agent module: its warnings,
  # the first time the node runs it. (Two first runs at once may both
  # log; nothing depends on once.)
  @spec log_first_run(module()) :: :ok
  def log_first_run(module) when is_atom(module) do
    key = {__MODULE__, :logged, module}

    if :persistent_term.get(key, false) do
      :ok
    else
      :persistent_term.put(key, true)
      [module] |> for_agents(Date.utc_today()) |> log()
    end
  end

  @doc """
  Forgets which agent modules have logged their warnings, so each logs
  again on its next run. The flag is per node, so a test that asserts
  an agent's warning in the log passes or fails by whether an earlier
  test ran that agent; call this in its `setup` first.
  """
  @spec reset() :: :ok
  def reset do
    for {{__MODULE__, :logged, _module} = key, _value} <- :persistent_term.get(),
        do: :persistent_term.erase(key)

    :ok
  end

  defp log(warnings) do
    Enum.each(warnings, fn
      {nil, warning} ->
        Logger.warning(warning.message)

      {label, warning} ->
        Logger.warning("#{label}: #{warning.message}. See mix clementine.models")
    end)
  end

  defp for_id(id, today) do
    case Models.fetch(id) do
      {:ok, model} -> for_model(model, today)
      {:error, _unknown} -> []
    end
  end

  defp declared_model(module) do
    if function_exported?(module, :__model__, 0), do: module.__model__()
  end

  defp deprecated(model, %{status: :deprecated} = lifecycle) do
    ending =
      case lifecycle.retires_on do
        nil -> "has set no #{ending_word(model)} date"
        date -> "#{retires_it(model)} on #{date}"
      end

    %__MODULE__{
      kind: :deprecated,
      model: model.id,
      vendor: model.vendor,
      date: lifecycle.deprecated_on,
      replacement: lifecycle.replacement,
      message: "#{model.id} is deprecated: #{vendor(model)} #{ending}#{replacement(lifecycle)}"
    }
  end

  defp deprecated(_model, _lifecycle), do: nil

  defp not_before_passed(model, %{retires_not_before: %Date{} = date} = lifecycle, today) do
    if Date.compare(date, today) == :lt do
      %__MODULE__{
        kind: :not_before_passed,
        model: model.id,
        vendor: model.vendor,
        date: date,
        replacement: lifecycle.replacement,
        message:
          "#{model.id}'s not-sooner-than date, #{date}, has passed: #{vendor(model)} may " <>
            "now #{retire_it(model)}, with notice#{replacement(lifecycle)}"
      }
    end
  end

  defp not_before_passed(_model, _lifecycle, _today), do: nil

  defp retirement_reached(model, %{retires_on: %Date{} = date} = lifecycle, today) do
    if Date.compare(date, today) != :gt do
      %__MODULE__{
        kind: :retirement_reached,
        model: model.id,
        vendor: model.vendor,
        date: date,
        replacement: lifecycle.replacement,
        message:
          "#{model.id}'s #{ending_word(model)} date, #{date}, has been reached: " <>
            "#{vendor(model)}'s own error ends the runs that reach it, and the next " <>
            "Clementine release marks it retired#{replacement(lifecycle)}"
      }
    end
  end

  defp retirement_reached(_model, _lifecycle, _today), do: nil

  defp replacement(%{replacement: nil}), do: ""
  defp replacement(%{replacement: id}), do: "; its replacement is #{id}"

  defp vendor(%Model{vendor: vendor}), do: vendor(vendor)
  defp vendor(:anthropic), do: "Anthropic"
  defp vendor(:openai), do: "OpenAI"
  defp vendor(_vendor), do: "its vendor"

  # OpenAI shuts a model down; Anthropic retires one.
  defp ending_word(%Model{vendor: :openai}), do: "shutdown"
  defp ending_word(%Model{}), do: "retirement"

  defp retires_it(%Model{vendor: :openai}), do: "shuts it down"
  defp retires_it(%Model{}), do: "retires it"

  defp retire_it(%Model{vendor: :openai}), do: "shut it down"
  defp retire_it(%Model{}), do: "retire it"
end
