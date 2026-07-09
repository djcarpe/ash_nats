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
      package: [licenses: ["MIT"]]
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
      {:decimal, "~> 2.0"}
    ]
  end
end
