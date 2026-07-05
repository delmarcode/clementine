defmodule Clementine.Pending do
  @moduledoc """
  What a suspended rollout stopped on.

  The only shape this epic activates is `ToolApproval`; other suspension
  reasons (`{:external, _}`, `{:until, _}`) are reserved and their pending
  shapes deliberately unspecified until they activate.
  """

  alias Clementine.ToolResult

  defmodule ToolApproval do
    @moduledoc """
    A gated tool call awaiting a decision.

    `completed_results` carries the ungated siblings from the same parallel
    batch that already executed — nothing is discarded at suspension, and
    nothing unsafe re-executes on resume. ToolResult `metadata` is advisory
    and not preserved across the checkpoint boundary.
    """

    @enforce_keys [:tool_use_id, :tool_name]
    defstruct tool_use_id: nil, tool_name: nil, args: %{}, completed_results: %{}

    @type t :: %__MODULE__{
            tool_use_id: String.t(),
            tool_name: String.t(),
            args: map(),
            completed_results: %{optional(String.t()) => Clementine.ToolResult.t()}
          }
  end

  @type t :: ToolApproval.t()

  @doc "JSON-safe encoding for checkpoint embedding."
  @spec to_map(t()) :: map()
  def to_map(%ToolApproval{} = pending) do
    %{
      "shape" => "tool_approval",
      "tool_use_id" => pending.tool_use_id,
      "tool_name" => pending.tool_name,
      "args" => pending.args,
      "completed_results" =>
        Map.new(pending.completed_results, fn {id, %ToolResult{} = result} ->
          {id, %{"content" => result.content, "is_error" => result.is_error}}
        end)
    }
  end

  @doc """
  Rebuilds a pending operation from `to_map/1` output. Raises
  `ArgumentError` on unknown shapes — checkpoint decoding maps that to
  `:incompatible_checkpoint`.
  """
  @spec from_map(map()) :: t()
  def from_map(%{"shape" => "tool_approval"} = data) do
    %ToolApproval{
      tool_use_id: Map.fetch!(data, "tool_use_id"),
      tool_name: Map.fetch!(data, "tool_name"),
      args: Map.get(data, "args", %{}),
      completed_results:
        data
        |> Map.get("completed_results", %{})
        |> Map.new(fn {id, result} ->
          {id,
           %ToolResult{
             content: Map.fetch!(result, "content"),
             is_error: Map.get(result, "is_error", false)
           }}
        end)
    }
  end

  def from_map(other) do
    raise ArgumentError, "unknown pending shape: #{inspect(other)}"
  end
end
