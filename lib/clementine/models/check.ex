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
  # vendor retired shows as a lifecycle change rather than vanishing. A
  # retired id the sheets never shipped (claude-1.x, claude-instant-1.x)
  # is counted as not shipped, not flagged.
  #
  # OpenAI's `GET /v1/models` (read 2026-11-01,
  # https://developers.openai.com/api/reference/resources/models/methods/list)
  # gives `id`, `created`, `owned_by`, and `shutdown_date`: no lifecycle,
  # capabilities, or ceilings, so only shutdown dates and unknown ids
  # are compared. It lists every model the key can use (embeddings,
  # audio, images, moderation, the organization's fine-tunes), so an id
  # the sheets lack is a finding only when OpenAI (or `system`) owns it
  # and created it after the sheets were last read; the older ones are
  # counted as not shipped. `created` can precede a model's launch, so a
  # model OpenAI created before that read and launched after it is
  # counted, not flagged: a gap docs/MODELS.md names. Neither API has
  # prices, so prices are never checked.
  #
  # Nothing here prints the key. It is trimmed and refused when it holds
  # anything but printable ASCII, a transport error is reported by its
  # reason's name only (Mint's `{:invalid_header_value, name, value}`
  # message quotes the header), and the key is scrubbed from every reason.

  alias Clementine.{Model, Models, Platform}

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

    case credential(vendor) do
      {:ok, key, raw} ->
        case fetch(vendor, key) do
          {:ok, listed} ->
            Map.merge(%{result | listed: length(listed)}, compare(vendor, listed))

          {:error, reason} ->
            %{result | status: :failed, reason: scrub(reason, [raw, key])}
        end

      {:skip, reason} ->
        %{result | status: :skipped, reason: reason}

      {:error, reason} ->
        %{result | status: :failed, reason: reason}
    end
  end

  @doc """
  Where `listed` (a vendor's Models API entries, decoded) differs from
  the sheets: findings, and the ids the sheets lack that are not findings
  (OpenAI's older and non-vendor ones).
  """
  @spec compare(:anthropic | :openai, [map()]) :: %{findings: [finding()], unshipped: [map()]}
  def compare(:anthropic, listed) do
    partition(listed, &anthropic/1)
  end

  def compare(:openai, listed) do
    # When Clementine last read OpenAI's pages; a date an app's own
    # declaration carries never moves it.
    read = Models.shipped_read(:openai)
    partition(listed, &openai(&1, read))
  end

  defp partition(listed, compare) do
    {findings, unshipped} =
      Enum.reduce(listed, {[], []}, fn entry, {findings, unshipped} ->
        case compare.(entry) do
          {:unshipped, note} -> {findings, [note | unshipped]}
          more -> {Enum.reverse(more, findings), unshipped}
        end
      end)

    %{findings: Enum.reverse(findings), unshipped: Enum.reverse(unshipped)}
  end

  ## Anthropic

  defp anthropic(%{"id" => id} = entry) when is_binary(id) do
    case Models.fetch(id) do
      {:ok, model} ->
        model = on_platform(model, :anthropic)

        lifecycle(model, entry) ++
          if model.lifecycle.status == :retired, do: [], else: anthropic_facts(model, entry)

      {:error, _unknown} ->
        note = %{
          id: id,
          lifecycle: entry["lifecycle"],
          line: entry["line"],
          released: date(entry["created_at"])
        }

        # One the vendor retired before the sheets would have shipped it.
        if entry["lifecycle"] == "retired",
          do: {:unshipped, note},
          else: [finding(id, :unknown, nil, Map.delete(note, :id))]
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

  # Only the types the API states a support for, true or false, are
  # compared. (A generator, not a match filter: a filter would drop a
  # stated false, and miss a type the API no longer takes.)
  defp thinking(model, capabilities) do
    stated =
      for {name, type} <- @thinking,
          supported <- [supported(capabilities, ["thinking", "types", name])],
          is_boolean(supported),
          do: {type, supported}

    sheet = for {type, _} <- stated, type in model.thinking.types, do: type
    api = for {type, true} <- stated, do: type
    {:thinking, sheet, api, stated != []}
  end

  defp efforts(model, capabilities) do
    stated =
      for {name, level} <- @efforts,
          supported <- [supported(capabilities, ["effort", name])],
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

  # Each vendor's own platform (`config :clementine, :platforms`), as
  # the Messages and Responses clients read it: its credential, and the
  # Models API under its base_url (`<base>/v1/models` on Anthropic's,
  # `<base>/models` on OpenAI's, whose base ends in `/v1`). The key comes
  # back trimmed, with the value as configured for scrubbing.
  defp credential(vendor) do
    setting = "config :clementine, :platforms, #{vendor}: [api_key: ...]"

    case Platform.fetch(vendor) do
      {:ok, %Platform{api_key: nil}} -> {:skip, "#{setting} is not set"}
      {:ok, %Platform{api_key: credential}} -> key(credential, setting)
      {:error, message} -> {:error, message}
    end
  end

  defp key(credential, setting) do
    case resolve(credential) do
      {:raised, what} ->
        {:error, "#{setting} #{what}"}

      raw when is_binary(raw) ->
        case printable(raw) do
          {:ok, key} -> {:ok, key, raw}
          :empty -> {:skip, "#{setting} is empty"}
          :unprintable -> {:error, "#{setting}: the key has non-printable characters"}
        end

      _nothing ->
        {:skip, "#{setting} resolved to no value"}
    end
  end

  defp resolve({:system, var}) when is_binary(var), do: System.get_env(var)

  defp resolve({module, function, args} = mfa)
       when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
  rescue
    # Its message is the app's, and could quote the credential.
    exception -> {:raised, "#{inspect(mfa)} raised #{inspect(exception.__struct__)}"}
  end

  defp resolve(value), do: value

  # Trimmed, as a secret file's trailing newline is no part of the key;
  # anything else outside printable ASCII is refused, since an HTTP
  # header cannot carry it and the transport's error would quote it.
  defp printable(raw) do
    case Regex.replace(~r/\A\s+|\s+\z/, raw, "") do
      "" -> :empty
      key -> if Regex.match?(~r/\A[\x21-\x7E]+\z/, key), do: {:ok, key}, else: :unprintable
    end
  end

  @doc false
  # The Models API URL on a vendor's configured platform.
  @spec url(:anthropic | :openai) :: String.t()
  def url(:anthropic), do: Platform.base_url(Platform.fetch!(:anthropic)) <> "/v1/models"
  def url(:openai), do: Platform.base_url(Platform.fetch!(:openai)) <> "/models"

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
        {:error, "#{url}: #{transport_reason(exception)}"}
    end
  end

  # The vendor's own error message; never the request, which holds the key.
  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: ": #{message}"

  defp error_message(_body), do: ""

  @transport_errors [Req.TransportError, Req.HTTPError, Mint.TransportError, Mint.HTTPError]

  # Never a transport exception's message: Mint's for an invalid header
  # quotes the header's value, which can be the key.
  defp transport_reason(%{__struct__: struct, reason: reason}) when struct in @transport_errors,
    do: reason_name(reason)

  defp transport_reason(%{__struct__: struct}), do: inspect(struct)

  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_name(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  defp reason_name(_reason), do: "transport error"

  defp scrub(reason, values) do
    values
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.reduce(reason, &String.replace(&2, &1, "**redacted**"))
  end
end
