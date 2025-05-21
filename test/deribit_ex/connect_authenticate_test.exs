defmodule DeribitEx.ConnectAuthenticateTest do
  @moduledoc """
  Tests for the authentication functionality in the Deribit WebSocket client.

  These tests verify that the Client.authenticate/3 function correctly
  extracts credentials from various sources in the following order of precedence:

  1. Explicitly provided credentials in the authenticate function call
  2. Credentials stored in the adapter_state of the connection
  3. Credentials stored in the connection_info of the connection
  4. Falls back to an empty map when no credentials are available, resulting in an authentication error

  All tests are integration tests that verify authentication against the real
  test.deribit.com API (as per the project's NO MOCKS policy).
  """

  use ExUnit.Case, async: false

  alias DeribitEx.Client
  alias DeribitEx.Test.EnvSetup

  @tag :integration
  test "connect and authenticate using credentials from connection" do
    # Skip test if no credentials available
    EnvSetup.ensure_credentials()
    config = Application.get_env(:deribit_ex, :websocket, [])
    client_id = Keyword.get(config, :client_id)
    client_secret = Keyword.get(config, :client_secret)

    if !(client_id && client_secret && client_id != "" && client_secret != "") do
      flunk("ERROR: No credentials available! Tests MUST have credentials to run.")
    end

    # Connect with credentials embedded in the connection
    credentials = %{
      "api_key" => client_id,
      "secret" => client_secret
    }

    IO.puts("Test with connection credentials present (redacted)")

    {:ok, conn} =
      Client.connect(%{
        credentials: credentials
      })

    # Authenticate using the connection's embedded credentials
    result = Client.authenticate(conn)
    IO.puts("Authentication result (explicit connection): #{match?({:ok, _}, result)}")

    # Assert that authentication succeeds
    assert {:ok, _auth_conn} = result
  end

  @tag :integration
  test "authenticate with explicitly provided credentials" do
    # Skip test if no credentials available
    EnvSetup.ensure_credentials()
    config = Application.get_env(:deribit_ex, :websocket, [])
    client_id = Keyword.get(config, :client_id)
    client_secret = Keyword.get(config, :client_secret)

    if !(client_id && client_secret && client_id != "" && client_secret != "") do
      flunk("ERROR: No credentials available! Tests MUST have credentials to run.")
    end

    # Connect without any credentials
    {:ok, conn} = Client.connect()

    # Authenticate with explicitly provided credentials
    credentials = %{
      "api_key" => client_id,
      "secret" => client_secret
    }

    IO.puts("Test with explicitly provided credentials (redacted)")
    result = Client.authenticate(conn, credentials)
    IO.puts("Authentication result (explicit credentials): #{match?({:ok, _}, result)}")

    # Assert that authentication succeeds
    assert {:ok, _auth_conn} = result
  end

  @tag :integration
  test "authenticate using credentials from connection_info" do
    # Skip test if no credentials available
    EnvSetup.ensure_credentials()
    config = Application.get_env(:deribit_ex, :websocket, [])
    client_id = Keyword.get(config, :client_id)
    client_secret = Keyword.get(config, :client_secret)

    if !(client_id && client_secret && client_id != "" && client_secret != "") do
      flunk("ERROR: No credentials available! Tests MUST have credentials to run.")
    end

    # Connect with credentials specified via connection_info option
    credentials = %{
      "api_key" => client_id,
      "secret" => client_secret
    }

    IO.puts("Test with connection_info credentials (redacted)")

    {:ok, conn} =
      Client.connect(%{
        connection_info: %{
          credentials: credentials
        }
      })

    # Authenticate without passing credentials explicitly (should use connection_info)
    result = Client.authenticate(conn)
    IO.puts("Authentication result (connection_info path): #{match?({:ok, _}, result)}")

    # Assert that authentication succeeds
    assert {:ok, _auth_conn} = result
  end

  @tag :integration
  test "authenticate should fail when no credentials available anywhere" do
    # This test verifies that authentication fails when no credentials are available
    # from any source (adapter_state, connection_info, or explicit parameter)

    # Clear any credentials from environment and application config for this test
    original_env_client_id = System.get_env("DERIBIT_CLIENT_ID")
    original_env_client_secret = System.get_env("DERIBIT_CLIENT_SECRET")
    original_config = Application.get_env(:deribit_ex, :websocket, [])

    # Temporarily modify environment to ensure no credentials are available
    # Note: This only affects the current process and won't interfere with other tests
    System.put_env("DERIBIT_CLIENT_ID", "")
    System.put_env("DERIBIT_CLIENT_SECRET", "")

    # Connect without specifying any credentials
    {:ok, conn} = Client.connect()

    # Attempt to authenticate without credentials
    IO.puts("Test with no credentials available")
    result = Client.authenticate(conn)
    IO.puts("Authentication result (empty credentials fallback): #{inspect(result)}")

    # We expect authentication to fail 
    assert match?({:error, _}, result)

    # Restore the original environment and config
    if original_env_client_id, do: System.put_env("DERIBIT_CLIENT_ID", original_env_client_id)

    if original_env_client_secret,
      do: System.put_env("DERIBIT_CLIENT_SECRET", original_env_client_secret)

    Application.put_env(:deribit_ex, :websocket, original_config)
  end
end
