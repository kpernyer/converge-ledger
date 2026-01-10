defmodule ConvergeLedger.Grpc.Endpoint do
  @moduledoc """
  gRPC endpoint for ConvergeLedger.

  Exposes the ContextService for external communication.
  """

  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger)

  run(ConvergeLedger.Grpc.Server)
end
