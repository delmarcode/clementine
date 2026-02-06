defmodule Clementine.Tools.ListDir do
  @moduledoc """
  Tool for listing directory contents.

  Lists files and directories with optional metadata.
  """

  use Clementine.Tool,
    name: "list_dir",
    description: "List the contents of a directory. Shows files and subdirectories with their types.",
    parameters: [
      path: [
        type: :string,
        required: true,
        description: "The directory path to list (absolute or relative to working directory)"
      ],
      show_hidden: [
        type: :boolean,
        required: false,
        description: "Whether to show hidden files (starting with dot). Default: false"
      ]
    ]

  @impl Clementine.Tool
  def summarize(%{path: path}), do: "list_dir(#{path})"
  def summarize(args), do: super(args)

  @impl true
  def run(args, context) do
    path = resolve_path(args.path, context)
    show_hidden = Map.get(args, :show_hidden, false)

    case File.ls(path) do
      {:ok, entries} ->
        entries =
          entries
          |> maybe_filter_hidden(show_hidden)
          |> Enum.sort()
          |> Enum.map(fn entry ->
            full_path = Path.join(path, entry)
            type = get_entry_type(full_path)
            "#{type_indicator(type)} #{entry}"
          end)

        output = Enum.join(entries, "\n")
        {:ok, if(output == "", do: "(empty directory)", else: output)}

      {:error, :enoent} ->
        {:error, "Directory not found: #{path}"}

      {:error, :enotdir} ->
        {:error, "Not a directory: #{path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, reason} ->
        {:error, "Failed to list directory: #{inspect(reason)}"}
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

  defp maybe_filter_hidden(entries, true), do: entries

  defp maybe_filter_hidden(entries, false) do
    Enum.reject(entries, &String.starts_with?(&1, "."))
  end

  defp get_entry_type(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> :directory
      {:ok, %{type: :regular}} -> :file
      {:ok, %{type: :symlink}} -> :symlink
      _ -> :unknown
    end
  end

  defp type_indicator(:directory), do: "[dir]"
  defp type_indicator(:file), do: "[file]"
  defp type_indicator(:symlink), do: "[link]"
  defp type_indicator(:unknown), do: "[?]"
end
