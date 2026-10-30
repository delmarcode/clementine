defmodule Clementine.Pending do
  @moduledoc """
  What a suspended rollout stopped on.

  Two shapes: `ToolApproval`, a gated call waiting on a decision
  (`{:approval, _}`), and `Delegation`, `delegate` calls waiting on the
  runs they started (`{:external, {:delegation, ids}}`). The `{:until, _}`
  reason is reserved, and its pending shape unspecified until it
  activates.
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

  defmodule Delegation do
    @moduledoc """
    `delegate` calls waiting on the runs they started
    (`Clementine.Delegation`).

    `children` maps each waiting call's `tool_use_id` to its child: the
    agent's key, the prompt, and `run_id`, the child's run once the
    runtime started it. A call whose child could not start keeps
    `run_id: nil`, and its refusal rides in `completed_results`.
    `completed_results` carries the batch's other results, as
    `ToolApproval`'s does: nothing settled before the park runs again.

    The resume payload is `{:delegated, %{tool_use_id => outcome}}`, an
    outcome (`Clementine.Delegation.outcome/2`) for each child that
    started.
    """

    @enforce_keys [:children]
    defstruct children: %{}, completed_results: %{}

    @type t :: %__MODULE__{
            children: %{optional(String.t()) => Clementine.Delegation.child()},
            completed_results: %{optional(String.t()) => Clementine.ToolResult.t()}
          }
  end

  @type t :: ToolApproval.t() | Delegation.t()

  @doc "JSON-safe encoding for checkpoint embedding."
  @spec to_map(t()) :: map()
  def to_map(%ToolApproval{} = pending) do
    %{
      "shape" => "tool_approval",
      "tool_use_id" => pending.tool_use_id,
      "tool_name" => pending.tool_name,
      "args" => pending.args,
      "completed_results" => encode_results(pending.completed_results)
    }
  end

  def to_map(%Delegation{} = pending) do
    %{
      "shape" => "delegation",
      "children" =>
        Map.new(pending.children, fn {id, child} ->
          {id, %{"agent" => child.agent, "prompt" => child.prompt, "run_id" => child.run_id}}
        end),
      "completed_results" => encode_results(pending.completed_results)
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
      completed_results: decode_results(data)
    }
  end

  def from_map(%{"shape" => "delegation"} = data) do
    %Delegation{
      children:
        data
        |> Map.fetch!("children")
        |> Map.new(fn {id, child} ->
          {id,
           %{
             agent: Map.fetch!(child, "agent"),
             prompt: Map.fetch!(child, "prompt"),
             run_id: Map.get(child, "run_id")
           }}
        end),
      completed_results: decode_results(data)
    }
  end

  def from_map(other) do
    raise ArgumentError, "unknown pending shape: #{inspect(other)}"
  end

  defp encode_results(results) do
    Map.new(results, fn {id, %ToolResult{} = result} ->
      {id, %{"content" => result.content, "is_error" => result.is_error}}
    end)
  end

  defp decode_results(data) do
    data
    |> Map.get("completed_results", %{})
    |> Map.new(fn {id, result} ->
      {id,
       %ToolResult{
         content: Map.fetch!(result, "content"),
         is_error: Map.get(result, "is_error", false)
       }}
    end)
  end
end
