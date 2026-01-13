defmodule Clementine.Tools.ReadFile do
  @moduledoc """
  Tool for reading file contents.

  Reads files from the filesystem, with optional line range support
  for large files.
  """

  use Clementine.Tool,
    name: "read_file",
    description: "Read the contents of a file. For large files, you can specify a line range.",
    parameters: [
      path: [
        type: :string,
        required: true,
        description: "The path to the file to read (absolute or relative to working directory)"
      ],
      start_line: [
        type: :integer,
        required: false,
        description: "Start reading from this line (1-indexed). If omitted, starts from the beginning."
      ],
      end_line: [
        type: :integer,
        required: false,
        description: "Stop reading at this line (inclusive). If omitted, reads to the end."
      ]
    ]

  @impl true
  def run(args, context) do
    path = resolve_path(args.path, context)

    case File.read(path) do
      {:ok, content} ->
        content = maybe_slice_lines(content, args[:start_line], args[:end_line])
        {:ok, content}

      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, :eisdir} ->
        {:error, "Path is a directory: #{path}"}

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
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

  defp maybe_slice_lines(content, nil, nil), do: content

  defp maybe_slice_lines(content, start_line, end_line) do
    lines = String.split(content, "\n")
    start_idx = (start_line || 1) - 1
    end_idx = (end_line || length(lines)) - 1

    lines
    |> Enum.slice(start_idx..end_idx)
    |> Enum.with_index(start_idx + 1)
    |> Enum.map(fn {line, num} -> "#{num}: #{line}" end)
    |> Enum.join("\n")
  end
end
