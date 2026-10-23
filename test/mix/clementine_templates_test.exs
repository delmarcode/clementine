defmodule Mix.ClementineTemplatesTest do
  @moduledoc """
  Keeps the generators' templates in lockstep with the library: every
  template renders, and the code `mix clementine.install` and
  `mix clementine.gen.agent` write compiles against the current API
  without a single warning. A renamed Clementine function or a changed
  callback breaks the template here, not in an app's first compile.

  `scripts/installer-smoke.sh` goes further and runs the generated tests,
  including the conformance suite, inside a real Phoenix app.
  """

  # Compiled template modules are global state; keep the file serial.
  use ExUnit.Case, async: false

  @install ~w(agent_run lifecycle definition catalog runs run_worker reaper drain_notifier agents_case)
  @install_tests ~w(lifecycle_test runs_test run_worker_test reaper_test drain_notifier_test)

  @repo """
  defmodule MyApp.Repo do
    use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
  end
  """

  for binary_id <- [false, true] do
    @tag :tmp_dir
    test "generated code compiles without warnings (binary_id: #{binary_id})", %{tmp_dir: dir} do
      assigns = assigns(unquote(binary_id))

      sources =
        [{"repo.ex", @repo}, {"migration.ex", migration(assigns)}] ++
          for(
            name <- @install,
            do: {"#{name}.ex", render("clementine.install/#{name}.ex", assigns)}
          ) ++
          [
            {"agent.ex", render("clementine.gen.agent/agent.ex", agent_assigns())},
            {"tool.ex", render("clementine.gen.agent/tool.ex", agent_assigns())}
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
  end

  test "generated tests parse" do
    for name <- @install_tests do
      Code.string_to_quoted!(render("clementine.install/#{name}.exs", assigns(false)))
    end

    Code.string_to_quoted!(render("clementine.gen.agent/agent_test.exs", agent_assigns()))
  end

  defp render(template, assigns) do
    EEx.eval_file(Mix.Clementine.template(template <> ".eex"), assigns: assigns)
  end

  defp migration(assigns) do
    """
    defmodule MyApp.Repo.Migrations.CreateAgentRuns do
      use Ecto.Migration

      #{render("clementine.install/create_agent_runs.exs", assigns)}
    end
    """
  end

  defp assigns(binary_id) do
    [
      app_name: :my_app,
      app_module: "MyApp",
      agents: "MyApp.Agents",
      repo: "MyApp.Repo",
      binary_id: binary_id
    ]
  end

  defp agent_assigns do
    [
      app_module: "MyApp",
      agents: "MyApp.Agents",
      module: "MyApp.Agents.Weather",
      alias: "Weather",
      key: "weather",
      human: "weather",
      tool_module: "MyApp.Agents.Weather.Tools.Lookup",
      tool_alias: "Lookup",
      tool_name: "lookup",
      test_aliases: [
        "MyApp.Agents.Catalog",
        "MyApp.Agents.Weather",
        "MyApp.Agents.Weather.Tools.Lookup"
      ]
    ]
  end
end
