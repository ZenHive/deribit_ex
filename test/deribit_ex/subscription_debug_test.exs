defmodule MarketMaker.WS.SubscriptionDebugTest do
  use ExUnit.Case

  alias MarketMaker.WS.DeribitClient

  require Logger

  @tag :debug
  test "debug subscription flow" do
    test_pid = self()

    # Track all messages we receive
    callback = fn frame ->
      Logger.info("Received frame: #{inspect(frame)}")
      send(test_pid, {:ws_frame, frame})
      :ok
    end

    Logger.info("Starting connection...")

    {:ok, conn} =
      DeribitClient.connect(%{
        callback_pid: test_pid,
        ws_recv_callback: callback
      })

    # Wait for connection up
    assert_receive {:websockex_nova, {:connection_up, :http}}, 5000
    Logger.info("Connection is up")

    # Try a simple time request first
    Logger.info("Sending get_time request...")
    {:ok, time_response} = DeribitClient.json_rpc(conn, "public/get_time", %{})
    Logger.info("Time response: #{inspect(time_response)}")

    # Now try a subscription
    Logger.info("Attempting subscription...")

    instrument = "BTC-PERPETUAL"
    channel = "ticker.#{instrument}.100ms"

    # Manually create the subscription message
    sub_msg = %{
      "jsonrpc" => "2.0",
      "id" => 123,
      "method" => "public/subscribe",
      "params" => %{
        "channels" => [channel]
      }
    }

    Logger.info("Sending subscription: #{inspect(sub_msg)}")

    # Send the subscription directly
    {:ok, sub_response} =
      DeribitClient.json_rpc(conn, "public/subscribe", %{
        "channels" => [channel]
      })

    Logger.info("Subscription response: #{inspect(sub_response)}")

    # Wait for subscription data
    Logger.info("Waiting for subscription data...")

    receive do
      {:ws_frame, frame} ->
        Logger.info("Received subscription frame: #{inspect(frame)}")

      msg ->
        Logger.info("Received other message: #{inspect(msg)}")
    after
      5000 ->
        Logger.info("No subscription data received")
    end

    # Clean up
    DeribitClient.disconnect(conn)
  end
end
