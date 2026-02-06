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
        description:
          "Start reading from this line (1-indexed, must be >= 1). If omitted, starts from the beginning. Returns an error if beyond the end of the file."
      ],
      end_line: [
        type: :integer,
        required: false,
        description:
          "Stop reading at this line (inclusive, must be >= 1 and >= start_line). If omitted or beyond the end of the file, reads to the last line."
      ]
    ]

  @impl Clementine.Tool
  def summarize(%{path: path} = args) do
    range =
      case {args[:start_line], args[:end_line]} do
        {nil, nil} -> ""
        {s, nil} -> ":#{s}"
        {nil, e} -> ":1-#{e}"
        {s, e} -> ":#{s}-#{e}"
      end

    "read_file(#{path}#{range})"
  end

  def summarize(args), do: super(args)

  @impl true
  def run(args, context) do
    path = resolve_path(args.path, context)

    with {:ok, content} <- read_file(path),
         {:ok, result} <- maybe_slice_lines(content, args[:start_line], args[:end_line]) do
      {:ok, result}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
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

  defp maybe_slice_lines(content, nil, nil), do: {:ok, content}

  defp maybe_slice_lines(content, start_line, end_line) do
    lines = split_lines(content)
    line_count = length(lines)

    with :ok <- validate_not_empty(line_count) do
      start_line = start_line || 1
      end_line = end_line || line_count

      with :ok <- validate_positive("start_line", start_line),
           :ok <- validate_positive("end_line", end_line),
           :ok <- validate_in_range(start_line, line_count),
           :ok <- validate_order(start_line, end_line) do
        end_line = min(end_line, line_count)
        start_idx = start_line - 1
        end_idx = end_line - 1

        result =
          lines
          |> Enum.slice(start_idx..end_idx)
          |> Enum.with_index(start_line)
          |> Enum.map(fn {line, num} -> "#{num}: #{line}" end)
          |> Enum.join("\n")

        {:ok, result}
      end
    end
  end

  defp validate_positive(name, value) when value < 1,
    do: {:error, "#{name} must be >= 1, got #{value}"}

  defp validate_positive(_name, _value), do: :ok

  defp validate_order(start_line, end_line) when start_line > end_line,
    do: {:error, "start_line (#{start_line}) must be <= end_line (#{end_line})"}

  defp validate_order(_start_line, _end_line), do: :ok

  defp validate_not_empty(0), do: {:error, "file is empty"}
  defp validate_not_empty(_line_count), do: :ok

  defp validate_in_range(start_line, line_count) when start_line > line_count,
    do: {:error, "start_line (#{start_line}) is beyond end of file (#{line_count} lines)"}

  defp validate_in_range(_start_line, _line_count), do: :ok

  # Split content into lines, dropping only the single phantom empty element
  # that String.split/2 produces when content ends with "\n".
  # Preserves intentional trailing blank lines (e.g., "a\n\n" → ["a", ""]).
  defp split_lines(""), do: []

  defp split_lines(content) do
    lines = String.split(content, "\n")

    if String.ends_with?(content, "\n") do
      List.delete_at(lines, -1)
    else
      lines
    end
  end
end
