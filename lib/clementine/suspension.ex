defmodule Clementine.Suspension do
  @moduledoc """
  The durable fact that a run is parked: a reason, the resume contract,
  and — for mid-rollout parks — a checkpoint.

  Assembly is split by who knows what. The rollout produces a `Request`
  (it knows loop state and never sees the lease); the runner completes the
  checkpoint's cursor from its event stamper; the protocol derives the
  token from the lease and persists the assembled suspension. The token is
  computed at that moment, not separately stored — it lives inside the
  suspension it authorizes.

  `checkpoint` is nilable for `{:external, _}` reasons only (LOOP_RFC
  amendment A4): a loop park needs the token machinery — resume by
  reference — but has no rollout checkpoint; its durable state is the
  envelope, which lives in its own recipe column. `{:approval, _}` and
  `{:until, _}` parks are mid-rollout by definition and always carry one —
  the Ecto codec refuses to store them without it.

  Reason scope: rollouts produce only `{:approval, _}` (gated tools).
  `{:external, tag}` is for host- and loop-initiated waits; `{:until, t}`
  for scheduled waits, whose wake-up is host-scheduled resume — nothing in
  Clementine owns a timer. The reaper's `:suspension_expired` is the
  policy ceiling over all waits, distinct from any wake-up path.
  """

  alias Clementine.{ApprovalRequest, Checkpoint, ResumeToken}

  @type reason ::
          {:approval, ApprovalRequest.t()}
          | {:external, term()}
          | {:until, DateTime.t()}

  @enforce_keys [:reason, :checkpoint, :token]
  defstruct reason: nil, checkpoint: nil, token: nil

  @type t :: %__MODULE__{
          reason: reason(),
          checkpoint: Checkpoint.t() | nil,
          token: ResumeToken.t()
        }

  defmodule Request do
    @moduledoc """
    The suspension body as the rollout produces it: reason, pending
    operation, and loop state — everything except the cursor and the
    token, which require the lease the rollout never sees.
    """

    @enforce_keys [:reason, :pending]
    defstruct reason: nil,
              pending: nil,
              messages: [],
              iteration: 0,
              usage: %Clementine.Usage{}

    @type t :: %__MODULE__{
            reason: Clementine.Suspension.reason(),
            pending: Clementine.Pending.t(),
            messages: [Clementine.LLM.Message.message()],
            iteration: non_neg_integer(),
            usage: Clementine.Usage.t()
          }
  end

  @doc "The reason discriminator a resume token validates against."
  @spec reason_type(t() | Request.t() | reason()) :: :approval | :external | :until
  def reason_type(%__MODULE__{reason: reason}), do: reason_type(reason)
  def reason_type(%Request{reason: reason}), do: reason_type(reason)
  def reason_type({:approval, _}), do: :approval
  def reason_type({:external, _}), do: :external
  def reason_type({:until, _}), do: :until
end
