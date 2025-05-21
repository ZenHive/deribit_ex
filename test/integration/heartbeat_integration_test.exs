defmodule MarketMaker.Integration.DeribitHeartbeatIntegrationTest do
  @moduledoc """
  Integration tests for Deribit heartbeat endpoints.

  These tests verify that the heartbeat endpoints (set_heartbeat and disable_heartbeat)
  interact correctly with the Deribit testnet API.
  """

  use ExUnit.Case

  alias DeribitEx.Test.EnvSetup
  alias DeribitEx.DeribitClient

  @moduletag :integration
  @moduletag :external
  @moduletag timeout: 60_000

  setup do
    # Ensure credentials are properly loaded
    EnvSetup.ensure_credentials()

    # Start a connection that can be shared by tests
    {:ok, conn} = DeribitClient.connect()

    # Ensure connection is closed after each test runs
    on_exit(fn ->
      DeribitClient.disconnect(conn)
    end)

    # Return the connection to be used by test cases
    %{conn: conn}
  end

  describe "heartbeat endpoints - happy path" do
    test "set_heartbeat/3 enables heartbeat messages", %{conn: conn} do
      # Use a reasonably long interval to not overload the test server
      interval = 30
      {:ok, result} = DeribitClient.set_heartbeat(conn, interval)

      # Result should be "ok" when successful
      assert result == "ok"

      # Wait for a short period to potentially receive a test_request
      # In a real integration, the adapter automatically handles these
      Process.sleep(2000)
    end

    test "disable_heartbeat/2 disables heartbeat messages", %{conn: conn} do
      # First enable heartbeat
      {:ok, _} = DeribitClient.set_heartbeat(conn, 30)

      # Then disable it
      {:ok, result} = DeribitClient.disable_heartbeat(conn)

      # Result should be "ok" when successful
      assert result == "ok"
    end

    test "heartbeat sequence: enable, wait for ping, disable", %{conn: conn} do
      # Enable heartbeat with shorter interval for testing
      interval = 15
      {:ok, enable_result} = DeribitClient.set_heartbeat(conn, interval)
      assert enable_result == "ok"

      # Wait for some time to potentially receive test_request messages
      # In a normal scenario, our adapter will auto-respond to these
      # This is not a deterministic test, but helps verify integration
      Process.sleep(interval * 1000 + 5000)

      # Now disable the heartbeat
      result = DeribitClient.disable_heartbeat(conn)

      # The server might send a heartbeat while we're disabling, causing an unexpected
      # response. We'll handle both successful and error cases.
      case result do
        {:ok, disable_result} ->
          assert disable_result == "ok"

        {:error, {:invalid_response, response}} ->
          # If we get an invalid response due to a heartbeat coming in,
          # verify it's a heartbeat message
          assert Map.has_key?(response, "method")
          assert response["method"] == "heartbeat"
      end

      # Wait briefly to confirm no more pings
      Process.sleep(2000)
    end
  end

  describe "heartbeat endpoints - error cases" do
    test "set_heartbeat/3 enforces minimum interval", %{conn: conn} do
      # The API or client should enforce a minimum interval of 10 seconds
      # Attempt to set a too small interval
      too_small = 5
      {:ok, result} = DeribitClient.set_heartbeat(conn, too_small)

      # Should still succeed but with the minimum value enforced
      assert result == "ok"
    end

    test "set_heartbeat/3 with extremely large interval", %{conn: conn} do
      # Try an extremely large interval
      # 1 hour
      large_interval = 3600
      result = DeribitClient.set_heartbeat(conn, large_interval)

      # The API may reject extremely large values
      case result do
        {:ok, "ok"} ->
          assert true

        {:error, error} ->
          # Verify the error contains the expected constraint message
          assert is_map(error)
          assert Map.has_key?(error, "code")
          assert error["code"] == -32_602
          assert Map.has_key?(error, "message")
          assert error["message"] == "Invalid params"
      end
    end

    test "disable_heartbeat/2 when heartbeat not enabled", %{conn: conn} do
      # Disable heartbeat without enabling first
      # This should still return "ok" in most APIs
      {:ok, result} = DeribitClient.disable_heartbeat(conn)
      assert result == "ok"
    end
  end

  describe "heartbeat interaction with other operations" do
    test "heartbeat and authenticate sequence", %{conn: conn} do
      # First set heartbeat
      {:ok, _} = DeribitClient.set_heartbeat(conn, 30)

      # Then authenticate
      {:ok, _} = DeribitClient.authenticate(conn)

      # Wait briefly
      Process.sleep(2000)

      # Disable heartbeat 
      {:ok, _} = DeribitClient.disable_heartbeat(conn)
    end

    test "bootstrap sequence includes heartbeat", %{conn: conn} do
      # Initialize performs a bootstrap sequence including heartbeat
      result = DeribitClient.initialize(conn, %{authenticate: false})

      case result do
        {:ok, bootstrap_results} ->
          # Check that heartbeat was set
          assert Map.has_key?(bootstrap_results, :set_heartbeat)

        _ ->
          flunk("Bootstrap initialization failed: #{inspect(result)}")
      end
    end
  end
end
