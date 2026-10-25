defmodule ClementineSmoke.Agents.Host do
  @moduledoc """
  The agents' host. A chat turn's messages commit with its end, and a
  conversation's runs stream on its PubSub topic: text as it arrives,
  each change of status, and the end.
  """

  @behaviour Clementine.Host

  alias Clementine.Event
  alias Clementine.Result
  alias ClementineSmoke.Conversations

  @impl true
  def run_event(%{subject_type: "conversation"} = run, %Event{type: :text_delta} = event) do
    broadcast(run, {:chat_text, run.id, event.payload.content})
  end

  def run_event(_run, _event), do: :ok

  @impl true
  def run_transition(%{subject_type: "conversation"} = run, transition) do
    broadcast(run, {:chat_status, run.id, transition})
  end

  def run_transition(_run, _transition), do: :ok

  @impl true
  def run_finished(%{agent_key: "chat"} = run, %Result.Completed{} = result) do
    Conversations.append!(run.subject_id, [result.input_message | result.messages])
  end

  def run_finished(_run, _result), do: :ok

  @impl true
  def run_committed(%{subject_type: "conversation"} = run, result) do
    broadcast(run, {:chat_ended, run.id, Result.status(result)})
  end

  def run_committed(_run, _result), do: :ok

  defp broadcast(run, message) do
    Phoenix.PubSub.broadcast(ClementineSmoke.PubSub, Conversations.topic(run.subject_id), message)
  end
end
