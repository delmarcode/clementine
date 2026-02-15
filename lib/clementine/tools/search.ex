defmodule Clementine.Tools.Search do
  @moduledoc """
  Tool for searching file contents.

  Searches for patterns in files using regular expressions.
  Similar to grep but returns structured results.
  """

  use Clementine.Tool,
    name: "search",
    description:
      "Search for a pattern in files. Returns matching lines with file names and line numbers. Supports regular expressions.",
    parameters: [
      pattern: [
        type: :string,
        required: true,
        description: "The pattern to search for (supports Elixir regex syntax)"
      ],
      path: [
        type: :string,
        required: false,
        description: "Directory or file to search in. Default: working directory"
      ],
      file_pattern: [
        type: :string,
        required: false,
        description: "Glob pattern to filter files (e.g., '*.ex', '**/*.exs'). Default: all files"
      ],
      max_results: [
        type: :integer,
        required: false,
        description: "Maximum number of matching lines to return. Default: 100"
      ]
    ]

  @default_max_results 100

  @impl Clementine.Tool
  def summarize(%{pattern: pattern} = args) do
    path = Map.get(args, :path, ".")
    "search(#{inspect(pattern)}, path=#{path})"
  end

  def summarize(args), do: super(args)

  @impl true
  def run(args, context) do
    search_path = resolve_path(Map.get(args, :path, "."), context)
    pattern = args.pattern
    file_pattern = Map.get(args, :file_pattern, "**/*")
    max_results = Map.get(args, :max_results, @default_max_results)

    case compile_regex(pattern) do
      {:ok, regex} ->
        results = search_files(search_path, regex, file_pattern, max_results)
        format_results(results, pattern)

      {:error, reason} ->
        {:error, "Invalid regex pattern: #{reason}"}
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

  defp compile_regex(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _}} -> {:error, reason}
    end
  end

  defp search_files(path, regex, file_pattern, max_results) do
    files = find_files(path, file_pattern)

    files
    |> Stream.flat_map(fn file ->
      search_file(file, regex)
    end)
    |> Enum.take(max_results)
  end

  defp find_files(path, pattern) do
    if File.regular?(path) do
      [path]
    else
      full_pattern = Path.join(path, pattern)

      Path.wildcard(full_pattern)
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&binary_file?/1)
    end
  end

  defp search_file(file, regex) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _num} ->
          Regex.match?(regex, line)
        end)
        |> Enum.map(fn {line, num} ->
          %{file: file, line_number: num, content: String.trim(line)}
        end)

      {:error, _} ->
        []
    end
  end

  defp binary_file?(path) do
    # Simple heuristic: check first few bytes for null characters
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        result =
          case IO.binread(file, 1024) do
            data when is_binary(data) -> String.contains?(data, <<0>>)
            _ -> false
          end

        File.close(file)
        result

      _ ->
        true
    end
  end

  defp format_results([], pattern) do
    {:ok, "No matches found for pattern: #{pattern}"}
  end

  defp format_results(results, _pattern) do
    output =
      results
      |> Enum.map(fn %{file: file, line_number: num, content: content} ->
        "#{file}:#{num}: #{content}"
      end)
      |> Enum.join("\n")

    count = length(results)
    {:ok, "Found #{count} match(es):\n\n#{output}"}
  end
end
