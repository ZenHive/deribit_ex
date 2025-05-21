# A script to debug and test Deribit heartbeat handling
# Run with: mix run test/integration/heartbeat_debug.exs

defmodule HeartbeatDebug do
  require Logger

  @doc """
  Run a test to verify the heartbeat implementation
  connecting to the Deribit API and ensuring the connection
  stays alive through multiple heartbeat cycles.
  """
  def run do
    # Configure Logger to display all debug messages
    Logger.configure(level: :debug)
    Logger.info("Starting Deribit heartbeat debug test")
    
    # Connect to Deribit API
    {:ok, conn} = DeribitEx.Client.connect()
    Logger.info("Successfully connected to Deribit API")
    
    # Enable heartbeat with 10 second interval (minimum allowed)
    # This should trigger test_request messages from Deribit
    {:ok, _} = DeribitEx.Client.set_heartbeat(conn, 10)
    Logger.info("Enabled heartbeat with 10 second interval")
    
    # Wait for 60 seconds to see multiple heartbeat cycles
    # This should be enough to observe test_request heartbeats and responses
    wait_duration = 60_000
    Logger.info("Waiting for #{wait_duration} ms to observe heartbeat cycles...")
    
    # Sleep for a while with periodic status checks
    Enum.reduce(1..12, 0, fn i, acc -> 
      Process.sleep(5_000)
      elapsed = acc + 5_000
      
      # Make a simple API call to verify connection is still alive
      case DeribitEx.Client.test(conn) do
        {:ok, _} -> 
          Logger.info("Connection active at #{elapsed} ms")
          elapsed
        error -> 
          Logger.error("Connection error at #{elapsed} ms: #{inspect(error)}")
          elapsed
      end
    end)
    
    # Disable heartbeat before disconnecting
    {:ok, _} = DeribitEx.Client.disable_heartbeat(conn)
    Logger.info("Disabled heartbeat")
    
    # Disconnect cleanly
    DeribitEx.Client.disconnect(conn)
    Logger.info("Disconnected from Deribit API")
    
    Logger.info("Heartbeat debug test completed successfully")
  end
end

# Run the test
HeartbeatDebug.run()
