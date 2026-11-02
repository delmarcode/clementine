defmodule Clementine.Error do
  @moduledoc """
  The one normalized error shape for the whole system.

  Produced at the provider boundary and at the runner's rescue site; carried
  in `Clementine.Result.Failed` and in error events. Retryability is decided
  here, at normalization time, so callers never re-derive it from raw
  provider payloads. `message` is safe for operators; hosts decide
  user-facing copy. `raw` preserves the original payload for logs and is
  never for display.

  A provider's error takes its code from the provider
  (`normalize/2`). The engine's own, all `kind: :rollout`, are a closed
  set: `:refused` and `:truncated` (`stopped/2`), `:empty` (`empty/1`),
  `:max_iterations`, `:deadline_exceeded`, `:invalid_output`,
  `:invalid_output_schema`, `:invalid_skills`, `:invalid_delegates`,
  `:incompatible_checkpoint`, and `:invalid_resume_payload`. A tool's or
  a host's error keeps whatever code it set.
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

  # The stop reasons a final answer may not end on, as the provider
  # clients normalize them. A refusal: Anthropic's "refusal" (its safety
  # classifiers stopped the answer), OpenAI's refusal content, and
  # OpenAI's content filter. A cut-off answer: max_tokens (OpenAI's
  # max_output_tokens), Anthropic's context window, and an OpenAI
  # response that ended incomplete for another reason.
  @refused ~w(refusal content_filter)
  @truncated ~w(max_tokens model_context_window_exceeded incomplete)

  # The error types Anthropic's stream sends in an `error` event, after
  # the 200 that started it: the statuses' codes, by type.
  @stream_error_types %{
    "overloaded_error" => {:overloaded, true},
    "rate_limit_error" => {:rate_limited, true},
    "api_error" => {:provider_unavailable, true},
    "timeout_error" => {:timeout, true},
    "invalid_request_error" => {:invalid_request, false},
    "request_too_large" => {:invalid_request, false},
    "authentication_error" => {:auth, false},
    "permission_error" => {:auth, false},
    "not_found_error" => {:not_found, false}
  }

  @doc """
  The error a final turn's stop reason makes of its run, or `nil` for a
  turn that ended as the model meant it to (`"end_turn"`,
  `"stop_sequence"`, or a stream that named no reason).

  A run whose final turn the provider refused fails `:refused`:
  Anthropic's `"refusal"`, OpenAI's refusal content (`"refusal"` too),
  and an OpenAI content filter's `"content_filter"`. A run whose final
  answer was cut off fails `:truncated`: `"max_tokens"` (OpenAI's
  `max_output_tokens` too), `"model_context_window_exceeded"`, and
  `"incomplete"`. Both are `kind: :rollout` and not retryable: the same
  request to the same model mostly gets the same answer.

  `raw` is `%{"stop_reason" => reason}`, and `"stop_details"` when the
  provider said more (`details`, `Clementine.LLM.Response`'s): on an
  Anthropic refusal, its `"category"` (`"cyber"`, `"bio"`,
  `"reasoning_extraction"`, ...) and `"explanation"`, never content. The
  message names the category.
  """
  @spec stopped(String.t() | nil, map() | nil) :: t() | nil
  def stopped(reason, details \\ nil)
  def stopped(reason, details) when reason in @refused, do: stopped(:refused, reason, details)
  def stopped(reason, details) when reason in @truncated, do: stopped(:truncated, reason, details)
  def stopped(_reason, _details), do: nil

  defp stopped(code, reason, details) do
    raw = %{"stop_reason" => reason}

    %__MODULE__{
      kind: :rollout,
      code: code,
      message: stop_message(reason, details),
      retryable?: false,
      raw: if(is_map(details), do: Map.put(raw, "stop_details", details), else: raw)
    }
  end

  defp stop_message(reason, details) do
    said = Enum.join(["stop_reason: #{reason}" | said(details)], ", ")
    "#{stop_text(reason)} (#{said})."
  end

  defp said(%{} = details) do
    for key <- ["category", "finish_reason"],
        is_binary(details[key]),
        do: "#{key}: #{details[key]}"
  end

  defp said(_details), do: []

  defp stop_text("refusal"), do: "The model refused to answer"
  defp stop_text("content_filter"), do: "The provider's content filter stopped the answer"
  defp stop_text("max_tokens"), do: "The model's answer was cut off at max_tokens"

  defp stop_text("model_context_window_exceeded"),
    do: "The model's answer was cut off at its context window"

  defp stop_text("incomplete"), do: "The provider ended the answer incomplete"

  @doc """
  The error of a run that ended without an answer: its final turn wrote
  no text, and no turn of the run called a tool. `kind: :rollout`, code
  `:empty`, not retryable. A run that called tools and then ended empty
  is done (an agent whose answer is its tool calls) and completes with
  `stop_reason: "empty"` instead (`Clementine.Result.Completed`). `raw`
  is `%{"stop_reason" => reason}`, the provider's (`"end_turn"`, most
  often).
  """
  @spec empty(String.t() | nil) :: t()
  def empty(reason) do
    %__MODULE__{
      kind: :rollout,
      code: :empty,
      message:
        "The model ended the run without an answer: it wrote no text and called no tool " <>
          "(stop_reason: #{reason || "none"}).",
      retryable?: false,
      raw: %{"stop_reason" => reason}
    }
  end

  @doc """
  Normalizes any error reason the engine can produce.

  Accepts the provider-boundary shapes (`{:api_error, status, body}`,
  `{:request_failed, reason}`, `{:llm_exception, info}`), the error event
  Anthropic's stream sends mid-turn (`%{"type" => "overloaded_error",
  "message" => ...}`), engine atoms (`:max_iterations_reached`), and
  passes an existing `%Clementine.Error{}` through unchanged. Anything
  unrecognized becomes a non-retryable `:unknown` — never a crash.
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

  def normalize(%{"type" => type} = event, provider) when is_map_key(@stream_error_types, type) do
    {code, retryable?} = Map.fetch!(@stream_error_types, type)

    %__MODULE__{
      kind: :provider,
      code: code,
      provider: provider,
      message: stream_error_message(event),
      retryable?: retryable?,
      raw: event
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

  defp stream_error_message(%{"type" => type, "message" => message}) when is_binary(message),
    do: "#{type} mid-stream: #{message}"

  defp stream_error_message(%{"type" => type}), do: "#{type} mid-stream"

  defp llm_exception_message(%{message: message}) when is_binary(message), do: message
  defp llm_exception_message(info), do: inspect(info)
end
