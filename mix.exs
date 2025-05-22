defmodule DeribitEx.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/ZenHive/deribit_ex"

  def project do
    [
      app: :deribit_ex,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
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
      {:websockex_nova, "~> 0.1.1"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},

      # Dev and test dependencies
      {:ex_doc, "~> 0.29", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22.0", only: :dev},
      {:excoveralls, "~> 0.16", only: :test},
      # Tasks
      {:task_validator, "~> 0.5.0", only: :dev}
    ]
  end

  defp description do
    """
    An Elixir library for interacting with the Deribit cryptocurrency exchange API via WebSocket.
    Handles authentication, request/response management, subscriptions, rate limiting, and time synchronization.
    """
  end

  defp package do
    [
      name: "deribit_ex",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md CONTRIBUTING.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      maintainers: ["E.FU"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        "Core Components": [
          DeribitEx.Client,
          DeribitEx.RPC,
          DeribitEx.Adapter
        ],
        Authentication: [
          DeribitEx.TokenManager,
          DeribitEx.SessionContext
        ],
        "WebSocket Management": [
          DeribitEx.ResubscriptionHandler,
          DeribitEx.RateLimitHandler,
          DeribitEx.TimeSyncService,
          DeribitEx.TimeSyncSupervisor
        ],
        Utilities: [
          DeribitEx.OrderContext,
          DeribitEx.Telemetry
        ]
      ]
    ]
  end
end
