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
        "guides/runtime.md": [title: "The Durable Runtime"],
        "guides/approvals.md": [title: "Approvals & Suspension"],
        "guides/observation.md": [title: "Observing Runs"],
        "guides/durable-loops.md": [title: "Durable Loops"],
        "guides/loop-operations.md": [title: "Loop Operations"],
        "usage-rules.md": [title: "Usage Rules"]
      ],
      groups_for_extras: [
        Guides: ~r{guides/}
      ],
      groups_for_modules: [
        "Durable runtime": [
          Clementine.Runs,
          Clementine.Runs.AgentRun,
          Clementine.Runs.Worker,
          Clementine.Host,
          Clementine.Migration
        ],
        Core: [
          Clementine,
          Clementine.Agent,
          Clementine.Skill,
          Clementine.Delegation,
          Clementine.EngineTool,
          Clementine.AgentServer,
          Clementine.Rollout,
          Clementine.Run,
          Clementine.Runner,
          Clementine.Result,
          Clementine.OutputSchema,
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
        "Durable runtime": [
          Clementine.Runs,
          Clementine.Runs.AgentRun,
          Clementine.Host,
          Clementine.Migration
        ],
        "Suspension & approval": [
          Clementine.Checkpoint,
          Clementine.Suspension,
          Clementine.Suspension.Request,
          Clementine.ResumeToken,
          Clementine.Pending,
          Clementine.Pending.ToolApproval,
          Clementine.Pending.Delegation,
          Clementine.ApprovalRequest
        ],
        Reaper: [
          Clementine.Reconciler,
          Clementine.Reconciler.Policy,
          Clementine.InterruptReason
        ],
        "Durable loops": [
          Clementine.Loop,
          Clementine.Thread,
          Clementine.Loop.Report,
          Clementine.Loop.StoredInput
        ],
        "Events & observation": [
          Clementine.Trace,
          Clementine.Trace.Entry,
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
      # Optional: the durable runtime (`{Clementine, ...}` and
      # `Clementine.Runs`) executes runs on the host's Oban and compiles
      # only when the host brings Oban and Ecto in.
      {:oban, "~> 2.18", optional: true},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      # Optional: `mix clementine.install` and `mix clementine.gen.agent`
      # compile only when the host brings Igniter in, the way Oban ships
      # `oban.install`. Nothing from it runs in production.
      {:igniter, "~> 0.8.4", optional: true},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
