defmodule Clementine.Platform do
  @moduledoc """
  Where a model is served: the endpoint a request goes to, the credential
  it carries, and how the model's id goes on the wire there.

  A model's sheet (`Clementine.Model`) lists the platforms that serve it,
  each with the id it goes by there and how its facts differ there. An
  agent picks one with `platform:`, or takes the model's default: the
  vendor's own (`:anthropic` for Claude, `:openai` for GPT), else the
  first one the model lists that Clementine can send to. The app
  configures each platform it sends to:

      config :clementine, :platforms,
        anthropic: [api_key: {:system, "ANTHROPIC_API_KEY"}],
        openai: [api_key: {:system, "OPENAI_API_KEY"}],
        bedrock: [region: "us-east-1", api_key: {MyApp.Bedrock, :token, []}],
        foundry: [
          resource: "myapp-prod",
          api_key: {:system, "ANTHROPIC_FOUNDRY_API_KEY"},
          deployments: %{"claude-sonnet-5-5" => "sonnet-chat"}
        ],
        tinker: [
          protocol: :chat_completions,
          base_url: "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1",
          api_key: {:system, "TINKER_API_KEY"}
        ]

  Moving an agent to another platform is its `platform:` and that
  platform's entry here; nothing else changes.

  ## The platforms

  | Platform | Wire | Endpoint | Credential | Model id |
  |---|---|---|---|---|
  | `:anthropic` | Messages | `https://api.anthropic.com/v1/messages` | `api_key:`, sent as `x-api-key` | the vendor id |
  | `:openai` | Responses | `https://api.openai.com/v1/responses` | `api_key:`, as a bearer | the vendor id |
  | `:bedrock` | Messages for Claude, Chat Completions for the open models it serves | `https://bedrock-mantle.{region}.api.aws/anthropic/v1/messages`; `.../v1/chat/completions` | `api_key:`, an Amazon Bedrock API key: `x-api-key` on Messages, a bearer on Chat Completions | `anthropic.<id>` for Claude; Bedrock's own for the rest |
  | `:foundry` | Messages, Claude only | `https://{resource}.services.ai.azure.com/anthropic/v1/messages` | `api_key:`, sent as `api-key`, or `access_token:`, a Microsoft Entra ID token sent as a bearer | the deployment name: `deployments:` maps a model id to one, and it defaults to the model id |
  | `:openrouter` | Chat Completions | `https://openrouter.ai/api/v1/chat/completions` | `api_key:`, as a bearer | OpenRouter's `vendor/model` slug |
  | `:vertex` | Chat Completions, for the open models Vertex serves | `https://{region}-aiplatform.googleapis.com/v1/projects/{project}/locations/{region}/endpoints/openapi/chat/completions` | `access_token:`, an OAuth token, as a bearer | `publisher/model` |
  | `:openai_compatible` | Chat Completions | `base_url:` | an optional `api_key:`, as a bearer | the server's |
  | an app's own name | `protocol:`, `:chat_completions` or `:messages` | `base_url:` | an optional `api_key:` | the server's |

  Where a platform speaks two wires, the model's vendor picks one: Claude
  goes to Bedrock's Messages endpoint, an open model to its Chat
  Completions one, on the same host with the same key. Claude on Vertex
  and Claude Platform on AWS (`:claude_on_aws`) are facts on the sheets
  that no request can reach yet.

  Every key but the credential is optional where it has a default.
  `base_url:` replaces the default endpoint (a proxy, a test server):
  on Messages it is the part before `/v1/messages`
  (`https://api.anthropic.com`), on Responses and Chat Completions the
  part before `/responses` or `/chat/completions`, and on Bedrock the
  Mantle host both wires share (`https://bedrock-mantle.us-east-1.api.aws`).
  Foundry takes `resource:` or `base_url:`
  (`https://myapp-prod.services.ai.azure.com/anthropic`), and Bedrock
  `region:` or `base_url:`. Vertex takes `project:` and `region:`, or
  `base_url:`.

  ## Credentials

  A credential is a literal string, `{:system, "ENV_VAR"}`, or
  `{module, function, args}`, called on every request. Short-lived
  credentials take the last form, with a function that caches the token
  and mints a new one before it expires: an Amazon Bedrock short-term API
  key lasts 12 hours at most (AWS's `aws-bedrock-token-generator`), a
  Microsoft Entra ID token about an hour, a Google OAuth token an hour.
  `inspect/2` on a platform redacts a literal credential, and no error
  prints one.

  Bedrock and Foundry are reached with bearer credentials only. AWS SigV4
  signing and Bedrock's InvokeModel API (with its ARN-versioned ids) are
  not built, so Bedrock serves the models its Messages endpoint serves:
  Claude Opus 4.7 and later, and Haiku 4.5.

  Boot checks that the platform each agent's model goes to is configured
  with its credential (present, not resolved: `{:system, ...}` passes
  before the variable is set), except under a test's mock client.

  ## What a platform withholds

  A model's facts on a platform are its sheet with that platform's
  entry merged in (`Clementine.Models.for_platform/2`), and the clients
  read only those: Foundry takes no mid-conversation system messages, so
  a skill's load folds into the system prompt there.

  ## Prices

  A call costs its model's prices wherever it runs. Foundry bills at the
  Claude API's rates. Bedrock prices Claude itself, and its regional
  endpoints cost 10% more than its global ones; an app that runs a model
  there overrides the model's `prices:` (`docs/MODELS.md`).
  """

  alias Clementine.Model

  @type name :: atom()
  @type protocol :: :messages | :responses | :chat_completions
  @type credential :: String.t() | {:system, String.t()} | {module(), atom(), list()}

  @type t :: %__MODULE__{
          name: name(),
          protocol: protocol() | nil,
          base_url: String.t() | nil,
          region: String.t() | nil,
          resource: String.t() | nil,
          project: String.t() | nil,
          api_key: credential() | nil,
          access_token: credential() | nil,
          deployments: %{String.t() => String.t()}
        }

  defstruct [
    :name,
    :protocol,
    :base_url,
    :region,
    :resource,
    :project,
    :api_key,
    :access_token,
    deployments: %{}
  ]

  @credential {:custom, Model, :validate_credential, []}
  @string {:custom, __MODULE__, :validate_string, []}

  @schemas %{
    anthropic: [api_key: [type: @credential], base_url: [type: @string]],
    openai: [api_key: [type: @credential], base_url: [type: @string]],
    openrouter: [api_key: [type: @credential], base_url: [type: @string]],
    bedrock: [api_key: [type: @credential], region: [type: @string], base_url: [type: @string]],
    foundry: [
      api_key: [type: @credential],
      access_token: [type: @credential],
      resource: [type: @string],
      base_url: [type: @string],
      deployments: [type: {:map, :string, :string}, default: %{}]
    ],
    vertex: [
      access_token: [type: @credential],
      project: [type: @string],
      region: [type: @string],
      base_url: [type: @string]
    ],
    openai_compatible: [api_key: [type: @credential], base_url: [type: @string]]
  }

  @app_schema [
    protocol: [type: {:in, [:chat_completions, :messages]}, required: true],
    base_url: [type: @string, required: true],
    api_key: [type: @credential]
  ]

  @defaults %{
    anthropic: "https://api.anthropic.com",
    openai: "https://api.openai.com/v1",
    openrouter: "https://openrouter.ai/api/v1"
  }

  # The app config keys `config :clementine, :platforms` replaced, and
  # where each went.
  @replaced [
    anthropic_api_key: {:anthropic, :api_key},
    anthropic_base_url: {:anthropic, :base_url},
    openai_api_key: {:openai, :api_key},
    openai_base_url: {:openai, :base_url},
    openrouter_api_key: {:openrouter, :api_key},
    openrouter_base_url: {:openrouter, :base_url},
    bedrock_api_key: {:bedrock, :api_key},
    bedrock_region: {:bedrock, :region},
    bedrock_base_url: {:bedrock, :base_url},
    vertex_access_token: {:vertex, :access_token},
    vertex_project: {:vertex, :project},
    vertex_region: {:vertex, :region},
    vertex_base_url: {:vertex, :base_url},
    openai_compatible_api_key: {:openai_compatible, :api_key},
    openai_compatible_base_url: {:openai_compatible, :base_url}
  ]

  @doc """
  The wire a request for a model of `vendor` takes on the platform
  `name`, or why no request can go there.
  """
  @spec protocol(name(), atom()) :: {:ok, protocol()} | {:error, String.t()}
  def protocol(:anthropic, _vendor), do: {:ok, :messages}
  def protocol(:openai, _vendor), do: {:ok, :responses}
  def protocol(:openrouter, _vendor), do: {:ok, :chat_completions}
  def protocol(:openai_compatible, _vendor), do: {:ok, :chat_completions}
  def protocol(:bedrock, :anthropic), do: {:ok, :messages}
  def protocol(:bedrock, _vendor), do: {:ok, :chat_completions}
  def protocol(:foundry, :anthropic), do: {:ok, :messages}

  def protocol(:foundry, vendor),
    do: {:error, "Clementine sends only Claude to :foundry, not a #{inspect(vendor)} model"}

  def protocol(:vertex, :anthropic),
    do: {:error, "Clementine does not send Claude to :vertex yet (OPS-199)"}

  def protocol(:vertex, _vendor), do: {:ok, :chat_completions}

  def protocol(:claude_on_aws, _vendor),
    do: {:error, "Clementine does not send to :claude_on_aws yet (OPS-199)"}

  def protocol(name, _vendor) when is_atom(name) do
    case app_entry(name) do
      {:ok, entry} when is_list(entry) ->
        case Keyword.get(entry, :protocol) do
          protocol when protocol in [:chat_completions, :messages] ->
            {:ok, protocol}

          _other ->
            {:error,
             "config :clementine, :platforms, #{name}: names no protocol: (:chat_completions " <>
               "or :messages)"}
        end

      _none ->
        {:error,
         "#{inspect(name)} is no platform Clementine ships, and config :clementine, " <>
           ":platforms names none by that name"}
    end
  end

  @doc """
  Whether `name` is a platform the app names itself under
  `config :clementine, :platforms`, as read now.
  """
  @spec app_named?(term()) :: boolean()
  def app_named?(name) when is_atom(name) and not is_nil(name) do
    name not in Model.platforms() and match?({:ok, _entry}, app_entry(name))
  end

  def app_named?(_name), do: false

  @doc """
  The platform `name`, built from its config entry, or what is wrong with
  that entry. A shipped platform with no entry builds with its defaults
  and no credential.
  """
  @spec fetch(name()) :: {:ok, t()} | {:error, String.t()}
  def fetch(name) when is_atom(name) do
    entry = Keyword.get(config!(), name, [])

    with {:ok, schema} <- schema(name),
         {:ok, opts} <- validate(name, entry, schema),
         platform = struct(__MODULE__, [name: name] ++ opts),
         :ok <- endpoint(platform),
         :ok <- one_credential(platform) do
      {:ok, platform}
    end
  end

  @doc "As `fetch/1`, raising `ArgumentError`."
  @spec fetch!(name()) :: t()
  def fetch!(name) do
    case fetch(name) do
      {:ok, platform} -> platform
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Whether a request for `model` on the platform `name` could go: the
  platform's entry builds, and holds the credential its wire needs
  (present, not resolved). Boot checks it for every agent.
  """
  @spec check(name(), Model.t()) :: :ok | {:error, String.t()}
  def check(name, %Model{} = model) do
    with {:ok, protocol} <- protocol(name, model.vendor),
         {:ok, platform} <- fetch(name) do
      unset =
        "#{inspect(model.id)} goes to #{inspect(name)}, and config :clementine, :platforms, " <>
          "#{name}:"

      case credential_key(platform, protocol) do
        {:required, key} ->
          if Map.fetch!(platform, key),
            do: :ok,
            else: {:error, "#{unset} [#{key}: ...] is not set"}

        {:either, keys} ->
          if Enum.any?(keys, &Map.fetch!(platform, &1)),
            do: :ok,
            else: {:error, "#{unset} sets none of #{inspect(keys)}"}

        {:optional, _key} ->
          :ok
      end
    end
  end

  @doc """
  The URL a request on `protocol` goes to on `platform`.
  """
  @spec url(t(), protocol()) :: String.t()
  def url(%__MODULE__{name: :bedrock} = platform, :messages),
    do: bedrock_host(platform) <> "/anthropic/v1/messages"

  def url(%__MODULE__{name: :bedrock} = platform, :chat_completions),
    do: bedrock_host(platform) <> "/v1/chat/completions"

  def url(%__MODULE__{name: :foundry, base_url: nil, resource: resource}, :messages),
    do: "https://#{resource}.services.ai.azure.com/anthropic/v1/messages"

  def url(%__MODULE__{name: :vertex, base_url: nil} = platform, :chat_completions) do
    %{project: project, region: region} = platform

    "https://#{region}-aiplatform.googleapis.com/v1/projects/#{project}/locations/" <>
      "#{region}/endpoints/openapi/chat/completions"
  end

  def url(%__MODULE__{} = platform, :messages), do: base(platform) <> "/v1/messages"
  def url(%__MODULE__{} = platform, :responses), do: base(platform) <> "/responses"
  def url(%__MODULE__{} = platform, :chat_completions), do: base(platform) <> "/chat/completions"

  @doc """
  The headers that carry `platform`'s credential on `protocol`, the
  credential resolved now. Raises naming the config key (never the
  value) when a required credential resolves to nothing.
  """
  @spec auth_headers(t(), protocol()) :: [{String.t(), String.t()}]
  def auth_headers(%__MODULE__{} = platform, protocol) do
    case credential_key(platform, protocol) do
      {:optional, key} ->
        case resolve(Map.fetch!(platform, key)) do
          nil -> []
          value -> [header(platform, protocol, key, value)]
        end

      {:required, key} ->
        [header(platform, protocol, key, resolve!(platform, key))]

      {:either, keys} ->
        raise ArgumentError,
              "config :clementine, :platforms, #{platform.name}: sets none of #{inspect(keys)}"
    end
  end

  @doc """
  The id `model` (its sheet on the platform `name`,
  `Clementine.Models.for_platform/2`) goes by in a request there: the
  platform's deployment name for it where the app maps one (Foundry),
  else the sheet's id on that platform (`Clementine.Model.platform_id/1`).
  Reads the mapping without building the platform, so a test's fake
  client needs no platform config.
  """
  @spec model_id(name(), Model.t()) :: String.t()
  def model_id(name, %Model{} = model) do
    deployments =
      case Keyword.get(config!(), name) do
        entry when is_list(entry) -> Keyword.get(entry, :deployments, %{})
        _none -> %{}
      end

    case deployments do
      %{} -> Map.get(deployments, model.id) || Model.platform_id(model, name)
      _malformed -> Model.platform_id(model, name)
    end
  end

  @doc """
  Checks `config :clementine, :platforms`: every entry builds, every app
  name speaks a wire Clementine has, and none of the app config keys it
  replaced is still set. Raises `ArgumentError`. `Clementine.Application`
  calls it at boot.
  """
  @spec validate_config!() :: :ok
  def validate_config! do
    for {old, {name, key}} <- @replaced, Application.get_env(:clementine, old) != nil do
      raise ArgumentError,
            "config :clementine, #{old}: is replaced by config :clementine, :platforms, " <>
              "#{name}: [#{key}: ...]" <> replaced_hint(key)
    end

    for {name, _entry} <- config!() do
      case fetch(name) do
        {:ok, _platform} -> :ok
        {:error, message} -> raise ArgumentError, "Invalid :clementine, :platforms: #{message}"
      end
    end

    :ok
  end

  defp replaced_hint(:base_url),
    do:
      "; base_url: is now the part before the wire's path (https://api.anthropic.com, " <>
        "https://api.openai.com/v1, the Bedrock Mantle host), see Clementine.Platform"

  defp replaced_hint(_key), do: ""

  @doc false
  @spec validate_string(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_string(value) when is_binary(value) and value != "", do: {:ok, value}
  def validate_string(other), do: {:error, "expected a non-empty string, got: #{inspect(other)}"}

  defp config! do
    case Application.get_env(:clementine, :platforms, []) do
      config when is_list(config) ->
        if Keyword.keyword?(config),
          do: config,
          else: raise(ArgumentError, malformed(config))

      config ->
        raise ArgumentError, malformed(config)
    end
  end

  defp malformed(config) do
    "Invalid :clementine, :platforms: expected a keyword list from platform to its config " <>
      "(anthropic: [api_key: ...]), got: #{inspect(redact(config))}"
  end

  defp app_entry(name) do
    case Application.get_env(:clementine, :platforms, []) do
      config when is_list(config) ->
        if Keyword.keyword?(config) and Keyword.has_key?(config, name),
          do: {:ok, Keyword.fetch!(config, name)},
          else: :error

      _other ->
        :error
    end
  end

  defp schema(name) do
    cond do
      Map.has_key?(@schemas, name) ->
        {:ok, @schemas[name]}

      name in Model.platforms() ->
        {:error,
         "#{inspect(name)} takes no configuration yet: " <> elem(protocol(name, :anthropic), 1)}

      true ->
        {:ok, @app_schema}
    end
  end

  defp validate(name, entry, schema) when is_list(entry) do
    case NimbleOptions.validate(entry, schema) do
      {:ok, opts} ->
        {:ok, opts}

      {:error, %NimbleOptions.ValidationError{} = error} ->
        {:error, "#{name}: " <> scrub(Exception.message(error), entry)}
    end
  end

  defp validate(name, other, _schema) do
    {:error, "#{name}: expected a keyword list, got: #{inspect(redact(other))}"}
  end

  # The keys a platform needs to know where to send.
  defp endpoint(%__MODULE__{name: :bedrock, region: nil, base_url: nil}),
    do: {:error, "bedrock: needs region: (\"us-east-1\") or base_url:"}

  defp endpoint(%__MODULE__{name: :foundry, resource: resource, base_url: base_url})
       when is_nil(resource) == is_nil(base_url),
       do: {:error, "foundry: needs one of resource: (your Foundry resource's name) or base_url:"}

  defp endpoint(%__MODULE__{name: :vertex, base_url: nil} = platform)
       when is_nil(platform.project) or is_nil(platform.region),
       do: {:error, "vertex: needs project: and region:, or base_url:"}

  defp endpoint(%__MODULE__{name: :openai_compatible, base_url: nil}),
    do: {:error, "openai_compatible: needs base_url: (the server's, before /chat/completions)"}

  defp endpoint(%__MODULE__{}), do: :ok

  defp one_credential(%__MODULE__{name: :foundry, api_key: key, access_token: token})
       when not is_nil(key) and not is_nil(token),
       do: {:error, "foundry: takes api_key: or access_token: (Entra ID), not both"}

  defp one_credential(%__MODULE__{}), do: :ok

  # Which credential a wire on a platform sends, and whether it must be
  # there.
  defp credential_key(%__MODULE__{name: :foundry} = platform, :messages) do
    cond do
      platform.access_token -> {:required, :access_token}
      platform.api_key -> {:required, :api_key}
      true -> {:either, [:api_key, :access_token]}
    end
  end

  defp credential_key(%__MODULE__{name: :vertex}, _protocol), do: {:required, :access_token}

  defp credential_key(%__MODULE__{name: name}, _protocol)
       when name in [:anthropic, :openai, :openrouter, :bedrock],
       do: {:required, :api_key}

  defp credential_key(%__MODULE__{}, _protocol), do: {:optional, :api_key}

  # Anthropic's and Bedrock's Messages endpoints take the key in
  # x-api-key; Foundry documents api-key, and an Entra ID token as a
  # bearer; every other wire takes a bearer.
  defp header(%__MODULE__{name: :foundry}, :messages, :api_key, value), do: {"api-key", value}
  defp header(%__MODULE__{}, :messages, :api_key, value), do: {"x-api-key", value}
  defp header(%__MODULE__{}, _protocol, _key, value), do: {"authorization", "Bearer " <> value}

  defp resolve!(platform, key) do
    case platform |> Map.fetch!(key) |> resolve() do
      nil ->
        raise ArgumentError,
              "config :clementine, :platforms, #{platform.name}: [#{key}: ...] " <>
                "#{if Map.fetch!(platform, key), do: "resolved to no value", else: "is not set"}"

      value ->
        value
    end
  end

  defp resolve({:system, var}), do: present(System.get_env(var))
  defp resolve({module, function, args}), do: present(apply(module, function, args))
  defp resolve(value), do: present(value)

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp base(%__MODULE__{base_url: nil, name: name}), do: Map.fetch!(@defaults, name)
  defp base(%__MODULE__{base_url: base_url}), do: String.trim_trailing(base_url, "/")

  defp bedrock_host(%__MODULE__{base_url: nil, region: region}),
    do: "https://bedrock-mantle.#{region}.api.aws"

  defp bedrock_host(%__MODULE__{base_url: base_url}), do: String.trim_trailing(base_url, "/")

  @doc false
  # `term` with every literal credential replaced, for an error message.
  @spec redact(term()) :: term()
  def redact({key, value}) when key in [:api_key, :access_token] and is_binary(value),
    do: {key, "**redacted**"}

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(%{__struct__: _} = struct), do: struct
  def redact(map) when is_map(map), do: Map.new(map, &redact/1)
  def redact({key, value}), do: {key, redact(value)}
  def redact(other), do: other

  # A NimbleOptions message may quote the value it refused.
  defp scrub(message, entry) do
    entry
    |> Enum.flat_map(fn
      {key, value} when key in [:api_key, :access_token] and is_binary(value) and value != "" ->
        [value]

      _other ->
        []
    end)
    |> Enum.reduce(message, &String.replace(&2, &1, "**redacted**"))
  end
end

defimpl Inspect, for: Clementine.Platform do
  def inspect(%Clementine.Platform{} = platform, opts) do
    redacted =
      for key <- [:api_key, :access_token], reduce: platform do
        acc ->
          case Map.fetch!(acc, key) do
            value when is_binary(value) -> Map.put(acc, key, "**redacted**")
            _other -> acc
          end
      end

    Inspect.Any.inspect(redacted, opts)
  end
end
