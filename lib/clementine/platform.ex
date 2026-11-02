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
  This is the convention Anthropic's SDKs follow, with one exception:
  Anthropic's Bedrock page sets an SDK's base URL to `.../anthropic`,
  which Clementine appends itself. A `base_url:` that ends in a path
  Clementine appends is refused rather than sent to a doubled path: on
  Messages `/v1/messages`, `/messages`, or `/v1`; on Responses
  `/responses`; on Chat Completions `/chat/completions` (a `.../v1` base
  is right there, as in the `tinker` entry above); and on Bedrock the
  Messages and Chat Completions ones, `/anthropic`, or `/openai/v1`.
  Foundry takes `resource:` or `base_url:`
  (`https://myapp-prod.services.ai.azure.com/anthropic`), and Bedrock
  `region:` or `base_url:`. Vertex takes `project:` and `region:`, or
  `base_url:`.

  Bedrock's Chat Completions wire is `/v1/chat/completions` on the
  Mantle host. An open model Bedrock serves under `/openai/v1` instead
  takes an app-named platform:

      bedrock_openai: [
        protocol: :chat_completions,
        base_url: "https://bedrock-mantle.us-east-1.api.aws/openai/v1",
        api_key: {MyApp.Bedrock, :token, []}
      ]

  ## Credentials

  A credential is a literal string, `{:system, "ENV_VAR"}`, or
  `{module, function, args}`, called on every request and returning the
  string itself. Short-lived credentials take the last form, with a
  function that caches the token and mints a new one before it expires:
  an Amazon Bedrock short-term API key lasts 12 hours at most (AWS's
  `aws-bedrock-token-generator`), a Microsoft Entra ID token about an
  hour, a Google OAuth token an hour. Boot checks that the function
  exists. No error prints a credential, whatever its shape (one in the
  wrong shape, such as `System.fetch_env/1`'s `{:ok, key}`, is named by
  its shape), and `inspect/2` on a platform shows only an environment
  variable's name and an `{m, f, a}`'s module and function.

  Bedrock and Foundry are reached with bearer credentials only. AWS SigV4
  signing and Bedrock's InvokeModel API (with its ARN-versioned ids) are
  not built, so Bedrock serves the models its Messages endpoint serves:
  Claude Opus 4.7 and later, and Haiku 4.5.

  Boot checks that the platform each agent's model goes to is configured
  with its credential (present, not resolved: `{:system, ...}` passes
  before the variable is set), except under a test's mock client.

  ## What a platform withholds

  A model's facts on a platform are its sheet with that platform's
  entry merged in, and then what the platform never takes on any model
  (`withheld/1`) set off, whatever the sheet or an app's declaration
  says (`Clementine.Models.for_platform/2`). The clients read only
  those: Foundry takes no mid-conversation system messages, so a skill's
  load folds into the system prompt and `tools` there, and Bedrock and
  Vertex take no tool defined inside one (`inline_tools`), so a skill's
  tools join `tools` there.

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

  @credential {:custom, __MODULE__, :validate_credential, []}
  @string {:custom, __MODULE__, :validate_string, []}
  @credential_keys [:api_key, :access_token]
  # The same keys as a string-keyed map or list (decoded JSON) holds them.
  @secret_keys @credential_keys ++ Enum.map(@credential_keys, &Atom.to_string/1)

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
  The features the platform `name` never takes, on any model, whatever a
  model's sheet or an app's declaration says. `Clementine.Models.for_platform/2`
  applies them over the model's facts there.

  - `:foundry` takes no mid-conversation system messages (Anthropic's
    platform table), and so no tool defined inside one.
  - `:bedrock` and `:vertex` take mid-conversation system messages but
    no tool defined inside one: Anthropic's mid-conversation system
    messages page documents `inline-tools-2026-09-15` on the Claude API
    only. A skill's tools join `tools` there.

  An app-named platform withholds nothing: its models' declarations
  say what the server takes.
  """
  @spec withheld(name()) :: %{atom() => false}
  def withheld(:foundry), do: %{mid_conversation_system: false, inline_tools: false}
  def withheld(name) when name in [:bedrock, :vertex], do: %{inline_tools: false}
  def withheld(_name), do: %{}

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
  # It runs on every request, so an app config key `:platforms` replaced
  # fails there too: a test's `Application.put_env(:clementine,
  # :anthropic_base_url, ...)` after boot is refused, not ignored on the
  # way to the real endpoint.
  @spec fetch(name()) :: {:ok, t()} | {:error, String.t()}
  def fetch(name) when is_atom(name) do
    with :ok <- replaced(),
         entry = Keyword.get(config!(), name, []),
         {:ok, schema} <- schema(name),
         {:ok, opts} <- validate(name, entry, schema),
         platform = struct(__MODULE__, [name: name] ++ opts),
         :ok <- endpoint(platform),
         :ok <- base_url_path(platform),
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

  @doc false
  # The part before the wire's path, on a platform with a default
  # endpoint (`:anthropic`, `:openai`, `:openrouter`) or a `base_url:`:
  # `mix clementine.models --check` puts the Models API under it.
  @spec base_url(t()) :: String.t()
  def base_url(%__MODULE__{} = platform), do: base(platform)

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
          {:ok, value} -> [header(platform, protocol, key, value)]
          {:none, _why} -> []
          {:error, why} -> raise ArgumentError, unresolved(platform, key, why)
        end

      {:required, key} ->
        case resolve(Map.fetch!(platform, key)) do
          {:ok, value} -> [header(platform, protocol, key, value)]
          {_none_or_error, why} -> raise ArgumentError, unresolved(platform, key, why)
        end

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
  name speaks a wire Clementine has, every `{m, f, a}` credential names a
  function that exists, and none of the app config keys it replaced is
  still set. Raises `ArgumentError`. `Clementine.Application` calls it at
  boot.
  """
  @spec validate_config!() :: :ok
  def validate_config! do
    with {:error, message} <- replaced(), do: raise(ArgumentError, message)

    for {name, _entry} <- config!() do
      with {:ok, platform} <- fetch(name),
           :ok <- callable(platform) do
        :ok
      else
        {:error, message} -> raise ArgumentError, "Invalid :clementine, :platforms: #{message}"
      end
    end

    :ok
  end

  # The first app config key `:platforms` replaced that is still set,
  # named with its new place. Boot checks it, and so does every request
  # (`fetch/1`), so one set after boot is refused rather than ignored.
  defp replaced do
    case Enum.find(@replaced, fn {old, _new} -> Application.get_env(:clementine, old) != nil end) do
      nil ->
        :ok

      {old, {name, key}} ->
        {:error,
         "config :clementine, #{old}: is replaced by config :clementine, :platforms, " <>
           "#{name}: [#{key}: ...]" <>
           replaced_hint(key) <>
           ". Clementine refuses it at boot and on every request, so one put after boot " <>
           "(Application.put_env(:clementine, #{inspect(old)}, ...) in a test) fails here " <>
           "rather than being ignored"}
    end
  end

  defp replaced_hint(:base_url),
    do:
      "; base_url: is now the part before the wire's path (https://api.anthropic.com, " <>
        "https://api.openai.com/v1, the Bedrock Mantle host), see Clementine.Platform"

  defp replaced_hint(_key), do: ""

  # An {m, f, a} credential names a function that exists. Only boot
  # checks it; a request would raise calling it.
  defp callable(%__MODULE__{} = platform) do
    Enum.find_value(@credential_keys, :ok, fn key ->
      case Map.fetch!(platform, key) do
        {module, function, args} ->
          unless Code.ensure_loaded?(module) and
                   function_exported?(module, function, length(args)) do
            {:error,
             "#{platform.name}: [#{key}: {#{inspect(module)}, #{inspect(function)}, ...}] names " <>
               "#{inspect(module)}.#{function}/#{length(args)}, which does not exist"}
          end

        _other ->
          nil
      end
    end)
  end

  @doc false
  @spec validate_string(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_string(value) when is_binary(value) and value != "", do: {:ok, value}
  def validate_string(other), do: {:error, "expected a non-empty string, got: #{inspect(other)}"}

  @doc false
  # A credential's shape, never its value: a message that quoted one in
  # the wrong shape ({:ok, key} from System.fetch_env/1, a vault helper's
  # tuple, a list) would print the key into a boot crash log.
  @spec validate_credential(term()) :: {:ok, credential()} | {:error, String.t()}
  def validate_credential(key) when is_binary(key), do: {:ok, key}
  def validate_credential({:system, env} = key) when is_binary(env), do: {:ok, key}

  def validate_credential({module, function, args} = key)
      when is_atom(module) and is_atom(function) and is_list(args),
      do: {:ok, key}

  def validate_credential(other) do
    {:error,
     ~s(expected a string, {:system, "ENV_VAR"}, or {module, function, args}, got ) <>
       shape(other) <> unwrap_hint(other)}
  end

  defp unwrap_hint({:ok, _value}),
    do:
      ~s( \(unwrap it, or give {:system, "ENV_VAR"} or {module, function, args}, read on ) <>
        "every request)"

  defp unwrap_hint(_other), do: ""

  @doc false
  # What kind of term `value` is, in words, without any of its contents.
  @spec shape(term()) :: String.t()
  def shape(nil), do: "nil"
  def shape(value) when is_binary(value), do: "a string"
  def shape(value) when is_boolean(value), do: "a boolean"
  def shape(value) when is_atom(value), do: "an atom"
  def shape(value) when is_integer(value), do: "an integer"
  def shape(value) when is_float(value), do: "a float"
  def shape({:ok, _value}), do: "an {:ok, value} tuple"
  def shape({:error, _reason}), do: "an {:error, reason} tuple"
  def shape(value) when is_tuple(value), do: "a #{tuple_size(value)}-element tuple"
  def shape(value) when is_list(value), do: "a list"
  def shape(%{__struct__: module}) when is_atom(module), do: "a #{inspect(module)} struct"
  def shape(value) when is_map(value), do: "a map"
  def shape(value) when is_function(value), do: "a function"
  def shape(_value), do: "a term of another kind"

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
      "(anthropic: [api_key: ...]), got #{shape(config)}"
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
    # NimbleOptions raises on a list that is not a keyword list, quoting
    # it, and the list may hold the credential (`[{"api_key", key}]`
    # from decoded JSON, `[key]`).
    if Keyword.keyword?(entry) do
      case NimbleOptions.validate(entry, schema) do
        {:ok, opts} ->
          {:ok, opts}

        {:error, %NimbleOptions.ValidationError{} = error} ->
          {:error, "#{name}: " <> scrub(Exception.message(error), entry)}
      end
    else
      {:error, "#{name}: #{not_keyword()}"}
    end
  end

  # An entry in the wrong shape may be the credential itself
  # (`anthropic: System.fetch_env("ANTHROPIC_API_KEY")`), so only its
  # shape is named.
  defp validate(name, other, _schema) do
    {:error, "#{name}: expected a keyword list (api_key: ...), got #{shape(other)}"}
  end

  @doc false
  # What is wrong with a list that is not a keyword list, without its
  # contents.
  @spec not_keyword() :: String.t()
  def not_keyword do
    "expected a keyword list (api_key: ...), got a list that is not one: each entry is an " <>
      "{atom, value} pair, and a string key such as {\"api_key\", ...} (decoded JSON's) is not"
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

  # A base_url stops before the path Clementine appends, as Anthropic's
  # and OpenAI's SDKs take it; one that carries it would send to a
  # doubled path (`/anthropic/anthropic/v1/messages`).
  defp base_url_path(%__MODULE__{base_url: nil}), do: :ok

  defp base_url_path(%__MODULE__{base_url: base_url} = platform) do
    {tails, convention} = base_url_convention(platform)
    trimmed = String.trim_trailing(base_url, "/")

    case tails
         |> Enum.filter(&String.ends_with?(trimmed, &1))
         |> Enum.sort_by(&(-byte_size(&1))) do
      [] ->
        :ok

      [tail | _shorter] ->
        {:error,
         "#{platform.name}: base_url: ends in #{tail}, which Clementine appends itself: " <>
           convention}
    end
  end

  @messages_tails ["/v1/messages", "/messages", "/v1"]
  @chat_tails ["/chat/completions"]
  @bedrock_tails ["/anthropic", "/anthropic/v1", "/anthropic/v1/messages", "/openai/v1"] ++
                   @messages_tails ++ ["/v1/chat/completions" | @chat_tails]

  defp base_url_convention(%__MODULE__{name: :bedrock}) do
    {@bedrock_tails,
     "give the Mantle host both of Bedrock's wires share " <>
       "(https://bedrock-mantle.us-east-1.api.aws), not the SDKs' .../anthropic. An open " <>
       "model Bedrock serves under /openai/v1 takes an app-named platform " <>
       "(protocol: :chat_completions, base_url: \"https://bedrock-mantle.<region>.api.aws/openai/v1\")"}
  end

  defp base_url_convention(%__MODULE__{name: :foundry}),
    do:
      {@messages_tails,
       "give the part before /v1/messages (https://myapp-prod.services.ai.azure.com/anthropic)"}

  defp base_url_convention(%__MODULE__{name: :openai}),
    do: {["/responses"], "give the part before /responses (https://api.openai.com/v1)"}

  defp base_url_convention(%__MODULE__{name: name, protocol: protocol})
       when name == :anthropic or protocol == :messages,
       do: {@messages_tails, "give the part before /v1/messages (https://api.anthropic.com)"}

  defp base_url_convention(%__MODULE__{}),
    do: {@chat_tails, "give the part before /chat/completions (https://openrouter.ai/api/v1)"}

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

  defp unresolved(platform, key, why),
    do: "config :clementine, :platforms, #{platform.name}: [#{key}: ...] #{why}"

  # A credential's value now, `{:none, why}` when it has none, or
  # `{:error, why}` when an {m, f, a} returned something other than a
  # string. Never a value in `why`.
  defp resolve(nil), do: {:none, "is not set"}

  defp resolve({:system, var}) do
    case System.get_env(var) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _unset -> {:none, "resolved to no value: the environment variable #{var} is unset or empty"}
    end
  end

  defp resolve({module, function, args}) do
    call = "#{inspect(module)}.#{function}/#{length(args)}"

    case apply(module, function, args) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      value when value in [nil, ""] ->
        {:none, "resolved to no value: #{call} returned #{inspect(value)}"}

      {:ok, _value} ->
        {:error, "#{call} returned an {:ok, value} tuple, not a string: return the token itself"}

      other ->
        {:error, "#{call} returned #{shape(other)}, not a string"}
    end
  end

  defp resolve(value) when is_binary(value) and value != "", do: {:ok, value}
  defp resolve(_empty), do: {:none, "resolved to no value"}

  defp base(%__MODULE__{base_url: nil, name: name}), do: Map.fetch!(@defaults, name)
  defp base(%__MODULE__{base_url: base_url}), do: String.trim_trailing(base_url, "/")

  defp bedrock_host(%__MODULE__{base_url: nil, region: region}),
    do: "https://bedrock-mantle.#{region}.api.aws"

  defp bedrock_host(%__MODULE__{base_url: base_url}), do: String.trim_trailing(base_url, "/")

  @doc false
  # `term` with every value under `api_key:` or `access_token:` redacted,
  # whatever its shape, for an error message.
  @spec redact(term()) :: term()
  def redact({key, value}) when key in @secret_keys, do: {key, redact_credential(value)}
  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(%{__struct__: _} = struct), do: struct
  def redact(map) when is_map(map), do: Map.new(map, &redact/1)
  def redact({key, value}), do: {key, redact(value)}
  def redact(other), do: other

  @doc false
  # A credential as it may be shown: an environment variable's name, an
  # {m, f, a}'s module and function with its arguments redacted, and
  # nothing of any other shape.
  @spec redact_credential(term()) :: term()
  def redact_credential(nil), do: nil
  def redact_credential({:system, var} = credential) when is_binary(var), do: credential

  def redact_credential({module, function, args})
      when is_atom(module) and is_atom(function) and is_list(args),
      do: {module, function, Enum.map(args, fn _arg -> "**redacted**" end)}

  def redact_credential(_value), do: "**redacted**"

  @doc false
  # `message` with every string held under `api_key:` or `access_token:`
  # anywhere in `term` replaced, for a message a library composed (a
  # NimbleOptions error may quote the value it refused).
  @spec scrub(String.t(), term()) :: String.t()
  def scrub(message, term) do
    term
    |> secrets()
    |> Enum.uniq()
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.reduce(message, &String.replace(&2, &1, "**redacted**"))
  end

  defp secrets({key, value}) when key in @secret_keys, do: secret_strings(value)
  defp secrets(list) when is_list(list), do: Enum.flat_map(list, &secrets/1)
  defp secrets(%{__struct__: _}), do: []
  defp secrets(map) when is_map(map), do: Enum.flat_map(map, &secrets/1)
  defp secrets(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> secrets()
  defp secrets(_other), do: []

  defp secret_strings({:system, var}) when is_binary(var), do: []

  defp secret_strings({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: secret_strings(args)

  # A string too short to be a key or token (a tag beside one in a
  # tuple) is left alone: replacing it would mangle the message.
  defp secret_strings(value) when is_binary(value) and byte_size(value) < 8, do: []
  defp secret_strings(value) when is_binary(value), do: [value]
  defp secret_strings(list) when is_list(list), do: Enum.flat_map(list, &secret_strings/1)

  defp secret_strings(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> secret_strings()

  defp secret_strings(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> secret_strings()

  defp secret_strings(map) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> secret_strings(key) ++ secret_strings(value) end)

  defp secret_strings(_other), do: []
end

defimpl Inspect, for: Clementine.Platform do
  def inspect(%Clementine.Platform{} = platform, opts) do
    redacted =
      for key <- [:api_key, :access_token], reduce: platform do
        acc -> Map.update!(acc, key, &Clementine.Platform.redact_credential/1)
      end

    Inspect.Any.inspect(redacted, opts)
  end
end
