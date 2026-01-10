defmodule ConvergeContext.Application do
  @moduledoc """
  OTP Application for ConvergeContext.

  Starts the supervision tree with:
  - Mnesia schema initialization
  - Watch registry for streaming subscriptions
  - gRPC server for external communication (not in test mode)
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Initialize Mnesia before starting supervised processes
    case ConvergeContext.Storage.Schema.init() do
      :ok ->
        Logger.info("Mnesia initialized")

      {:error, reason} ->
        Logger.error("Failed to initialize Mnesia: #{inspect(reason)}")
        raise "Mnesia initialization failed: #{inspect(reason)}"
    end

    children = base_children() ++ grpc_children()

    opts = [strategy: :one_for_one, name: ConvergeContext.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        unless Mix.env() == :test do
          Logger.info("ConvergeContext started on port #{grpc_port()}")
        end

        {:ok, pid}

      error ->
        error
    end
  end

  defp base_children do
    [
      # Watch registry for streaming subscriptions
      ConvergeContext.WatchRegistry
    ]
  end

  # Don't start gRPC server in test mode to avoid port conflicts
  defp grpc_children do
    if Mix.env() == :test do
      []
    else
      [
        {GRPC.Server.Supervisor,
         endpoint: ConvergeContext.Grpc.Endpoint, port: grpc_port(), start_server: true}
      ]
    end
  end

  defp grpc_port do
    case System.get_env("GRPC_PORT") do
      nil -> 50_051
      port -> String.to_integer(port)
    end
  end
end
