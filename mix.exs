defmodule Clementine.MixProject do
  use Mix.Project

  def project do
    [
      app: :clementine,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
