defmodule DeribitEx.SimpleConnectionTest do
  use ExUnit.Case

  alias DeribitEx.DeribitClient

  @doc """
  Basic smoke test to verify WebSocket connection and JSON-RPC communication work.
  """
  test "can connect and send JSON-RPC requests" do
    # Create a connection
    test_pid = self()

    {:ok, conn} =
      DeribitClient.connect(%{
        callback_pid: test_pid,
        ws_recv_callback: fn frame ->
          send(test_pid, {:ws_frame, frame})
          :ok
        end
      })

    # Wait for connection to be ready
    assert_receive {:websockex_nova, {:connection_up, :http}}, 5000

    # Send a simple request
    {:ok, response} = DeribitClient.json_rpc(conn, "public/get_time", %{})

    # Parse and verify response
    decoded = Jason.decode!(response)
    assert decoded["jsonrpc"] == "2.0"
    assert Map.has_key?(decoded, "result")
    assert is_integer(decoded["result"])

    # Clean up
    DeribitClient.disconnect(conn)
  end

  test "can authenticate with valid credentials" do
    # Skip if no credentials are available
    api_key = System.get_env("DERIBIT_CLIENT_ID")
    secret = System.get_env("DERIBIT_CLIENT_SECRET")

    if api_key && secret && api_key != "" && secret != "" do
      {:ok, conn} = DeribitClient.connect()

      # Wait for connection
      receive do
        {:websockex_nova, {:connection_up, :http}} -> :ok
      after
        5000 -> throw(:connection_timeout)
      end

      # Authenticate
      {:ok, auth_response} = DeribitClient.authenticate(conn)

      # Verify authentication
      decoded = Jason.decode!(auth_response)
      assert decoded["result"]["access_token"]
      assert decoded["result"]["expires_in"] > 0

      DeribitClient.disconnect(conn)
    else
      :skipped
    end
  end
end
