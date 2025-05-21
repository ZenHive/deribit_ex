# defmodule DeribitEx.ConnectionDiagnosticTest do
#   use ExUnit.Case, async: false

#   alias DeribitEx.Adapter
#   alias DeribitEx.Client
#   alias WebsockexNova.Client

#   @moduletag :debug

#   test "debug connection error with telemetry capture" do
#     # Setup telemetry listener to capture events
#     :telemetry.attach_many(
#       "connection-test-handler",
#       [
#         [:deribit_ex, :client, :connect, :failure],
#         [:deribit_ex, :adapter, :auth_refresh_config],
#         [:deribit_ex, :connection, :opened],
#         [:deribit_ex, :connection, :closed]
#       ],
#       &handle_event/4,
#       nil
#     )

#     # Connection options with verbose logging
#     opts = %{
#       callback_pid: self(),
#       log_level: :debug,
#       ws_recv_callback: fn frame ->
#         IO.inspect(frame, label: "WebSocket Frame")
#         send(self(), {:ws_frame, frame})
#         :ok
#       end
#     }

#     # Check the connection info before connecting
#     {:ok, connection_info} = Adapter.connection_info(opts)
#     IO.inspect(connection_info, label: "Connection Info")

#     # Try to connect
#     result = Client.connect(opts)
#     IO.inspect(result, label: "Connection Result")

#     # Log error details for debugging
#     case result do
#       {:error, error} ->
#         IO.inspect(error, label: "Error Details")

#         # Get more details if it's a WebSocket error
#         if is_tuple(error) and elem(error, 0) == :websocket_error do
#           IO.inspect(elem(error, 1), label: "WebSocket Error Code")
#           IO.inspect(elem(error, 2), label: "WebSocket Error Reason")
#         end

#       _ ->
#         :ok
#     end

#     # Wait for events from telemetry
#     Process.sleep(1000)

#     # If we got a connection, test a simple command
#     if match?({:ok, _}, result) do
#       {:ok, conn} = result
#       ping_result = Client.ping(conn)
#       IO.inspect(ping_result, label: "Ping Result")

#       # Try a simple API call
#       time_result = Client.get_time(conn)
#       IO.inspect(time_result, label: "Get Time Result")

#       # Disconnect
#       Client.disconnect(conn)
#     end

#     # Cleanup telemetry handler
#     :telemetry.detach("connection-test-handler")

#     # Always pass this test - we're just gathering diagnostic info
#     assert true
#   end

#   # Telemetry event handler
#   defp handle_event(event, measurements, metadata, _config) do
#     IO.puts("Telemetry Event: #{inspect(event)}")
#     IO.inspect(measurements, label: "Measurements")
#     IO.inspect(metadata, label: "Metadata")
#   end
# end
