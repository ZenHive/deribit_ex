defmodule DeribitEx.TokenManagerTest do
  use ExUnit.Case, async: true

  alias DeribitEx.OrderContext
  alias DeribitEx.ResubscriptionHandler
  alias DeribitEx.SessionContext
  alias DeribitEx.TokenManager

  # Mock client for resubscription testing
  defmodule MockClient do
    @moduledoc false
    def subscribe(_conn, _channel, _params) do
      {:ok, "subscription_id"}
    end
  end

  describe "new/1" do
    test "creates a new TokenManager instance" do
      manager = TokenManager.new()

      assert manager.session == nil
      assert %OrderContext{} = manager.orders
      assert %ResubscriptionHandler{} = manager.resubscription
    end

    test "accepts options for resubscription" do
      manager = TokenManager.new(max_retries: 5)

      assert manager.resubscription.max_retries == 5
    end
  end

  describe "init_from_auth/3" do
    test "initializes token manager from auth response" do
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900,
        "scope" => "connection"
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Should create a session
      assert %SessionContext{} = initialized.session
      assert initialized.session.access_token == "test_token"
      assert initialized.session.refresh_token == "test_refresh"
      assert initialized.session.scope == "connection"
    end
  end

  describe "handle_exchange_token/3" do
    test "handles token exchange for subaccount switching" do
      # Create initialized manager
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "initial_token",
        "refresh_token" => "initial_refresh",
        "expires_in" => 900,
        "scope" => "connection"
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Capture initial session ID
      initial_session_id = initialized.session.id

      # Perform token exchange
      exchange_data = %{
        "access_token" => "exchanged_token",
        "refresh_token" => "exchanged_refresh",
        "expires_in" => 900,
        "scope" => "connection mainaccount"
      }

      subject_id = 123

      {:ok, updated} = TokenManager.handle_exchange_token(initialized, exchange_data, subject_id)

      # Session should be updated
      assert updated.session.access_token == "exchanged_token"
      assert updated.session.refresh_token == "exchanged_refresh"
      assert updated.session.subject_id == 123

      # Session transition should be tracked
      assert updated.session.prev_id == initial_session_id
      assert updated.session.transition == :exchange

      # Resubscription handler should be notified
      assert updated.resubscription.resubscribe_after_auth == true
    end

    test "returns error without active session" do
      manager = TokenManager.new()

      exchange_data = %{
        "access_token" => "exchanged_token",
        "refresh_token" => "exchanged_refresh",
        "expires_in" => 900
      }

      result = TokenManager.handle_exchange_token(manager, exchange_data, 123)

      assert result == {:error, :no_active_session}
    end
  end

  describe "handle_fork_token/3" do
    test "handles token forking for named sessions" do
      # Create initialized manager
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "initial_token",
        "refresh_token" => "initial_refresh",
        "expires_in" => 900,
        "scope" => "connection"
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data, subject_id: 123)

      # Capture initial session ID
      initial_session_id = initialized.session.id

      # Perform token fork
      fork_data = %{
        "access_token" => "forked_token",
        "refresh_token" => "forked_refresh",
        "expires_in" => 900,
        "scope" => "session:named_session mainaccount"
      }

      session_name = "forked_session"

      {:ok, updated} = TokenManager.handle_fork_token(initialized, fork_data, session_name)

      # Session should be updated
      assert updated.session.access_token == "forked_token"
      assert updated.session.refresh_token == "forked_refresh"
      assert updated.session.session_name == "forked_session"

      # Session transition should be tracked
      assert updated.session.prev_id == initial_session_id
      assert updated.session.transition == :fork

      # Subject ID should be preserved
      assert updated.session.subject_id == 123

      # Resubscription handler should be notified
      assert updated.resubscription.resubscribe_after_auth == true
    end

    test "returns error without active session" do
      manager = TokenManager.new()

      fork_data = %{
        "access_token" => "forked_token",
        "refresh_token" => "forked_refresh",
        "expires_in" => 900
      }

      result = TokenManager.handle_fork_token(manager, fork_data, "test_session")

      assert result == {:error, :no_active_session}
    end
  end

  describe "handle_token_refresh/2" do
    test "updates session with refreshed token data" do
      # Create initialized manager
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "initial_token",
        "refresh_token" => "initial_refresh",
        "expires_in" => 900,
        "scope" => "connection"
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Capture initial session ID
      initial_session_id = initialized.session.id

      # Perform token refresh
      refresh_data = %{
        "access_token" => "refreshed_token",
        "refresh_token" => "refreshed_refresh",
        "expires_in" => 900
      }

      {:ok, updated} = TokenManager.handle_token_refresh(initialized, refresh_data)

      # Session should be updated with new tokens
      assert updated.session.access_token == "refreshed_token"
      assert updated.session.refresh_token == "refreshed_refresh"

      # Session ID should remain the same (no transition)
      assert updated.session.id == initial_session_id
      assert updated.session.transition == :refresh
    end

    test "returns error without active session" do
      manager = TokenManager.new()

      refresh_data = %{
        "access_token" => "refreshed_token",
        "refresh_token" => "refreshed_refresh",
        "expires_in" => 900
      }

      result = TokenManager.handle_token_refresh(manager, refresh_data)

      assert result == {:error, :no_active_session}
    end
  end

  describe "handle_logout/1" do
    test "invalidates session" do
      # Create initialized manager
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Initially the session should be active
      assert initialized.session.active == true

      # Perform logout
      {:ok, updated} = TokenManager.handle_logout(initialized)

      # Session should be invalidated
      assert updated.session.active == false
    end

    test "handles logout without active session" do
      manager = TokenManager.new()

      # Should not error
      {:ok, updated} = TokenManager.handle_logout(manager)

      assert updated == manager
    end
  end

  describe "register_subscription/3" do
    test "registers subscription with resubscription handler" do
      # Create initialized manager
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Register subscription
      channel = "ticker.BTC-PERPETUAL.100ms"
      params = %{interval: "100ms"}

      {:ok, updated} = TokenManager.register_subscription(initialized, channel, params)

      # Subscription should be tracked in resubscription handler
      assert Map.has_key?(updated.resubscription.channels, channel)
      assert updated.resubscription.channels[channel] == params
    end

    test "returns error without active session" do
      manager = TokenManager.new()

      result = TokenManager.register_subscription(manager, "test_channel", %{})

      assert result == {:error, :no_active_session}
    end
  end

  describe "unregister_subscription/2" do
    test "removes subscription from resubscription handler" do
      # Create initialized manager with subscription
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      channel = "ticker.BTC-PERPETUAL.100ms"
      {:ok, with_sub} = TokenManager.register_subscription(initialized, channel, %{})

      # Verify subscription was registered
      assert Map.has_key?(with_sub.resubscription.channels, channel)

      # Unregister subscription
      {:ok, updated} = TokenManager.unregister_subscription(with_sub, channel)

      # Subscription should be removed
      refute Map.has_key?(updated.resubscription.channels, channel)
    end
  end

  describe "register_order/2" do
    test "registers order with order context" do
      # Create initialized manager
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Register order
      order = %{
        "order_id" => "ETH-123456",
        "instrument_name" => "ETH-PERPETUAL",
        "direction" => "buy",
        "order_state" => "open"
      }

      {:ok, updated} = TokenManager.register_order(initialized, order)

      # Order should be tracked in order context
      assert Map.has_key?(updated.orders.orders, "ETH-123456")

      # Order should be associated with current session
      session_id = initialized.session.id
      assert "ETH-123456" in Map.get(updated.orders.orders_by_session, session_id, [])
    end

    test "returns error without active session" do
      manager = TokenManager.new()

      order = %{"order_id" => "ETH-123456"}

      result = TokenManager.register_order(manager, order)

      assert result == {:error, :no_active_session}
    end
  end

  describe "update_order/2" do
    test "updates existing order in order context" do
      # Create initialized manager with order
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      order = %{
        "order_id" => "ETH-123456",
        "instrument_name" => "ETH-PERPETUAL",
        "direction" => "buy",
        "order_state" => "open"
      }

      {:ok, with_order} = TokenManager.register_order(initialized, order)

      # Update order
      updated_order = %{
        "order_id" => "ETH-123456",
        "order_state" => "filled"
      }

      {:ok, with_updated_order} = TokenManager.update_order(with_order, updated_order)

      # Order status should be updated
      assert with_updated_order.orders.orders["ETH-123456"].status == "filled"
    end

    test "returns error for non-existent order" do
      # Create initialized manager
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Try to update non-existent order
      unknown_order = %{
        "order_id" => "NONEXISTENT",
        "order_state" => "filled"
      }

      result = TokenManager.update_order(initialized, unknown_order)

      assert result == {:error, :not_found}
    end
  end

  describe "perform_resubscription/2" do
    # Note: Instead of using mocks, this test now skips the actual resubscription
    # operation since it would require a live connection to test.deribit.com
    test "handles empty resubscribe state" do
      # Create a manager with no resubscribe flag set
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Add subscriptions but don't set resubscribe flag
      {:ok, with_sub1} =
        TokenManager.register_subscription(
          initialized,
          "ticker.BTC-PERPETUAL.100ms",
          %{}
        )

      {:ok, with_subs} =
        TokenManager.register_subscription(
          with_sub1,
          "orderbook.BTC-PERPETUAL.100ms",
          %{depth: 10}
        )

      # Without the resubscribe flag, perform_resubscription should return empty results
      # Just use any process ID as the mock connection
      conn = self()

      {:ok, updated, results} = TokenManager.perform_resubscription(with_subs, conn)

      # Manager should be unchanged
      assert updated == with_subs

      # No results when resubscribe_after_auth is false
      assert results == %{}
    end

    test "sets up resubscription when session transition occurs" do
      # Create manager with session
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Add subscriptions
      {:ok, with_sub1} =
        TokenManager.register_subscription(
          initialized,
          "ticker.BTC-PERPETUAL.100ms",
          %{}
        )

      {:ok, with_subs} =
        TokenManager.register_subscription(
          with_sub1,
          "orderbook.BTC-PERPETUAL.100ms",
          %{depth: 10}
        )

      # Create a new session via token exchange
      exchange_data = %{
        "access_token" => "new_token",
        "refresh_token" => "new_refresh",
        "expires_in" => 900
      }

      # This should trigger the resubscription flag to be set
      {:ok, after_exchange} =
        TokenManager.handle_exchange_token(
          with_subs,
          exchange_data,
          123
        )

      # Verify the resubscription flag is set after token exchange
      assert after_exchange.resubscription.resubscribe_after_auth == true

      # Channels should still be tracked
      assert map_size(after_exchange.resubscription.channels) == 2
      assert Map.has_key?(after_exchange.resubscription.channels, "ticker.BTC-PERPETUAL.100ms")
      assert Map.has_key?(after_exchange.resubscription.channels, "orderbook.BTC-PERPETUAL.100ms")
    end
  end

  describe "get_session_id/1" do
    test "returns current session ID when available" do
      # Create initialized manager
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Get session ID
      {:ok, session_id} = TokenManager.get_session_id(initialized)

      assert session_id == initialized.session.id
    end

    test "returns error without active session" do
      manager = TokenManager.new()

      result = TokenManager.get_session_id(manager)

      assert result == {:error, :no_active_session}
    end

    test "returns error with inactive session" do
      # Create initialized manager
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Invalidate session
      {:ok, with_inactive} = TokenManager.handle_logout(initialized)

      # Try to get session ID
      result = TokenManager.get_session_id(with_inactive)

      assert result == {:error, :no_active_session}
    end
  end

  describe "get_active_orders/1" do
    test "returns active orders for current session" do
      # Create initialized manager
      manager = TokenManager.new()

      auth_data = %{
        "access_token" => "test_token",
        "refresh_token" => "test_refresh",
        "expires_in" => 900
      }

      {:ok, initialized} = TokenManager.init_from_auth(manager, auth_data)

      # Add orders
      open_order = %{
        "order_id" => "ETH-123",
        "instrument_name" => "ETH-PERPETUAL",
        "direction" => "buy",
        "order_state" => "open"
      }

      filled_order = %{
        "order_id" => "BTC-456",
        "instrument_name" => "BTC-PERPETUAL",
        "direction" => "sell",
        "order_state" => "filled"
      }

      {:ok, with_order1} = TokenManager.register_order(initialized, open_order)
      {:ok, with_orders} = TokenManager.register_order(with_order1, filled_order)

      # Get active orders
      {:ok, active_orders} = TokenManager.get_active_orders(with_orders)

      # Should only include open orders
      assert length(active_orders) == 1
      assert hd(active_orders).order_id == "ETH-123"
    end

    test "returns error without active session" do
      manager = TokenManager.new()

      result = TokenManager.get_active_orders(manager)

      assert result == {:error, :no_active_session}
    end
  end
end
