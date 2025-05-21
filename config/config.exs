import Config

config :deribit_ex,
  websocket: [
    host: "test.deribit.com",
    auth_refresh_threshold: 180,
    time_sync: [
      enabled: true,
      auto_sync_on_connect: true,
      sync_interval: 3600_000  # 1 hour
    ],
    rate_limit_mode: :normal  # :cautious, :normal, or :aggressive
  ]

# Optional dev configuration
if config_env() == :dev do
  config :deribit_ex,
    websocket: [
      client_id: System.get_env("DERIBIT_CLIENT_ID"),
      client_secret: System.get_env("DERIBIT_CLIENT_SECRET")
    ]
end

# Test-specific configuration
if config_env() == :test do
  config :deribit_ex,
    websocket: [
      time_sync: [
        enabled: false,
        auto_sync_on_connect: false
      ]
    ]
end
