# Production configuration
import Config

# Use info level logging in production
config :logger, level: :info

# Configure libcluster with Gossip strategy for VPC communication
config :libcluster,
  topologies: [
    converge_context: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_addr: "230.1.1.251",
        # Broadcast only works if multicast is supported in the VPC.
        # Ensure your VPC allows UDP traffic on this port.
        broadcast_only: true
      ]
    ]
  ]