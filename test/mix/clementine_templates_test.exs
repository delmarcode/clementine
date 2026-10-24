defmodule Mix.ClementineTemplatesTest do
  @moduledoc """
  Keeps the generators' templates in lockstep with the library: every
  template renders, and the code `mix clementine.install` and
  `mix clementine.gen.agent` write compiles against the current API
  without a single warning. A renamed Clementine function or a changed
  option breaks the template here, not in an app's first compile.

  `scripts/installer-smoke.sh` goes further and runs the generated test,
  which executes the agent end to end through the runtime, inside a real
  Phoenix app.
  """

  # Compiled template modules are global state; keep the file serial.
  use ExUnit.Case, async: false

  @repo """
  defmodule MyApp.Repo do
    use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
  end
  """

  @assigns [
    app_module: "MyApp",
    agents: "MyApp.Agents",
    repo: "MyApp.Repo",
    module: "MyApp.Agents.Weather",
    alias: "Weather",
    key: "weather",
    human: "weather",
    tool_module: "MyApp.Agents.Weather.Tools.Lookup",
    tool_alias: "Lookup",
    tool_name: "lookup"
  ]

  @tag :tmp_dir
  test "generated code compiles without warnings", %{tmp_dir: dir} do
    sources = [
      {"repo.ex", @repo},
      {"migration.ex", migration()},
      {"agents_case.ex", render("clementine.install/agents_case.ex")},
      {"agent.ex", render("clementine.gen.agent/agent.ex")},
      {"tool.ex", render("clementine.gen.agent/tool.ex")}
    ]

    paths =
      for {name, source} <- sources do
        path = Path.join(dir, name)
        File.write!(path, source)
        path
      end

    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        Kernel.ParallelCompiler.compile(paths, return_diagnostics: true)
      end)

    case result do
      {:ok, modules, %{compile_warnings: compile, runtime_warnings: runtime}} ->
        for module <- modules do
          :code.purge(module)
          :code.delete(module)
        end

        assert compile ++ runtime ++ diagnostics == []

      {:error, errors, _warnings} ->
        flunk(
          "generated code does not compile:\n\n#{Enum.map_join(errors, "\n\n", & &1.message)}"
        )
    end
  end

  test "the generated test parses" do
    Code.string_to_quoted!(render("clementine.gen.agent/agent_test.exs"))
  end

  defp render(template) do
    EEx.eval_file(Mix.Clementine.template(template <> ".eex"), assigns: @assigns)
  end

  defp migration do
    """
    defmodule MyApp.Repo.Migrations.AddClementine do
      use Ecto.Migration

      #{render("clementine.install/add_clementine.exs")}
    end
    """
  end
end
