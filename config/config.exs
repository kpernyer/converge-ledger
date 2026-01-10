# General application configuration
import Config

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Libcluster configuration
config :libcluster,
  topologies: [
    converge_ledger: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: []] # In dev, we can pass hosts manually or rely on local discovery
    ]
  ]

# Import environment specific config
import_config "#{config_env()}.exs"
