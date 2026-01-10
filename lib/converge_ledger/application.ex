defmodule ConvergeLedger.Application do
  @moduledoc """
  OTP Application for ConvergeLedger.

  Starts the supervision tree with:
  - Mnesia schema initialization
  - Watch registry for streaming subscriptions
  - gRPC server for external communication (not in test mode)
  """

  use Application

  require Logger

  # Capture Mix.env at compile time (Mix is not available in releases)
  @mix_env Mix.env()

  @impl true
  def start(_type, _args) do
    # Initialize Mnesia before starting supervised processes
    case ConvergeLedger.Storage.Schema.init() do
      :ok ->
        Logger.info("Mnesia initialized")

      {:error, reason} ->
        Logger.error("Failed to initialize Mnesia: #{inspect(reason)}")
        raise "Mnesia initialization failed: #{inspect(reason)}"
    end

    children = base_children() ++ grpc_children()

    opts = [strategy: :one_for_one, name: ConvergeLedger.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if start_grpc?() do
          Logger.info("ConvergeLedger started on port #{grpc_port()}")
        end

        {:ok, pid}

      error ->
        error
    end
  end

  defp base_children do
    [
      # Start pg scope (default)
      %{id: :pg, start: {:pg, :start_link, []}},

      # Cluster Supervisor
      {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies) || [], [name: ConvergeLedger.ClusterSupervisor]]},

      # Mnesia Cluster Manager
      ConvergeLedger.Cluster.MnesiaManager,

      # Watch registry for streaming subscriptions
      ConvergeLedger.WatchRegistry
    ]
  end

  # Don't start gRPC server in test mode to avoid port conflicts
  defp grpc_children do
    if start_grpc?() do
      [
        {GRPC.Server.Supervisor,
         endpoint: ConvergeLedger.Grpc.Endpoint, port: grpc_port(), start_server: true}
      ]
    else
      []
    end
  end

  # Use compile-time captured Mix.env
  defp start_grpc?, do: @mix_env != :test

  defp grpc_port do
    case System.get_env("GRPC_PORT") do
      nil -> 50_051
      port -> String.to_integer(port)
    end
  end
end