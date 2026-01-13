defmodule Clementine.Tools.WriteFile do
  @moduledoc """
  Tool for writing content to files.

  Creates or overwrites files. Creates parent directories if needed.
  """

  use Clementine.Tool,
    name: "write_file",
    description: "Write content to a file. Creates the file if it doesn't exist, or overwrites if it does. Creates parent directories automatically.",
    parameters: [
      path: [
        type: :string,
        required: true,
        description: "The path to write to (absolute or relative to working directory)"
      ],
      content: [
        type: :string,
        required: true,
        description: "The content to write to the file"
      ]
    ]

  @impl true
  def run(%{path: path, content: content}, context) do
    full_path = resolve_path(path, context)

    # Ensure parent directory exists
    parent_dir = Path.dirname(full_path)

    case File.mkdir_p(parent_dir) do
      :ok ->
        write_file(full_path, content)

      {:error, reason} ->
        {:error, "Failed to create directory #{parent_dir}: #{inspect(reason)}"}
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok ->
        {:ok, "Successfully wrote #{byte_size(content)} bytes to #{path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, :enospc} ->
        {:error, "No space left on device"}

      {:error, reason} ->
        {:error, "Failed to write file: #{inspect(reason)}"}
    end
  end

  defp resolve_path(path, context) do
    if Path.type(path) == :absolute do
      path
    else
      working_dir = Map.get(context, :working_dir, File.cwd!())
      Path.join(working_dir, path)
    end
  end
end
