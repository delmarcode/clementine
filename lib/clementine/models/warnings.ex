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
  - `:stale_registry`: the newest `read` date of the sheets Clementine
    ships is more than 120 days before today, so their facts may have
    moved on.

  `{Clementine, ...}` logs them when it starts, for every agent in its
  `agents:` that declares a model and every model the app offers
  (`config :clementine, :offer`, `Clementine.Models.offered/0`). Nothing
  here reads the network: the vendors' Models APIs are read only by
  `mix clementine.models --check`.
  """

  require Logger

  alias Clementine.{Model, Models}

  @stale_after_days 120

  @enforce_keys [:kind, :message]
  defstruct [:kind, :model, :date, :replacement, :message]

  @type kind :: :deprecated | :not_before_passed | :retirement_reached | :stale_registry

  @typedoc """
  One warning: its kind, the model it is about (`nil` for the registry),
  the date it turns on, the vendor's replacement where it names one, and
  a message that names the model and the date.
  """
  @type t :: %__MODULE__{
          kind: kind(),
          model: String.t() | nil,
          date: Date.t() | nil,
          replacement: String.t() | nil,
          message: String.t()
        }

  @doc "How many days old the shipped sheets may be before they warn."
  @spec stale_after_days() :: pos_integer()
  def stale_after_days, do: @stale_after_days

  @doc """
  The warnings `model`'s lifecycle and dates give on `today`, in the
  order the moduledoc lists them.
  """
  @spec for_model(Model.t(), Date.t()) :: [t()]
  def for_model(%Model{lifecycle: lifecycle} = model, %Date{} = today) do
    [
      deprecated(model, lifecycle),
      not_before_passed(model, lifecycle, today),
      retirement_reached(model, lifecycle, today)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The newest `read` date among the sheets Clementine ships: when this
  release last read the vendors' pages.
  """
  @spec registry_read() :: Date.t()
  def registry_read, do: Models.shipped_read()

  @doc """
  The stale-registry warning on `today`, or `nil` while the shipped
  sheets were read within the last 120 days.
  """
  @spec registry(Date.t()) :: t() | nil
  def registry(%Date{} = today) do
    read = registry_read()

    if Date.diff(today, read) > @stale_after_days do
      %__MODULE__{
        kind: :stale_registry,
        date: read,
        message:
          "Clementine's model sheets were last read on #{read}, more than " <>
            "#{@stale_after_days} days ago: their lifecycles, ceilings, and prices may " <>
            "have changed since. Upgrade Clementine, or run mix clementine.models --check " <>
            "to compare them with the vendors' Models APIs"
      }
    end
  end

  @doc """
  The warnings for what an app runs, on `today`: each agent module's
  declared model (`__model__/0`), labeled `agent "key"`; each offered
  id, labeled `offered`; and the registry's age. An id that names no
  model gives none here, since boot's own check refuses it.
  """
  @spec at_boot([module()], [String.t()], Date.t()) :: [{String.t() | nil, t()}]
  def at_boot(agents, offered, %Date{} = today) do
    subjects =
      for(
        module <- agents,
        id = declared_model(module),
        do: {"agent #{inspect(module.key())}", id}
      ) ++
        for id <- offered, do: {"offered", id}

    per_model =
      for {label, id} <- subjects,
          {:ok, model} <- [Models.fetch(id)],
          warning <- for_model(model, today),
          do: {label, warning}

    case registry(today) do
      nil -> per_model
      stale -> per_model ++ [{nil, stale}]
    end
  end

  @doc """
  Logs `at_boot/3` for today, one warning per line. `{Clementine, ...}`
  calls it when it starts.
  """
  @spec log([module()], [String.t()]) :: :ok
  def log(agents, offered) do
    agents
    |> at_boot(offered, Date.utc_today())
    |> Enum.each(fn
      {nil, warning} ->
        Logger.warning(warning.message)

      {label, warning} ->
        Logger.warning("#{label}: #{warning.message}. See mix clementine.models")
    end)
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

  defp vendor(%Model{vendor: :anthropic}), do: "Anthropic"
  defp vendor(%Model{vendor: :openai}), do: "OpenAI"
  defp vendor(%Model{}), do: "its vendor"

  # OpenAI shuts a model down; Anthropic retires one.
  defp ending_word(%Model{vendor: :openai}), do: "shutdown"
  defp ending_word(%Model{}), do: "retirement"

  defp retires_it(%Model{vendor: :openai}), do: "shuts it down"
  defp retires_it(%Model{}), do: "retires it"

  defp retire_it(%Model{vendor: :openai}), do: "shut it down"
  defp retire_it(%Model{}), do: "retire it"
end
