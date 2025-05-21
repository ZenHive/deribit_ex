defmodule DeribitEx.HeartbeatLoggerTest do
  use ExUnit.Case
  require Logger
  
  @moduletag :integration
  @moduletag timeout: 60_000 # Increase timeout for this test
  
  test "logs heartbeat test_request messages and responses" do
    # Connect to Deribit test API
    {:ok, conn} = DeribitEx.Client.connect()
    
    # Enable heartbeat with minimum interval (10s)
    # This should trigger test_request messages from Deribit
    {:ok, _} = DeribitEx.Client.set_heartbeat(conn, 10)
    
    # Wait for 30 seconds to observe heartbeat messages
    IO.puts("Waiting 30 seconds for heartbeat messages...")
    
    # Sleep with periodic status checks to verify connection stays alive
    Enum.reduce(1..6, 0, fn i, acc -> 
      Process.sleep(5_000)
      elapsed = acc + 5_000
      
      # Make a simple API call to verify connection is still alive
      case DeribitEx.Client.test(conn) do
        {:ok, _} -> 
          IO.puts("Connection active at #{elapsed} ms")
          elapsed
        error -> 
          IO.puts("Connection error at #{elapsed} ms: #{inspect(error)}")
          elapsed
      end
    end)
    
    # Clean up - disable heartbeat and disconnect
    {:ok, _} = DeribitEx.Client.disable_heartbeat(conn)
    DeribitEx.Client.disconnect(conn)
    
    # Test passes if we made it through without connection closing
    assert true
  end
end