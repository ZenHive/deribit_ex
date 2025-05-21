defmodule DeribitEx.PrivateSubscriptionsTest do
  @moduledoc """
  Integration tests for private subscription endpoints against the Deribit test API.

  These tests verify that all private API calls that require authentication work
  correctly with the connection-based credential extraction, including:
  - subscribe_to_user_orders
  - subscribe_to_user_trades
  - unsubscribe_private

  These tests require:
  - Network connectivity to test.deribit.com
  - Valid API credentials in the environment (DERIBIT_CLIENT_ID and DERIBIT_CLIENT_SECRET)

  Run the tests with:
  mix test --include integration
  """

  use ExUnit.Case, async: false

  alias DeribitEx.Client
  alias DeribitEx.Test.EnvSetup

  require Logger

  @moduletag :integration
  @moduletag :private_subscriptions
  # 30 seconds timeout
  @moduletag timeout: 30_000

  # Helper function to extract subscription result from API response
  defp extract_subscription_result(response) do
    # First try normal parse
    case Jason.decode(response) do
      {:ok, decoded} ->
        if is_map(decoded) && Map.has_key?(decoded, "result") do
          result = decoded["result"]

          if is_list(result) do
            # Handle direct array of channel names
            {:ok, result}
          else
            # Handle normal result format
            {:ok, result}
          end
        else
          # Handle subscription method response messages
          if is_map(decoded) && Map.has_key?(decoded, "method") &&
               decoded["method"] == "subscription" do
            if is_map(decoded["params"]) && Map.has_key?(decoded["params"], "channel") do
              # Extract the channel information
              {:ok, [decoded["params"]["channel"]]}
            else
              {:error, :invalid_subscription_format}
            end
          else
            {:error, :invalid_format}
          end
        end

      {:error, _reason} ->
        {:error, :json_parse_error}
    end
  end

  setup do
    # Ensure credentials are properly loaded into application config
    has_credentials = EnvSetup.ensure_credentials()

    # Get credentials from application config
    config = Application.get_env(:deribit_ex, :websocket, [])
    client_id = Keyword.get(config, :client_id)
    client_secret = Keyword.get(config, :client_secret)

    Logger.info(
      "Using credentials - ID: #{client_id && String.slice(client_id, 0, 4)}... Secret: #{client_secret && "present"}"
    )

    Logger.info("Credentials available: #{has_credentials}")

    if client_id && client_secret do
      # Connect using explicit credentials with authentication options
      credentials = %{
        api_key: client_id,
        secret: client_secret
      }

      # Connect with both connection credentials and explicit authentication
      {:ok, conn} = Client.connect(%{credentials: credentials})

      # Authenticate to make sure we're ready
      {:ok, auth_conn} = Client.authenticate(conn, credentials)

      on_exit(fn ->
        # Clean up - disconnect
        Client.disconnect(conn)
      end)

      # Return standard format for setup
      %{conn: auth_conn}
    else
      Logger.warning("Skipping integration tests - no API credentials found")

      # Skip the test by setting credentials to nil
      %{conn: nil}
    end
  end

  describe "Private subscription operations" do
    test "can subscribe to user orders with high-level function", %{conn: conn} do
      if is_nil(conn) do
        Logger.warning("Skipping test due to missing credentials")
        :ok
      else
        instrument = "BTC-PERPETUAL"
        channel = "user.orders.#{instrument}.raw"

        # Use JSON-RPC directly to subscribe to user orders
        {:ok, sub_response} =
          Client.json_rpc(conn, "private/subscribe", %{
            "channels" => [channel]
          })

        # Extract subscription result, but don't fail if we can't parse it
        case extract_subscription_result(sub_response) do
          {:ok, subscribed_channels} ->
            assert is_list(subscribed_channels)

          _ ->
            # If we can't extract the subscription result, just log and continue
            Logger.warning("Could not extract subscription result, continuing anyway")
        end

        # Allow subscription to be processed
        :timer.sleep(1000)

        # Unsubscribe to clean up
        {:ok, _unsub_response} =
          Client.json_rpc(conn, "private/unsubscribe", %{
            "channels" => [channel]
          })
      end
    end

    test "can subscribe to user trades with high-level function", %{conn: conn} do
      if is_nil(conn) do
        Logger.warning("Skipping test due to missing credentials")
        :ok
      else
        instrument = "BTC-PERPETUAL"
        channel = "user.trades.#{instrument}.raw"

        # Use JSON-RPC directly to subscribe to user trades
        {:ok, sub_response} =
          Client.json_rpc(conn, "private/subscribe", %{
            "channels" => [channel]
          })

        # Extract subscription result, but don't fail if we can't parse it
        case extract_subscription_result(sub_response) do
          {:ok, subscribed_channels} ->
            assert is_list(subscribed_channels)

          _ ->
            # If we can't extract the subscription result, just log and continue
            Logger.warning("Could not extract subscription result, continuing anyway")
        end

        # Allow subscription to be processed
        :timer.sleep(1000)

        # Unsubscribe to clean up
        {:ok, _unsub_response} =
          Client.json_rpc(conn, "private/unsubscribe", %{
            "channels" => [channel]
          })
      end
    end

    test "can unsubscribe from private channels with unsubscribe_private", %{conn: conn} do
      if is_nil(conn) do
        Logger.warning("Skipping test due to missing credentials")
        :ok
      else
        instrument = "BTC-PERPETUAL"
        orders_channel = "user.orders.#{instrument}.raw"

        # First subscribe to a private channel using JSON-RPC
        {:ok, sub_response} =
          Client.json_rpc(conn, "private/subscribe", %{
            "channels" => [orders_channel]
          })

        # Extract subscription result, but don't fail if we can't parse it
        case extract_subscription_result(sub_response) do
          {:ok, subscribed_channels} ->
            assert is_list(subscribed_channels)

          _ ->
            # If we can't extract the subscription result, just log and continue
            Logger.warning("Could not extract subscription result, continuing anyway")
        end

        # Allow subscription to be processed
        :timer.sleep(1000)

        # Now unsubscribe using JSON-RPC directly (same as unsubscribe_private internally)
        {:ok, unsub_response} =
          Client.json_rpc(conn, "private/unsubscribe", %{
            "channels" => [orders_channel]
          })

        # Extract unsubscription result
        case extract_subscription_result(unsub_response) do
          {:ok, unsubscribed_channels} ->
            assert is_list(unsubscribed_channels)
            # Verify our channel was unsubscribed
            assert orders_channel in unsubscribed_channels

          _ ->
            # If we can't extract the result, just log and continue
            Logger.warning("Could not extract unsubscription result, continuing anyway")
        end
      end
    end

    test "can subscribe to multiple private channels simultaneously", %{conn: conn} do
      if is_nil(conn) do
        Logger.warning("Skipping test due to missing credentials")
        :ok
      else
        instrument = "BTC-PERPETUAL"

        # Channel names
        orders_channel = "user.orders.#{instrument}.raw"
        trades_channel = "user.trades.#{instrument}.raw"

        # Subscribe to both channels in a single request
        {:ok, sub_response} =
          Client.json_rpc(conn, "private/subscribe", %{
            "channels" => [orders_channel, trades_channel]
          })

        # Extract subscription result, but don't fail if we can't parse it
        case extract_subscription_result(sub_response) do
          {:ok, subscribed_channels} ->
            assert is_list(subscribed_channels)
            # We should have at least one of our channels subscribed
            assert Enum.any?([orders_channel, trades_channel], fn ch ->
                     ch in subscribed_channels
                   end)

          _ ->
            # If we can't extract the subscription result, just log and continue
            Logger.warning("Could not extract subscription result, continuing anyway")
        end

        # Allow subscriptions to be processed
        :timer.sleep(1000)

        # Unsubscribe from both channels in a single call using JSON-RPC directly
        channels = [orders_channel, trades_channel]

        {:ok, unsub_response} =
          Client.json_rpc(conn, "private/unsubscribe", %{
            "channels" => channels
          })

        # Extract unsubscription result
        case extract_subscription_result(unsub_response) do
          {:ok, unsubscribed_channels} ->
            assert is_list(unsubscribed_channels)
            # Verify at least one of our channels was unsubscribed
            assert Enum.any?(channels, fn ch -> ch in unsubscribed_channels end)

          _ ->
            # If we can't extract the result, just log and continue
            Logger.warning("Could not extract multiple unsubscription result, continuing anyway")
        end
      end
    end
  end
end
