require Logger

## Configure Logger to only show warnings and errors
Logger.configure(level: :none)
# Logger.configure(level: :info)
# Logger.configure(level: :warning)
# Logger.configure(level: :debug)

ExUnit.start()

# Make sure we load our test support code first
Code.require_file("support/env_setup.ex", __DIR__)

# Run EnvSetup to ensure credentials are loaded
DeribitEx.Test.EnvSetup.ensure_credentials()

# Double-check that we loaded credentials and abort tests if missing
websocket_config = Application.get_env(:deribit_ex, :websocket, [])
client_id = Keyword.get(websocket_config, :client_id)
client_secret = Keyword.get(websocket_config, :client_secret)

# Ensure credentials are present in config - if not, raise an error
if !client_id || !client_secret do
  raise "FATAL: No credentials found in application config. Please set up environment variables."
end

# Display credentials check message
Logger.info("""
\n[✓] CREDENTIALS CHECK [✓]
--------------------------------------------------
Using credentials for Deribit API tests:
Client ID (first 4 chars): #{String.slice(client_id || "", 0, 4)}...
Client Secret: #{if client_secret, do: "provided", else: "MISSING"}
Host: #{Keyword.get(websocket_config, :host, "test.deribit.com")}
--------------------------------------------------
\n
""")

# Display testing policy message
Logger.warning("""
\n[!] TESTING POLICY [!]
--------------------------------------------------
DO NOT USE MOCKS! They are proven to be unreliable.
ALWAYS test against real test APIs (e.g., test.deribit.com).
If no test API is available, use real API.

NEVER SKIP TESTS because you can not find CREDENTIALS. Credentials
must be always present. LET THEM FAIL.
--------------------------------------------------
\n
""")

# Disable automatic time sync during tests
Application.put_env(
  :deribit_ex,
  :websocket,
  :deribit_ex
  |> Application.get_env(:websocket, [])
  |> Keyword.put(:time_sync, enabled: false, auto_sync_on_connect: false)
)
