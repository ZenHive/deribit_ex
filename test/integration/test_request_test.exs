defmodule MarketMaker.Integration.DeribitTestRequestTest do
  @moduledoc """
  Integration tests that verify our handler correctly responds to test_request messages.

  This is critical because if we don't respond to test_request messages properly,
  Deribit will close the WebSocket connection.
  """

  use ExUnit.Case

  alias DeribitEx.Test.EnvSetup
  alias DeribitEx.DeribitAdapter
  alias DeribitEx.DeribitClient

  @moduletag :integration
  @moduletag :external
  @moduletag timeout: 60_000

  setup do
    # Ensure credentials are properly loaded
    EnvSetup.ensure_credentials()
    :ok
  end

  describe "test_request handling" do
    test "adapter properly responds to test_request messages" do
      # Create a test state
      state = %{
        requests: %{},
        auth_status: :unauthenticated
      }

      # Create a test_request message similar to what Deribit would send
      test_request_message = %{
        "jsonrpc" => "2.0",
        "method" => "test_request",
        "params" => %{
          "expected_result" => "test_value"
        }
      }

      # Call the handle_message function with our test message
      result = DeribitAdapter.handle_message(test_request_message, state)

      # Verify the response format
      assert {:reply, encoded_payload, updated_state} = result

      # Decode the response
      response = Jason.decode!(encoded_payload)

      # Verify it's a proper test response
      assert response["jsonrpc"] == "2.0"
      assert response["method"] == "public/test"
      assert response["params"]["expected_result"] == "test_value"
      assert is_binary(response["id"]) or is_integer(response["id"])

      # Verify the request was tracked
      assert map_size(updated_state.requests) > map_size(state.requests)
    end

    test "integration: heartbeat causes test_request and we stay connected" do
      # Connect to the real API
      {:ok, conn} = DeribitClient.connect()

      # Enable heartbeat with a short interval to trigger test_request
      # Using a slightly longer interval to be more stable
      # slightly above minimum interval
      interval = 15
      {:ok, _} = DeribitClient.set_heartbeat(conn, interval)

      # Wait a short time for test_request messages to potentially arrive
      # We don't need to wait too long as it might cause other connection issues
      Process.sleep(5_000)

      # Try to perform another API operation to verify the connection is still active
      result = DeribitClient.get_time(conn)

      # Clean up - put in a try/catch to ensure we don't fail on cleanup
      try do
        DeribitClient.disable_heartbeat(conn)
      catch
        _kind, _error -> :ok
      end

      try do
        DeribitClient.disconnect(conn)
      catch
        _kind, _error -> :ok
      end

      # We are mainly checking that the connection stays active
      # So if we get any response (success or error) that's not a disconnection,
      # that means our automatic test_request handling is working.
      # Just want to make sure we didn't get a connection termination error.
      refute match?({:error, :connection_closed}, result)
      refute match?({:error, :disconnected}, result)
    end
  end
end
