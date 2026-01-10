# Runtime configuration
#
# This file is executed at runtime, not compile time.
# Use for environment variable configuration.
import Config

# gRPC port configuration
# Default: 50051
# Override: GRPC_PORT environment variable
#
# Note: The port is read directly in Application.start/2
# to ensure it's available before the gRPC server starts.
