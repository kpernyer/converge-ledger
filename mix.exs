defmodule ConvergeContext.MixProject do
  use Mix.Project

  def project do
    [
      app: :converge_context,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Releases
      releases: [
        converge_context: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia],
      mod: {ConvergeContext.Application, []}
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
      {:stream_data, "~> 1.1", only: [:test]}
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
