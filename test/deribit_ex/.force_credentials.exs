# This file is loaded before running tests to force credentials to be available
# If credentials are not available, the tests will fail
#
# IMPORTANT: NEVER COMMIT THIS FILE WITH ACTUAL CREDENTIALS
# This is a template - copy this to .force_credentials.local.exs and add your credentials there
# .force_credentials.local.exs should be in .gitignore

# Get existing environment variables first
existing_client_id = System.get_env("DERIBIT_CLIENT_ID")
existing_client_secret = System.get_env("DERIBIT_CLIENT_SECRET")
existing_host = System.get_env("DERIBIT_HOST") || "test.deribit.com"

# You should replace these placeholder values with real credentials in your local copy
# DO NOT modify these values in the committed version of this file
client_id = existing_client_id || "REPLACE_WITH_YOUR_CLIENT_ID"
client_secret = existing_client_secret || "REPLACE_WITH_YOUR_CLIENT_SECRET"
host = existing_host

# Set credentials in environment variables if not already set
if !existing_client_id || existing_client_id == "" do
  System.put_env("DERIBIT_CLIENT_ID", client_id)
end

if !existing_client_secret || existing_client_secret == "" do
  System.put_env("DERIBIT_CLIENT_SECRET", client_secret)
end

System.put_env("DERIBIT_HOST", host)

# Also directly set the values in application config to ensure they're available
# This handles cases where the env vars aren't being properly loaded into config
current_config = Application.get_env(:market_maker, :websocket, [])

Application.put_env(
  :market_maker,
  :websocket,
  Keyword.merge(current_config,
    client_id: client_id,
    client_secret: client_secret,
    host: host,
    auth_refresh_threshold: 180
  )
)

# Log the credentials (safely)
IO.puts("Forced credentials from .force_credentials.exs - Client ID: #{String.slice(client_id || "", 0, 4)}...")
IO.puts("Application config credentials are now set directly")
