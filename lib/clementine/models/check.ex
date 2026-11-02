defmodule Clementine.Models.Check do
  @moduledoc false
  # mix clementine.models --check: reads Anthropic's and OpenAI's Models
  # APIs with the app's configured credentials and reports where the
  # sheets differ from what the vendor says now. Only the task calls it;
  # boot never reads the network.
  #
  # Anthropic's `GET /v1/models` (read 2026-11-01,
  # https://platform.claude.com/docs/en/api/models/list) lists every
  # Claude model with `lifecycle`, `deprecated_at`, `retires_at`, `line`,
  # `max_input_tokens`, `max_tokens`, and `capabilities` (thinking types,
  # effort levels, structured outputs). It lists active and deprecated
  # models unless `lifecycle` asks for retired ones too, which this does
  # (as `lifecycle[]=`, the official SDKs' array format), so a model the
  # vendor retired shows as a lifecycle change rather than vanishing.
  #
  # OpenAI's `GET /v1/models` (read 2026-11-01,
  # https://developers.openai.com/api/reference/resources/models/methods/list)
  # gives `id`, `created`, `owned_by`, and `shutdown_date`: no lifecycle,
  # capabilities, or ceilings, so only shutdown dates and unknown ids
  # are compared. It lists every model the key can use (embeddings,
  # audio, images, moderation, the organization's fine-tunes), so an id
  # the sheets lack is a finding only when OpenAI (or `system`) owns it
  # and created it after the sheets were last read; the older ones are
  # counted as not shipped. Neither API has prices, so prices are never
  # checked.

  alias Clementine.{Model, Models}

  @vendors [:anthropic, :openai]
  @lifecycles ["active", "deprecated", "retired"]
  @thinking [
    {"adaptive", :adaptive},
    {"enabled", :enabled},
    {"between_tools", :between_tools},
    {"disabled", :off}
  ]
  @efforts [{"low", :low}, {"medium", :medium}, {"high", :high}, {"xhigh", :xhigh}, {"max", :max}]
  @vendor_owners ["openai", "system"]
  @max_pages 50

  @type finding :: %{id: String.t(), kind: atom(), sheet: term(), api: term()}

  @type result :: %{
          vendor: :anthropic | :openai,
          status: :checked | :skipped | :failed,
          reason: String.t() | nil,
          listed: non_neg_integer(),
          findings: [finding()],
          unshipped: [map()]
        }

  @doc "Checks each vendor whose credential is configured."
  @spec run() :: [result()]
  def run, do: Enum.map(@vendors, &check/1)

  @doc "Checks one vendor: skipped without a credential, failed on an HTTP error."
  @spec check(:anthropic | :openai) :: result()
  def check(vendor) do
    result = %{
      vendor: vendor,
      status: :checked,
      reason: nil,
      listed: 0,
      findings: [],
      unshipped: []
    }

    with {:ok, key} <- credential(vendor),
         {:ok, listed} <- fetch(vendor, key) do
      Map.merge(%{result | listed: length(listed)}, compare(vendor, listed))
    else
      {:skip, reason} -> %{result | status: :skipped, reason: reason}
      {:error, reason} -> %{result | status: :failed, reason: reason}
    end
  end

  @doc """
  Where `listed` (a vendor's Models API entries, decoded) differs from
  the sheets: findings, and the ids the sheets lack that are not findings
  (OpenAI's older and non-vendor ones).
  """
  @spec compare(:anthropic | :openai, [map()]) :: %{findings: [finding()], unshipped: [map()]}
  def compare(:anthropic, listed) do
    %{findings: Enum.flat_map(listed, &anthropic/1), unshipped: []}
  end

  def compare(:openai, listed) do
    read = read(:openai)

    {findings, unshipped} =
      Enum.reduce(listed, {[], []}, fn entry, {findings, unshipped} ->
        case openai(entry, read) do
          {:unshipped, note} -> {findings, [note | unshipped]}
          more -> {findings ++ more, unshipped}
        end
      end)

    %{findings: findings, unshipped: Enum.reverse(unshipped)}
  end

  ## Anthropic

  defp anthropic(%{"id" => id} = entry) when is_binary(id) do
    case Models.fetch(id) do
      {:ok, model} ->
        model = on_platform(model, :anthropic)

        lifecycle(model, entry) ++
          if model.lifecycle.status == :retired, do: [], else: anthropic_facts(model, entry)

      {:error, _unknown} ->
        [
          finding(id, :unknown, nil, %{
            lifecycle: entry["lifecycle"],
            line: entry["line"],
            released: date(entry["created_at"])
          })
        ]
    end
  end

  defp anthropic(_entry), do: []

  defp lifecycle(model, entry) do
    lifecycle = model.lifecycle

    [
      {:lifecycle, Atom.to_string(lifecycle.status), entry["lifecycle"]},
      {:deprecated_at, lifecycle.deprecated_on, date(entry["deprecated_at"])},
      {:retires_at, lifecycle.retires_on, date(entry["retires_at"])}
    ]
    |> Enum.filter(fn {kind, _sheet, _api} -> Map.has_key?(entry, api_key(kind)) end)
    |> differing(model.id)
  end

  defp anthropic_facts(model, entry) do
    capabilities = if is_map(entry["capabilities"]), do: entry["capabilities"], else: %{}

    [
      {:line, model.line && Atom.to_string(model.line), entry["line"],
       Map.has_key?(entry, "line")},
      {:context, model.context, entry["max_input_tokens"], true},
      {:max_output, model.max_output, entry["max_tokens"], true},
      thinking(model, capabilities),
      efforts(model, capabilities),
      {:structured_outputs, model.features.structured_outputs,
       supported(capabilities, ["structured_outputs"]), true}
    ]
    |> Enum.filter(fn {_kind, sheet, api, stated?} ->
      stated? and not is_nil(sheet) and not is_nil(api)
    end)
    |> Enum.map(fn {kind, sheet, api, _stated?} -> {kind, sheet, api} end)
    |> differing(model.id)
  end

  # Only the types the API states a support for are compared.
  defp thinking(model, capabilities) do
    stated =
      for {name, type} <- @thinking,
          supported = supported(capabilities, ["thinking", "types", name]),
          is_boolean(supported),
          do: {type, supported}

    sheet = for {type, _} <- stated, type in model.thinking.types, do: type
    api = for {type, true} <- stated, do: type
    {:thinking, sheet, api, stated != []}
  end

  defp efforts(model, capabilities) do
    stated =
      for {name, level} <- @efforts,
          supported = supported(capabilities, ["effort", name]),
          is_boolean(supported),
          do: {level, supported}

    sheet = for {level, _} <- stated, level in model.thinking.efforts, do: level
    api = for {level, true} <- stated, do: level
    {:effort, sheet, api, stated != []}
  end

  defp supported(capabilities, path) do
    case get_in(capabilities, path) do
      %{"supported" => supported} when is_boolean(supported) -> supported
      _unstated -> nil
    end
  end

  defp api_key(:lifecycle), do: "lifecycle"
  defp api_key(:deprecated_at), do: "deprecated_at"
  defp api_key(:retires_at), do: "retires_at"
  defp api_key(:shutdown_date), do: "shutdown_date"

  ## OpenAI

  defp openai(%{"id" => id} = entry, read) when is_binary(id) do
    case Models.fetch(id) do
      {:ok, model} ->
        [{:shutdown_date, model.lifecycle.retires_on, date(entry["shutdown_date"])}]
        |> Enum.filter(fn {kind, _sheet, _api} -> Map.has_key?(entry, api_key(kind)) end)
        |> differing(model.id)

      {:error, _unknown} ->
        created = created(entry["created"])

        note = %{id: id, owned_by: entry["owned_by"], created: created}

        if (entry["owned_by"] in @vendor_owners and created) && Date.compare(created, read) == :gt,
          do: [finding(id, :unknown, nil, note)],
          else: {:unshipped, note}
    end
  end

  defp openai(_entry, _read), do: []

  ## Shared

  defp differing(pairs, id) do
    for {kind, sheet, api} <- pairs, sheet != api, do: finding(id, kind, sheet, api)
  end

  defp finding(id, kind, sheet, api), do: %{id: id, kind: kind, sheet: sheet, api: api}

  defp on_platform(%Model{} = model, platform) do
    case Models.for_platform(model, platform) do
      {:ok, on_platform} -> on_platform
      {:error, _not_served} -> model
    end
  end

  # When the sheets of a vendor were last read: the newest `read` among
  # its models, the app's declarations included.
  defp read(vendor) do
    [vendor: vendor]
    |> Models.list()
    |> Enum.map(& &1.read)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(Date, fn -> Models.shipped_read() end)
  end

  defp date(nil), do: nil

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_date(datetime)

      {:error, _not_datetime} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          {:error, _} -> value
        end
    end
  end

  defp date(other), do: other

  defp created(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> DateTime.to_date(datetime)
      {:error, _} -> nil
    end
  end

  defp created(_other), do: nil

  ## HTTP

  # The credentials and endpoints the Messages and Responses clients
  # use; the Models API is beside each endpoint (`.../v1/models`).
  defp credential(vendor) do
    config_key = credential_key(vendor)

    case resolve(Application.get_env(:clementine, config_key)) do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _unset ->
        {:skip, "config :clementine, #{config_key}: is not set, or names an unset variable"}
    end
  end

  defp credential_key(:anthropic), do: :anthropic_api_key
  defp credential_key(:openai), do: :openai_api_key

  defp resolve({:system, var}) when is_binary(var), do: System.get_env(var)
  defp resolve({module, function, args}), do: apply(module, function, args)
  defp resolve(value), do: value

  @doc false
  # The Models API URL beside a vendor's configured endpoint.
  @spec url(:anthropic | :openai) :: String.t()
  def url(:anthropic) do
    :clementine
    |> Application.get_env(:anthropic_base_url, "https://api.anthropic.com/v1/messages")
    |> beside("models")
  end

  def url(:openai) do
    :clementine
    |> Application.get_env(:openai_base_url, "https://api.openai.com/v1/responses")
    |> beside("models")
  end

  defp beside(endpoint, name) do
    uri = URI.parse(endpoint)
    %{uri | path: Path.join(Path.dirname(uri.path || "/"), name), query: nil} |> URI.to_string()
  end

  defp fetch(:anthropic, key) do
    headers = [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}]
    anthropic_pages(url(:anthropic), headers, nil, [], @max_pages)
  end

  defp fetch(:openai, key) do
    case get(url(:openai), [{"authorization", "Bearer " <> key}], []) do
      {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
      {:ok, _other} -> {:error, "#{url(:openai)} answered without a data list"}
      error -> error
    end
  end

  defp anthropic_pages(url, _headers, _after_id, _acc, 0),
    do: {:error, "#{url} kept paging past #{@max_pages} pages"}

  defp anthropic_pages(url, headers, after_id, acc, pages) do
    params =
      [{"limit", 1000}] ++
        Enum.map(@lifecycles, &{"lifecycle[]", &1}) ++
        if(after_id, do: [{"after_id", after_id}], else: [])

    case get(url, headers, params) do
      {:ok, %{"data" => data} = body} when is_list(data) ->
        case body do
          %{"has_more" => true, "last_id" => last} when is_binary(last) ->
            anthropic_pages(url, headers, last, acc ++ data, pages - 1)

          _last_page ->
            {:ok, acc ++ data}
        end

      {:ok, _other} ->
        {:error, "#{url} answered without a data list"}

      error ->
        error
    end
  end

  defp get(url, headers, params) do
    case Req.get(url, headers: headers, params: params, retry: false, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "#{url} answered #{status}#{error_message(body)}"}

      {:error, exception} ->
        {:error, "#{url}: #{Exception.message(exception)}"}
    end
  end

  # The vendor's own error message; never the request, which holds the key.
  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: ": #{message}"

  defp error_message(_body), do: ""
end
