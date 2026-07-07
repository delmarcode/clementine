defmodule Clementine.MixProject do
  use Mix.Project

  def project do
    [
      app: :clementine,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Clementine",
      source_url: "https://github.com/delmarcode/clementine",
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "getting-started",
      extras: [
        "guides/getting-started.md": [title: "Getting Started"],
        "guides/durable-execution.md": [title: "Durable Execution"],
        "guides/approvals.md": [title: "Approvals & Suspension"],
        "guides/observation.md": [title: "Observing Runs"]
      ],
      groups_for_extras: [
        Guides: ~r{guides/}
      ],
      groups_for_modules: [
        Core: [
          Clementine,
          Clementine.Agent,
          Clementine.AgentServer,
          Clementine.Rollout,
          Clementine.Run,
          Clementine.Runner,
          Clementine.Result,
          Clementine.Error,
          Clementine.Usage,
          Clementine.Verifier
        ],
        Lifecycle: [
          Clementine.Lifecycle,
          Clementine.Lifecycle.Protocol,
          Clementine.Lifecycle.Facts,
          Clementine.Lifecycle.Transition,
          Clementine.Lifecycle.Ephemeral,
          Clementine.Lease,
          Clementine.Heartbeat
        ],
        "Ecto adapter": [
          Clementine.Lifecycle.Ecto,
          Clementine.Lifecycle.Ecto.Migration,
          Clementine.Lifecycle.Ecto.Codec,
          Clementine.Lifecycle.Ecto.Oban,
          Clementine.LifecycleCase,
          Clementine.LifecycleCase.Battery
        ],
        "Suspension & approval": [
          Clementine.Checkpoint,
          Clementine.Suspension,
          Clementine.Suspension.Request,
          Clementine.ResumeToken,
          Clementine.Pending,
          Clementine.Pending.ToolApproval,
          Clementine.ApprovalRequest
        ],
        Reaper: [
          Clementine.Reconciler,
          Clementine.Reconciler.Policy,
          Clementine.InterruptReason
        ],
        "Events & observation": [
          Clementine.Event,
          Clementine.Events,
          Clementine.Events.Null,
          Clementine.Events.Stamper,
          Clementine.RunView,
          Clementine.Telemetry,
          Clementine.Telemetry.Logger
        ],
        Tools: ~r{Clementine\.Tool},
        LLM: ~r{Clementine\.LLM}
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Clementine.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # Optional: the Ecto lifecycle adapter compiles only when the host
      # app brings these in.
      {:ecto_sql, "~> 3.10", optional: true},
      {:postgrex, "~> 0.18", optional: true},
      # Optional: the Ecto adapter's cancel push channel lights up only
      # when a host configures `pubsub:`.
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      # Dev/test only: lets the guides' Oban-based host samples (workers,
      # enqueue, reaper cron) compile-verify against the real macros.
      {:oban, "~> 2.18", only: [:dev, :test]},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
