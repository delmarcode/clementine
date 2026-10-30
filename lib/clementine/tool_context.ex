defmodule Clementine.ToolContext do
  @moduledoc """
  Helpers for interpreting tool execution context.

  Built-in tools use this module to keep filesystem and shell access explicit.
  Capabilities are opt-in via `context[:capabilities]`:

      %{
        working_dir: "/repo",
        capabilities: %{read: true, write: true, shell: false}
      }

  Relative paths are resolved inside `:workspace_root` when present, otherwise
  inside `:working_dir`. Absolute paths are allowed only when they remain inside
  that root after expansion and symlink resolution.

  In-process (`Clementine.run/3`, `Clementine.AgentServer`) a context with
  neither root resolves under the current working directory. A context the
  durable runtime built, which carries `:run_id`, never does: a tool reading
  or writing in the server's own directory is the hazard, so `resolve_path/2`
  refuses, and the agent sets `working_dir` through
  `c:Clementine.Agent.agent/1`'s `tool_context:`.
  """

  @type capability :: :read | :write | :shell
  @type context :: map()

  @doc """
  Returns `:ok` when the requested capability is explicitly enabled.
  """
  @spec require_capability(context(), capability()) :: :ok | {:error, String.t()}
  def require_capability(context, capability) when is_map(context) do
    if get_in(context, [:capabilities, capability]) == true do
      :ok
    else
      {:error, "Tool capability denied: #{capability}"}
    end
  end

  @doc """
  Resolves `path` under the configured workspace root.

  The returned path is expanded and guaranteed to be inside the workspace root.
  Existing path segments are checked after symlink resolution so links inside the
  workspace cannot escape the root.
  """
  @spec resolve_path(String.t(), context()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(path, context) when is_binary(path) and is_map(context) do
    with {:ok, root} <- root(context) do
      expanded =
        if Path.type(path) == :absolute do
          Path.expand(path)
        else
          Path.expand(path, root)
        end

      if under_root?(expanded, root) and symlink_safe?(expanded, root) do
        {:ok, expanded}
      else
        {:error, "Path escapes workspace root: #{path}"}
      end
    end
  end

  @doc """
  Returns the expanded workspace root for a context: `:workspace_root`,
  else `:working_dir`, else the current working directory. That last
  default is the in-process one; `resolve_path/2`, which the built-in
  tools use, refuses it for a context the durable runtime built.
  """
  @spec workspace_root(context()) :: String.t()
  def workspace_root(context) when is_map(context) do
    context
    |> Map.get(:workspace_root, Map.get(context, :working_dir, File.cwd!()))
    |> Path.expand()
  end

  # A durable run's context carries :run_id and has no default root: the
  # current directory is the server's, never the run's.
  defp root(%{run_id: _} = context) do
    case Map.get(context, :workspace_root) || Map.get(context, :working_dir) do
      root when is_binary(root) ->
        {:ok, Path.expand(root)}

      _none ->
        {:error,
         "No working_dir for this run's tools: the agent sets one in agent/1's " <>
           "tool_context (the durable runtime never falls back to the app's own directory)"}
    end
  end

  defp root(context), do: {:ok, workspace_root(context)}

  defp under_root?(path, root) do
    root == "/" or path == root or String.starts_with?(path, root <> "/")
  end

  defp symlink_safe?(path, root) do
    real_root = realpath(root) || root

    path
    |> existing_ancestors(root)
    |> Enum.all?(fn ancestor ->
      case realpath(ancestor) do
        nil -> true
        real_path -> under_root?(real_path, real_root)
      end
    end)
  end

  defp realpath(path) do
    path
    |> String.to_charlist()
    |> :file.read_link_all()
    |> case do
      {:ok, resolved} -> List.to_string(resolved)
      {:error, _reason} -> nil
    end
  end

  defp existing_ancestors(path, root) do
    path
    |> ancestor_paths(root)
    |> Enum.filter(&File.exists?/1)
  end

  defp ancestor_paths(path, root) do
    do_ancestor_paths(path, root, [])
  end

  defp do_ancestor_paths(path, root, acc) do
    acc = [path | acc]

    cond do
      path == root ->
        Enum.reverse(acc)

      path == Path.dirname(path) ->
        Enum.reverse(acc)

      true ->
        do_ancestor_paths(Path.dirname(path), root, acc)
    end
  end
end
