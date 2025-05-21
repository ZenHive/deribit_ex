defmodule DeribitEx.DirectHeartbeatTest do
  use ExUnit.Case
  
  @moduletag :integration
  @moduletag timeout: 60_000 # Increase timeout for this test
  
  test "connection stays alive through heartbeat cycles with direct frame handler" do
    # Connect to Deribit test API
    {:ok, conn} = DeribitEx.Client.connect()
    
    # Enable heartbeat with minimum interval (10s)
    {:ok, _} = DeribitEx.Client.set_heartbeat(conn, 10)
    
    # Keep the connection alive for 45 seconds, which should be
    # enough time to receive multiple test_request heartbeats
    wait_with_checks(conn, 45_000)
    
    # Verify we can still make API calls after the wait period
    assert {:ok, _} = DeribitEx.Client.test(conn)
    
    # Clean up - disable heartbeat and disconnect
    {:ok, _} = DeribitEx.Client.disable_heartbeat(conn)
    DeribitEx.Client.disconnect(conn)
  end
  
  # Helper function to wait with periodic connection checks
  defp wait_with_checks(conn, total_duration_ms) do
    interval_ms = 5_000 # Check every 5 seconds
    iterations = div(total_duration_ms, interval_ms)
    
    Enum.each(1..iterations, fn i ->
      # Sleep for the interval
      Process.sleep(interval_ms)
      
      # Check connection is still alive with a simple API call
      elapsed_ms = i * interval_ms
      assert {:ok, _} = DeribitEx.Client.test(conn)
      IO.puts("Connection check passed at #{elapsed_ms} ms")
    end)
  end
end
