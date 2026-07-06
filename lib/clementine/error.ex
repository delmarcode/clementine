defmodule Clementine.Error do
  @moduledoc """
  The one normalized error shape for the whole system.

  Produced at the provider boundary and at the runner's rescue site; carried
  in `Clementine.Result.Failed` and in error events. Retryability is decided
  here, at normalization time, so callers never re-derive it from raw
  provider payloads. `message` is safe for operators; hosts decide
  user-facing copy. `raw` preserves the original payload for logs and is
  never for display.
  """

  defstruct kind: :runtime,
            code: :unknown,
            provider: nil,
            message: "",
            retryable?: false,
            raw: nil

  @type kind :: :provider | :tool | :rollout | :runtime
  @type t :: %__MODULE__{
          kind: kind(),
          code: atom(),
          provider: :anthropic | :openai | nil,
          message: String.t(),
          retryable?: boolean(),
          raw: term()
        }

  @max_body_message 200

  @doc """
  Normalizes any error reason the engine can produce.

  Accepts the provider-boundary shapes (`{:api_error, status, body}`,
  `{:request_failed, reason}`, `{:llm_exception, info}`), engine atoms
  (`:max_iterations_reached`), and passes an existing `%Clementine.Error{}`
  through unchanged. Anything unrecognized becomes a non-retryable
  `:unknown` — never a crash.
  """
  @spec normalize(term(), :anthropic | :openai | nil) :: t()
  def normalize(reason, provider \\ nil)

  def normalize(%__MODULE__{} = error, _provider), do: error

  def normalize({:api_error, status, body}, provider) when is_integer(status) do
    {code, retryable?} = classify_status(status)

    %__MODULE__{
      kind: :provider,
      code: code,
      provider: provider,
      message: api_message(body, status),
      retryable?: retryable?,
      raw: {:api_error, status, body}
    }
  end

  def normalize({:request_failed, reason}, provider) do
    %__MODULE__{
      kind: :provider,
      code: :network,
      provider: provider,
      message: "Request failed: #{inspect(reason)}",
      retryable?: true,
      raw: {:request_failed, reason}
    }
  end

  def normalize({:llm_exception, info}, provider) do
    %__MODULE__{
      kind: :provider,
      code: :exception,
      provider: provider,
      message: llm_exception_message(info),
      retryable?: false,
      raw: {:llm_exception, info}
    }
  end

  def normalize(:max_iterations_reached, _provider) do
    %__MODULE__{
      kind: :rollout,
      code: :max_iterations,
      message: "Max iterations reached before a final answer.",
      retryable?: false,
      raw: :max_iterations_reached
    }
  end

  def normalize(:deadline_exceeded, _provider) do
    %__MODULE__{
      kind: :rollout,
      code: :deadline_exceeded,
      message: "Execution deadline exceeded before a final answer.",
      retryable?: false,
      raw: :deadline_exceeded
    }
  end

  def normalize(other, provider) do
    %__MODULE__{
      kind: :runtime,
      code: :unknown,
      provider: provider,
      message: inspect(other),
      retryable?: false,
      raw: other
    }
  end

  @doc "Normalizes a rescued exception or a caught exit/throw."
  @spec from_exception(:error | :exit | :throw, term(), Exception.stacktrace()) :: t()
  def from_exception(:error, exception, stacktrace) when is_exception(exception) do
    %__MODULE__{
      kind: :runtime,
      code: :exception,
      message: Exception.message(exception),
      retryable?: false,
      raw: {:error, exception, stacktrace}
    }
  end

  def from_exception(kind, reason, stacktrace) do
    %__MODULE__{
      kind: :runtime,
      code: :exception,
      message: "#{kind}: #{inspect(reason)}",
      retryable?: false,
      raw: {kind, reason, stacktrace}
    }
  end

  @doc "A rollout returned a value outside its closed contract."
  @spec invalid_return(term()) :: t()
  def invalid_return(value) do
    %__MODULE__{
      kind: :runtime,
      code: :invalid_rollout_return,
      message: "Rollout returned a value outside its contract: #{inspect(value)}",
      retryable?: false,
      raw: value
    }
  end

  defp classify_status(401), do: {:auth, false}
  defp classify_status(403), do: {:auth, false}
  defp classify_status(404), do: {:not_found, false}
  defp classify_status(408), do: {:timeout, true}
  defp classify_status(429), do: {:rate_limited, true}
  defp classify_status(529), do: {:overloaded, true}
  defp classify_status(status) when status in 400..499, do: {:invalid_request, false}
  defp classify_status(status) when status in 500..599, do: {:provider_unavailable, true}
  defp classify_status(_status), do: {:unknown, false}

  defp api_message(%{"error" => %{"message" => message}}, _status) when is_binary(message) do
    message
  end

  defp api_message(body, status) when is_binary(body) do
    "HTTP #{status}: #{String.slice(body, 0, @max_body_message)}"
  end

  defp api_message(_body, status), do: "HTTP #{status}"

  defp llm_exception_message(%{message: message}) when is_binary(message), do: message
  defp llm_exception_message(info), do: inspect(info)
end
