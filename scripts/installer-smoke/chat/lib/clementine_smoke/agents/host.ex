defmodule ClementineSmoke.Agents.Host do
  @moduledoc """
  The agents' host. A chat turn's messages commit with its end (a
  failed turn's: the steps it completed), after the user's message it
  answers, and a conversation's runs stream on its PubSub topic: text as
  it arrives, each change of status, and the end.
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

  # The user's message was stored when it arrived, so a thread's retry
  # of a failed turn never stores it twice, and an interrupted or
  # cancelled turn never loses it. The turn stores what it said.
  @impl true
  def run_finished(%{agent_key: "chat"} = run, %ended{} = result)
      when ended in [Result.Completed, Result.Failed] do
    Conversations.append_reply!(run.subject_id, run.metadata["message_id"], result.messages)
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
