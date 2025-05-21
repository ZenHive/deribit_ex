defmodule DeribitEx.ReconnectMonitorTest do
  use ExUnit.Case
  require Logger
  
  @moduletag :integration
  @moduletag timeout: 20_000 # Increase timeout for extended monitoring
  
  test "monitors reconnections when heartbeat is enabled" do
    # Configure logger for detailed connection info
    Logger.configure(level: :debug)
    
    # Create an agent to track reconnection events
    {:ok, agent} = Agent.start_link(fn -> [] end)
    
    # Connect to Deribit test API
    {:ok, conn} = DeribitEx.Client.connect()
    
    # Register a process to monitor connection events
    # Extract the actual connection process PID from the ClientConn struct
    conn_pid = if is_pid(conn) do
      conn
    else
      Map.get(conn, :transport_pid)
    end
    
    # Now monitor the actual process
    Process.monitor(conn_pid)
    
    # Monitor our client for disconnection/reconnection
    spawn_link(fn -> 
      monitor_client(conn, agent, 90_000)
    end)
    
    # Enable heartbeat with minimum interval (10s)
    # This should trigger test_request messages from Deribit
    {:ok, _} = DeribitEx.Client.set_heartbeat(conn, 10)
    
    # Wait for a while to give time for Deribit to send heartbeat messages
    # and potentially close the connection if we fail to respond properly
    IO.puts("Monitoring connection for 90 seconds...")
    
    # Keep connection alive with periodic operations and status checks
    Enum.reduce(1..18, 0, fn _i, acc -> 
      Process.sleep(5_000)
      elapsed = acc + 5_000
      
      # Check current reconnection count
      reconnect_count = Agent.get(agent, fn list -> length(list) end)
      
      # Make a simple API call to verify connection is still alive
      case DeribitEx.Client.test(conn) do
        {:ok, _} -> 
          IO.puts("Connection active at #{elapsed} ms, reconnects: #{reconnect_count}")
          elapsed
        error -> 
          IO.puts("Connection error at #{elapsed} ms: #{inspect(error)}, reconnects: #{reconnect_count}")
          elapsed
      end
    end)
    
    # Check final reconnection count
    reconnections = Agent.get(agent, fn list -> list end)
    reconnect_count = length(reconnections)
    
    # Clean up - disable heartbeat and disconnect
    {:ok, _} = DeribitEx.Client.disable_heartbeat(conn)
    DeribitEx.Client.disconnect(conn)
    Agent.stop(agent)
    
    # Log the reconnection information
    if reconnect_count > 0 do
      IO.puts("⚠️ Connection experienced #{reconnect_count} reconnects at:")
      Enum.each(reconnections, fn timestamp -> 
        IO.puts("  - #{format_timestamp(timestamp)}")
      end)
    else
      IO.puts("✅ Connection remained stable with no reconnects")
    end
    
    # Our test should assert that we maintained a stable connection
    assert reconnect_count == 0, "Connection reconnected #{reconnect_count} times"
  end
  
  # Helper to monitor the client for reconnections
  defp monitor_client(_client_pid, agent, timeout) do
    receive do
      {:DOWN, _ref, :process, _pid, reason} ->
        # Record the reconnection timestamp
        Agent.update(agent, fn list -> [System.system_time(:millisecond) | list] end)
        IO.puts("⚠️ Client process went down: #{inspect(reason)}")
    after
      timeout ->
        # Timeout without reconnection
        :ok
    end
  end
  
  # Format a timestamp for readable output
  defp format_timestamp(timestamp) do
    {:ok, datetime} = DateTime.from_unix(timestamp, :millisecond)
    Calendar.strftime(datetime, "%H:%M:%S.%f")
  end
end