defmodule Clementine.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail fast on an invalid override or declaration under
    # config :clementine, :models. Each agent's own model and choices are
    # checked when it is built, and again at the child spec's start.
    Clementine.Models.validate_config!()

    # What is ending only warns, and never stops the start: sheets read
    # long ago, and the dates of the models the app offers. Each agent's
    # model warns when the runtime starts it, or on its first run.
    Clementine.Models.Warnings.log_start()

    children = [
      # Task supervisor for tool execution
      {Task.Supervisor, name: Clementine.TaskSupervisor},
      # Durable-runtime workers register here so a draining node can reach
      # them (Clementine.Runs.DrainNotifier). It lives in Clementine's own
      # tree, which starts before the host's and stops after it, because a
      # registry links to every process registered in it: stopped while
      # workers still run, it would take them down with it.
      {Registry, keys: :duplicate, name: Clementine.Runs.Registry}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Clementine.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
