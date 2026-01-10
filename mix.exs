defmodule ConvergeLedger.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/kpernyer/converge-ledger"

  def project do
    [
      app: :converge_ledger,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex.pm
      name: "Converge Ledger",
      description: "Distributed append-only runtime substrate for Converge workflows",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,

      # Releases
      releases: [
        converge_ledger: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia],
      mod: {ConvergeLedger.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # gRPC
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.13"},

      # Clustering
      {:libcluster, "~> 3.3"},

      # Development & Testing
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "converge_ledger",
      maintainers: ["Kenneth Pernyer"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(
        lib
        priv/protos
        .formatter.exs
        mix.exs
        README.md
        LICENSE
        CHANGELOG.md
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "ARCHITECTURE.md",
        "CONTRIBUTING.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile"],
      lint: ["format --check-formatted", "credo --strict"],
      test: ["test"]
    ]
  end
end
