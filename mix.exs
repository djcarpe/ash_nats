defmodule AshNats.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_nats,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "NATS integration for Ash resources: publications and request/reply.",
      package: [licenses: ["MIT"]],
      name: "AshNats",
      source_url: "https://github.com/TODO/ash_nats",
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      groups_for_modules: [
        DSL: [AshNats, AshNats.Domain, AshNats.Info, AshNats.Domain.Info],
        "Request/reply": [
          AshNats.Rpc.Server,
          AshNats.Rpc.Service,
          AshNats.Rpc.Client,
          AshNats.Rpc.ErrorSerializer
        ],
        Internals: [
          AshNats.Notifier,
          AshNats.Encoder,
          AshNats.Encoder.Json,
          AshNats.Serializer,
          AshNats.Publication,
          AshNats.Exposure
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:spark, "~> 2.0"},
      {:gnat, "~> 1.8"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0"},
      {:telemetry, "~> 1.0"},
      {:igniter, "~> 0.6", optional: true},
      {:sourceror, "~> 1.7"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
