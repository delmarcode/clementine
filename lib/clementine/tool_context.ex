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
  that root after expansion.
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
  """
  @spec resolve_path(String.t(), context()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(path, context) when is_binary(path) and is_map(context) do
    root = workspace_root(context)

    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, root)
      end

    if under_root?(expanded, root) do
      {:ok, expanded}
    else
      {:error, "Path escapes workspace root: #{path}"}
    end
  end

  @doc """
  Returns the expanded workspace root for a context.
  """
  @spec workspace_root(context()) :: String.t()
  def workspace_root(context) when is_map(context) do
    context
    |> Map.get(:workspace_root, Map.get(context, :working_dir, File.cwd!()))
    |> Path.expand()
  end

  defp under_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end
end
