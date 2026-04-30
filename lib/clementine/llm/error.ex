defmodule Clementine.LLM.Error do
  @moduledoc false

  def normalize_exception(:error, exception) do
    {:llm_exception,
     %{
       kind: :error,
       exception: exception,
       message: Exception.message(exception)
     }}
  end

  def normalize_exception(kind, reason) do
    {:llm_exception, %{kind: kind, reason: reason}}
  end
end
