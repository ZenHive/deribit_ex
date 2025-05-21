# This file contains ACTUAL credentials and should NEVER be committed
# It's automatically added to .gitignore

# Set credentials directly
client_id = "UMFboFY2"
client_secret = "Oaehkq5mnBhZiVLIrjElvSTGBJtFNDEzyQt6JCd1UDE"
host = "test.deribit.com"

# Set in environment variables
System.put_env("DERIBIT_CLIENT_ID", client_id)
System.put_env("DERIBIT_CLIENT_SECRET", client_secret)
System.put_env("DERIBIT_HOST", host)

# Also set directly in application config
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

# Log that we're using the local credentials file
IO.puts("Using LOCAL credentials from .force_credentials.local.exs - Client ID: #{String.slice(client_id, 0, 4)}...")
IO.puts("Application config credentials are now set directly")
