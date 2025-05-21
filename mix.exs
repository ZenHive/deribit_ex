defmodule DeribitEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :deribit_ex,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "An Elixir library for interacting with the Deribit API via WebSocket"
    ]
  end

  # Ensure test support files are compiled in test environment
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {DeribitEx.Application, []}
    ]
  end

  defp deps do
    [
      {:websockex_nova, "~> 0.1"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},

      # Dev and test dependencies
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end
end
