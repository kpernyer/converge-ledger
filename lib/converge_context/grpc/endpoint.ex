defmodule ConvergeContext.Grpc.Endpoint do
  @moduledoc """
  gRPC endpoint for ConvergeContext.

  Exposes the ContextService for external communication.
  """

  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger)

  run(ConvergeContext.Grpc.Server)
end
