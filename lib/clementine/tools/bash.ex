defmodule Clementine.Tools.Bash do
  @moduledoc """
  Tool for executing shell commands.

  Runs commands in a bash shell with configurable timeout.
  Captures both stdout and stderr.
  """

  use Clementine.Tool,
    name: "bash",
    description: "Execute a shell command. Runs in bash with a timeout. Use for running tests, builds, git operations, and other system commands.",
    parameters: [
      command: [
        type: :string,
        required: true,
        description: "The command to execute"
      ],
      timeout_ms: [
        type: :integer,
        required: false,
        description: "Timeout in milliseconds. Default: 60000 (1 minute)"
      ]
    ]

  @default_timeout 60_000

  @impl true
  def run(%{command: command} = args, context) do
    working_dir = Map.get(context, :working_dir, File.cwd!())
    timeout = Map.get(args, :timeout_ms, @default_timeout)

    opts = [
      cd: working_dir,
      stderr_to_stdout: true
    ]

    # Use a Task with timeout to handle long-running commands
    task =
      Task.async(fn ->
        System.cmd("bash", ["-c", command], opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        format_result(output, exit_code)

      nil ->
        {:error, "Command timed out after #{timeout}ms"}

      {:exit, reason} ->
        {:error, "Command failed: #{inspect(reason)}"}
    end
  end

  defp format_result(output, 0) do
    {:ok, String.trim(output)}
  end

  defp format_result(output, exit_code) do
    # Return output even on failure - the model needs to see errors
    {:ok, "Exit code: #{exit_code}\n\n#{String.trim(output)}"}
  end
end
