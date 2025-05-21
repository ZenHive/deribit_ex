defmodule DeribitEx.Test.EnvSetup do
  @moduledoc """
  Helper module to ensure environment variables are properly loaded for tests.
  This addresses the issue where System.get_env() in config files doesn't
  always get evaluated at runtime.

  The module also handles automatic credential detection from multiple
  environment variable formats:
  - DERIBIT_CLIENT_ID / DERIBIT_CLIENT_SECRET
  - DERIBIT_API_KEY / DERIBIT_API_SECRET  
  - DERIBIT_TESTNET_KEY / DERIBIT_TESTNET_SECRET
  """

  @doc """
  Ensures the environment variables are correctly loaded into application configuration.
  Call this in your test setup functions.
  """
  def ensure_credentials do
    # First check if credentials are already in the application config
    current_config = Application.get_env(:deribit_ex, :websocket, [])
    config_id = Keyword.get(current_config, :client_id)
    config_secret = Keyword.get(current_config, :client_secret)

    # Also check environment variables
    env_id = System.get_env("DERIBIT_CLIENT_ID")
    env_secret = System.get_env("DERIBIT_CLIENT_SECRET")

    # Try API key variables if client variables aren't set
    api_id = System.get_env("DERIBIT_API_KEY")
    api_secret = System.get_env("DERIBIT_API_SECRET")

    # Or testnet credentials if those are available
    testnet_id = System.get_env("DERIBIT_TESTNET_KEY")
    testnet_secret = System.get_env("DERIBIT_TESTNET_SECRET")

    # Use the first available credentials
    client_id = env_id || config_id || api_id || testnet_id
    client_secret = env_secret || config_secret || api_secret || testnet_secret
    host = System.get_env("DERIBIT_HOST") || "test.deribit.com"

    # Force credentials to be available for tests
    if client_id && client_secret do
      require Logger
      # Set them directly in the application env
      updated_config =
        Keyword.merge(current_config,
          client_id: client_id,
          client_secret: client_secret,
          host: host,
          auth_refresh_threshold: 180
        )

      Application.put_env(:deribit_ex, :websocket, updated_config)

      # Log where credentials were found
      Logger.info("Credentials found and set in application config")

      true
    else
      # CRITICAL: Tests MUST have credentials
      require Logger

      Logger.error("""

      [CRITICAL ERROR] No valid credentials found in environment or application config.
      Tests MUST have credentials to run. The following environment variables should be set:

      DERIBIT_CLIENT_ID=your_client_id
      DERIBIT_CLIENT_SECRET=your_client_secret

      Or alternate formats:
      - DERIBIT_API_KEY / DERIBIT_API_SECRET
      - DERIBIT_TESTNET_KEY / DERIBIT_TESTNET_SECRET

      Please set these environment variables and try again.
      """)

      raise "No test credentials available - please provide API credentials"
    end
  end
end
